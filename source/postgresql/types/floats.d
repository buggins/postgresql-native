/++
Text of `float4` and `float8` values as PostgreSQL 12 and later print them
(with the default `extra_float_digits = 1`): the shortest decimal that reads
back exactly and is not exactly halfway to a neighbouring value (the server
doesn't count on round-half-even for those: checked, e.g. it prints
`-3.6681927456064224e+16`, not the 16-digit tie `-3.668192745606422e+16`), in plain notation when the decimal exponent X (value =
d.ddd × 10^X) is at least -4 and below 15 (`float8`) or 6 (`float4`), else as
`d.ddde+XX` with at least two exponent digits; `NaN`, `Infinity`,
`-Infinity`, `-0`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.floats;

import std.bigint : BigInt;

@safe:

/// The text of a `float8` value.
string formatFloat8(double value)
{
    return formatShortest!double(value, 15);
}

/// The text of a `float4` value.
string formatFloat4(float value)
{
    return formatShortest!float(value, 6);
}

///
unittest
{
    import std.math : ldexp;

    assert(formatFloat8(1e14) == "100000000000000" && formatFloat8(1e15) == "1e+15");
    assert(formatFloat8(1_234_567_890_123_456) == "1.234567890123456e+15" && formatFloat8(0.0001) == "0.0001");
    assert(formatFloat8(0.00001) == "1e-05" && formatFloat8(0.000123) == "0.000123" && formatFloat8(1.5) == "1.5");
    assert(formatFloat8(-0.0) == "-0" && formatFloat8(0.0) == "0" && formatFloat8(cast(double) 1e-310L) == "1e-310");
    assert(formatFloat8(double.max) == "1.7976931348623157e+308" && formatFloat8(0.1) == "0.1");
    assert(formatFloat8(12_345_678_901_234_567_890.0) == "1.2345678901234567e+19");
    assert(formatFloat8(ldexp(1.0, -1074)) == "5e-324");
    assert(formatFloat8(123.456e10) == "1234560000000" && formatFloat8(double.nan) == "NaN");
    assert(formatFloat8(-double.infinity) == "-Infinity" && formatFloat8(-1.25) == "-1.25");
    assert(formatFloat8(-36_681_927_456_064_224.0) == "-3.6681927456064224e+16"); // not the 16-digit tie
    assert(formatFloat4(1e5f) == "100000" && formatFloat4(1e6f) == "1e+06");
    assert(formatFloat4(1_234_567f) == "1.234567e+06");
    assert(formatFloat4(12_345_678f) == "1.2345678e+07" && formatFloat4(1.1f) == "1.1");
    assert(formatFloat4(float.max) == "3.4028235e+38" && formatFloat4(ldexp(1.0f, -149)) == "1e-45");
}

// Whether the decimal `text` ([-]d.ddde±X) is exactly halfway between `value` and a neighbour.
private bool isTie(T)(string text, T value) @trusted
{
    import std.conv : to;
    import std.math : abs, nextDown, nextUp;

    // the decimal as digits × 10^exponent10
    auto s = text[0] == '-' ? text[1 .. $] : text;
    size_t e;
    foreach (i, c; s)
        if (c == 'e')
            e = i;
    string digits;
    long fractionDigits;
    bool afterPoint;
    foreach (c; s[0 .. e])
    {
        if (c == '.')
            afterPoint = true;
        else
        {
            digits ~= c;
            if (afterPoint)
                fractionDigits++;
        }
    }
    const exponent10 = s[e + 1 .. $].to!long - fractionDigits;
    const decimal = BigInt(digits);

    // midpoint between the magnitude and its neighbour on the decimal's side: sum × 2^(emin - 1)
    const magnitude = abs(value);
    const a = exact(magnitude);
    const side = compareExact(decimal, exponent10, a.mantissa, a.exponent);
    if (side == 0)
        return false; // the decimal is the value itself
    const b = exact(side > 0 ? nextUp(magnitude) : nextDown(magnitude));
    const emin = a.exponent < b.exponent ? a.exponent : b.exponent;
    const sum = (a.mantissa << (a.exponent - emin)) + (b.mantissa << (b.exponent - emin));
    return compareExact(decimal, exponent10, sum, emin - 1) == 0;
}

// Compares decimal × 10^exponent10 with binary × 2^exponent2 exactly: -1, 0 or 1.
private int compareExact(const BigInt decimal, long exponent10, const BigInt binary, long exponent2) @trusted
{
    BigInt left = decimal, right = binary;
    if (exponent10 >= 0)
        left *= BigInt(10) ^^ exponent10;
    else
        right *= BigInt(10) ^^ -exponent10;
    if (exponent2 >= 0)
        right <<= exponent2;
    else
        left <<= -exponent2;
    return left < right ? -1 : left > right ? 1 : 0;
}

private struct Exact
{
    BigInt mantissa;
    int exponent;
}

// A finite non-negative value as mantissa × 2^exponent (mantissa an integer below 2^mant_dig).
private Exact exact(T)(T value) @trusted
{
    import std.math : ilogb, ldexp;

    enum bits = T.mant_dig;
    const e = ilogb(value) + 1; // value = m × 2^e with 0.5 <= m < 1 (subnormals included)
    return Exact(BigInt(cast(ulong) ldexp(cast(double) value, bits - e)), e - bits);
}

// Reads a number as C's strtod/strtof do: correctly rounded, subnormals included, out of range = infinity.
private T parseC(T)(string text) @trusted
{
    import core.stdc.stdlib : strtod, strtof;
    import std.string : toStringz;

    // strtod reads the NUL-terminated copy and keeps no pointer to it
    static if (is(T == float))
        return strtof(text.toStringz, null);
    else
        return strtod(text.toStringz, null);
}

private string formatShortest(T)(T value, int plainLimit)
{
    import std.conv : to;
    import std.format : format;
    import std.math : isInfinity, isNaN, signbit;

    if (isNaN(value))
        return "NaN";
    if (isInfinity(value))
        return value > 0 ? "Infinity" : "-Infinity";
    if (value == 0)
        return signbit(value) ? "-0" : "0";

    // the fewest significant digits that read back as the same value
    enum maxDigits = is(T == float) ? 9 : 17;
    string scientific;
    foreach (precision; 1 .. maxDigits + 1)
    {
        scientific = format("%.*e", precision - 1, value);
        if (parseC!T(scientific) == value && !isTie(scientific, value))
            break;
    }
    // scientific: [-]d[.ddd]e(+|-)XX
    const negative = scientific[0] == '-';
    auto s = negative ? scientific[1 .. $] : scientific;
    size_t e;
    foreach (i, c; s)
        if (c == 'e')
            e = i;
    string digits;
    foreach (c; s[0 .. e])
        if (c != '.')
            digits ~= c;
    while (digits.length > 1 && digits[$ - 1] == '0')
        digits = digits[0 .. $ - 1];
    const exponent = s[e + 1 .. $].to!int;

    string text;
    if (exponent < -4 || exponent >= plainLimit)
    {
        text = digits[0 .. 1];
        if (digits.length > 1)
            text ~= "." ~ digits[1 .. $];
        text ~= format("e%s%02d", exponent < 0 ? "-" : "+", exponent < 0 ? -exponent : exponent);
    }
    else if (exponent >= 0)
    {
        if (digits.length <= exponent + 1)
        {
            text = digits;
            foreach (i; digits.length .. exponent + 1)
                text ~= '0';
        }
        else
            text = digits[0 .. exponent + 1] ~ "." ~ digits[exponent + 1 .. $];
    }
    else
    {
        text = "0.";
        foreach (i; 0 .. -exponent - 1)
            text ~= '0';
        text ~= digits;
    }
    return negative ? "-" ~ text : text;
}
