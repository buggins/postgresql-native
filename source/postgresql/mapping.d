/++
Struct mapping: rows read into structs, structs inserted as rows.

Fields map to columns by name: a column with exactly the field's name, else
one whose name differs only in case. `@column("name")` gives a field another
column name and `@ignore` leaves it out. Result columns without a field are
ignored.

Field types: those `Value.get` reads: `bool`, integers, `float`/`double`,
`string`, `ubyte[]`, `Decimal`, `Date`, `TimeOfDay`, `DateTime`, `SysTime`,
`Duration`, `Interval`, `UUID`, `Variant`, enums (from numbers, or from text
and PostgreSQL enum columns holding their member names), D arrays (from
arrays), `Range!T`, `Inet`, `BitString`, the geometric types, structs (from
composite values), `string[string]` (from `hstore`), and `Nullable!T` of
these. A NULL read into a field that can't hold it (anything but `string`,
`ubyte[]`, arrays, `Variant` and `Nullable!T`) throws `ClientException`, as
the `Value` getters do.

Example:
---
struct Order
{
    int id;
    @column("customer_name") string customer;
    Decimal amount;
    Nullable!DateTime shipped;
    @ignore string note;
}

conn.insert("orders", [Order(1, "Ann", Decimal.fromString("9.90"))]);
foreach (o; conn.query!Order("SELECT * FROM orders WHERE amount > ?", 5))
    writeln(o.customer, " ", o.amount);
auto total = conn.queryValue!long("SELECT count(*) FROM orders");
---

The templates infer their attributes (`Variant` copies are `@system`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.mapping;

import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.traits : FieldNameTuple, getUDAs, hasUDA, isFloatingPoint, isIntegral, isSomeString, OriginalType,
    Unqual;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;

import dbwire.types.decimal : Decimal;

import postgresql.exception : ClientException;
import postgresql.params : integerText, putParam;
import postgresql.protocol.messages : MessageBuilder;
import postgresql.result : QueryResult;
import postgresql.types.oids : Oid;
import postgresql.types.temporal : Interval;
import postgresql.value : Value;

public import postgresql.attributes : column, ColumnName, columnNames, ignore, IgnoreField, mappedFields;

/// Whether a mapped field of `T` is a `Variant`, whose copies are `@system`.
template hasVariantField(T) if (is(T == struct))
{
    enum hasVariantField = () {
        bool found;
        static foreach (name; mappedFields!T)
        {
            static if (is(Unqual!(typeof(__traits(getMember, T, name))) == Variant))
                found = true;
        }
        return found;
    }();
}

/++
`v` converted to the field type `T`: `v.get!T` (see `Value.get` and the module documentation).

Throws: `ClientException` if the column's type can't be converted to `T`,
the value doesn't fit, or it is NULL and `T` can't hold NULL.
+/
T readValue(T)(const Value v)
{
    return v.get!T();
}

/++
For each mapped field of `T`, the index of its column in `result`: the
column with exactly that name, else the first whose name differs only in case.

Throws: `ClientException` (after closing the result, so the connection is
released) if a field has no column.
+/
size_t[] fieldPositions(T)(QueryResult result)
{
    import std.uni : icmp;

    enum names = columnNames!T;
    auto positions = new size_t[names.length];
    foreach (i, name; names)
    {
        ptrdiff_t found = -1;
        foreach (c, col; result.columns)
            if (col.name == name)
            {
                found = c;
                break;
            }
        if (found < 0)
            foreach (c, col; result.columns)
                if (icmp(col.name, name) == 0)
                {
                    found = c;
                    break;
                }
        if (found < 0)
        {
            result.close();
            throw new ClientException(
                    "The result has no column '" ~ name ~ "' for field " ~ T.stringof ~ "."
                    ~ mappedFields!T[i]);
        }
        positions[i] = found;
    }
    return positions;
}

/// The current row of `result` as a `T`, with the columns at `positions` (from `fieldPositions`).
T readStruct(T)(QueryResult result, const size_t[] positions)
{
    T value;
    const row = result.front;
    static foreach (i, name; mappedFields!T)
    {
        try
            __traits(getMember, value, name) = readValue!(typeof(__traits(getMember, T, name)))(
                    row[positions[i]]);
        catch (ClientException e)
            throw new ClientException(T.stringof ~ "." ~ name ~ ": " ~ e.msg);
    }
    return value;
}

/++
The rows of a result as `T`s: an input range (`Connection.query!T`). Like the
result, it holds the connection until all rows are read or `close` is called.
+/
struct RowRange(T) if (is(T == struct))
{
    private QueryResult result;
    private size_t[] positions;

    /// Maps the rows of `result`; closes it if a field has no column.
    this(QueryResult result)
    {
        this.result = result;
        try
            positions = fieldPositions!T(result);
        catch (Exception e)
        {
            closeAfterError();
            throw e;
        }
    }

    /// Whether there are no more rows.
    @property bool empty()
    {
        return result.empty;
    }

    /++
    The current row.

    Throws: `ClientException` if a value can't be read into its field; the
    result is closed then, so the connection is free again.
    +/
    @property T front()
    {
        try
            return readStruct!T(result, positions);
        catch (Exception e)
        {
            closeAfterError();
            throw e;
        }
    }

    /// Moves to the next row.
    void popFront()
    {
        result.popFront();
    }

    /// Releases the connection; remaining rows are discarded.
    void close()
    {
        result.close();
    }

    // Closes the result after a mapping error, which is the one reported.
    private void closeAfterError() nothrow
    {
        try
            result.close();
        catch (Exception)
        {
        }
    }

    /// The underlying result (columns, command tag).
    @property QueryResult queryResult()
    {
        return result;
    }
}

/++
`name` as a column name in SQL. A name of letters, digits and `_` (not
starting with a digit) is folded to lower case, as PostgreSQL folds
unquoted names, and quoted (so names like `user` or `order` work);
other names are quoted as they are.
+/
string sqlColumnName(string name) @safe pure
{
    import std.ascii : isAlpha, isAlphaNum;
    import std.string : toLower;
    import postgresql.settings : quoteIdentifier;

    bool plain = name.length > 0 && (isAlpha(name[0]) || name[0] == '_');
    foreach (c; name)
        plain = plain && (isAlphaNum(c) || c == '_');
    return quoteIdentifier(plain ? name.toLower : name);
}

///
@safe unittest
{
    assert(sqlColumnName("customerName") == `"customername"` && sqlColumnName("user") == `"user"`);
    assert(sqlColumnName("Order Date") == `"Order Date"`);
}

/++
The SQL of a multi-row insert of `rows` rows of `T` into `table`:
`INSERT INTO table (cols) VALUES ($1, $2), ($3, $4), ...`.
+/
package string insertSql(T)(string table, size_t rows)
{
    import std.array : appender;
    import std.conv : to;

    enum columns = columnNames!T;
    auto sql = appender!string;
    sql ~= "INSERT INTO ";
    sql ~= table;
    sql ~= " (";
    foreach (i, c; columns)
    {
        if (i)
            sql ~= ", ";
        sql ~= sqlColumnName(c);
    }
    sql ~= ") VALUES ";
    sql.reserve(sql.data.length + rows * columns.length * 8);
    size_t n;
    char[20] digits;
    foreach (r; 0 .. rows)
    {
        sql ~= r ? ", (" : "(";
        foreach (c; 0 .. columns.length)
        {
            if (c)
                sql ~= ", ";
            sql ~= "$";
            sql ~= digits[integerText(++n, digits) .. $];
        }
        sql ~= ")";
    }
    return sql.data;
}

@safe unittest
{
    static struct S
    {
        int id;
        @column("Full Name") string name;
    }

    assert(insertSql!S("t", 2) == `INSERT INTO t ("id", "Full Name") VALUES ($1, $2), ($3, $4)`);
}

/// Rows to insert, encoded for the parameter types of their insert statement.
package final class RowsEncoder(T)
{
    const(T)[] rows;

    /// Empties `rows`, keeping their memory for the next batch.
    void clear() @trusted nothrow
    {
        // the rows of the last batch are no longer used: their memory can take the next ones
        auto memory = cast(T[]) rows;
        memory.length = 0;
        memory.assumeSafeAppend();
        rows = memory;
    }

    static if (hasVariantField!T)
        enum attributes = "@trusted"; // copies of Variant values, which hold plain values
    else
        enum attributes = "@safe";

    mixin("void encode(const(uint)[] types, ref MessageBuilder b) " ~ attributes ~ q{
    {
        import std.conv : to;
        import postgresql.statement : beginParameters, setFormat;

        enum width = mappedFields!T.length;
        if (types.length != rows.length * width)
            throw new ClientException("The insert statement has " ~ types.length.to!string
                ~ " parameter(s), expected " ~ (rows.length * width).to!string);
        const formats = beginParameters(b, types.length);
        size_t i;
        foreach (ref row; rows)
        {
            static foreach (name; mappedFields!T)
            {
                try
                {
                    static if (is(Unqual!(typeof(__traits(getMember, T, name))) == Variant))
                        const format = putParam(b, cast() __traits(getMember, row, name), types[i]); // a copy
                    else
                        const format = putParam(b, __traits(getMember, row, name), types[i]);
                    setFormat(b, formats, i, format);
                }
                catch (ClientException e)
                    throw new ClientException(T.stringof ~ "." ~ name ~ ": " ~ e.msg);
                i++;
            }
        }
    }
    });
}

unittest
{
    import std.exception : assertThrown;
    import postgresql.result : ColumnInfo, ValueFormat;

    Value v(uint oid, immutable(ubyte)[] bytes, ValueFormat format = ValueFormat.binary, bool isNull = false)
    {
        auto c = new ColumnInfo;
        c.typeOid = oid;
        c.format = format;
        return Value(c, bytes, isNull, "UTC");
    }

    enum Color
    {
        red = 1,
        green = 2
    }

    assert(readValue!int(v(Oid.int8, [0, 0, 0, 0, 0, 0, 0, 7])) == 7);
    assertThrown!ClientException(readValue!ubyte(v(Oid.int4, [0, 0, 1, 0])));
    assertThrown!ClientException(readValue!ulong(v(Oid.int4, [0xFF, 0xFF, 0xFF, 0xFF]))); // -1
    assertThrown!ClientException(readValue!uint(v(Oid.int8, [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    ])));
    assert(readValue!Color(v(Oid.int4, [0, 0, 0, 2])) == Color.green);
    assert(readValue!Color(v(Oid.unknown, cast(immutable(ubyte)[]) "red", ValueFormat.text)) == Color.red);
    assert(readValue!Color(v(Oid.text, cast(immutable(ubyte)[]) "2", ValueFormat.text)) == Color.green);
    assertThrown!ClientException(readValue!Color(v(Oid.text, cast(immutable(ubyte)[]) "blue", ValueFormat.text)));
    assert(readValue!(Nullable!int)(v(Oid.int4, null, ValueFormat.binary, true)).isNull);
    assertThrown!ClientException(readValue!int(v(Oid.int4, null, ValueFormat.binary, true)));
    assert(readValue!string(v(Oid.text, null, ValueFormat.binary, true)) is null);
    assert(readValue!ulong(v(Oid.numeric, cast(immutable(ubyte)[]) "18446744073709551615", ValueFormat.text))
            == ulong.max);
    assert(readValue!double(v(Oid.float8, [0x3F, 0xF8, 0, 0, 0, 0, 0, 0])) == 1.5);
    assert(readValue!Date(v(Oid.date, [0, 0, 0x26, 0x4E])) == Date(2026, 11, 6));
}
