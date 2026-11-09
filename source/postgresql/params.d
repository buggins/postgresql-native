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
import std.traits : isDynamicArray, isFloatingPoint, isIntegral, isSomeChar, isSomeString, OriginalType, Unqual;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;

import dbwire.types.decimal : Decimal;

import postgresql.exception : ClientException;
import postgresql.protocol.messages : MessageBuilder;
import postgresql.types.floats : formatFloat4, formatFloat8;
import postgresql.types.oids : Oid;
import postgresql.types.temporal;
import postgresql.types.bitstring : BitString;
import postgresql.types.geometric;
import postgresql.types.network : Inet;
import postgresql.types.ranges : isRange;
import postgresql.types.textformat : quoteHstore;

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
`Duration`, `Interval`, `UUID`, `Inet`, `BitString`, the geometric types
(`Point`, `Line`, `LineSegment`, `Box`, `Path`, `Polygon`, `Circle`), enums,
`Nullable!T` and `null` (NULL), and `Variant` holding one of these; and
D arrays of them (arrays; nested D arrays for several dimensions),
`Range!T` (ranges), `string[string]` and `Nullable!string[string]`
(`hstore`), and other structs (composite values, fields as in struct
mapping). Enums with an integer base type are sent as their value for
numeric parameters and as their member name for the others (text,
PostgreSQL enum types); other enums as their value. Arrays go in binary
when the parameter is an array of a built-in type whose elements go in
binary, else as text, as ranges, `hstore` values and composite values do.

Throws: `ClientException` for an integer out of the target type's range or
an unsupported D type.
+/
Param encodeParam(T)(T value, uint oid)
{
    MessageBuilder b;
    const format = putParam(b, value, oid);
    if (format == nullValue)
        return Param(true);
    return Param(false, format, (() @trusted => cast(immutable) b.data[4 .. $])()); // b's memory isn't used again
}

/// What `putParam` returns for NULL (else the format).
package enum short nullValue = -1;

/++
Writes `value`, encoded as `encodeParam` encodes it, into a Bind message:
its length (-1 for NULL) and bytes.

Returns: the format, text (0) or binary (1); `nullValue` (-1) for NULL.
+/
package short putParam(T)(ref MessageBuilder b, T value, uint oid)
{
    alias U = Unqual!T;
    static if (is(U == typeof(null)))
        return b.putNull();
    else static if (is(U : Nullable!V, V))
        return value.isNull ? b.putNull() : putParam(b, value.get, oid);
    else static if (is(U == Variant))
        return putVariant(b, value, oid);
    else static if (is(U == enum))
    {
        // integer enums: their value for numeric parameters, else their member name (text, varchar,
        // PostgreSQL enum types); other enums: their value
        static if (isIntegral!(OriginalType!U))
        {
            if (!isNumericOid(oid))
                foreach (member; __traits(allMembers, U))
                    if (__traits(getMember, U, member) == value)
                        return b.putText(member);
        }
        return putParam(b, cast(OriginalType!U) value, oid);
    }
    else static if (is(U == bool))
    {
        if (oid == Oid.bool_)
            return b.putBinary(ubyte(value ? 1 : 0));
        return b.putText(value ? "true" : "false");
    }
    else static if (isSomeChar!U)
    {
        import std.utf : encode;

        char[4] chars;
        return b.putText(chars[0 .. encode(chars, value)]);
    }
    else static if (isIntegral!U)
        return putInteger(b, value, oid);
    else static if (isFloatingPoint!U)
    {
        if (oid == Oid.float8)
            return b.putBinary(doubleBits(cast(double) value));
        if (oid == Oid.float4)
            return b.putBinary(floatBits(cast(float) value));
        return b.putText(is(U == float) ? formatFloat4(value) : formatFloat8(cast(double) value));
    }
    else static if (is(U == Decimal))
        return b.putText(value.toFixedString());
    else static if (isSomeString!U)
    {
        static if (is(U : const(char)[]))
            return b.putText(value);
        else
        {
            import std.conv : to;

            return b.putText(value.to!string);
        }
    }
    else static if (is(U : const(ubyte)[]))
    {
        if (oid == Oid.bytea || oid == 0)
            return b.putBinaryBytes(value);
        return b.putText(hexBytea(value));
    }
    else static if (is(U == Date))
    {
        if (oid == Oid.date)
            return b.putBinary(dateToPostgres(value));
        return b.putText(dateText(value));
    }
    else static if (is(U == DateTime))
    {
        if (oid == Oid.timestamp)
            return b.putBinary(dateTimeToPostgres(value));
        return b.putText(dateText(value.date) ~ " " ~ value.timeOfDay.toISOExtString());
    }
    else static if (is(U == SysTime))
    {
        // timestamptz: the point in time; timestamp: the wall time in UTC (as getSysTime reads it)
        if (oid == Oid.timestamptz || oid == Oid.timestamp)
            return b.putBinary(sysTimeToPostgres(value));
        return b.putText(formatTimestampTz(sysTimeToPostgres(value), "UTC"));
    }
    else static if (is(U == TimeOfDay))
    {
        const us = ((value.hour * 60L + value.minute) * 60 + value.second) * 1_000_000;
        if (oid == Oid.time)
            return b.putBinary(us);
        return b.putText(value.toISOExtString());
    }
    else static if (is(U == Duration))
    {
        const us = value.total!"usecs";
        if (oid == Oid.interval)
            return b.putInterval(Interval(0, 0, us));
        if (oid == Oid.time && us >= 0 && us <= microsecondsPerDay)
            return b.putBinary(us);
        import std.conv : to;

        return b.putText(us.to!string ~ " microseconds");
    }
    else static if (is(U == Interval))
    {
        if (oid == Oid.interval)
            return b.putInterval(value);
        return b.putText(value.toString());
    }
    else static if (is(U == UUID))
    {
        if (oid == Oid.uuid)
            return b.putBinaryBytes(value.data[]);
        return b.putText(value.toString());
    }
    else static if (is(U == Inet))
    {
        if (oid == Oid.inet || oid == Oid.cidr)
            return b.putBinaryBytes(Inet(value.address, value.prefix, oid == Oid.cidr).toBinary());
        return b.putText(value.toString());
    }
    else static if (is(U == BitString))
    {
        if (oid == Oid.bit || oid == Oid.varbit)
            return b.putBinaryBytes(value.toBinary());
        return b.putText(value.toString());
    }
    else static if (isGeometric!U)
    {
        if (oid == geometricOidOf!U)
            return b.putBinaryBytes(geometricToBinary(value));
        return b.putText(value.toString());
    }
    else static if (isRange!U)
    {
        if (value.empty)
            return b.putText("empty");
        const lower = value.lowerInfinite ? "" : literalItem(value.lower);
        const upper = value.upperInfinite ? "" : literalItem(value.upper);
        return b.putText((value.lowerInclusive ? "[" : "(") ~ lower ~ "," ~ upper ~ (value.upperInclusive ? "]" : ")"));
    }
    else static if (is(U : V[K], V, K))
    {
        // hstore: "key"=>"value", ...
        static assert(is(K : const(char)[]), "Only maps with string keys (hstore) are supported parameters");
        string literal;
        foreach (k, v; value)
        {
            literal ~= (literal.length ? ", " : "") ~ quoteHstore(k) ~ "=>";
            static if (is(V : Nullable!X, X))
                literal ~= v.isNull ? "NULL" : quoteHstore(textOf(v.get));
            else
                literal ~= quoteHstore(textOf(v));
        }
        return b.putText(literal);
    }
    else static if (isDynamicArray!U)
        return putArray(b, value, oid);
    else static if (is(U == struct))
    {
        // a composite value: (field,field,...)
        import postgresql.attributes : mappedFields;

        string literal = "(";
        static foreach (i, name; mappedFields!U)
            literal ~= (i ? "," : "") ~ literalItem(__traits(getMember, value, name));
        return b.putText(literal ~ ")");
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
    import std.array : appender;
    import std.string : indexOf;

    if (sql.indexOf('?') < 0)
        return sql; // nothing to rewrite
    auto result = appender!string;
    result.reserve(sql.length + 16);
    size_t copied; // sql[0 .. copied] is in result
    size_t i;
    char[20] digits;
    while (i < sql.length)
    {
        const c = sql[i];
        if (c == '?')
        {
            result ~= sql[copied .. i];
            if (i + 1 < sql.length && sql[i + 1] == '?')
            {
                result ~= '?';
                i += 2;
            }
            else
            {
                result ~= '$';
                result ~= digits[integerText(++count, digits) .. $];
                i++;
            }
            copied = i;
        }
        else if (c == '\'' || c == '"')
        {
            const escapes = c == '\'' && i > 0 && (sql[i - 1] == 'E' || sql[i - 1] == 'e')
                && (i < 2 || !isIdentifierChar(sql[i - 2]));
            i = quotedEnd(sql, i, c, escapes);
        }
        else if (c == '-' && i + 1 < sql.length && sql[i + 1] == '-')
        {
            while (i < sql.length && sql[i] != '\n')
                i++;
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
                i = end + tag.length <= sql.length ? end + tag.length : sql.length;
            }
            else
                i++;
        }
        else
            i++;
    }
    if (copied == 0)
        return sql; // the ? were all in literals or comments
    result ~= sql[copied .. $];
    return result.data;
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

// The text of a value, as the server parses it.
string textOf(T)(T value)
{
    const p = encodeParam(value, Oid.text);
    return p.isNull ? null : cast(string) p.data;
}

// A part of an array, range or record literal: quoted, `"` and `\` escaped; empty for NULL in records and
// ranges (arrays use NULL).
string literalItem(T)(T value)
{
    const p = encodeParam(value, Oid.text);
    return p.isNull ? "" : quoteHstore(cast(string) p.data);
}

// An array parameter: binary when the parameter is an array of a built-in type and every element is sent in
// binary; else array text.
short putArray(A)(ref MessageBuilder b, A value, uint oid)
{
    import std.traits : isDynamicArray, isSomeString;
    import postgresql.types.pgtype : builtinType, TypeKind;

    enum bool isValue(X) = !isDynamicArray!X || isSomeString!X || is(X : const(ubyte)[]);
    int[] lengths;
    void measure(X)(X items, size_t level)
    {
        if (lengths.length <= level)
            lengths ~= cast(int) items.length;
        else if (lengths[level] != items.length)
            throw new ClientException("Multidimensional arrays must have sub-arrays of the same size");
        static if (!isValue!(typeof(X.init[0])))
            foreach (item; items)
                measure(item, level + 1);
    }

    measure(value, 0);
    size_t total = 1;
    foreach (l; lengths)
        total *= l;
    if (total == 0)
        lengths = null;

    const t = builtinType(oid);
    const element = t !is null && t.kind == TypeKind.array ? t.element : null;
    if (element !is null && element.kind == TypeKind.base)
    {
        // binary: dimensions, NULL flag, element OID, (length, lower bound) per dimension, elements; written
        // in place, and undone if an element goes as text
        const start = b.skip(4); // the length
        b.putInt32(cast(int) lengths.length);
        const nullFlag = b.skip(4);
        b.putInt32(cast(int) element.oid);
        foreach (l; lengths)
        {
            b.putInt32(l);
            b.putInt32(1);
        }
        bool allBinary = true, hasNull;
        void put(X)(X items)
        {
            foreach (item; items)
            {
                static if (isValue!(typeof(X.init[0])))
                {
                    const format = putParam(b, item, element.oid);
                    if (format == nullValue)
                        hasNull = true;
                    else if (format != 1)
                        allBinary = false;
                }
                else
                    put(item);
                if (!allBinary)
                    return;
            }
        }

        put(value);
        if (allBinary)
        {
            b.patchInt32(nullFlag, hasNull ? 1 : 0);
            return b.endValue(start);
        }
        b.truncate(start);
    }
    // text: {"a","b"}, NULL for NULL, nested braces for more dimensions
    const delimiter = element !is null ? element.delimiter : ',';
    string literal;
    void write(X)(X items)
    {
        literal ~= "{";
        foreach (i, item; items)
        {
            if (i)
                literal ~= delimiter;
            static if (isValue!(typeof(X.init[0])))
            {
                const p = encodeParam(item, Oid.text);
                literal ~= p.isNull ? "NULL" : quoteHstore(cast(string) p.data);
            }
            else
                write(item);
        }
        literal ~= "}";
    }

    write(value);
    return b.putText(literal);
}

template geometricOidOf(T)
{
    static if (is(T == Point))
        enum geometricOidOf = Oid.point;
    else static if (is(T == Line))
        enum geometricOidOf = Oid.line;
    else static if (is(T == LineSegment))
        enum geometricOidOf = Oid.lseg;
    else static if (is(T == Box))
        enum geometricOidOf = Oid.box;
    else static if (is(T == Path))
        enum geometricOidOf = Oid.path;
    else static if (is(T == Polygon))
        enum geometricOidOf = Oid.polygon;
    else
        enum geometricOidOf = Oid.circle;
}

// The value parts of a Bind message: the length (-1 for NULL), then the bytes; each returns the format, or
// nullValue.
short putNull(ref MessageBuilder b) @safe pure nothrow
{
    b.putInt32(-1);
    return nullValue;
}

short putText(ref MessageBuilder b, scope const(char)[] s) @safe pure
{
    b.putBinaryBytes(cast(const(ubyte)[]) s);
    return 0;
}

short putBinaryBytes(ref MessageBuilder b, scope const(ubyte)[] bytes) @safe pure
{
    checkLength(bytes.length);
    b.putInt32(cast(int) bytes.length);
    b.putBytes(bytes);
    return 1;
}

short putBinary(T)(ref MessageBuilder b, T value) if (isIntegral!T)
{
    b.putInt32(T.sizeof);
    b.putBigEndian(value);
    return 1;
}

short putInterval(ref MessageBuilder b, const Interval value) @safe pure nothrow
{
    b.putInt32(16);
    b.putBigEndian(value.microseconds);
    b.putBigEndian(value.days);
    b.putBigEndian(value.months);
    return 1;
}

// Ends a binary value whose length was reserved at `start` (b.skip(4)).
short endValue(ref MessageBuilder b, size_t start) @safe pure
{
    const length = b.length - start - 4;
    checkLength(length);
    b.patchInt32(start, cast(int) length);
    return 1;
}

void checkLength(size_t length) @safe pure
{
    if (length > int.max)
        throw new ClientException("A parameter value is longer than 2 GB");
}

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

short putInteger(T)(ref MessageBuilder b, T value, uint oid) @safe
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
        return b.putBinary(cast(short) value);
    case Oid.int4:
        if (!fits(int.min, int.max))
            throw outOfRange(value.to!string, "integer");
        return b.putBinary(cast(int) value);
    case Oid.int8:
        if (!fits(long.min, long.max))
            throw outOfRange(value.to!string, "bigint");
        return b.putBinary(cast(long) value);
    case Oid.oid:
        if (!fits(0, uint.max))
            throw outOfRange(value.to!string, "oid");
        return b.putBinary(cast(uint) value);
    case Oid.float8:
        return b.putBinary(doubleBits(cast(double) value));
    case Oid.float4:
        return b.putBinary(floatBits(cast(float) value));
    default:
        char[20] digits;
        return b.putText(digits[integerText(value, digits) .. $]);
    }
}

/// Writes the decimal digits of `value` at the end of `buffer`; returns where they start.
package size_t integerText(T)(T value, ref char[20] buffer)
{
    static if (T.min < 0)
    {
        const negative = value < 0;
        ulong v = negative ? -cast(ulong) value : value; // also right for T.min
    }
    else
    {
        enum negative = false;
        ulong v = value;
    }
    size_t at = buffer.length;
    do
    {
        buffer[--at] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v);
    if (negative)
        buffer[--at] = '-';
    return at;
}

@safe pure nothrow @nogc unittest
{
    char[20] digits;
    assert(digits[integerText(-42, digits) .. $] == "-42" && digits[integerText(0u, digits) .. $] == "0");
    assert(digits[integerText(long.min, digits) .. $] == "-9223372036854775808");
    assert(digits[integerText(ulong.max, digits) .. $] == "18446744073709551615");
}

@safe pure nothrow unittest
{
    MessageBuilder b;
    b.putBinary(short(-2));
    b.putBinary(ulong(1));
    assert(b.data == [0, 0, 0, 2, 0xFF, 0xFE, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1]);
}

ClientException outOfRange(string value, string type) @safe pure
{
    return new ClientException("The value " ~ value ~ " is out of the range of the parameter's type " ~ type);
}

/// Encodes a `Variant` holding a type `encodeParam` takes (empty or `null`: NULL) into a Bind message.
package short putVariant(ref MessageBuilder b, Variant value, uint oid) @trusted
{
    // Variant's accessors aren't @safe; each branch copies a plain value out of it
    const type = value.type;
    if (!value.hasValue || type is typeid(typeof(null)))
        return b.putNull();
    if (type is typeid(byte[]))
        return putParam(b, cast(const(ubyte)[]) value.get!(byte[]), oid);
    alias Types = AliasSeq!(bool, byte, ubyte, short, ushort, int, uint, long, ulong, float, double, real, Decimal,
            string, const(char)[], char[], immutable(ubyte)[], const(ubyte)[], ubyte[], Date, DateTime, SysTime,
            TimeOfDay, Duration, Interval, UUID, char, wchar, dchar, Inet, BitString, Point, Line, LineSegment, Box,
            Path, Polygon, Circle);
    static foreach (T; Types)
        if (type is typeid(T)) // the usual case: one TypeInfo object per type
            return putParam(b, value.get!T, oid);
    if (type == typeid(typeof(null)))
        return b.putNull();
    if (type == typeid(byte[]))
        return putParam(b, cast(const(ubyte)[]) value.get!(byte[]), oid);
    static foreach (T; Types)
        if (type == typeid(T)) // e.g. a TypeInfo of another shared library
            return putParam(b, value.get!T, oid);
    throw new ClientException("Unsupported parameter type in a Variant: " ~ type.toString());
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
    return formatDate(dateToPostgres(d)); // 2026-11-09, 0044-03-15 BC
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
