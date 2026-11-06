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
        import std.format : format;

        final switch (kind)
        {
        case Kind.nan:
            return "NaN";
        case Kind.positiveInfinity:
            return "Infinity";
        case Kind.negativeInfinity:
            return "-Infinity";
        case Kind.finite:
            break;
        }
        ushort digitAt(long i) // base-10000 digit with weight `i`
        {
            const index = weight - i;
            return index >= 0 && index < digits.length ? digits[cast(size_t) index] : 0;
        }

        string text = negative ? "-" : "";
        if (weight < 0)
            text ~= "0";
        else
        {
            text ~= format("%d", digitAt(weight));
            foreach_reverse (i; 0 .. weight)
                text ~= format("%04d", digitAt(i));
        }
        if (displayScale > 0)
        {
            string fraction;
            for (long i = -1; fraction.length < displayScale; i--)
                fraction ~= format("%04d", digitAt(i));
            text ~= "." ~ fraction[0 .. displayScale];
        }
        return text;
    }

    /++
    The value as a dbwire `Decimal`, with `displayScale` as its scale.

    Throws: `ClientException` for NaN, an infinity, or more than 76 digits.
    +/
    Decimal toDecimal() const
    {
        if (kind != Kind.finite)
            throw new ClientException("A numeric " ~ toString() ~ " can't be a Decimal");
        try
            return Decimal.fromString(toString());
        catch (Exception e)
            throw new ClientException("The numeric value has too many digits for a Decimal (76 at most)");
    }

    /// The value as a `double` (NaN and infinities included), rounded to the nearest.
    double toDouble() const
    {
        import std.conv : to;

        final switch (kind)
        {
        case Kind.nan:
            return double.nan;
        case Kind.positiveInfinity:
            return double.infinity;
        case Kind.negativeInfinity:
            return -double.infinity;
        case Kind.finite:
            return toString().to!double;
        }
    }

    /// Whether the value is finite and has no fractional part (whatever its display scale).
    @property bool isIntegral() const pure nothrow
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
    assert(Numeric.decode([0, 0, 0, 0, 0xC0, 0, 0, 0]).toString() == "NaN");
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
            data ~= [cast(ubyte)(v >> 8), cast(ubyte) v];
    }

    ubyte[] data;
    switch (s)
    {
    case "NaN":
        header(data, 0, 0, NumericSign.nan, 0);
        return (() @trusted => cast(immutable) data)();
    case "Infinity":
        header(data, 0, 0, NumericSign.positiveInfinity, 0);
        return (() @trusted => cast(immutable) data)();
    case "-Infinity":
        header(data, 0, 0, NumericSign.negativeInfinity, 0);
        return (() @trusted => cast(immutable) data)();
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
        data ~= [cast(ubyte)(g >> 8), cast(ubyte) g];
    return (() @trusted => cast(immutable) data)(); // not referenced elsewhere
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
