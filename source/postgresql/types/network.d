/++
`inet` and `cidr` (IP addresses and networks), `macaddr` and `macaddr8`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.network;

import postgresql.exception : ClientException, ProtocolException;

@safe:

/++
An `inet` or `cidr` value: an IPv4 or IPv6 address with a prefix length
(netmask bits).
+/
struct Inet
{
    /// The address: 4 bytes (IPv4) or 16 (IPv6), in network order.
    immutable(ubyte)[] address;
    /// The prefix length: 0 to 32 (IPv4) or 128 (IPv6).
    ubyte prefix;
    /// Whether it is a `cidr` (a network: no bits set after the prefix) rather than an `inet`.
    bool isCidr;

    /// An IPv4 or IPv6 host address with the full prefix length.
    static Inet host(immutable(ubyte)[] address) pure
    {
        if (address.length != 4 && address.length != 16)
            throw new ClientException("An IP address has 4 or 16 bytes");
        return Inet(address, cast(ubyte)(address.length * 8), false);
    }

    /// Whether it is an IPv6 address.
    @property bool isIPv6() const pure nothrow
    {
        return address.length == 16;
    }

    /++
    The text PostgreSQL writes: the address, `/prefix` unless an `inet` has
    the full prefix length; IPv6 with the longest run of zero groups as `::`
    and an embedded IPv4 address in dotted form (`::ffff:1.2.3.4`).
    +/
    string toString() const pure
    {
        AddressText t;
        if (isIPv6)
            t.ipv6(address);
        else
            t.ipv4(address);
        if (isCidr || prefix != address.length * 8)
        {
            t.put('/');
            t.decimal(prefix);
        }
        return t.chars[0 .. t.length].idup;
    }

    /++
    Parses `inet`/`cidr` text: `192.168.0.1`, `10.0.0.0/8`, `2001:db8::1/64`.

    Throws: `ClientException` for malformed text.
    +/
    static Inet parse(string text, bool isCidr = false) pure
    {
        import std.conv : ConvException, to;
        import std.string : indexOf, strip;

        auto s = text.strip;
        int bitsGiven = -1;
        const slash = s.indexOf('/');
        if (slash >= 0)
        {
            try
                bitsGiven = s[slash + 1 .. $].to!int;
            catch (ConvException)
                throw new ClientException("Invalid prefix length in '" ~ text ~ "'");
            s = s[0 .. slash];
        }
        const bytes = s.indexOf(':') >= 0 ? parseIPv6(s) : parseIPv4(s);
        if (bytes is null)
            throw new ClientException("Invalid IP address '" ~ text ~ "'");
        const bits = cast(int) bytes.length * 8;
        if (bitsGiven < 0)
            bitsGiven = bits;
        if (bitsGiven > bits)
            throw new ClientException("Invalid prefix length in '" ~ text ~ "'");
        return Inet(bytes, cast(ubyte) bitsGiven, isCidr);
    }

    /// The binary format (`inet_send`).
    immutable(ubyte)[] toBinary() const pure
    {
        immutable(ubyte)[] header = [
            isIPv6 ? familyIPv6 : familyIPv4, prefix, isCidr ? 1 : 0, cast(ubyte) address.length
        ];
        return header ~ address;
    }

    /++
    Reads the binary format (`inet_send`).

    Throws: `ProtocolException` for malformed data.
    +/
    static Inet fromBinary(scope const(ubyte)[] data) pure
    {
        if (data.length < 4 || (data[0] != familyIPv4 && data[0] != familyIPv6))
            throw new ProtocolException("Malformed inet value");
        const length = data[0] == familyIPv4 ? 4 : 16;
        if (data[3] != length || data.length != 4 + length || data[1] > length * 8)
            throw new ProtocolException("Malformed inet value");
        return Inet(data[4 .. $].idup, data[1], data[2] != 0);
    }
}

private enum ubyte familyIPv4 = 2, familyIPv6 = 3; // PGSQL_AF_INET, PGSQL_AF_INET6

///
unittest
{
    assert(Inet.parse("192.168.0.1/24").toString() == "192.168.0.1/24");
    assert(Inet.parse("10.0.0.1").toString() == "10.0.0.1");
    assert(Inet.parse("1.2.3.4/32", true).toString() == "1.2.3.4/32");
    assert(Inet.parse("::ffff:1.2.3.4").toString() == "::ffff:1.2.3.4");
    assert(Inet.parse("::0.1.2.3").toString() == "::0.1.2.3" && Inet.parse("::2").toString() == "::2");
    assert(Inet.parse("::ffff:0:1").toString() == "::ffff:0.0.0.1");
    assert(Inet.parse("1:0:0:2:0:0:0:3").toString() == "1:0:0:2::3");
    assert(Inet.parse("1:0:2:0:3:0:4:0").toString() == "1:0:2:0:3:0:4:0");
    assert(Inet.parse("::1:0:0:0:0").toString() == "0:0:0:1::" && Inet.parse("::").toString() == "::");
    assert(Inet.parse("2001:DB8::1/64").toString() == "2001:db8::1/64");
    const i = Inet.parse("10.1.2.3/8");
    assert(Inet.fromBinary(i.toBinary()) == i && i.toBinary() == [2, 8, 0, 4, 10, 1, 2, 3]);
}

// The text of an address, written in place (at most 49 characters: a mapped IPv6 address and a prefix).
private struct AddressText
{
    char[64] chars;
    size_t length;

    void put(char c) pure nothrow @nogc
    {
        chars[length++] = c;
    }

    void decimal(uint v) pure nothrow @nogc
    {
        if (v >= 100)
            put(cast(char)('0' + v / 100));
        if (v >= 10)
            put(cast(char)('0' + v / 10 % 10));
        put(cast(char)('0' + v % 10));
    }

    void hex(uint v) pure nothrow @nogc
    {
        static immutable digits = "0123456789abcdef";
        bool started;
        foreach_reverse (k; 0 .. 4)
        {
            const d = v >> (4 * k) & 15;
            if (d || started || k == 0)
            {
                put(digits[d]);
                started = true;
            }
        }
    }

    void ipv4(scope const(ubyte)[] a) pure nothrow @nogc
    {
        foreach (i; 0 .. 4)
        {
            if (i)
                put('.');
            decimal(a[i]);
        }
    }

    void ipv6(scope const(ubyte)[] a) pure nothrow @nogc
    {
        ushort[8] words;
        foreach (i; 0 .. 8)
            words[i] = cast(ushort)(a[2 * i] << 8 | a[2 * i + 1]);
        // the longest run of zero words (the first of equal ones), if at least 2
        int bestBase = -1, bestLength, currentBase = -1, currentLength;
        foreach (i; 0 .. 8)
        {
            if (words[i] == 0)
            {
                if (currentBase < 0)
                {
                    currentBase = i;
                    currentLength = 0;
                }
                currentLength++;
                if (currentLength > bestLength)
                {
                    bestBase = currentBase;
                    bestLength = currentLength;
                }
            }
            else
                currentBase = -1;
        }
        if (bestLength < 2)
            bestBase = -1;
        foreach (i; 0 .. 8)
        {
            if (bestBase >= 0 && i >= bestBase && i < bestBase + bestLength)
            {
                if (i == bestBase)
                    put(':');
                continue;
            }
            if (i != 0)
                put(':');
            // an IPv4 address embedded (compatible, ::a.b.c.d, or mapped, ::ffff:a.b.c.d)
            if (i == 6 && bestBase == 0 && (bestLength == 6 || (bestLength == 5 && words[5] == 0xFFFF)))
            {
                ipv4(a[12 .. 16]);
                return;
            }
            hex(words[i]);
        }
        if (bestBase >= 0 && bestBase + bestLength == 8)
            put(':');
    }
}

private immutable(ubyte)[] parseIPv4(const(char)[] s) pure
{
    import std.array : split;
    import std.conv : ConvException, to;

    auto parts = s.split(".");
    if (parts.length != 4)
        return null;
    auto a = new ubyte[4];
    foreach (i, p; parts)
    {
        try
        {
            const v = p.to!uint;
            if (v > 255 || p.length == 0)
                return null;
            a[i] = cast(ubyte) v;
        }
        catch (ConvException)
            return null;
    }
    return a;
}

private immutable(ubyte)[] parseIPv6(const(char)[] s) pure
{
    import std.array : split;
    import std.conv : ConvException, to;
    import std.string : indexOf;

    ushort[] head, tail;
    immutable(ubyte)[] ipv4;
    bool parseGroups(const(char)[] part, ref ushort[] into, bool allowIPv4)
    {
        if (part.length == 0)
            return true;
        auto groups = part.split(":");
        foreach (gi, g; groups)
        {
            if (allowIPv4 && gi + 1 == groups.length && g.indexOf('.') >= 0)
            {
                ipv4 = parseIPv4(g);
                if (ipv4 is null)
                    return false;
                continue;
            }
            if (g.length == 0 || g.length > 4)
                return false;
            try
                into ~= g.to!ushort(16);
            catch (ConvException)
                return false;
        }
        return true;
    }

    const gap = s.indexOf("::");
    if (gap >= 0)
    {
        if (s[gap + 2 .. $].indexOf("::") >= 0)
            return null;
        if (!parseGroups(s[0 .. gap], head, false) || !parseGroups(s[gap + 2 .. $], tail, true))
            return null;
    }
    else if (!parseGroups(s, head, true))
        return null;
    const words = head.length + tail.length + (ipv4 !is null ? 2 : 0);
    if (words > 8 || (gap < 0 && words != 8) || (gap >= 0 && words == 8))
        return null;
    auto a = new ubyte[16];
    foreach (i, w; head)
    {
        a[2 * i] = cast(ubyte)(w >> 8);
        a[2 * i + 1] = cast(ubyte) w;
    }
    const tailStart = 16 - (ipv4 !is null ? 4 : 0) - tail.length * 2;
    foreach (i, w; tail)
    {
        a[tailStart + 2 * i] = cast(ubyte)(w >> 8);
        a[tailStart + 2 * i + 1] = cast(ubyte) w;
    }
    if (ipv4 !is null)
        a[12 .. 16] = ipv4[];
    return a;
}

/// A `macaddr` (6 bytes) or `macaddr8` (8 bytes) as PostgreSQL writes it: `08:00:2b:01:02:03`.
string macAddressText(scope const(ubyte)[] bytes) pure
{
    import std.format : format;

    string text;
    foreach (i, b; bytes)
        text ~= (i ? ":" : "") ~ format("%02x", b);
    return text;
}

/++
Parses a MAC address (`08:00:2b:01:02:03`, also with `-` or `.` separators
or none) into its bytes.

Throws: `ClientException` for malformed text.
+/
immutable(ubyte)[] parseMacAddress(string text) pure
{
    import std.ascii : isHexDigit;
    import std.conv : to;

    char[] digits;
    foreach (c; text)
    {
        if (isHexDigit(c))
            digits ~= c;
        else if (c != ':' && c != '-' && c != '.')
            throw new ClientException("Invalid MAC address '" ~ text ~ "'");
    }
    if (digits.length != 12 && digits.length != 16)
        throw new ClientException("Invalid MAC address '" ~ text ~ "'");
    auto bytes = new ubyte[digits.length / 2];
    foreach (i, ref b; bytes)
        b = digits[2 * i .. 2 * i + 2].to!ubyte(16);
    return bytes;
}

///
unittest
{
    assert(macAddressText([8, 0, 0x2b, 1, 2, 3]) == "08:00:2b:01:02:03");
    assert(parseMacAddress("08-00-2B-01-02-03") == [8, 0, 0x2b, 1, 2, 3]);
}
