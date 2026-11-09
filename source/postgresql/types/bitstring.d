/++
Bit strings: `bit(n)` and `bit varying` (`varbit`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.bitstring;

import dbwire.io.buffer : fromBigEndian, toBigEndian;

import postgresql.exception : ClientException, ProtocolException;

@safe:

/// A bit string: `length` bits, the first in the high bit of the first byte.
struct BitString
{
    /// The number of bits.
    size_t length;
    /// The bits, 8 per byte, the last byte padded with zero bits.
    immutable(ubyte)[] bytes;

    /// Bit `i` (0 is the first, leftmost).
    bool opIndex(size_t i) const pure
    {
        if (i >= length)
            throw new ClientException("Bit index out of range");
        return (bytes[i / 8] >> (7 - i % 8) & 1) != 0;
    }

    /// The text PostgreSQL writes: `0` and `1` characters.
    string toString() const pure
    {
        auto text = new char[length];
        foreach (i, ref c; text)
            c = this[i] ? '1' : '0';
        return text;
    }

    /++
    Parses a string of `0` and `1` characters (as `B'1010'` without the quotes).

    Throws: `ClientException` for other characters.
    +/
    static BitString parse(string text) pure
    {
        return BitString(text.length, parseBits(text));
    }

    // The bytes of the bits in `text`.
    private static immutable(ubyte)[] parseBits(string text) pure
    {
        auto bytes = new ubyte[(text.length + 7) / 8];
        foreach (i, c; text)
        {
            if (c == '1')
                bytes[i / 8] |= 0x80 >> (i % 8);
            else if (c != '0')
                throw new ClientException("Invalid bit string '" ~ text ~ "'");
        }
        return bytes;
    }

    /// The binary format (`bit_send`): an int32 bit count, then the bytes.
    immutable(ubyte)[] toBinary() const pure
    {
        const n = cast(uint) length;
        return toBigEndian(n) ~ bytes;
    }

    /++
    Reads the binary format.

    Throws: `ProtocolException` for malformed data.
    +/
    static BitString fromBinary(scope const(ubyte)[] data) pure
    {
        if (data.length < 4)
            throw new ProtocolException("Malformed bit string value");
        const n = fromBigEndian!uint(data[0 .. 4]);
        if (data.length != 4 + (cast(size_t) n + 7) / 8)
            throw new ProtocolException("Malformed bit string value");
        return BitString(n, data[4 .. $].idup);
    }
}

///
unittest
{
    const b = BitString.parse("110000101");
    assert(b.length == 9 && b.bytes == [0xC2, 0x80] && b[0] && !b[2] && b.toString() == "110000101");
    assert(BitString.fromBinary(b.toBinary()) == b && BitString.parse("").toString() == "");
}
