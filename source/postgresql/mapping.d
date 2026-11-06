/++
Struct mapping: rows read into structs, structs inserted as rows.

Fields map to columns by name: a column with exactly the field's name, else
one whose name differs only in case. `@column("name")` gives a field another
column name and `@ignore` leaves it out. Result columns without a field are
ignored.

Field types: `bool`, integers, `float`/`double`, `string`, `ubyte[]`,
`Decimal`, `Date`, `TimeOfDay`, `DateTime`, `SysTime`, `Duration`,
`Interval`, `UUID`, `Variant`, enums (from numbers, or from text and
PostgreSQL enum columns holding their member names), and `Nullable!T` of
these. A NULL read into a field that can't hold it (anything but `string`,
`ubyte[]`, `Variant` and `Nullable!T`) throws `ClientException`, as the
`Value` getters do.

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
import postgresql.params : encodeParam, Param;
import postgresql.result : QueryResult;
import postgresql.types.oids : Oid;
import postgresql.types.temporal : Interval;
import postgresql.value : Value;

/// The value of a `@column("name")` attribute.
struct ColumnName
{
    /// The column name.
    string name;
}

/// The type of the `@ignore` attribute.
struct IgnoreField
{
}

/// UDA: maps a field to the column `name` (instead of the field's name).
ColumnName column(string name) @safe pure nothrow
{
    return ColumnName(name);
}

/// UDA: leaves a field out of the mapping.
enum ignore = IgnoreField();

/// The names of the mapped fields of `T` (not `@ignore`d), in field order.
template mappedFields(T) if (is(T == struct))
{
    enum string[] mappedFields = () {
        string[] names;
        static foreach (name; FieldNameTuple!T)
        {
            static if (!hasUDA!(__traits(getMember, T, name), IgnoreField))
                names ~= name;
        }
        return names;
    }();
}

/// The column names of the mapped fields of `T`, in field order.
template columnNames(T) if (is(T == struct))
{
    enum string[] columnNames = () {
        string[] names;
        static foreach (name; mappedFields!T)
        {
            static if (hasUDA!(__traits(getMember, T, name), ColumnName))
                names ~= getUDAs!(__traits(getMember, T, name), ColumnName)[0].name;
            else
                names ~= name;
        }
        return names;
    }();
}

///
@safe unittest
{
    static struct S
    {
        int id;
        @column("full_name") string name;
        @ignore int cache;
    }

    static assert(columnNames!S == ["id", "full_name"]);
}

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
`v` converted to the field type `T` (see the module documentation).

Throws: `ClientException` if the column's type can't be converted to `T`,
the value doesn't fit, or it is NULL and `T` can't hold NULL.
+/
T readValue(T)(const Value v)
{
    import std.conv : ConvException, to;

    alias U = Unqual!T;
    static if (is(U : Nullable!N, N))
        return v.isNull ? T.init : T(readValue!N(v));
    else static if (is(U == Variant))
        return v.getVariant();
    else static if (is(U == enum))
    {
        if (v.isNull)
            throw new ClientException("NULL can't be read as " ~ T.stringof);
        if (isNumericColumn(v))
        {
            const n = v.getLong();
            foreach (member; __traits(allMembers, U))
                if (__traits(getMember, U, member) == n)
                    return __traits(getMember, U, member);
            throw new ClientException(n.to!string ~ " is not a value of " ~ T.stringof);
        }
        // the member's name, or its value (as text)
        const text = v.getString();
        try
            return text.to!U;
        catch (ConvException)
        {
        }
        foreach (member; __traits(allMembers, U))
            if ((cast(OriginalType!U) __traits(getMember, U, member)).to!string == text)
                return __traits(getMember, U, member);
        throw new ClientException("'" ~ text ~ "' is not a value of " ~ T.stringof);
    }
    else static if (is(U == bool))
        return v.getBool();
    else static if (isIntegral!U)
    {
        static if (is(U == ulong))
        {
            if (v.info.typeOid == Oid.numeric && !v.isNull)
            {
                // beyond long: through the decimal text
                try
                    return v.getString().to!ulong;
                catch (ConvException)
                    throw new ClientException("Value " ~ v.getString() ~ " does not fit in ulong");
            }
        }
        const n = v.getLong();
        if (n < U.min || (U.max <= long.max && n > cast(long) U.max))
            throw new ClientException("Value " ~ n.to!string ~ " does not fit in " ~ U.stringof);
        return cast(T) n;
    }
    else static if (isFloatingPoint!U)
        return cast(T) v.getDouble();
    else static if (isSomeString!U)
        return v.getString().to!T;
    else static if (is(U : const(ubyte)[]))
    {
        static if (is(immutable(ubyte)[] : U))
            return v.getBytes();
        else
            return v.getBytes().dup;
    }
    else static if (is(U == Decimal))
        return v.getDecimal();
    else static if (is(U == Date))
        return v.getDate();
    else static if (is(U == TimeOfDay))
        return v.getTimeOfDay();
    else static if (is(U == Duration))
        return v.getDuration();
    else static if (is(U == Interval))
        return v.getInterval();
    else static if (is(U == DateTime))
        return v.getDateTime();
    else static if (is(U == SysTime))
        return v.getSysTime();
    else static if (is(U == UUID))
        return v.getUUID();
    else
        static assert(0, "Fields of type " ~ T.stringof ~ " can't be read");
}

private bool isNumericColumn(const Value v) @safe pure nothrow
{
    switch (v.info.typeOid)
    {
    case Oid.int2, Oid.int4, Oid.int8, Oid.oid, Oid.numeric:
        return true;
    default:
        return false;
    }
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

    /// Maps the rows of `result`.
    this(QueryResult result)
    {
        this.result = result;
        positions = fieldPositions!T(result);
    }

    /// Whether there are no more rows.
    @property bool empty()
    {
        return result.empty;
    }

    /// The current row.
    @property T front()
    {
        return readStruct!T(result, positions);
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
    size_t n;
    foreach (r; 0 .. rows)
    {
        sql ~= r ? ", (" : "(";
        foreach (c; 0 .. columns.length)
        {
            if (c)
                sql ~= ", ";
            sql ~= "$";
            sql ~= (++n).to!string;
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

    static if (hasVariantField!T)
        enum attributes = "@trusted"; // copies of Variant values, which hold plain values
    else
        enum attributes = "@safe";

    mixin("Param[] encode(const(uint)[] types) " ~ attributes ~ q{
    {
        import std.conv : to;

        enum width = mappedFields!T.length;
        if (types.length != rows.length * width)
            throw new ClientException("The insert statement has " ~ types.length.to!string
                ~ " parameter(s), expected " ~ (rows.length * width).to!string);
        Param[] params;
        params.reserve(types.length);
        size_t i;
        foreach (ref row; rows)
        {
            static foreach (name; mappedFields!T)
            {
                try
                {
                    static if (is(Unqual!(typeof(__traits(getMember, T, name))) == Variant))
                        params ~= encodeParam(cast() __traits(getMember, row, name), types[i]); // a copy to encode
                    else
                        params ~= encodeParam(__traits(getMember, row, name), types[i]);
                }
                catch (ClientException e)
                    throw new ClientException(T.stringof ~ "." ~ name ~ ": " ~ e.msg);
                i++;
            }
        }
        return params;
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
