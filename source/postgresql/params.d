/++
Parameters: D values encoded for the types the server expects, and `?`
placeholders rewritten to PostgreSQL's `$1`, `$2`, ...

Statements are parsed without parameter types, so the server infers them
from the SQL (`WHERE id = $1` takes the type of `id`). Each value is then
encoded for that type: in the binary format when the D type matches it
(an `int` for an `int4`, a `Date` for a `date`, ...), otherwise as text that
the server parses (a `string` for a `jsonb`, a `Decimal` for a `numeric`).
Add a cast in the SQL (`$1::int8`) when the server can't infer the type you
want.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.params;

import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.traits : isFloatingPoint, isIntegral, isSomeChar, isSomeString, OriginalType, Unqual;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;

import dbwire.types.decimal : Decimal;

import postgresql.exception : ClientException;
import postgresql.types.floats : formatFloat4, formatFloat8;
import postgresql.types.oids : Oid;
import postgresql.types.temporal;

/// Whether `Args` contain a `Variant`, whose copies are `@system`: calls copying them need `@trusted`.
enum bool hasVariant(Args...) = anySatisfyVariant!Args;

private template anySatisfyVariant(Args...)
{
    import std.meta : anySatisfy;

    enum isVariantType(T) = is(Unqual!T == Variant);
    enum anySatisfyVariant = anySatisfy!(isVariantType, Args);
}

/// A parameter value as sent in a Bind message.
struct Param
{
    /// NULL.
    bool isNull;
    /// Text (0) or binary (1).
    short format;
    /// The value's bytes.
    immutable(ubyte)[] data;
}

/++
Encodes `value` for a parameter of type `oid`.

Supported D types: `bool`, integers, floating point, `Decimal`, strings and
characters, `ubyte[]`, `Date`, `DateTime`, `SysTime`, `TimeOfDay`,
`Duration`, `Interval`, `UUID`, enums, `Nullable!T` and
`null` (NULL), and `Variant` holding one of these. Enums with an integer
base type are sent as their value for numeric parameters and as their
member name for the others (text, PostgreSQL enum types); other enums as
their value.

Throws: `ClientException` for an integer out of the target type's range or
an unsupported D type.
+/
Param encodeParam(T)(T value, uint oid)
{
    alias U = Unqual!T;
    static if (is(U == typeof(null)))
        return Param(true);
    else static if (is(U : Nullable!V, V))
        return value.isNull ? Param(true) : encodeParam(value.get, oid);
    else static if (is(U == Variant))
        return encodeVariant(value, oid);
    else static if (is(U == enum))
    {
        // integer enums: their value for numeric parameters, else their member name (text, varchar,
        // PostgreSQL enum types); other enums: their value
        static if (isIntegral!(OriginalType!U))
        {
            if (!isNumericOid(oid))
                foreach (member; __traits(allMembers, U))
                    if (__traits(getMember, U, member) == value)
                        return text(member);
        }
        return encodeParam(cast(OriginalType!U) value, oid);
    }
    else static if (is(U == bool))
    {
        if (oid == Oid.bool_)
            return binary([value ? ubyte(1) : ubyte(0)]);
        return text(value ? "true" : "false");
    }
    else static if (isSomeChar!U)
    {
        import std.conv : to;

        return text([value].to!string);
    }
    else static if (isIntegral!U)
        return encodeInteger(value, oid);
    else static if (isFloatingPoint!U)
    {
        if (oid == Oid.float8)
            return binary(bigEndianBytes(doubleBits(cast(double) value)));
        if (oid == Oid.float4)
            return binary(bigEndianBytes(floatBits(cast(float) value)));
        return text(is(U == float) ? formatFloat4(value) : formatFloat8(cast(double) value));
    }
    else static if (is(U == Decimal))
        return text(value.toFixedString());
    else static if (isSomeString!U)
    {
        import std.conv : to;

        return text(value.to!string);
    }
    else static if (is(U : const(ubyte)[]))
    {
        if (oid == Oid.bytea || oid == 0)
            return binary(value.idup);
        return text(hexBytea(value));
    }
    else static if (is(U == Date))
    {
        if (oid == Oid.date)
            return binary(bigEndianBytes(dateToPostgres(value)));
        return text(dateText(value));
    }
    else static if (is(U == DateTime))
    {
        if (oid == Oid.timestamp)
            return binary(bigEndianBytes(dateTimeToPostgres(value)));
        return text(dateText(value.date) ~ " " ~ value.timeOfDay.toISOExtString());
    }
    else static if (is(U == SysTime))
    {
        // timestamptz: the point in time; timestamp: the wall time in UTC (as getSysTime reads it)
        if (oid == Oid.timestamptz || oid == Oid.timestamp)
            return binary(bigEndianBytes(sysTimeToPostgres(value)));
        return text(formatTimestampTz(sysTimeToPostgres(value), "UTC"));
    }
    else static if (is(U == TimeOfDay))
    {
        const us = ((value.hour * 60L + value.minute) * 60 + value.second) * 1_000_000;
        if (oid == Oid.time)
            return binary(bigEndianBytes(us));
        return text(value.toISOExtString());
    }
    else static if (is(U == Duration))
    {
        const us = value.total!"usecs";
        if (oid == Oid.interval)
            return binary(intervalBytes(Interval(0, 0, us)));
        if (oid == Oid.time && us >= 0 && us <= microsecondsPerDay)
            return binary(bigEndianBytes(us));
        import std.conv : to;

        return text(us.to!string ~ " microseconds");
    }
    else static if (is(U == Interval))
    {
        if (oid == Oid.interval)
            return binary(intervalBytes(value));
        return text(value.toString());
    }
    else static if (is(U == UUID))
    {
        if (oid == Oid.uuid)
            return binary(value.data.idup);
        return text(value.toString());
    }
    else
        static assert(false, "Unsupported parameter type " ~ T.stringof);
}

///
@safe unittest
{
    assert(encodeParam(42, Oid.int4) == Param(false, 1, [0, 0, 0, 42]));
    assert(encodeParam(42, Oid.int8) == Param(false, 1, [0, 0, 0, 0, 0, 0, 0, 42]));
    assert(encodeParam(42, Oid.text) == Param(false, 0, cast(immutable(ubyte)[]) "42"));
    assert(encodeParam("x", Oid.jsonb) == Param(false, 0, cast(immutable(ubyte)[]) "x"));
    assert(encodeParam(null, Oid.int4).isNull && encodeParam(Nullable!int.init, Oid.int4).isNull);
    assert(encodeParam(Date(2026, 11, 6), Oid.date) == Param(false, 1, [0, 0, 0x26, 0x4E]));
    assert(encodeParam(Date(2026, 11, 6), Oid.timestamptz).data == cast(immutable(ubyte)[]) "2026-11-06");
    assert(encodeParam(true, Oid.bool_).data == [1] && encodeParam(1.5, Oid.float8).data == [
        0x3F, 0xF8, 0, 0, 0, 0, 0, 0
    ]);
    assert(encodeParam(Decimal.fromString("1.50"), Oid.numeric).data == cast(immutable(ubyte)[]) "1.50");
    assert(encodeParam(cast(const(ubyte)[])[1, 2], Oid.text).data == cast(immutable(ubyte)[]) `\x0102`);
}

@safe unittest
{
    import core.time : hours;
    import std.exception : assertThrown;

    assertThrown!ClientException(encodeParam(70_000, Oid.int2));
    assertThrown!ClientException(encodeParam(-1, Oid.oid));
    assertThrown!ClientException(encodeParam(ulong.max, Oid.int8));
    assert(encodeParam(ulong.max, Oid.numeric).data == cast(immutable(ubyte)[]) "18446744073709551615");
    assert(encodeParam(2.hours, Oid.interval).data == [
        0, 0, 0, 1, 0xAD, 0x27, 0x48, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]);
    assert(encodeParam(DateTime(2026, 11, 6, 12, 34, 56), Oid.text).data
            == cast(
                immutable(ubyte)[]) "2026-11-06 12:34:56");
    assert(encodeParam(Date(-43, 3, 15), Oid.text).data == cast(immutable(ubyte)[]) "0044-03-15 BC");
    enum Color : short
    {
        red = 3
    }

    assert(encodeParam(Color.red, Oid.int2).data == [0, 3]);
    assert(encodeParam(Color.red, Oid.text).data == cast(immutable(ubyte)[]) "red");
    assert(encodeParam(cast(Color) 4, Oid.text).data == cast(immutable(ubyte)[]) "4");
    assert(encodeParam('é', Oid.text).data == cast(immutable(ubyte)[]) "é");
}

/++
Rewrites `?` placeholders to `$1`, `$2`, ... outside string literals
(`'...'`, `E'...'`), quoted identifiers (`"..."`), dollar-quoted strings
(`$tag$...$tag$`) and comments (`-- ...`, nested `/* ... */`). `??` stands for
a literal `?` (e.g. the jsonb `?` operator).

Returns: the rewritten SQL; `count` is set to the number of placeholders.
+/
string rewritePlaceholders(string sql, out size_t count) @safe pure
{
    import std.conv : to;

    string result;
    size_t i;
    while (i < sql.length)
    {
        const c = sql[i];
        if (c == '?')
        {
            if (i + 1 < sql.length && sql[i + 1] == '?')
            {
                result ~= '?';
                i += 2;
            }
            else
            {
                result ~= "$" ~ (++count).to!string;
                i++;
            }
        }
        else if (c == '\'' || c == '"')
        {
            const escapes = c == '\'' && i > 0 && (sql[i - 1] == 'E' || sql[i - 1] == 'e')
                && (i < 2 || !isIdentifierChar(sql[i - 2]));
            const end = quotedEnd(sql, i, c, escapes);
            result ~= sql[i .. end];
            i = end;
        }
        else if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-')
        {
            size_t end = i;
            while (end < sql.length && sql[end] != '\n')
                end++;
            result ~= sql[i .. end];
            i = end;
        }
        else if (c == '/' && i + 1 < sql.length && sql[i + 1] == '*')
        {
            size_t end = i + 2;
            int depth = 1;
            while (end < sql.length && depth > 0)
            {
                if (sql[end] == '/' && end + 1 < sql.length && sql[end + 1] == '*')
                {
                    depth++;
                    end += 2;
                }
                else if (sql[end] == '*' && end + 1 < sql.length && sql[end + 1] == '/')
                {
                    depth--;
                    end += 2;
                }
                else
                    end++;
            }
            result ~= sql[i .. end];
            i = end;
        }
        else if (c == '$' && (i == 0 || !isIdentifierChar(sql[i - 1])))
        {
            // $tag$ ... $tag$ (tag empty or an identifier); $1 is a parameter, left alone
            size_t t = i + 1;
            while (t < sql.length && isIdentifierChar(sql[t]) && !(t == i + 1 && sql[t] >= '0' && sql[t] <= '9'))
                t++;
            if (t < sql.length && sql[t] == '$')
            {
                const tag = sql[i .. t + 1];
                size_t end = t + 1;
                while (end < sql.length && !(end + tag.length <= sql.length && sql[end .. end + tag.length] == tag))
                    end++;
                end = end + tag.length <= sql.length ? end + tag.length : sql.length;
                result ~= sql[i .. end];
                i = end;
            }
            else
            {
                result ~= c;
                i++;
            }
        }
        else
        {
            result ~= c;
            i++;
        }
    }
    return result;
}

///
@safe unittest
{
    size_t n;
    assert(rewritePlaceholders("SELECT * FROM t WHERE a = ? AND b = ?", n) == "SELECT * FROM t WHERE a = $1 AND b = $2"
            && n == 2);
    assert(rewritePlaceholders("SELECT '?', \"?\", ? -- ?\n, ?", n) == "SELECT '?', \"?\", $1 -- ?\n, $2" && n == 2);
    assert(rewritePlaceholders("SELECT 'it''s ?', E'\\' ?', ?", n) == "SELECT 'it''s ?', E'\\' ?', $1" && n == 1);
    assert(rewritePlaceholders("SELECT $$ ? $$, $fn$ ? $fn$, ?, $1", n) == "SELECT $$ ? $$, $fn$ ? $fn$, $1, $1");
    assert(rewritePlaceholders("SELECT /* ? /* ? */ ? */ ?", n) == "SELECT /* ? /* ? */ ? */ $1" && n == 1);
    assert(rewritePlaceholders("SELECT '{\"a\":1}'::jsonb ?? 'a', ?", n) == "SELECT '{\"a\":1}'::jsonb ? 'a', $1");
    assert(rewritePlaceholders("SELECT ?, 'unterminated ?", n) == "SELECT $1, 'unterminated ?" && n == 1);
}

private:

bool isNumericOid(uint oid) @safe pure nothrow
{
    switch (oid)
    {
    case Oid.int2, Oid.int4, Oid.int8, Oid.oid, Oid.numeric, Oid.float4, Oid.float8:
        return true;
    default:
        return false;
    }
}

Param binary(immutable(ubyte)[] data) @safe pure nothrow
{
    return Param(false, 1, data);
}

Param text(string s) @safe pure nothrow
{
    return Param(false, 0, cast(immutable(ubyte)[]) s);
}

Param encodeInteger(T)(T value, uint oid) @safe
{
    import std.conv : to;

    bool fits(long lo, long hi)
    {
        static if (T.min < 0)
            return value >= lo && value <= hi;
        else
            return value <= cast(ulong) hi;
    }

    switch (oid)
    {
    case Oid.int2:
        if (!fits(short.min, short.max))
            throw outOfRange(value.to!string, "smallint");
        return binary(bigEndianBytes(cast(short) value));
    case Oid.int4:
        if (!fits(int.min, int.max))
            throw outOfRange(value.to!string, "integer");
        return binary(bigEndianBytes(cast(int) value));
    case Oid.int8:
        if (!fits(long.min, long.max))
            throw outOfRange(value.to!string, "bigint");
        return binary(bigEndianBytes(cast(long) value));
    case Oid.oid:
        if (!fits(0, uint.max))
            throw outOfRange(value.to!string, "oid");
        return binary(bigEndianBytes(cast(uint) value));
    case Oid.float8:
        return binary(bigEndianBytes(doubleBits(cast(double) value)));
    case Oid.float4:
        return binary(bigEndianBytes(floatBits(cast(float) value)));
    default:
        return text(value.to!string);
    }
}

ClientException outOfRange(string value, string type) @safe pure
{
    return new ClientException("The value " ~ value ~ " is out of the range of the parameter's type " ~ type);
}

Param encodeVariant(Variant value, uint oid) @trusted
{
    // Variant's accessors aren't @safe; each branch copies a plain value out of it
    if (!value.hasValue)
        return Param(true);
    static foreach (T; AliasSeq!(bool, byte, ubyte, short, ushort, int, uint, long, ulong, float, double, real,
            Decimal, string, const(char)[], char[], immutable(ubyte)[], const(ubyte)[], ubyte[], Date, DateTime,
            SysTime, TimeOfDay, Duration, Interval, UUID, char, wchar, dchar))
    {
        if (value.type == typeid(T))
            return encodeParam(value.get!T, oid);
    }
    throw new ClientException("Unsupported parameter type in a Variant: " ~ value.type.toString());
}

import std.meta : AliasSeq;

uint floatBits(float f) @trusted pure nothrow
{
    return *cast(uint*)&f; // reinterprets the 4 bytes
}

ulong doubleBits(double d) @trusted pure nothrow
{
    return *cast(ulong*)&d; // reinterprets the 8 bytes
}

immutable(ubyte)[] bigEndianBytes(T)(T value) @safe pure nothrow
{
    auto bytes = new ubyte[T.sizeof];
    foreach (i; 0 .. T.sizeof)
        bytes[i] = cast(ubyte)(cast(ulong) value >> (8 * (T.sizeof - 1 - i)));
    return (() @trusted => cast(immutable) bytes)();
}

immutable(ubyte)[] intervalBytes(const Interval value) @safe pure nothrow
{
    return bigEndianBytes(value.microseconds) ~ bigEndianBytes(value.days) ~ bigEndianBytes(value.months);
}

string hexBytea(const(ubyte)[] bytes) @safe pure
{
    static immutable digits = "0123456789abcdef";
    auto text = new char[2 + bytes.length * 2];
    text[0 .. 2] = `\x`;
    foreach (i, b; bytes)
    {
        text[2 + 2 * i] = digits[b >> 4];
        text[3 + 2 * i] = digits[b & 15];
    }
    return text;
}

string dateText(Date d) @safe pure
{
    import std.format : format;

    if (d.year > 0)
        return format("%04d-%02d-%02d", d.year, cast(int) d.month, d.day);
    return format("%04d-%02d-%02d BC", 1 - d.year, cast(int) d.month, d.day);
}

bool isIdentifierChar(char c) @safe pure nothrow
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c >= 0x80;
}

// The index after the quoted text starting at `start` (the opening quote), or the end of `sql`.
size_t quotedEnd(string sql, size_t start, char quote, bool backslashEscapes) @safe pure nothrow
{
    size_t i = start + 1;
    while (i < sql.length)
    {
        if (backslashEscapes && sql[i] == '\\')
            i += 2;
        else if (sql[i] == quote)
        {
            if (i + 1 < sql.length && sql[i + 1] == quote)
                i += 2; // doubled quote
            else
                return i + 1;
        }
        else
            i++;
    }
    return sql.length;
}
