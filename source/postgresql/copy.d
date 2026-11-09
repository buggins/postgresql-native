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
import postgresql.params : nullValue, putParam;
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
    private MessageBuilder message; // the CopyData message being filled (begun when it has data)
    private MessageBuilder value; // a value encoded by writeRow, before it is escaped into `message`
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
        if (data.length >= bufferLimit)
        {
            // large data: a message of its own, sent without copying it into the buffer
            flush();
            if (!done)
                conn.guarded({
                    ubyte[5] header = [FrontendMessage.copyData, 0, 0, 0, 0];
                    if (data.length > int.max - 4)
                        throw new ClientException("A COPY data chunk is longer than 2 GB");
                    const length = cast(uint)(data.length + 4);
                    header[1 .. 5] = [
                        cast(ubyte)(length >> 24), cast(ubyte)(length >> 16), cast(ubyte)(length >> 8),
                        cast(ubyte) length
                    ];
                    conn.stream.write(header[]);
                    conn.stream.send(data);
                });
            return;
        }
        startMessage();
        message.putBytes(data);
        if (message.length >= bufferLimit)
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
        checkOpen();
        const rowBegin = startRow(Args.length);
        try
        {
            static foreach (i; 0 .. Args.length)
            {
                if (format_ == CopyFormat.binary)
                {
                    const at = message.length;
                    putBinaryField(i, at, putParam(message, values[i], columnOid(i)));
                }
                else
                {
                    value.clear();
                    putTextField(i, putParam(value, values[i], Oid.text) == nullValue);
                }
            }
        }
        catch (Exception e)
        {
            undoRow(rowBegin); // nothing of the row is sent
            throw e;
        }
        endRow();
    }

    /++
    Writes a struct as a row: its mapped fields (`@column`, `@ignore`) in
    field order, as `writeRow` writes values.
    +/
    void writeStruct(T)(const auto ref T value) if (is(T == struct))
    {
        import postgresql.attributes : mappedFields;

        enum names = mappedFields!T;
        checkOpen();
        const rowBegin = startRow(names.length);
        try
        {
            static foreach (i, name; names)
            {
                if (format_ == CopyFormat.binary)
                {
                    const at = message.length;
                    putBinaryField(i, at, putParam(message, __traits(getMember, value, name), columnOid(i)));
                }
                else
                {
                    this.value.clear();
                    putTextField(i, putParam(this.value, __traits(getMember, value, name), Oid.text) == nullValue);
                }
            }
        }
        catch (Exception e)
        {
            undoRow(rowBegin); // nothing of the row is sent
            throw e;
        }
        endRow();
    }

    private uint columnOid(size_t i) const @safe
    {
        if (i >= types.length)
            throw new ClientException("Binary COPY rows need the column types: use Connection.copyInto or copyInsert");
        return types[i] is null ? 0 : types[i].oid;
    }

    // Starts a row of `writeRow`/`writeStruct` of `count` fields: the binary header before the first one, the
    // field count. Returns where the row begins in `message`, with the header if this row wrote it.
    private size_t startRow(size_t count) @safe
    {
        startMessage();
        const rowBegin = message.length;
        if (format_ == CopyFormat.binary)
        {
            if (!binaryStarted)
            {
                message.putBytes(binarySignature[]);
                message.putBigEndian(ulong(0)); // flags, header extension length
                binaryStarted = true;
                headerRow = true;
            }
            message.putInt16(cast(short) count);
        }
        return rowBegin;
    }

    private bool headerRow; // the current row wrote the binary header

    // After a row failed: removes what it wrote (the header too, if it wrote it).
    private void undoRow(size_t rowBegin) @safe pure nothrow
    {
        message.truncate(rowBegin);
        if (message.length == 5)
            message.clear(); // only the CopyData header is left: nothing to send
        if (headerRow)
            binaryStarted = false;
        headerRow = false;
    }

    private void endRow() @safe
    {
        headerRow = false;
        if (format_ != CopyFormat.binary)
            message.putByte('\n');
        if (message.length >= bufferLimit)
            flush();
    }

    // Writes the text of field `i` (encoded in `value`) into the row: escaped, or quoted for CSV.
    private void putTextField(size_t i, bool isNull) @safe
    {
        const text = value.data[4 .. $];
        if (format_ == CopyFormat.text)
        {
            if (i)
                message.putByte('\t');
            if (isNull)
            {
                message.putBytes(cast(const(ubyte)[]) `\N`);
                return;
            }
            // runs without special characters at once
            size_t start;
            foreach (k, c; text)
            {
                const escape = c == '\\' ? '\\' : c == '\t' ? 't' : c == '\n' ? 'n' : c == '\r' ? 'r' : '\0';
                if (escape)
                {
                    message.putBytes(text[start .. k]);
                    message.putByte('\\');
                    message.putByte(escape);
                    start = k + 1;
                }
            }
            message.putBytes(text[start .. $]);
        }
        else
        {
            if (i)
                message.putByte(',');
            if (isNull)
                return; // an unquoted empty value
            message.putByte('"');
            size_t start;
            foreach (k, c; text)
                if (c == '"')
                {
                    message.putBytes(text[start .. k + 1]);
                    start = k; // the quote again: doubled
                }
            message.putBytes(text[start .. $]);
            message.putByte('"');
        }
    }

    // After putParam wrote field `i` into `message` at `at`, returning `format`: converts text to the binary
    // form where the binary form is the text (text types, enums, json), jsonb (a version byte first) and numeric.
    private void putBinaryField(size_t i, size_t at, short format) @safe
    {
        import postgresql.types.numeric : encodeNumericText;

        if (format != 0)
            return; // binary, or NULL
        const t = types[i];
        const codec = t is null ? 0 : t.codec;
        switch (codec)
        {
        case Oid.text, Oid.varchar, Oid.bpchar, Oid.name, Oid.json, Oid.unknown, Oid.xml:
            return;
        case Oid.jsonb:
            const text = message.data[at + 4 .. $].idup;
            message.truncate(at);
            message.putInt32(cast(int) text.length + 1);
            message.putByte(1);
            message.putBytes(text);
            return;
        case Oid.numeric:
            const text = cast(string) message.data[at + 4 .. $].idup;
            message.truncate(at);
            const bytes = encodeNumericText(text);
            message.putInt32(cast(int) bytes.length);
            message.putBytes(bytes);
            return;
        default:
            const text = cast(string) message.data[at + 4 .. $].idup;
            throw new ClientException("The value '" ~ text ~ "' has no binary form for column type "
                    ~ (t is null ? "unknown" : t.name) ~ ": use text or CSV COPY");
        }
    }

    // Begins a CopyData message in `message` unless one is begun.
    private void startMessage() @safe pure nothrow
    {
        if (message.length == 0)
            message.begin(FrontendMessage.copyData);
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
        {
            startMessage();
            message.putInt16(-1); // the trailer
        }
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
        message = MessageBuilder.init;
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
                    message = MessageBuilder.init;
                }
            }
            if (!done && message.length)
            {
                message.finish();
                conn.stream.send(message.data);
                message.clear();
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

private static immutable ubyte[1] emptyChunk; // an empty chunk that isn't null (null means the end)

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
    private immutable(ubyte)[] binaryData; // binary data not parsed yet
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
                    chunk = m.data.length ? m.data.idup : emptyChunk[0 .. 0]; // empty, but not null (the end)
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
        auto fields = format_ == CopyFormat.csv ? parseCsvLine(line) : parseTextLine(line);
        setRow(fields);
    }

    private void setRow(string[] fields) @safe
    {
        import std.conv : to;

        if (fields.length != columnCount_)
            throw new ClientException(
                    "A COPY row has " ~ fields.length.to!string ~ " field(s), expected "
                    ~ columnCount_.to!string);
        // the fields are slices of the line or new strings, "" when empty: null only for NULL, as makeRow needs
        current = makeRow(columns, (() @trusted => cast(immutable(ubyte)[][]) fields)(), timeZone); // chars as bytes
        hasCurrent = true;
    }

    private void advanceBinary() @safe
    {
        import std.conv : to;

        // the row starts at binaryData[0]; the values are slices of it (rows within one chunk: no copy)
        size_t at;
        bool need(size_t n)
        {
            while (binaryData.length < at + n)
            {
                const chunk = readChunk();
                if (chunk is null)
                    return false;
                binaryData = binaryData.length ? binaryData ~ chunk : chunk;
            }
            return true;
        }

        int int32()
        {
            const v = binaryData[at] << 24 | binaryData[at + 1] << 16 | binaryData[at + 2] << 8 | binaryData[at + 3];
            at += 4;
            return v;
        }

        if (!binaryHeaderRead)
        {
            if (!need(19))
                return;
            if (binaryData[0 .. 11] != binarySignature[])
                throw new ClientException("Invalid binary COPY signature");
            at = 15; // signature, flags
            const extension = int32();
            if (extension < 0 || !need(extension))
                throw new ClientException("Invalid binary COPY header");
            at += extension;
            binaryHeaderRead = true;
            binaryData = binaryData[at .. $];
            at = 0;
        }
        if (!need(2))
            return;
        const count = cast(short)(binaryData[0] << 8 | binaryData[1]);
        at = 2;
        if (count == -1)
        {
            // the trailer: read to the end
            binaryData = null;
            close();
            return;
        }
        if (count != columnCount_)
            throw new ClientException(
                    "A binary COPY row has " ~ count.to!string ~ " field(s), expected "
                    ~ columnCount_.to!string);
        auto values = new immutable(ubyte)[][count];
        foreach (ref v; values)
        {
            if (!need(4))
                throw new ClientException("Truncated binary COPY row");
            const length = int32();
            if (length == -1)
                continue; // NULL
            if (length < 0 || !need(length))
                throw new ClientException("Truncated binary COPY row");
            v = binaryData[at .. at + length]; // not null: binaryData holds at least the count
            at += length;
        }
        binaryData = binaryData[at .. $];
        current = makeRow(columns, values, timeZone);
        hasCurrent = true;
    }
}

/++
Splits a line of text-format COPY data into its fields: tab-separated,
`\N` for NULL (null), backslash escapes decoded (`\t`, `\n`, `\\`, `\b`,
`\f`, `\r`, `\v`, octal `\nnn`, hexadecimal `\xhh`). Fields without escapes are
slices of `line`.
+/
string[] parseTextLine(string line) @safe pure
{
    import std.string : indexOf;

    string[] fields;
    for (;;)
    {
        auto end = line.indexOf('\t');
        const field = end < 0 ? line : line[0 .. end];
        fields ~= field == `\N` ? null : field.indexOf('\\') >= 0 ? unescapeText(field) : field.length ? field : "";
        if (end < 0)
            return fields;
        line = line[end + 1 .. $];
    }
}

// A field with backslash escapes, decoded.
private string unescapeText(string field) @safe pure
{
    char[] current;
    size_t i;
    while (i < field.length)
    {
        // up to the next escape at once
        size_t run = i;
        while (run < field.length && field[run] != '\\')
            run++;
        current ~= field[i .. run];
        i = run;
        if (i >= field.length)
            break;
        if (++i >= field.length)
        {
            current ~= '\\'; // a lone backslash at the end
            break;
        }
        const e = field[i++];
        switch (e)
        {
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
            while (digits < 2 && i < field.length && isHex(field[i]))
            {
                value = value * 16 + hexValue(field[i++]);
                digits++;
            }
            if (digits == 0)
                current ~= 'x';
            else
                current ~= cast(char) value;
            break;
        case '0': .. case '7':
            int value = e - '0', digits = 1;
            while (digits < 3 && i < field.length && field[i] >= '0' && field[i] <= '7')
            {
                value = value * 8 + (field[i++] - '0');
                digits++;
            }
            current ~= cast(char) value;
            break;
        default: // \N inside a value is an N
            current ~= e;
        }
    }
    return current.length ? (() @trusted => cast(string) current)() : ""; // unique: built here
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

@safe unittest
{
    assert(parseTextLine("") == [""] && parseTextLine("a\\") == ["a\\"] && parseTextLine(`a\Nb`) == [
        "aNb"
    ]);
    assert(parseTextLine("\\N\t\\\\N") == [null, `\N`] && parseTextLine(`x\x4`) == ["x\x04"]);
    assert(parseTextLine(`\x`) == ["x"] && parseTextLine(`\0101`) == ["\x081"]);
    const line = "plain\tmore";
    const f = parseTextLine(line);
    assert(&f[0][0] is &line[0] && &f[1][0] is &line[6]); // slices, not copies
}

/++
Splits a line of CSV COPY data into its fields: comma-separated, `"` quotes
(doubled inside quotes); an unquoted empty field is NULL (null), a quoted
one an empty string. Fields without doubled quotes are slices of `line`.
+/
string[] parseCsvLine(string line) @safe pure
{
    string[] fields;
    size_t i;
    for (;;)
    {
        // most fields are slices of the line: unquoted, or quoted without doubled quotes
        string field;
        bool isNull;
        if (i < line.length && line[i] == '"')
        {
            size_t close = i + 1;
            while (close < line.length && line[close] != '"')
                close++;
            if (close < line.length && (close + 1 == line.length || line[close + 1] == ','))
            {
                field = line[i + 1 .. close];
                i = close + 1;
            }
            else
                field = parseCsvField(line, i);
        }
        else
        {
            size_t end = i;
            while (end < line.length && line[end] != ',' && line[end] != '"')
                end++;
            if (end < line.length && line[end] == '"')
                field = parseCsvField(line, i);
            else
            {
                field = line[i .. end];
                isNull = end == i;
                i = end;
            }
        }
        fields ~= isNull ? null : field.length ? field : "";
        if (i >= line.length)
            break;
        i++; // the comma
    }
    return fields;
}

// A CSV field with doubled quotes, or with quoted and unquoted parts, from `i` to its comma (or the end).
private string parseCsvField(string line, ref size_t i) @safe pure
{
    char[] current;
    while (i < line.length)
    {
        const c = line[i];
        if (c == '"')
        {
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
        i++;
    }
    return current.length ? (() @trusted => cast(string) current)() : ""; // unique: built here
}

///
@safe unittest
{
    const f = parseCsvLine(`1,"a ""b"", c",,""`);
    assert(f.length == 4 && f[0] == "1" && f[1] == `a "b", c` && f[2] is null && f[3]!is null && f[3].length == 0);
}

@safe unittest
{
    assert(parseCsvLine("") == [null] && parseCsvLine("a,") == ["a", null] && parseCsvLine(",") == [
        null, null
    ]);
    assert(parseCsvLine(`"a,b",c`) == ["a,b", "c"] && parseCsvLine(`ab"c,d"e,f`) == ["abc,de", "f"]);
    assert(parseCsvLine(`"unterminated, x`) == ["unterminated, x"]);
    assert(parseCsvLine(`"",""""`) == ["", `"`] && parseCsvLine(`"x"y`) == ["xy"]);
    const line = "plain,\"quoted\"";
    const f = parseCsvLine(line);
    assert(&f[0][0] is &line[0] && &f[1][0] is &line[7]); // slices, not copies
}
