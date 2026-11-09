/++
`COPY`: loading rows with `COPY ... FROM STDIN` (`CopyIn`) and reading them
with `COPY ... TO STDOUT` (`CopyOut`), in text, CSV or binary format.

Example:
---
// load: rows as values (text, CSV or binary), or bytes as they are
auto copy = conn.copyIn("COPY items (id, name) FROM STDIN");
copy.writeRow(1, "apple");
copy.writeRow(2, null);                         // NULL
const loaded = copy.finish();                   // 2

conn.copyInsert("items", items);                // structs, binary COPY

// read
auto csv = conn.copyOut("COPY items TO STDOUT WITH (FORMAT csv)", CopyFormat.csv);
foreach (row; csv)
    writeln(row.getInt(0), " ", row.getString(1));
---

While a `CopyIn` or `CopyOut` is open the connection is busy. A `CopyIn`
must end with `finish` (or `abort`); a `CopyOut` ends when read to the end
(or `close`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.copy;

import postgresql.connection : affectedRows, Connection;
import postgresql.exception : ClientException, ServerException;
import postgresql.params : encodeParam, Param;
import postgresql.protocol.codes : BackendMessage, FrontendMessage;
import postgresql.protocol.messages : Message, MessageBuilder;
import postgresql.result : ColumnInfo, makeRow, Row, ValueFormat;
import postgresql.types.oids : Oid;
import postgresql.types.pgtype : builtinType, PgType;

/// The data format of a `COPY` (its `FORMAT` option).
enum CopyFormat
{
    /// Tab-separated lines, `\N` for NULL, backslash escapes (the default).
    text,
    /// Comma-separated values, double quotes; NULL is an unquoted empty value.
    csv,
    /// PostgreSQL's binary format: each value in its type's binary form.
    binary,
}

/// The signature at the start of binary `COPY` data.
private static immutable ubyte[11] binarySignature = [
    'P', 'G', 'C', 'O', 'P', 'Y', '\n', 0xFF, '\r', '\n', 0
];

/++
A running `COPY ... FROM STDIN`: data written to it goes to the server in
`CopyData` messages (buffered, 64 KiB at a time); `finish` ends the copy and
returns the number of rows, `abort` cancels it (nothing is loaded).

`write` sends bytes as they are, in the format the statement named.
`writeRow` and `writeStruct` write one row of D values in the format given
to `Connection.copyIn` (text and CSV with the default delimiters, quotes and
NULL marker); binary rows need the column types, which `Connection.copyInto`
and `Connection.copyInsert` look up.

A server error during the copy (a malformed row, a constraint) is noticed
while writing and thrown by the next `write` or by `finish`; the rows of the
copy are then not loaded.
+/
final class CopyIn
{
    private Connection conn;
    private CopyFormat format_;
    private size_t columnCount_;
    private const(PgType)[] types;
    private ubyte[] buffer;
    private bool binaryStarted; // the binary header was written by writeRow
    private bool done;
    private enum bufferLimit = 64 * 1024;

    package this(Connection conn, CopyFormat format, size_t columnCount, const(PgType)[] types) @safe
    {
        this.conn = conn;
        format_ = format;
        columnCount_ = columnCount;
        this.types = types;
    }

    /// The row format: binary if the statement asked for it, else text or CSV as given to `copyIn`.
    @property CopyFormat format() const @safe pure nothrow
    {
        return format_;
    }

    /// Number of columns the copy fills.
    @property size_t columnCount() const @safe pure nothrow
    {
        return columnCount_;
    }

    /// Whether `finish` or `abort` was called (or the copy failed).
    @property bool isDone() const @safe pure nothrow
    {
        return done;
    }

    /++
    Writes bytes of the copy data as they are.

    Throws: `ServerException` if the server reported an error (the copy is
    over); `ClientException` after `finish`/`abort`.
    +/
    void write(scope const(ubyte)[] data) @safe
    {
        checkOpen();
        buffer ~= data;
        if (buffer.length >= bufferLimit)
            flush();
    }

    /// ditto
    void write(scope const(char)[] text) @safe
    {
        write(cast(const(ubyte)[]) text);
    }

    /++
    Writes one row: one value per column (any parameter type of
    `postgresql.params.encodeParam`; `null` or a null `Nullable` for NULL).
    Text and CSV rows use the values' text; binary rows their binary form
    for each column's type.

    Throws: `ClientException` for a wrong number of values, or a value that
    has no binary form for its column (binary format); as `write`.
    +/
    void writeRow(Args...)(Args values)
    {
        import std.conv : to;

        static if (Args.length > 0)
        {
            if (columnCount_ != 0 && Args.length != columnCount_)
                throw new ClientException("The copy has " ~ columnCount_.to!string ~ " column(s), but "
                        ~ Args.length.to!string ~ " value(s) were given");
        }
        Param[Args.length] fields;
        static foreach (i; 0 .. Args.length)
            fields[i] = format_ == CopyFormat.binary ? encodeParam(values[i], columnOid(i)) : encodeParam(values[i], Oid
                    .text);
        writeFields(fields[]);
    }

    /++
    Writes a struct as a row: its mapped fields (`@column`, `@ignore`) in
    field order, as `writeRow` writes values.
    +/
    void writeStruct(T)(const auto ref T value) if (is(T == struct))
    {
        import postgresql.attributes : mappedFields;

        enum names = mappedFields!T;
        Param[names.length] fields;
        static foreach (i, name; names)
            fields[i] = format_ == CopyFormat.binary ? encodeParam(__traits(getMember, value, name), columnOid(i))
                : encodeParam(__traits(getMember, value, name), Oid.text);
        writeFields(fields[]);
    }

    private uint columnOid(size_t i) const @safe
    {
        if (i >= types.length)
            throw new ClientException("Binary COPY rows need the column types: use Connection.copyInto or copyInsert");
        return types[i] is null ? 0 : types[i].oid;
    }

    private void writeFields(scope Param[] fields) @safe
    {
        import std.conv : to;

        checkOpen();
        final switch (format_)
        {
        case CopyFormat.text:
            foreach (i, f; fields)
            {
                if (i)
                    buffer ~= '\t';
                if (f.isNull)
                    buffer ~= `\N`;
                else
                    foreach (c; f.data)
                    {
                        switch (c)
                        {
                        case '\\':
                            buffer ~= `\\`;
                            break;
                        case '\t':
                            buffer ~= `\t`;
                            break;
                        case '\n':
                            buffer ~= `\n`;
                            break;
                        case '\r':
                            buffer ~= `\r`;
                            break;
                        default:
                            buffer ~= c;
                        }
                    }
            }
            buffer ~= '\n';
            break;
        case CopyFormat.csv:
            foreach (i, f; fields)
            {
                if (i)
                    buffer ~= ',';
                if (f.isNull)
                    continue; // an unquoted empty value
                buffer ~= '"';
                foreach (c; f.data)
                {
                    if (c == '"')
                        buffer ~= '"';
                    buffer ~= c;
                }
                buffer ~= '"';
            }
            buffer ~= '\n';
            break;
        case CopyFormat.binary:
            if (!binaryStarted)
            {
                buffer ~= binarySignature[];
                buffer ~= [0, 0, 0, 0, 0, 0, 0, 0]; // flags, header extension length
                binaryStarted = true;
            }
            const n = cast(ushort) fields.length;
            buffer ~= [cast(ubyte)(n >> 8), cast(ubyte) n];
            foreach (i, f; fields)
            {
                if (f.isNull)
                {
                    buffer ~= [0xFF, 0xFF, 0xFF, 0xFF];
                    continue;
                }
                const bytes = binaryForm(f, i);
                const length = cast(uint) bytes.length;
                buffer ~= [
                    cast(ubyte)(length >> 24), cast(ubyte)(length >> 16), cast(ubyte)(length >> 8),
                    cast(ubyte) length
                ];
                buffer ~= bytes;
            }
            break;
        }
        if (buffer.length >= bufferLimit)
            flush();
    }

    // The binary form of an encoded value: binary as it is; text for types whose binary form is their text
    // (text types, enums, json), jsonb (a version byte first), numeric (converted).
    private immutable(ubyte)[] binaryForm(const Param p, size_t column) @safe
    {
        import postgresql.types.numeric : encodeNumericText;

        if (p.format == 1)
            return p.data;
        const t = types[column];
        const codec = t is null ? 0 : t.codec;
        switch (codec)
        {
        case Oid.text, Oid.varchar, Oid.bpchar, Oid.name, Oid.json, Oid.unknown, Oid.xml:
            return p.data;
        case Oid.jsonb:
            immutable(ubyte)[] version1 = [1];
            return version1 ~ p.data;
        case Oid.numeric:
            return encodeNumericText(cast(string) p.data);
        default:
            throw new ClientException("The value '" ~ cast(string) p.data ~ "' has no binary form for column type "
                    ~ (
                        t is null ? "unknown" : t.name) ~ ": use text or CSV COPY");
        }
    }

    /++
    Ends the copy: sends the rest of the data and `CopyDone`, and waits for
    the server.

    Returns: the number of rows loaded.
    Throws: `ServerException` if the server refused the data (nothing is loaded).
    +/
    ulong finish() @safe
    {
        checkOpen();
        if (binaryStarted)
            buffer ~= [0xFF, 0xFF]; // the trailer
        flush();
        done = true;
        string tag;
        conn.guarded({
            MessageBuilder b;
            b.begin(FrontendMessage.copyDone);
            b.finish();
            conn.stream.send(b.data);
            tag = readToEnd();
        });
        conn.throwPendingError();
        return affectedRows(tag);
    }

    /++
    Cancels the copy (`CopyFail`): nothing is loaded and the connection is
    ready again. Does nothing after `finish`, `abort` or a failure.
    +/
    void abort(string reason = "aborted by the client") @safe
    {
        if (done)
            return;
        MessageBuilder b;
        b.begin(FrontendMessage.copyFail);
        b.putCString(reason); // a NUL in it throws here, before anything changes
        b.finish();
        done = true;
        buffer = null;
        if (!conn.isOpen)
            return; // e.g. after a FATAL error, which is the one to report
        conn.guarded({ conn.stream.send(b.data); readToEnd(); });
        conn.discardPendingError(); // the server's "COPY from stdin failed" error
    }

    package void setTypes(const(PgType)[] columnTypes) @safe pure nothrow
    {
        types = columnTypes;
    }

    private void checkOpen() @safe
    {
        if (done)
            throw new ClientException("The COPY is over");
    }

    // Sends the buffered data; first reads what the server sent meanwhile (an error ends the copy).
    private void flush() @safe
    {
        conn.guarded({
            if (conn.serverDataAvailable())
            {
                // the server only speaks during COPY IN to report an error (or a notice)
                readToEnd();
                if (conn.isReadyForQuery)
                {
                    done = true;
                    buffer = null;
                }
            }
            if (!done && buffer.length)
            {
                MessageBuilder b;
                b.begin(FrontendMessage.copyData);
                b.putBytes(buffer);
                b.finish();
                conn.stream.send(b.data);
                buffer.length = 0;
            }
        });
        if (done)
            conn.throwPendingError();
    }

    // Reads messages up to ReadyForQuery (or, while copying, as long as some are available); returns the tag.
    private string readToEnd() @safe
    {
        string tag;
        while (!conn.isReadyForQuery && (done || conn.serverDataAvailable()))
        {
            Message m;
            if (!conn.readMessage(m))
                continue; // a notice or the like: maybe nothing else is coming yet
            switch (m.type)
            {
            case BackendMessage.commandComplete:
                tag = m.body.readCString();
                break;
            case BackendMessage.readyForQuery:
                conn.readyForQuery(m);
                break;
            default:
                conn.handleResponseMessage(m);
            }
        }
        return tag;
    }
}

/++
A running `COPY ... TO STDOUT`: the data comes in chunks (one row each, as
the server sends them), readable as bytes (`readChunk`, `readAll`) or as
rows (an input range of `Row`s, parsed from the text, CSV or binary format).

Rows from text and CSV have text values; give the column types
(`columnTypes`) for the getters to read them as those types, and for binary
data to be decoded at all (without types, binary values have only their
bytes, `Value.raw`).
+/
final class CopyOut
{
    private Connection conn;
    private CopyFormat format_;
    private size_t columnCount_;
    private ColumnInfo[] columns;
    private string timeZone;
    private bool done;
    private ulong rows;
    private ubyte[] binaryBuffer; // binary data not parsed yet
    private bool binaryHeaderRead;
    private Row current;
    private bool hasCurrent;

    package this(Connection conn, CopyFormat format, size_t columnCount, string timeZone) @safe
    {
        this.conn = conn;
        format_ = format;
        columnCount_ = columnCount;
        this.timeZone = timeZone;
        columns = new ColumnInfo[columnCount];
        foreach (i, ref c; columns)
            c.format = format == CopyFormat.binary ? ValueFormat.binary : ValueFormat.text;
    }

    /// The row format: binary if the statement asked for it, else text or CSV as given to `copyOut`.
    @property CopyFormat format() const @safe pure nothrow
    {
        return format_;
    }

    /// Number of columns of each row.
    @property size_t columnCount() const @safe pure nothrow
    {
        return columnCount_;
    }

    /++
    Sets the column types (OIDs, e.g. `[Oid.int4, Oid.text]`), so the rows'
    getters read their values as those types. Call before reading rows.
    +/
    void columnTypes(const uint[] oids) @safe
    {
        if (oids.length != columnCount_)
            throw new ClientException("The copy has a different number of columns");
        foreach (i, ref c; columns)
        {
            c.typeOid = oids[i];
            c.type = builtinType(oids[i]);
        }
    }

    /// Whether all data was read (then `rowCount` is known).
    @property bool isDone() const @safe pure nothrow
    {
        return done;
    }

    /// The number of rows the server sent (its `COPY n` tag); known when done.
    @property ulong rowCount() const @safe pure nothrow
    {
        return rows;
    }

    /++
    The next chunk of data as the server sent it (a row, or the binary
    header or trailer); null at the end.

    Throws: `ServerException` if the copy failed.
    +/
    immutable(ubyte)[] readChunk() @safe
    {
        if (done)
            return null;
        immutable(ubyte)[] chunk;
        bool finished;
        conn.guarded({
            for (;;)
            {
                auto m = conn.nextMessage();
                switch (m.type)
                {
                case BackendMessage.copyData:
                    chunk = m.body.readRest().idup;
                    return;
                case BackendMessage.copyDone:
                    break;
                case BackendMessage.commandComplete:
                    rows = affectedRows(m.body.readCString());
                    break;
                case BackendMessage.readyForQuery:
                    conn.readyForQuery(m);
                    finished = true;
                    return;
                default:
                    conn.handleResponseMessage(m);
                }
            }
        });
        if (finished)
        {
            done = true;
            conn.throwPendingError();
            return null;
        }
        return chunk;
    }

    /// All the remaining data, concatenated.
    immutable(ubyte)[] readAll() @safe
    {
        immutable(ubyte)[] all;
        for (auto chunk = readChunk(); chunk !is null; chunk = readChunk())
            all ~= chunk;
        return all;
    }

    /// All the remaining data as text (text and CSV formats).
    string readText() @safe
    {
        return cast(string) readAll();
    }

    /++
    Whether there are no more rows.

    Throws: `ClientException` if a row doesn't have the expected format (the
    rest of the data is read then, so the connection is ready again);
    `ServerException` if the copy failed.
    +/
    @property bool empty() @safe
    {
        if (!hasCurrent && !done)
            advance();
        return !hasCurrent;
    }

    /// The current row.
    @property Row front() @safe
    {
        if (empty)
            throw new ClientException("No more rows");
        return current;
    }

    /// Moves to the next row.
    void popFront() @safe
    {
        if (empty)
            throw new ClientException("No more rows");
        hasCurrent = false;
    }

    /// Reads the rest of the data and discards it; the connection is ready again.
    void close() @safe
    {
        while (readChunk() !is null)
        {
        }
        hasCurrent = false;
    }

    private void advance() @safe
    {
        try
            readRow();
        catch (ClientException e)
        {
            // the data doesn't have the expected format (e.g. other COPY options): read the rest, so the
            // connection is ready again
            try
                close();
            catch (Exception)
            {
            }
            throw e;
        }
    }

    private void readRow() @safe
    {
        if (format_ == CopyFormat.binary)
        {
            advanceBinary();
            return;
        }
        const chunk = readChunk();
        if (chunk is null)
            return;
        auto line = cast(string) chunk;
        if (line.length && line[$ - 1] == '\n')
            line = line[0 .. $ - 1];
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        const fields = format_ == CopyFormat.csv ? parseCsvLine(line) : parseTextLine(line);
        setRow(fields);
    }

    private void setRow(const string[] fields) @safe
    {
        import std.conv : to;

        if (fields.length != columnCount_)
            throw new ClientException(
                    "A COPY row has " ~ fields.length.to!string ~ " field(s), expected "
                    ~ columnCount_.to!string);
        auto values = new immutable(ubyte)[][fields.length];
        auto nulls = new bool[fields.length];
        foreach (i, f; fields)
        {
            nulls[i] = f is null;
            values[i] = cast(immutable(ubyte)[]) f;
        }
        current = makeRow(columns, values, nulls, timeZone);
        hasCurrent = true;
    }

    private void advanceBinary() @safe
    {
        import std.conv : to;

        size_t at;
        bool need(size_t n)
        {
            while (binaryBuffer.length < at + n)
            {
                const chunk = readChunk();
                if (chunk is null)
                    return false;
                binaryBuffer ~= chunk;
            }
            return true;
        }

        int int32()
        {
            const v = binaryBuffer[at] << 24 | binaryBuffer[at + 1] << 16 | binaryBuffer[at + 2] << 8
                | binaryBuffer[at + 3];
            at += 4;
            return v;
        }

        if (!binaryHeaderRead)
        {
            if (!need(19))
                return;
            if (binaryBuffer[0 .. 11] != binarySignature[])
                throw new ClientException("Invalid binary COPY signature");
            at = 15; // signature, flags
            const extension = int32();
            if (extension < 0 || !need(extension))
                throw new ClientException("Invalid binary COPY header");
            at += extension;
            binaryHeaderRead = true;
        }
        if (!need(2))
            return;
        const count = cast(short)(binaryBuffer[at] << 8 | binaryBuffer[at + 1]);
        at += 2;
        if (count == -1)
        {
            // the trailer: read to the end
            binaryBuffer = null;
            close();
            return;
        }
        if (count != columnCount_)
            throw new ClientException(
                    "A binary COPY row has " ~ count.to!string ~ " field(s), expected "
                    ~ columnCount_.to!string);
        auto values = new immutable(ubyte)[][count];
        auto nulls = new bool[count];
        foreach (i; 0 .. count)
        {
            if (!need(4))
                throw new ClientException("Truncated binary COPY row");
            const length = int32();
            if (length == -1)
            {
                nulls[i] = true;
                continue;
            }
            if (length < 0 || !need(length))
                throw new ClientException("Truncated binary COPY row");
            values[i] = binaryBuffer[at .. at + length].idup;
            at += length;
        }
        binaryBuffer = binaryBuffer[at .. $].dup;
        current = makeRow(columns, values, nulls, timeZone);
        hasCurrent = true;
    }
}

/++
Splits a line of text-format COPY data into its fields: tab-separated,
`\N` for NULL (null), backslash escapes decoded (`\t`, `\n`, `\\`, `\b`,
`\f`, `\r`, `\v`, octal `\nnn`, hexadecimal `\xhh`).
+/
string[] parseTextLine(string line) @safe pure
{
    string[] fields;
    char[] current;
    bool isNullMarker;
    size_t i;
    void endField()
    {
        fields ~= isNullMarker ? null : current.length ? (() @trusted => cast(string) current)() : "";
        current = null;
        isNullMarker = false;
    }

    while (i < line.length)
    {
        const c = line[i++];
        if (c == '\t')
        {
            endField();
            continue;
        }
        if (c != '\\' || i >= line.length)
        {
            current ~= c;
            continue;
        }
        const e = line[i++];
        switch (e)
        {
        case 'N':
            isNullMarker = current.length == 0 && (i >= line.length || line[i] == '\t');
            if (!isNullMarker)
                current ~= 'N';
            break;
        case 'b':
            current ~= '\b';
            break;
        case 'f':
            current ~= '\f';
            break;
        case 'n':
            current ~= '\n';
            break;
        case 'r':
            current ~= '\r';
            break;
        case 't':
            current ~= '\t';
            break;
        case 'v':
            current ~= '\v';
            break;
        case 'x':
            int value, digits;
            while (digits < 2 && i < line.length && isHex(line[i]))
            {
                value = value * 16 + hexValue(line[i++]);
                digits++;
            }
            if (digits == 0)
                current ~= 'x';
            else
                current ~= cast(char) value;
            break;
        case '0': .. case '7':
            int value = e - '0', digits = 1;
            while (digits < 3 && i < line.length && line[i] >= '0' && line[i] <= '7')
            {
                value = value * 8 + (line[i++] - '0');
                digits++;
            }
            current ~= cast(char) value;
            break;
        default:
            current ~= e;
        }
    }
    endField();
    return fields;
}

private bool isHex(char c) @safe pure nothrow
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private int hexValue(char c) @safe pure nothrow
{
    return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
}

///
@safe unittest
{
    assert(parseTextLine("1\tapple\t\\N") == ["1", "apple", null]);
    assert(parseTextLine(`a\tb\\c\nd\101\x42`) == ["a\tb\\c\ndAB"]);
    const f = parseTextLine("\t");
    assert(f.length == 2 && f[0]!is null && f[0].length == 0);
}

/++
Splits a line of CSV COPY data into its fields: comma-separated, `"` quotes
(doubled inside quotes); an unquoted empty field is NULL (null), a quoted
one an empty string.
+/
string[] parseCsvLine(string line) @safe pure
{
    string[] fields;
    size_t i;
    for (;;)
    {
        char[] current;
        bool quoted, any;
        while (i < line.length)
        {
            const c = line[i];
            if (c == '"')
            {
                quoted = true;
                any = true;
                i++;
                while (i < line.length)
                {
                    if (line[i] == '"')
                    {
                        if (i + 1 < line.length && line[i + 1] == '"')
                        {
                            current ~= '"';
                            i += 2;
                            continue;
                        }
                        i++;
                        break;
                    }
                    current ~= line[i++];
                }
                continue;
            }
            if (c == ',')
                break;
            current ~= c;
            any = true;
            i++;
        }
        if (!any && !quoted)
            fields ~= null;
        else
            fields ~= current.length ? (() @trusted => cast(string) current)() : "";
        if (i >= line.length)
            break;
        i++; // the comma
    }
    return fields;
}

///
@safe unittest
{
    const f = parseCsvLine(`1,"a ""b"", c",,""`);
    assert(f.length == 4 && f[0] == "1" && f[1] == `a "b", c` && f[2] is null && f[3]!is null && f[3].length == 0);
}
