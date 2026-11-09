/++
Message framing of the PostgreSQL protocol.

After the startup packet, every message is a type byte, an int32 length (which
counts itself but not the type byte) and a body. Integers are big-endian,
strings are NUL-terminated UTF-8.

`MessageBody` parses a received body with every length checked;
`MessageBuilder` composes frontend messages; `MessageStream` reads and writes
them over a transport.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.protocol.messages;

import dbwire.exception : ProtocolException;
import dbwire.io.buffer : BufferedReader, BufferedWriter;
import dbwire.io.transport : Transport;

@safe:

/// The longest message accepted by default: PostgreSQL's 1 GB field limit plus room for the row around it.
enum size_t defaultMaxMessageLength = (1 << 30) + (1 << 20);

/// A received message: its type byte and its body (without type and length).
struct Message
{
    /// The type byte, e.g. `'Z'` for ReadyForQuery.
    char type;
    /// The body.
    const(ubyte)[] data;

    /// A parser over the body.
    MessageBody body() const pure nothrow
    {
        return MessageBody(data, type);
    }
}

/++
Reads the fields of a message body. Every read checks that the body is long
enough and throws `ProtocolException` otherwise.
+/
struct MessageBody
{
    private const(ubyte)[] data;
    private size_t pos;
    private char type;

    /// Creates a parser over `data`; `type` is used in error messages.
    this(const(ubyte)[] data, char type = '?') pure nothrow
    {
        this.data = data;
        this.type = type;
    }

    /// Whether the whole body has been read.
    @property bool empty() const pure nothrow
    {
        return pos >= data.length;
    }

    /// Number of bytes not read yet.
    @property size_t remaining() const pure nothrow
    {
        return data.length - pos;
    }

    /// Reads one byte.
    ubyte readByte() pure
    {
        need(1);
        return data[pos++];
    }

    /// Reads a big-endian int16.
    short readInt16() pure
    {
        need(2);
        const v = cast(short)((data[pos] << 8) | data[pos + 1]);
        pos += 2;
        return v;
    }

    /// Reads a big-endian int32.
    int readInt32() pure
    {
        need(4);
        const v = (cast(uint) data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3];
        pos += 4;
        return cast(int) v;
    }

    /// Reads `n` bytes (a slice of the body).
    const(ubyte)[] readBytes(size_t n) pure
    {
        need(n);
        auto bytes = data[pos .. pos + n];
        pos += n;
        return bytes;
    }

    /// Reads the rest of the body.
    const(ubyte)[] readRest() pure nothrow
    {
        auto bytes = data[pos .. $];
        pos = data.length;
        return bytes;
    }

    /// Reads a NUL-terminated string (copied).
    string readCString() pure
    {
        foreach (i; pos .. data.length)
            if (data[i] == 0)
            {
                auto s = cast(string) data[pos .. i].idup;
                pos = i + 1;
                return s;
            }
        throw new ProtocolException("Unterminated string in a '" ~ type ~ "' message");
    }

    private void need(size_t n) const pure
    {
        if (data.length - pos < n)
            throw new ProtocolException("Truncated '" ~ type ~ "' message");
    }
}

///
unittest
{
    import std.exception : assertThrown;

    static immutable ubyte[] bytes = [0, 5, 0, 0, 1, 0, 'a', 'b', 0, 0xFF];
    auto b = MessageBody(bytes, 'X');
    assert(b.readInt16() == 5 && b.readInt32() == 256 && b.readCString() == "ab");
    assert(b.remaining == 1 && b.readByte() == 0xFF && b.empty);
    assertThrown!ProtocolException(b.readByte());
    assertThrown!ProtocolException(MessageBody(bytes[0 .. 3]).readInt32());
    assertThrown!ProtocolException(MessageBody(bytes[6 .. 8]).readCString());
    assert(MessageBody(bytes).readInt16() == 5);
    assert(MessageBody([0xFF, 0xFE]).readInt16() == -2);
}

/++
Composes a frontend message: `begin` writes the type and reserves the length,
the `put*` functions append fields, `finish` fills in the length.
+/
struct MessageBuilder
{
    /// The bytes composed so far.
    ubyte[] data;
    private size_t start;

    /// Starts a message of `type`; a startup-phase packet (no type byte) when `type` is 0.
    void begin(char type) pure nothrow
    {
        if (type != 0)
            data ~= cast(ubyte) type;
        start = data.length;
        data ~= [ubyte(0), 0, 0, 0];
    }

    /// Appends a byte.
    void putByte(ubyte b) pure nothrow
    {
        data ~= b;
    }

    /// Appends a big-endian int16.
    void putInt16(short v) pure nothrow
    {
        data ~= [cast(ubyte)(v >> 8), cast(ubyte) v];
    }

    /// Appends a big-endian int32.
    void putInt32(int v) pure nothrow
    {
        data ~= [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
    }

    /// Appends raw bytes.
    void putBytes(scope const(ubyte)[] bytes) pure nothrow
    {
        data ~= bytes;
    }

    /++
    Appends `s` and a NUL byte.

    Throws: `ClientException` if `s` contains a NUL byte, which would end it early.
    +/
    void putCString(scope const(char)[] s) pure
    {
        import dbwire.exception : ClientException;
        import std.string : indexOf;

        if (s.indexOf('\0') >= 0)
            throw new ClientException("A string sent to the server contains a NUL character");
        data ~= cast(const(ubyte)[]) s;
        data ~= 0;
    }

    /++
    Fills in the length of the current message.

    Throws: `ClientException` if the message is longer than the protocol allows (2 GB).
    +/
    void finish() pure
    {
        import dbwire.exception : ClientException;

        const length = data.length - start;
        if (length > int.max)
            throw new ClientException("A message to the server is longer than 2 GB");
        data[start] = cast(ubyte)(length >> 24);
        data[start + 1] = cast(ubyte)(length >> 16);
        data[start + 2] = cast(ubyte)(length >> 8);
        data[start + 3] = cast(ubyte) length;
    }
}

///
unittest
{
    MessageBuilder m;
    m.begin('Q');
    m.putCString("SELECT 1");
    m.finish();
    assert(m.data == cast(const(ubyte)[]) "Q\x00\x00\x00\x0DSELECT 1\x00");

    MessageBuilder s;
    s.begin(0);
    s.putInt32(80_877_103);
    s.finish();
    assert(s.data == [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F]); // SSLRequest
}

/++
Reads backend messages from, and writes frontend messages to, a transport.
+/
final class MessageStream
{
    private BufferedReader reader;
    private BufferedWriter writer;
    private ubyte[] buffer;

    /// The longest message accepted; longer ones throw `ProtocolException`.
    size_t maxMessageLength = defaultMaxMessageLength;

    /// Creates a stream over `transport`.
    this(Transport transport)
    {
        reader = new BufferedReader(transport);
        writer = new BufferedWriter(transport);
    }

    /// Whether received bytes are buffered and not read yet.
    @property bool hasBuffered() const pure nothrow
    {
        return reader.buffered > 0;
    }

    /++
    Reads the next message. Its body stays valid until the next call.

    Throws: `ProtocolException` if the length is invalid; `ConnectionException` on network errors.
    +/
    Message read()
    {
        ubyte[5] header;
        reader.readExact(header[]);
        const length = (cast(uint) header[1] << 24) | (header[2] << 16) | (header[3] << 8) | header[4];
        if (length < 4 || length - 4 > maxMessageLength)
            throw new ProtocolException("Invalid length of a '" ~ cast(char) header[0] ~ "' message");
        const size = length - 4;
        // a buffer grown for a large message isn't kept for the small ones after it
        if (buffer.length > keptBufferSize && size <= keptBufferSize)
            buffer = null;
        if (buffer.length >= size)
            reader.readExact(buffer[0 .. size]);
        else
        {
            // grown as the bytes arrive, so that a length alone never allocates much
            size_t done;
            while (done < size)
            {
                const next = size - done > done + growStep ? done + done + growStep : size;
                if (buffer.length < next)
                    buffer.length = next;
                reader.readExact(buffer[done .. next]);
                done = next;
            }
        }
        return Message(cast(char) header[0], buffer[0 .. size]);
    }

    private enum size_t keptBufferSize = 1 << 20;
    private enum size_t growStep = 1 << 16;

    /// Queues the composed bytes; `flush` sends them.
    void write(scope const(ubyte)[] bytes)
    {
        writer.writeBytes(bytes);
    }

    /// Sends the queued bytes.
    void flush()
    {
        writer.flush();
    }

    /// Queues and sends `bytes`.
    void send(scope const(ubyte)[] bytes)
    {
        writer.writeBytes(bytes);
        writer.flush();
    }
}

unittest
{
    import dbwire.exception : ConnectionException;
    import dbwire.io.mock : MockTransport;
    import std.exception : assertThrown;

    MockTransport mock(string bytes)
    {
        auto t = new MockTransport;
        t.feed(cast(const(ubyte)[]) bytes);
        return t;
    }

    auto s = new MessageStream(mock("Z\x00\x00\x00\x05IS\x00\x00\x00\x04"));
    auto m = s.read();
    assert(m.type == 'Z' && m.data == cast(const(ubyte)[]) "I");
    m = s.read();
    assert(m.type == 'S' && m.data.length == 0);

    s = new MessageStream(mock("E\x00\x00\x00\x02"));
    assertThrown!ProtocolException(s.read());
    s = new MessageStream(mock("D\x7F\x00\x00\x00"));
    assertThrown!ProtocolException(s.read()); // longer than the limit: nothing allocated

    // a length alone allocates at most one growth step; a large buffer isn't kept
    s = new MessageStream(mock("D\x10\x00\x00\x00abc"));
    assertThrown!ConnectionException(s.read()); // the data ends early
    assert(s.buffer.length == 1 << 16);
    auto big = new ubyte[5 + (3 << 20)];
    big[0] = 'D';
    big[1 .. 5] = [0, 0x30, 0, 4];
    big[$ - 1] = 7;
    auto t = new MockTransport;
    t.feed(big);
    t.feed(cast(const(ubyte)[]) "Z\x00\x00\x00\x05I");
    s = new MessageStream(t);
    m = s.read();
    assert(m.type == 'D' && m.data.length == 3 << 20 && m.data[$ - 1] == 7);
    m = s.read();
    assert(m.type == 'Z' && m.data == cast(const(ubyte)[]) "I" && s.buffer.length == 1);
}
