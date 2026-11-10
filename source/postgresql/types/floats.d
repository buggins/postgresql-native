/++
Text of `float4` and `float8` values as PostgreSQL 12 and later print them
(with the default `extra_float_digits = 1`): the shortest decimal that reads
back exactly and is not exactly halfway to a neighbouring value (the server's
Ryu doesn't count on round-half-even for those, e.g. it prints
`-3.6681927456064224e+16`, not the 16-digit tie `-3.668192745606422e+16`;
dbwire's `shortestDigits` with `Ties.avoid`), in plain notation when the
decimal exponent X (value = d.ddd × 10^X) is at least -4 and below 15
(`float8`) or 6 (`float4`), else as `d.ddde+XX` with at least two exponent
digits (dbwire's `formatDigits` with `FloatLayout(-4, 15 or 6, false)`); `NaN`,
`Infinity`, `-Infinity`, `-0`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.floats;

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

/++
Reads a float8 as the server writes it (`1.5`, `1e+20`, `NaN`, `-Infinity`),
correctly rounded.

Throws: `ClientException` if `text` is not a number.
+/
package(postgresql) double parseFloat8(string text)
{
    import postgresql.exception : ClientException;

    if (isFloatText(text))
    {
        const r = parseC!double(text);
        if (r.complete)
            return r.value;
    }
    throw new ClientException("Invalid number '" ~ text ~ "'");
}

// Whether `text` looks like float text as the server reads it: digits with a sign, point and exponent, or NaN,
// Infinity or inf in any case. strtod also takes leading spaces, hexadecimal numbers and `nan(...)`.
private bool isFloatText(scope const(char)[] text) pure nothrow @nogc
{
    import std.ascii : isDigit;
    import postgresql.types.textformat : equalsIgnoringCase;

    const s = text.length && (text[0] == '-' || text[0] == '+') ? text[1 .. $] : text;
    if (equalsIgnoringCase(s, "infinity") || equalsIgnoringCase(s, "inf") || equalsIgnoringCase(text, "nan"))
        return true;
    bool digits;
    foreach (c; s)
    {
        if (isDigit(c))
            digits = true;
        else if (c != '.' && c != 'e' && c != 'E' && c != '-' && c != '+')
            return false;
    }
    return digits;
}

// What parseC read: the value, and whether it read the whole text.
private struct Parsed(T)
{
    T value;
    bool complete;
}

// Reads a number as C's strtod/strtof do: correctly rounded, subnormals included, out of range = infinity.
// strtod reads the decimal point of the C library's locale (LC_NUMERIC: "." unless the application called
// setlocale, as GUI toolkits do).
private Parsed!T parseC(T)(string text) if (is(T == float) || is(T == double))
{
    import std.array : replace;

    const point = decimalPoint();
    return strtodCopy!T(point == "." ? text : text.replace(".", point));
}

// strtod (strtof for float) on a NUL-terminated copy of `text`, on the stack when it is short.
private Parsed!T strtodCopy(T)(scope const(char)[] text) @trusted if (is(T == float) || is(T == double))
{
    import core.stdc.stdlib : strtod, strtof;

    char[64] stack = void;
    char[] z = text.length < stack.length ? stack[0 .. text.length + 1] : new char[text.length + 1];
    z[0 .. $ - 1] = text[];
    z[$ - 1] = 0;
    char* end; // strtod keeps no pointer to z
    static if (is(T == float))
        const value = strtof(z.ptr, &end);
    else
        const value = strtod(z.ptr, &end);
    return Parsed!T(value, end == z.ptr + text.length); // also false when there is a NUL in the text
}

// The decimal point of the C library's locale.
private string decimalPoint() @trusted
{
    import core.stdc.locale : localeconv;
    import std.string : fromStringz;

    // localeconv's strings stay valid until the next setlocale: copied
    const lc = localeconv();
    if (lc is null || lc.decimal_point is null)
        return ".";
    const point = fromStringz(lc.decimal_point);
    return point == "." ? "." : point.idup;
}

@safe unittest
{
    import postgresql.exception : ClientException;
    import std.array : replicate;
    import std.exception : assertThrown;

    assert(parseFloat8("1.5") == 1.5 && parseFloat8("-Infinity") == -double.infinity);
    assertThrown!ClientException(parseFloat8(""));
    assertThrown!ClientException(parseFloat8("1.5x"));
    assertThrown!ClientException(parseFloat8("1.5\0x"));
    assert(parseFloat8("NaN") != parseFloat8("NaN") && parseFloat8("-inf") == -double.infinity);
    assert(parseFloat8("1e+20") == 1e20 && parseFloat8(".5") == 0.5);
    foreach (bad; [" 12", "0x1A", "nan(5)", "1e", "-", "1-2", "e5"])
        assertThrown!ClientException(parseFloat8(bad));
    assert(parseFloat8("0." ~ "0000000000".replicate(10) ~ "1") == 1e-101); // longer than the stack buffer
}

@system unittest
{
    import core.stdc.locale : LC_NUMERIC, setlocale;
    import std.string : fromStringz, toStringz;

    // with a locale whose decimal point is a comma, where the system has one
    const saved = fromStringz(setlocale(LC_NUMERIC, null)).idup;
    scope (exit)
        setlocale(LC_NUMERIC, saved.toStringz);
    foreach (name; ["de_DE.UTF-8", "de_DE.utf8", "fr_FR.UTF-8", "German_Germany.1252"])
        if (setlocale(LC_NUMERIC, name.ptr) !is null)
        {
            assert(parseFloat8("1.5") == 1.5 && parseFloat8("-2.5e-3") == -2.5e-3);
            assert(formatFloat8(0.1) == "0.1");
            break;
        }
}

private string formatShortest(T)(T value, int plainLimit)
{
    import dbwire.types.floattext : FloatLayout, formatDigits, shortestDigits, Ties;
    import std.math : isInfinity, isNaN, signbit;

    if (isNaN(value))
        return "NaN";
    if (isInfinity(value))
        return value > 0 ? "Infinity" : "-Infinity";
    if (value == 0)
        return signbit(value) ? "-0" : "0";

    // plain from 1e-4 up to below 10^plainLimit, else 1.5e+300
    return formatDigits(shortestDigits(value, Ties.avoid), signbit(value) != 0, FloatLayout(-4, plainLimit, false));
}
