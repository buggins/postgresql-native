/++
Query results: column descriptions, rows, and the streamed result range.

Rows are read from the connection as the range advances, so a large result
never sits in memory as a whole. A result holds its connection until it is
read to the end or closed.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.result;

import postgresql.connection : Connection;
import postgresql.exception : ClientException, ProtocolException;
import postgresql.protocol.messages : MessageBody;

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
One row of a result. Values are kept as the server sent them; for now (text
format) `getString` returns them as `psql` prints them.
+/
struct Row
{
    private const(ColumnInfo)[] columns_;
    private immutable(ubyte)[][] values;
    private bool[] nulls;

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

    /// Whether the value in column `index` is NULL.
    bool isNull(size_t index) const
    {
        check(index);
        return nulls[index];
    }

    /// ditto
    bool isNull(string name) const
    {
        return isNull(columnIndex(name));
    }

    /++
    The value in column `index` as text; null for NULL.

    Throws: `ClientException` for an invalid index, or a binary value (P2 brings typed getters).
    +/
    string getString(size_t index) const
    {
        check(index);
        if (nulls[index])
            return null;
        if (columns_[index].format != ValueFormat.text)
            throw new ClientException("Column " ~ columns_[index].name ~ " is in binary format");
        return cast(string) values[index];
    }

    /// ditto
    string getString(string name) const
    {
        return getString(columnIndex(name));
    }

    /// The raw bytes of the value in column `index`, as sent by the server; null for NULL.
    immutable(ubyte)[] getRaw(size_t index) const
    {
        check(index);
        return nulls[index] ? null : values[index];
    }

    /++
    The index of the first column named `name`.

    Throws: `ClientException` if there is none.
    +/
    size_t columnIndex(string name) const
    {
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

/// Parses a DataRow body into a `Row` for `columns`.
package Row parseDataRow(MessageBody body, const(ColumnInfo)[] columns)
{
    const count = body.readInt16();
    if (count != columns.length)
        throw new ProtocolException("DataRow has a different number of values than the row description");
    Row row;
    row.columns_ = columns;
    row.values = new immutable(ubyte)[][count];
    row.nulls = new bool[count];
    foreach (i; 0 .. count)
    {
        const length = body.readInt32();
        if (length == -1)
            row.nulls[i] = true;
        else if (length < 0)
            throw new ProtocolException("Invalid value length");
        else
            row.values[i] = body.readBytes(length).idup;
    }
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
    auto row = parseDataRow(MessageBody(data, 'D'), columns);
    assert(row.getString(0) == "42" && row.getString("id") == "42" && row.isNull("name") && row.getString(1) is null);
    assertThrown!ClientException(row.getString(2));
    assertThrown!ClientException(row.getString("nope"));
    assertThrown!ProtocolException(parseDataRow(MessageBody(data[0 .. 7], 'D'), columns));
    assertThrown!ProtocolException(
            parseDataRow(MessageBody(cast(immutable(ubyte)[]) "\x00\x01\x00\x00\x00\x00",
            'D'), columns));
}

/++
The rows of a query, read from the connection as the range advances.

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
    private Row current;
    private bool hasCurrent;
    private bool done; // the server's response has been read up to ReadyForQuery
    private bool rowsDone; // no more rows of this result
    private string tag;

    package this(Connection conn, ColumnInfo[] columns, string tag, bool rowsDone)
    {
        this.conn = conn;
        this.columns_ = columns;
        this.tag = tag;
        this.rowsDone = rowsDone;
        if (rowsDone)
            finish();
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
        if (!done)
        {
            rowsDone = true;
            finish();
        }
    }

    private void advance()
    {
        hasCurrent = false;
        if (rowsDone)
            return;
        conn.nextRow(columns_, current, hasCurrent, tag);
        if (!hasCurrent)
        {
            rowsDone = true;
            finish();
        }
    }

    private void finish()
    {
        done = true;
        conn.finishResponse();
    }
}
