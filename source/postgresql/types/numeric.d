/++
`numeric`: the binary format and its exact text.

A binary `numeric` is int16 count of digits, int16 weight, uint16 sign, int16
display scale, then the digits in base 10000, most significant first. The
value is `sum(digit[i] * 10000^(weight - i))`; the display scale is the
number of decimal digits after the point.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.numeric;

import dbwire.io.buffer : toBigEndian;
import dbwire.types.decimal : Decimal;

import postgresql.exception : ClientException, ProtocolException;
import postgresql.protocol.messages : MessageBody;

@safe:

/// The sign field of a binary `numeric`.
private enum NumericSign : ushort
{
    positive = 0x0000,
    negative = 0x4000,
    nan = 0xC000,
    positiveInfinity = 0xD000, // PostgreSQL 14 and later
    negativeInfinity = 0xF000, // ditto
}

/// A decoded `numeric` value.
struct Numeric
{
    /// Kinds of values.
    enum Kind
    {
        finite, ///
        nan, ///
        positiveInfinity, ///
        negativeInfinity, ///
    }

    /// Finite, NaN or an infinity.
    Kind kind;
    /// Whether a finite value is negative.
    bool negative;
    /// Weight of the first digit (power of 10000).
    short weight;
    /// Number of decimal digits after the point.
    ushort displayScale;
    /// Base-10000 digits, most significant first.
    const(ushort)[] digits;

    /++
    Decodes the binary format.

    Throws: `ProtocolException` if it is malformed.
    +/
    static Numeric decode(const(ubyte)[] bytes)
    {
        auto b = MessageBody(bytes, 'D');
        Numeric n;
        const count = b.readInt16();
        n.weight = b.readInt16();
        const sign = cast(ushort) b.readInt16();
        const scale = b.readInt16();
        if (count < 0 || scale < 0)
            throw new ProtocolException("Malformed numeric value");
        n.displayScale = cast(ushort) scale;
        switch (sign)
        {
        case NumericSign.positive:
            break;
        case NumericSign.negative:
            n.negative = true;
            break;
        case NumericSign.nan:
            n.kind = Kind.nan;
            return n;
        case NumericSign.positiveInfinity:
            n.kind = Kind.positiveInfinity;
            return n;
        case NumericSign.negativeInfinity:
            n.kind = Kind.negativeInfinity;
            return n;
        default:
            throw new ProtocolException("Malformed numeric value: invalid sign");
        }
        auto d = new ushort[count];
        foreach (ref digit; d)
        {
            const v = b.readInt16();
            if (v < 0 || v > 9999)
                throw new ProtocolException("Malformed numeric value: invalid digit");
            digit = cast(ushort) v;
        }
        if (!b.empty)
            throw new ProtocolException("Malformed numeric value: extra bytes");
        n.digits = d;
        return n;
    }

    /// The value as PostgreSQL prints it: exact, with `displayScale` digits after the point; `NaN`, `Infinity`.
    string toString() const pure
    {
        final switch (kind)
        {
        case Kind.nan:
            return "NaN";
        case Kind.positiveInfinity:
            return "Infinity";
        case Kind.negativeInfinity:
            return "-Infinity";
        case Kind.finite:
            auto text = new char[textLength];
            writeText(text);
            return text;
        }
    }

    /++
    The value as a `long`, when it is integral (`isIntegral`).

    Throws: `ClientException` if it is out of `long`'s range.
    +/
    package(postgresql) long toLong() const pure
    {
        const m = magnitude();
        if (m.fits && negative && m.value <= cast(ulong) long.max + 1)
            return cast(long)(0 - m.value); // two's complement: also right for long.min
        if (m.fits && !negative && m.value <= long.max)
            return cast(long) m.value;
        throw new ClientException("The numeric value " ~ toString() ~ " is out of long's range");
    }

    /++
    The value as a `ulong`, when it is integral (`isIntegral`).

    Throws: `ClientException` if it is out of `ulong`'s range.
    +/
    package(postgresql) ulong toUlong() const pure
    {
        const m = magnitude();
        if (m.fits && (!negative || m.value == 0))
            return m.value;
        throw new ClientException("The numeric value " ~ toString() ~ " is out of ulong's range");
    }

    private static struct Magnitude
    {
        ulong value;
        bool fits; // false beyond ulong.max
    }

    // The absolute value of an integral value.
    private Magnitude magnitude() const pure nothrow @nogc
    {
        assert(isIntegral);
        Magnitude m = {fits: true};
        for (long w = weight; w >= 0 && m.fits; w--)
        {
            const d = digitAt(w);
            m.fits = m.value <= (ulong.max - d) / 10_000;
            m.value = m.value * 10_000 + d;
        }
        return m;
    }

    // The base-10000 digit with weight `i` (0 beyond the stored digits).
    private ushort digitAt(long i) const pure nothrow @nogc
    {
        const index = weight - i;
        return index >= 0 && index < digits.length ? digits[cast(size_t) index] : 0;
    }

    // The length of the text of a finite value.
    private size_t textLength() const pure nothrow @nogc
    {
        size_t length = negative ? 1 : 0;
        if (weight < 0)
            length += 1;
        else
        {
            const first = digitAt(weight);
            length += (first >= 1000 ? 4 : first >= 100 ? 3 : first >= 10 ? 2 : 1) + 4 * cast(size_t) weight;
        }
        return displayScale > 0 ? length + 1 + displayScale : length;
    }

    // Writes the text of a finite value into `text` (`textLength` characters).
    private void writeText(scope char[] text) const pure nothrow @nogc
    {
        size_t at;
        void group(ushort d, size_t width) // the last `width` of its 4 digits
        {
            foreach_reverse (k; 0 .. width)
            {
                text[at + k] = cast(char)('0' + d % 10);
                d /= 10;
            }
            at += width;
        }

        if (negative)
            text[at++] = '-';
        if (weight < 0)
            text[at++] = '0';
        else
        {
            const first = digitAt(weight);
            group(first, first >= 1000 ? 4 : first >= 100 ? 3 : first >= 10 ? 2 : 1);
            foreach_reverse (i; 0 .. weight)
                group(digitAt(i), 4);
        }
        if (displayScale > 0)
        {
            text[at++] = '.';
            for (long i = -1; at < text.length; i--)
            {
                const left = text.length - at;
                if (left >= 4)
                    group(digitAt(i), 4);
                else
                {
                    ushort d = digitAt(i);
                    foreach (k; left .. 4)
                        d /= 10; // the first `left` digits
                    group(d, left);
                }
            }
        }
    }

    /++
    The value as a dbwire `Decimal`, with `displayScale` as its scale.

    Throws: `ClientException` for NaN, an infinity, or more than 76 digits.
    +/
    Decimal toDecimal() const
    {
        if (kind != Kind.finite)
            throw new ClientException("A numeric " ~ toString() ~ " can't be a Decimal");
        char[128] buffer;
        const length = textLength;
        auto text = length <= buffer.length ? buffer[0 .. length] : new char[length];
        writeText(text);
        try
            return Decimal.fromString(text);
        catch (ClientException)
            throw new ClientException("The numeric value has too many digits for a Decimal (76 at most)");
    }

    /// The value as a `double` (NaN and infinities included), correctly rounded; beyond `double.max`, an infinity.
    double toDouble() const
    {
        final switch (kind)
        {
        case Kind.nan:
            return double.nan;
        case Kind.positiveInfinity:
            return double.infinity;
        case Kind.negativeInfinity:
            return -double.infinity;
        case Kind.finite:
            break;
        }
        if (digits.length == 0)
            return 0;
        // all the digits and an exponent, `[-]dddd...e-n`: no decimal point, which would depend on the locale
        char[256] stack;
        const length = 4 * digits.length + 16; // sign, digits, "e-", up to 6 exponent digits, NUL
        auto text = length <= stack.length ? stack[] : new char[length];
        size_t at;
        if (negative)
            text[at++] = '-';
        foreach (digit; digits)
        {
            ushort d = digit;
            foreach_reverse (k; 0 .. 4)
            {
                text[at + k] = cast(char)('0' + d % 10);
                d /= 10;
            }
            at += 4;
        }
        long exponent = 4 * (weight - cast(long) digits.length + 1);
        text[at++] = 'e';
        if (exponent < 0)
        {
            text[at++] = '-';
            exponent = -exponent;
        }
        char[20] digitsOfExponent;
        size_t e = digitsOfExponent.length;
        do
        {
            digitsOfExponent[--e] = cast(char)('0' + exponent % 10);
            exponent /= 10;
        }
        while (exponent);
        text[at .. at + digitsOfExponent.length - e] = digitsOfExponent[e .. $];
        at += digitsOfExponent.length - e;
        text[at] = 0;
        // strtod rounds correctly and gives an infinity beyond double.max; it keeps no pointer to the text
        return (() @trusted { import core.stdc.stdlib : strtod;

        return strtod(&text[0], null); })();
    }

    /// Whether the value is finite and has no fractional part (whatever its display scale).
    @property bool isIntegral() const pure nothrow @nogc
    {
        if (kind != Kind.finite)
            return false;
        foreach (i, d; digits)
            if (weight - cast(long) i < 0 && d != 0)
                return false;
        return true;
    }
}

///
unittest
{
    import std.exception : assertThrown;

    // 123456789.12 (dscale 2): digits 1, 2345, 6789, 1200; weight 2
    static immutable ubyte[] v = [0, 4, 0, 2, 0, 0, 0, 2, 0, 1, 0x09, 0x29, 0x1A, 0x85, 0x04, 0xB0];
    const n = Numeric.decode(v);
    assert(n.toString() == "123456789.12" && n.toDecimal().toFixedString() == "123456789.12");
    assert(n.toDouble() == 123_456_789.12 && !n.isIntegral);
    // -0.0001 (dscale 4): digit 1 at weight -1
    assert(Numeric.decode([0, 1, 0xFF, 0xFF, 0x40, 0, 0, 4, 0, 1]).toString() == "-0.0001");
    // 0.00 (no digits, dscale 2)
    assert(Numeric.decode([0, 0, 0, 0, 0, 0, 0, 2]).toString() == "0.00");
    // 1e30: digit 100 at weight 7
    assert(Numeric.decode([0, 1, 0, 7, 0, 0, 0, 0, 0, 100]).toString() == "1000000000000000000000000000000");
    // 1e400 and -1e400 (digit 1 at weight 100): beyond double
    assert(Numeric.decode([0, 1, 0, 100, 0, 0, 0, 0, 0, 1]).toDouble() == double.infinity);
    assert(Numeric.decode([0, 1, 0, 100, 0x40, 0, 0, 0, 0, 1]).toDouble() == -double.infinity);
    assert(Numeric.decode([0, 0, 0, 0, 0xC0, 0, 0, 0]).toString() == "NaN");
    // 0.1 (dscale 1), 12.5 (digits 12, 5000, dscale 3), -1000.00001 (dscale 5)
    assert(Numeric.decode([0, 1, 0xFF, 0xFF, 0, 0, 0, 1, 0x03, 0xE8]).toDouble() == 0.1);
    const n2 = Numeric.decode([0, 2, 0, 0, 0, 0, 0, 3, 0, 12, 0x13, 0x88]);
    assert(n2.toString() == "12.500" && n2.toDouble() == 12.5 && n2.toDecimal().toFixedString() == "12.500");
    const n3 = Numeric.decode([0, 3, 0, 0, 0x40, 0, 0, 5, 0x03, 0xE8, 0, 0, 0x03, 0xE8]);
    assert(n3.toString() == "-1000.00001" && n3.toDouble() == -1000.00001);
    assert(Numeric.decode([0, 1, 0, 0, 0, 0, 0, 2, 0, 5]).toLong() == 5); // 5.00
    // long.min = -9223372036854775808: digits 922, 3372, 0368, 5477, 5808 at weights 4 .. 0
    assert(Numeric.decode([
        0, 5, 0, 4, 0x40, 0, 0, 0, 0x03, 0x9A, 0x0D, 0x2C, 0x01, 0x70, 0x15, 0x65, 0x16, 0xB0
    ])
        .toLong() == long.min);
    assertThrown!ClientException(Numeric.decode([
        0, 5, 0, 4, 0, 0, 0, 0, 0x03, 0x9A, 0x0D, 0x2C, 0x01, 0x70, 0x15,
        0x65, 0x16, 0xB0
    ]).toLong()); // 9223372036854775808
    assertThrown!ClientException(Numeric.decode([0, 1, 0, 100, 0, 0, 0, 0, 0, 1]).toLong()); // 10^400
    assert(Numeric.decode([
        0, 5, 0, 4, 0, 0, 0, 0, 0x03, 0x9A, 0x0D, 0x2C, 0x01, 0x70, 0x15, 0x65, 0x16, 0xB0
    ]).toUlong() == 9_223_372_036_854_775_808UL);
    // ulong.max = 18446744073709551615: 1844, 6744, 0737, 0955, 1615; then 18446744073709551616
    assert(Numeric.decode([
        0, 5, 0, 4, 0, 0, 0, 0, 0x07, 0x34, 0x1A, 0x58, 0x02, 0xE1, 0x03, 0xBB, 0x06, 0x4F
    ]).toUlong() == ulong.max);
    assertThrown!ClientException(Numeric.decode([
        0, 5, 0, 4, 0, 0, 0, 0, 0x07, 0x34, 0x1A, 0x58, 0x02, 0xE1, 0x03, 0xBB, 0x06, 0x50
    ]).toUlong());
    assertThrown!ClientException(Numeric.decode([0, 1, 0, 0, 0x40, 0, 0, 0, 0, 5]).toUlong()); // -5
    // the longest exponent: many digits at the lowest weight (only a malformed value has them)
    ubyte[] bytes = [0, 62, 0x80, 0, 0x40, 0, 0, 0];
    foreach (i; 0 .. 62)
        bytes ~= [ubyte(0), 1];
    assert(Numeric.decode(bytes).toDouble() == -0.0);
    assert(Numeric.decode([0, 0, 0, 0, 0xF0, 0, 0, 0]).toString() == "-Infinity");
    assertThrown!ClientException(Numeric.decode([0, 0, 0, 0, 0xD0, 0, 0, 0]).toDecimal());
    assertThrown!ProtocolException(Numeric.decode([0, 1, 0, 0, 0, 0, 0, 0, 0x27, 0x10])); // digit 10000
    assertThrown!ProtocolException(Numeric.decode([0, 2, 0, 0, 0, 0, 0, 0, 0, 1])); // truncated
    assertThrown!ProtocolException(Numeric.decode([0, 0, 0, 0, 0x12, 0x34, 0, 0])); // sign
}

/++
The binary format of the numeric written as `text` (`-12.340`, `1e3` is not
accepted; `NaN`, `Infinity`, `-Infinity`): what `numeric_send` would send
for it, the display scale being the number of digits after the point.

Throws: `ClientException` if `text` is not a decimal number.
+/
immutable(ubyte)[] encodeNumericText(string text) pure
{
    import std.string : strip;

    const s = text.strip;
    ushort sign = NumericSign.positive;
    void header(ref ubyte[] data, int count, int weight, ushort signBits, int scale)
    {
        foreach (v; [count, weight, cast(int) signBits, scale])
            data ~= toBigEndian(cast(ushort) v)[];
    }

    ubyte[] data;
    switch (s)
    {
    case "NaN":
        header(data, 0, 0, NumericSign.nan, 0);
        return data;
    case "Infinity":
        header(data, 0, 0, NumericSign.positiveInfinity, 0);
        return data;
    case "-Infinity":
        header(data, 0, 0, NumericSign.negativeInfinity, 0);
        return data;
    default:
        break;
    }
    string digits = s;
    if (digits.length && (digits[0] == '-' || digits[0] == '+'))
    {
        if (digits[0] == '-')
            sign = NumericSign.negative;
        digits = digits[1 .. $];
    }
    string intPart = digits, fracPart;
    foreach (i, c; digits)
        if (c == '.')
        {
            intPart = digits[0 .. i];
            fracPart = digits[i + 1 .. $];
            break;
        }
    if (intPart.length + fracPart.length == 0)
        throw new ClientException("Invalid numeric '" ~ text ~ "'");
    foreach (c; intPart ~ fracPart)
        if (c < '0' || c > '9')
            throw new ClientException("Invalid numeric '" ~ text ~ "'");
    const scale = cast(int) fracPart.length;
    // align to groups of 4 digits around the point
    const intPad = (4 - intPart.length % 4) % 4;
    const fracPad = (4 - fracPart.length % 4) % 4;
    string all;
    foreach (k; 0 .. intPad)
        all ~= '0';
    all ~= intPart;
    all ~= fracPart;
    foreach (k; 0 .. fracPad)
        all ~= '0';
    const intGroups = cast(int)((intPad + intPart.length) / 4);
    short[] groups;
    for (size_t i = 0; i < all.length; i += 4)
        groups ~= cast(short)((all[i] - '0') * 1000 + (all[i + 1] - '0') * 100 + (all[i + 2] - '0') * 10
                + (
                    all[i + 3] - '0'));
    int weight = intGroups - 1;
    // strip leading and trailing zero groups
    size_t first;
    while (first < groups.length && groups[first] == 0)
    {
        first++;
        weight--;
    }
    size_t last = groups.length;
    while (last > first && groups[last - 1] == 0)
        last--;
    if (first == last)
    {
        weight = 0;
        sign = NumericSign.positive;
    }
    header(data, cast(int)(last - first), weight, sign, scale);
    foreach (g; groups[first .. last])
        data ~= toBigEndian(cast(ushort) g)[];
    return data;
}

///
unittest
{
    foreach (text; [
        "0", "1", "-12.340", "12345678.9", "0.0001", "10000", "-0.5", "123456789012345678901234567890",
        "NaN", "Infinity", "0.00", "100.000100"
    ])
    {
        const n = Numeric.decode(encodeNumericText(text));
        const expected = text == "-0.5" ? "-0.5" : text;
        assert(n.toString() == expected, text ~ " -> " ~ n.toString());
    }
    // the server's own bytes for 2.5 (weight 0, scale 1, digits 2 and 5000)
    assert(encodeNumericText("2.5") == [0, 2, 0, 0, 0, 0, 0, 1, 0, 2, 0x13, 0x88]);
}
