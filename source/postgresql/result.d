/++
Query results: column descriptions, rows, and the streamed result range.

Rows are read from the connection as the range advances, so a large result
never sits in memory as a whole. A result holds its connection until it is
read to the end or closed.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.result;

import dbwire.io.buffer : fromBigEndian;

import postgresql.connection : Connection;
import postgresql.exception : ClientException, ProtocolException;
import postgresql.protocol.messages : MessageBody;
import postgresql.value : Value;
import std.typecons : Rebindable;

import postgresql.types.pgtype : PgType;

@safe:

/// Format of a column's values: text (as `psql` prints them) or the type's binary format.
enum ValueFormat : short
{
    text = 0, ///
    binary = 1, ///
}

/// One column of a result (from RowDescription).
struct ColumnInfo
{
    /// Column name (or the label given with `AS`).
    string name;
    /// OID of the table the column comes from, or 0.
    uint tableOid;
    /// Attribute number of the column in that table, or 0.
    short columnNumber;
    /// OID of the column's data type (e.g. 23 for `int4`, 25 for `text`).
    uint typeOid;
    /// Size of the type in bytes; negative for variable-length types.
    short typeSize;
    /// Type modifier (e.g. `varchar(n)` length + 4, `numeric(p, s)` precision and scale); -1 if none.
    int typeModifier;
    /// Format of the values.
    ValueFormat format;
    /++
    The data type, when the client knows it: built-in types, and for
    `Connection.query` the types of the database (enums, composite types,
    domains, their arrays and ranges, extension types), looked up once per
    connection. Null for other types (read as text).
    +/
    Rebindable!(const(PgType)) type;
}

/// Parses a RowDescription body.
package ColumnInfo[] parseRowDescription(MessageBody body)
{
    const count = body.readInt16();
    if (count < 0)
        throw new ProtocolException("Invalid column count");
    auto columns = new ColumnInfo[count];
    foreach (ref c; columns)
    {
        c.name = body.readCString();
        c.tableOid = cast(uint)
        body.readInt32();
        c.columnNumber = body.readInt16();
        c.typeOid = cast(uint)
        body.readInt32();
        c.typeSize = body.readInt16();
        c.typeModifier = body.readInt32();
        const format = body.readInt16();
        if (format != ValueFormat.text && format != ValueFormat.binary)
            throw new ProtocolException("Invalid column format");
        c.format = cast(ValueFormat) format;
    }
    return columns;
}

/++
One row of a result. `row[i]` and `row["name"]` give a `Value`; the getters
here are shortcuts for the same calls on it (see `postgresql.value.Value`).

The values of a row share one copy of the row's data (rows over 16 KiB copy
each value): a value kept after the row, such as the string of `getString`
or the bytes of `getRaw`, keeps that copy in memory.
+/
struct Row
{
    private const(ColumnInfo)[] columns_;
    private const(immutable(ubyte)[])[] values; // null for NULL; empty values are not null
    private string timeZone;
    private const(ColumnIndex)* names; // for results with many columns

    /// The columns of the result.
    @property const(ColumnInfo)[] columns() const pure nothrow
    {
        return columns_;
    }

    /// Number of values.
    @property size_t length() const pure nothrow
    {
        return values.length;
    }

    /++
    The value in column `index`.

    Throws: `ClientException` for an invalid index.
    +/
    Value opIndex(size_t index) const
    {
        check(index);
        return Value(&columns_[index], values[index], values[index] is null, timeZone);
    }

    /++
    The value in the first column named `name`.

    Throws: `ClientException` if there is no such column.
    +/
    Value opIndex(string name) const
    {
        return this[columnIndex(name)];
    }

    /// Whether the value in a column is NULL.
    bool isNull(size_t index) const
    {
        return this[index].isNull;
    }

    /// ditto
    bool isNull(string name) const
    {
        return this[name].isNull;
    }

    static foreach (getter; [
        "getString", "getBool", "getLong", "getInt", "getDouble", "getDecimal", "getBytes",
        "getDate", "getDateTime", "getSysTime", "getMicrosecondsOfSecond", "getTimeOfDay",
        "getDuration", "getInterval", "getUUID", "getVariant", "getArray", "getRange",
        "getMultirange", "getRecord", "getInet", "getBitString", "getHstore"
    ])
    {
        mixin("/// Shortcut for `this[index]." ~ getter ~ "()` (see `Value`).\n"
                ~ "auto " ~ getter ~ "(size_t index) const { return this[index]." ~ getter ~ "(); }\n"
                ~ "/// ditto\n" ~ "auto " ~ getter ~ "(string name) const { return this[name]." ~ getter ~ "(); }");
    }

    /++
    Shortcut for `this[index].get!T()`: the value converted to `T` (see `Value.get`).
    +/
    T get(T)(size_t index) const
    {
        return this[index].get!T();
    }

    /// ditto
    T get(T)(string name) const
    {
        return this[name].get!T();
    }

    /// The bytes of the value in column `index` as the server sent them; null for NULL.
    immutable(ubyte)[] getRaw(size_t index) const
    {
        return this[index].raw;
    }

    /++
    The index of the first column named `name`.

    Throws: `ClientException` if there is none.
    +/
    size_t columnIndex(string name) const
    {
        if (names !is null)
        {
            if (auto i = name in names.byName)
                return *i;
        }
        else
            foreach (i, c; columns_)
                if (c.name == name)
                    return i;
        throw new ClientException("No column named '" ~ name ~ "'");
    }

    private void check(size_t index) const
    {
        import std.conv : to;

        if (index >= values.length)
            throw new ClientException(
                    "Column index " ~ index.to!string ~ " out of range (" ~ values.length.to!string
                    ~ " columns)");
    }
}

/++
A `Row` of `values` for `columns`: null for NULL; empty values must not be
null (e.g. `""` or an empty slice of a larger array).
+/
package Row makeRow(const(ColumnInfo)[] columns, const(immutable(ubyte)[])[] values, string timeZone)
{
    Row row;
    row.columns_ = columns;
    row.values = values;
    row.timeZone = timeZone;
    return row;
}

/// The column of each name (the first one with it).
package struct ColumnIndex
{
    size_t[string] byName;
}

/// The `ColumnIndex` of `columns` when there are enough of them for it to pay off; else null.
package const(ColumnIndex)* columnNameIndex(const(ColumnInfo)[] columns)
{
    if (columns.length < 32)
        return null; // a few string comparisons are cheaper than building it
    auto index = new ColumnIndex;
    foreach_reverse (i, c; columns)
        index.byName[c.name] = i;
    return index;
}

/++
Parses a DataRow body into a `Row` for `columns`. A row up to 16 KiB is
copied at once and its values are slices of the copy (a value kept longer
keeps that row's memory); a larger row, which has a large value, copies each
value on its own, so that keeping a small one doesn't keep the large one.
+/
package Row parseDataRow(scope const(ubyte)[] body, const(ColumnInfo)[] columns, string timeZone,
        const(ColumnIndex)* names)
{
    static immutable ubyte[1] none;
    if (body.length < 2 || (body[0] << 8 | body[1]) != columns.length)
        throw new ProtocolException("DataRow has a different number of values than the row description");
    const separate = body.length > 16 * 1024;
    const copy = separate ? null : body.idup;
    auto values = new immutable(ubyte)[][columns.length];
    size_t at = 2;
    foreach (ref v; values)
    {
        if (body.length - at < 4)
            throw new ProtocolException("Truncated DataRow");
        const length = fromBigEndian!int(body[at .. $][0 .. 4]);
        at += 4;
        if (length == -1)
            continue; // NULL: a null slice
        if (length < 0 || length > body.length - at)
            throw new ProtocolException("Invalid value length");
        // not null even when empty: `copy` holds at least the count
        v = !separate ? copy[at .. at + length] : length ? body[at .. at + length].idup : none[0 .. 0];
        at += length;
    }
    Row row;
    row.columns_ = columns;
    row.values = values;
    row.timeZone = timeZone;
    row.names = names;
    return row;
}

unittest
{
    import std.exception : assertThrown;

    static immutable ubyte[] desc = cast(immutable(ubyte)[])("\x00\x02" ~ "id\0" ~ "\x00\x00\x40\x00\x00\x01"
            ~ "\x00\x00\x00\x17\x00\x04\xFF\xFF\xFF\xFF\x00\x00" ~ "name\0" ~ "\x00\x00\x00\x00\x00\x00"
            ~ "\x00\x00\x00\x19\xFF\xFF\xFF\xFF\xFF\xFF\x00\x00");
    auto columns = parseRowDescription(MessageBody(desc, 'T'));
    assert(columns.length == 2 && columns[0].name == "id" && columns[0].typeOid == 23 && columns[0].tableOid == 0x4000);
    assert(columns[0].columnNumber == 1 && columns[1].typeSize == -1 && columns[1].typeModifier == -1);

    static immutable ubyte[] data = cast(immutable(ubyte)[]) "\x00\x02\x00\x00\x00\x0242\xFF\xFF\xFF\xFF";
    auto row = parseDataRow(data, columns, null, null);
    assert(row.getString(0) == "42" && row.getString("id") == "42" && row.isNull("name") && row.getString(1) is null);
    assertThrown!ClientException(row.getString(2));
    assertThrown!ClientException(row.getString("nope"));
    assertThrown!ProtocolException(parseDataRow(data[0 .. 7], columns, null, null));
    assertThrown!ProtocolException(parseDataRow(data[0 .. 1], columns, null, null));
    assertThrown!ProtocolException(parseDataRow(cast(immutable(ubyte)[]) "\x00\x01\x00\x00\x00\x00", columns,
            null, null));
    assertThrown!ProtocolException(parseDataRow(cast(immutable(ubyte)[]) "\x00\x02\x00\x00\x00\x05ab", columns,
            null, null));

    // an empty value is not NULL
    row = parseDataRow(cast(immutable(ubyte)[]) "\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00", columns, null,
            null);
    assert(!row.isNull(0) && row.getString(0) == "" && row.getRaw(0) !is null);

    // a large row: each value copied on its own (an empty one still not NULL)
    immutable(ubyte)[] large = cast(immutable(ubyte)[]) "\x00\x02\x00\x00\x00\x00\x00\x00\x50\x00";
    large ~= new immutable(ubyte)[0x5000];
    row = parseDataRow(large, columns, null, null);
    assert(!row.isNull(0) && row.getRaw(0) !is null && row.getRaw(1).length == 0x5000);

    // many columns: by name through an index; the first column of a name wins
    import std.conv : to;

    auto wide = new ColumnInfo[40];
    foreach (i, ref c; wide)
        c.name = i == 39 ? "c3" : "c" ~ i.to!string;
    immutable(ubyte)[] values = [0, 40];
    foreach (i; 0 .. 40)
        values ~= [0, 0, 0, 1, cast(ubyte)('0' + i % 10)];
    row = parseDataRow(values, wide, null, columnNameIndex(wide));
    assert(row.getString("c7") == "7" && row.getString("c3") == "3" && row.columnIndex("c0") == 0);
    assertThrown!ClientException(row.getString("c40"));
    assert(columnNameIndex(columns) is null);

    // rows copy out of const ones, and assign
    const(Row) constant = row;
    Row copy = constant;
    copy = constant;
    assert(copy.getString("c7") == "7");
}

/++
The rows of a query, read from the connection as the range advances.

Typed getters are on each row (`Row`, `postgresql.value.Value`).

The connection is busy until the range is empty or `close` is called; then
the rest of the server's response (further statements of a multi-statement
query included) is read and discarded. A server error in the middle of the
rows is thrown by `empty`/`popFront` after the response has been read to its
end, so the connection stays usable.
+/
final class QueryResult
{
    private Connection conn;
    private ColumnInfo[] columns_;
    private const(ColumnIndex)* names; // see columnNameIndex
    private Row current;
    private bool hasCurrent;
    private bool done; // the server's response has been read up to ReadyForQuery
    private bool rowsDone; // no more rows of this result
    private string tag;
    private string timeZone;
    private ColumnInfo[] nextColumns; // the next result of a multi-statement query, already described
    private bool hasNext;

    package this(Connection conn, ColumnInfo[] columns, string tag, bool rowsDone)
    {
        this.conn = conn;
        this.timeZone = conn.parameterStatus("TimeZone");
        this.columns_ = columns;
        this.names = columnNameIndex(columns);
        this.tag = tag;
        this.rowsDone = rowsDone;
        if (rowsDone)
        {
            if (conn.nextResult(nextColumns))
                hasNext = true;
            else
                finish();
        }
        else
            advance();
    }

    /// The columns; empty for a statement that returns no rows.
    @property const(ColumnInfo)[] columns() const pure nothrow
    {
        return columns_;
    }

    /// Whether there are no more rows.
    @property bool empty() const pure nothrow
    {
        return !hasCurrent;
    }

    /// The current row.
    @property ref const(Row) front() const
    {
        if (!hasCurrent)
            throw new ClientException("No current row: the result is empty");
        return current;
    }

    /// Moves to the next row.
    void popFront()
    {
        if (!hasCurrent)
            throw new ClientException("No current row: the result is empty");
        advance();
    }

    /++
    The command tag of the statement once all rows are read (e.g. `SELECT 3`),
    or null before.
    +/
    @property string commandTag() const pure nothrow
    {
        return rowsDone ? tag : null;
    }

    /// Reads and discards the rest of the result, freeing the connection. Calling it again does nothing.
    void close()
    {
        hasCurrent = false;
        hasNext = false;
        if (!done)
        {
            rowsDone = true;
            finish();
        }
    }

    /++
    Moves to the rows of the next statement of a multi-statement query
    (`Connection.querySimple`), once the current rows are read: returns
    false when there are no more statements with rows. Statements without
    rows in between are skipped. The connection stays busy while another
    result may follow.

    Throws: `ClientException` if the current rows aren't all read yet.
    +/
    bool nextResult()
    {
        if (hasCurrent)
            throw new ClientException("Read the rows of the current result before moving to the next one");
        if (!hasNext)
            return false;
        hasNext = false;
        columns_ = nextColumns;
        names = columnNameIndex(columns_);
        nextColumns = null;
        tag = null;
        rowsDone = false;
        advance();
        return true;
    }

    // Reads past the rest of the rows (for their command tag) without decoding them.
    package void skipRows()
    {
        hasCurrent = false;
        if (rowsDone)
            return;
        conn.skipRows(current, tag);
        rowsDone = true;
        if (conn.nextResult(nextColumns))
            hasNext = true;
        else
            finish();
    }

    private void advance()
    {
        hasCurrent = false;
        if (rowsDone)
            return;
        conn.nextRow(columns_, timeZone, names, current, hasCurrent, tag);
        if (!hasCurrent)
        {
            rowsDone = true;
            if (conn.nextResult(nextColumns))
                hasNext = true; // the connection stays busy for it
            else
                finish();
        }
    }

    private void finish()
    {
        done = true;
        conn.finishResponse();
    }
}
