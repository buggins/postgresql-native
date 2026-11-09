/++
An in-memory PostgreSQL server for the benchmarks: a `Transport` that
answers the frontend messages it receives with canned responses, so the
client's own work can be timed without a network or a real server.

It understands the startup packet (trust login), the extended protocol
(Parse, Describe, Bind, Execute, Sync, Flush, Close), simple queries and
COPY in both directions. Parameters have the types `paramTypes`;
statements whose SQL starts with SELECT or VALUES return `rowsPerExecute`
copies of one row of `columns`, in the formats the client asked for.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.fakeserver;

import core.time : Duration;

import dbwire.io.transport : Transport;

/// One result column: its type and its value in both formats (null for NULL).
struct Column
{
    string name; ///
    uint oid; ///
    short size; /// the type size (-1 for variable-length types)
    immutable(ubyte)[] text; ///
    immutable(ubyte)[] binary; ///
    bool isNull; ///
}

/// The fake server.
final class FakeServer : Transport
{
    /// The parameter types, repeated as needed (parameter i has `paramTypes[i % $]`).
    uint[] paramTypes = [23]; // int4
    /// The columns of SELECT results.
    Column[] columns;
    /// Rows per SELECT (Execute with max rows 0, or a simple query).
    size_t rowsPerExecute = 1;
    /// One row of COPY TO STDOUT data (text or CSV; with `copyBinaryRow` for binary).
    immutable(ubyte)[] copyTextRow;
    /// One row of binary COPY TO STDOUT data (after the header).
    immutable(ubyte)[] copyBinaryRow;
    /// Rows per COPY TO STDOUT.
    size_t copyRows;
    /// Columns of COPY data.
    short copyColumns = 5;
    /// Bytes of CopyData received.
    size_t copyBytesReceived;

    private struct Segment
    {
        immutable(ubyte)[] bytes;
        size_t repeat = 1;
        size_t offset;
    }

    private Segment[] output;
    private size_t outputStart;
    private ubyte[] partial;
    private bool started;
    private char txStatus = 'I';
    private string[string] statements;
    private string[string] portals;
    private short[] resultFormats;
    private short[] rowFormats; // of `row`
    private immutable(ubyte)[] row;
    private immutable(ubyte)[] description; // RowDescription of `columns`
    private immutable(ubyte)[][string] descriptions; // by statement name
    private immutable(ubyte)[][size_t][string] completes; // by tag and rows
    private static immutable ubyte[] parseComplete = ['1', 0, 0, 0, 4], bindComplete = [
        '2', 0, 0, 0, 4
    ],
    closeComplete = ['3', 0, 0, 0, 4], noData = ['n', 0, 0, 0, 4], portalSuspended = [
        's', 0, 0, 0, 4
    ],
    readyIdle = ['Z', 0, 0, 0, 5, 'I'], readyInTransaction = ['Z', 0, 0, 0, 5, 'T'];

    override size_t read(scope ubyte[] buffer) @safe
    {
        size_t n;
        while (n < buffer.length && outputStart < output.length)
        {
            auto s = &output[outputStart];
            const chunk = s.bytes.length - s.offset < buffer.length - n ? s.bytes.length - s.offset : buffer.length - n;
            buffer[n .. n + chunk] = s.bytes[s.offset .. s.offset + chunk];
            n += chunk;
            s.offset += chunk;
            if (s.offset == s.bytes.length)
            {
                s.offset = 0;
                if (--s.repeat == 0)
                    outputStart++;
            }
        }
        if (outputStart == output.length)
        {
            output.length = 0;
            (() @trusted => output.assumeSafeAppend())(); // nothing else refers to the old segments
            outputStart = 0;
        }
        return n;
    }

    override void write(scope const(ubyte)[] data) @safe
    {
        partial ~= data;
        size_t at;
        for (;;)
        {
            const typed = started ? 1 : 0;
            if (partial.length - at < typed + 4)
                break;
            const length = int32(partial[at + typed .. $]);
            if (partial.length - at < typed + length)
                break;
            const type = started ? cast(char) partial[at] : '\0';
            handle(type, partial[at + typed + 4 .. at + typed + length]);
            at += typed + length;
        }
        if (at == partial.length)
        {
            partial.length = 0;
            (() @trusted => partial.assumeSafeAppend())(); // nothing else refers to the old bytes
        }
        else
            partial = partial[at .. $].dup;
    }

    override bool dataAvailable() @safe
    {
        return outputStart < output.length;
    }

    override void close() @safe nothrow
    {
    }

    override bool connected() const @safe nothrow
    {
        return true;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
    }

    private void handle(char type, scope const(ubyte)[] body) @safe
    {
        switch (type)
        {
        case '\0': // startup: trust
            started = true;
            send(message('R', be32(0)) ~ message('K', be32(1) ~ be32(2))
                    ~ message('S', cstr("server_version") ~ cstr("18.0"))
                    ~ message('S', cstr("TimeZone") ~ cstr("UTC"))
                    ~ message('S', cstr("integer_datetimes") ~ cstr("on")) ~ ready());
            break;
        case 'P':
            size_t at;
            const name = cstring(body, at);
            const sql = cstring(body, at);
            if (auto known = name in statements)
            {
                if (*known != sql)
                {
                    statements[name.idup] = sql.idup;
                    descriptions.remove(name.idup);
                }
            }
            else
                statements[name.idup] = sql.idup;
            send(parseComplete);
            break;
        case 'D':
            size_t at = 1;
            const name = cstring(body, at);
            const sql = body[0] == 'S' ? statements[name] : portals[name];
            if (body[0] == 'S')
            {
                if (auto known = name in descriptions)
                    send(*known);
                else
                {
                    const count = parameterCount(sql);
                    immutable(ubyte)[] types = be16(cast(int) count);
                    foreach (i; 0 .. count)
                        types ~= be32(paramTypes[i % paramTypes.length]);
                    send(descriptions[name.idup] = message('t', types));
                }
            }
            send(returnsRows(sql) ? rowDescription() : noData);
            break;
        case 'B':
            size_t at;
            const portal = cstring(body, at);
            const sql = statements[cstring(body, at)];
            if (auto known = portal in portals)
                *known = sql;
            else
                portals[portal.idup] = sql;
            at += 2 * int16(body[at .. $]) + 2;
            const count = int16(body[at .. $]);
            at += 2;
            foreach (i; 0 .. count)
            {
                const length = int32(body[at .. $]);
                at += 4 + (length > 0 ? length : 0);
            }
            const formats = int16(body[at .. $]);
            at += 2;
            resultFormats.length = formats;
            foreach (i; 0 .. formats)
                resultFormats[i] = cast(short) int16(body[at + 2 * i .. $]);
            send(bindComplete);
            break;
        case 'E':
            size_t at;
            const sql = portals[cstring(body, at)];
            const maxRows = int32(body[at .. $]);
            if (returnsRows(sql))
            {
                const rows = maxRows > 0 && maxRows < rowsPerExecute ? maxRows : rowsPerExecute;
                send(dataRow(), rows);
                send(maxRows > 0 && maxRows < rowsPerExecute ? portalSuspended : complete("SELECT", rows));
            }
            else
                send(complete("INSERT 0", 1));
            break;
        case 'S':
            send(ready());
            break;
        case 'C':
            send(closeComplete);
            break;
        case 'Q':
            size_t at;
            simpleQuery(cstring(body, at));
            break;
        case 'd':
            copyBytesReceived += body.length;
            break;
        case 'c':
            send(complete("COPY", 1));
            send(ready());
            break;
        case 'f':
            send(message('E', cstr("SERROR") ~ cstr("C57014") ~ cstr("Mcopy failed") ~ [ubyte(0)]) ~ ready());
            break;
        default: // 'H' Flush, 'X' Terminate
            break;
        }
    }

    private void simpleQuery(const(char)[] sql) @safe
    {
        import std.algorithm.searching : canFind, startsWith;
        import std.uni : toUpper;

        const upper = sql.toUpper;
        if (upper.startsWith("COPY") && upper.canFind("FROM STDIN"))
            send(message('G', [ubyte(0)] ~ be16(0)));
        else if (upper.startsWith("COPY"))
        {
            const binary = upper.canFind("BINARY");
            ubyte[] header = [ubyte(binary ? 1 : 0)] ~ be16(copyColumns);
            foreach (i; 0 .. copyColumns)
                header ~= be16(binary ? 1 : 0);
            send(message('H', header));
            if (binary)
                send(message('d', cast(immutable(ubyte)[]) "PGCOPY\n\xff\r\n\0" ~ be32(0) ~ be32(0)));
            send(message('d', binary ? copyBinaryRow : copyTextRow), copyRows);
            if (binary)
                send(message('d', be16(-1)));
            send(message('c'));
            send(complete("COPY", copyRows));
            send(ready());
        }
        else if (returnsRows(sql))
        {
            resultFormats = null;
            send(rowDescription());
            send(dataRow(), rowsPerExecute);
            send(complete("SELECT", rowsPerExecute));
            send(ready());
        }
        else
        {
            if (upper.startsWith("BEGIN"))
                txStatus = 'T';
            else if (upper.startsWith("COMMIT") || upper.startsWith("ROLLBACK"))
                txStatus = 'I';
            send(message('C', cstr((upper.length > 6 ? upper[0 .. 6] : upper).idup)) ~ ready());
        }
    }

    private void send(immutable(ubyte)[] bytes, size_t repeat = 1) @safe
    {
        if (repeat && bytes.length)
            output ~= Segment(bytes, repeat);
    }

    private immutable(ubyte)[] ready() @safe
    {
        return txStatus == 'T' ? readyInTransaction : readyIdle;
    }

    private immutable(ubyte)[] complete(string tag, size_t rows) @safe
    {
        import std.conv : to;

        if (auto byRows = tag in completes)
            if (auto known = rows in *byRows)
                return *known;
        return completes[tag][rows] = message('C', cstr(tag ~ " " ~ rows.to!string));
    }

    private immutable(ubyte)[] rowDescription() @safe
    {
        if (description.length)
            return description;
        immutable(ubyte)[] body = be16(cast(int) columns.length);
        foreach (c; columns)
            body ~= cstr(c.name) ~ be32(0) ~ be16(0) ~ be32(c.oid) ~ be16(c.size) ~ be32(-1) ~ be16(0);
        return description = message('T', body);
    }

    private immutable(ubyte)[] dataRow() @safe
    {
        if (row.length && rowFormats == resultFormats)
            return row;
        rowFormats = resultFormats.dup;
        immutable(ubyte)[] body = be16(cast(int) columns.length);
        foreach (i, c; columns)
        {
            // one format code for all columns, or one per column
            const format = resultFormats.length == 1 ? resultFormats[0] : i < resultFormats.length ? resultFormats[i]
                : 0;
            const binary = format == 1;
            const value = binary ? c.binary : c.text;
            body ~= c.isNull ? be32(-1) : be32(cast(int) value.length) ~ value;
        }
        return row = message('D', body);
    }
}

/// A backend message.
immutable(ubyte)[] message(char type, scope const(ubyte)[] body = null) @safe pure
{
    return [cast(ubyte) type] ~ be32(cast(int)
            body.length + 4) ~ body.idup;
}

/// Big-endian integers and a NUL-terminated string.
immutable(ubyte)[] be16(int v) @safe pure
{
    return [cast(ubyte)(v >> 8), cast(ubyte) v];
}

/// ditto
immutable(ubyte)[] be32(long v) @safe pure
{
    return [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
}

/// ditto
immutable(ubyte)[] be64(long v) @safe pure
{
    return be32(v >> 32) ~ be32(v);
}

/// ditto
immutable(ubyte)[] cstr(string s) @safe pure
{
    return cast(immutable(ubyte)[]) s ~ ubyte(0);
}

private int int32(scope const(ubyte)[] b) @safe pure
{
    return b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
}

private int int16(scope const(ubyte)[] b) @safe pure
{
    return cast(short)(b[0] << 8 | b[1]);
}

// A NUL-terminated string of `body` (a slice of it: copy it to keep it).
private const(char)[] cstring(return scope const(ubyte)[] body, ref size_t at) @safe pure
{
    size_t end = at;
    while (body[end] != 0)
        end++;
    const s = cast(const(char)[])
    body[at .. end];
    at = end + 1;
    return s;
}

// The highest $n in `sql`.
private size_t parameterCount(const(char)[] sql) @safe pure
{
    size_t highest;
    foreach (i, c; sql)
        if (c == '$')
        {
            size_t n, j = i + 1;
            while (j < sql.length && sql[j] >= '0' && sql[j] <= '9')
                n = n * 10 + (sql[j++] - '0');
            if (n > highest)
                highest = n;
        }
    return highest;
}

private bool returnsRows(const(char)[] sql) @safe pure
{
    import std.algorithm.searching : startsWith;
    import std.uni : toUpper;

    const upper = sql.length > 6 ? sql[0 .. 6].toUpper : sql.toUpper;
    return upper.startsWith("SELECT") || upper.startsWith("VALUES");
}
