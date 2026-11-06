/++
One value of a result row and its typed getters.

Values keep the bytes the server sent, in binary format for the types this
client decodes and in text format for the others, and are converted on access.
`getString` gives the text PostgreSQL itself prints for the value (`psql`'s
output with the session's `TimeZone`), whatever the format.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.value;

import core.time : Duration;
import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.variant : Variant;

import dbwire.types.decimal : Decimal;

import postgresql.exception : ClientException, ProtocolException;
import postgresql.result : ColumnInfo, ValueFormat;
import postgresql.types.floats;
import postgresql.types.numeric;
import postgresql.types.oids;
import postgresql.types.temporal;

/// One value of a row.
struct Value
{
    private const(ColumnInfo)* column;
    private immutable(ubyte)[] data;
    private bool null_;
    private string timeZone;

    package this(const(ColumnInfo)* column, immutable(ubyte)[] data, bool isNull, string timeZone) @safe pure nothrow
    {
        this.column = column;
        this.data = data;
        this.null_ = isNull;
        this.timeZone = timeZone;
    }

    /// The column the value belongs to.
    @property ref const(ColumnInfo) info() const @safe pure nothrow
    {
        return *column;
    }

    /// Whether the value is NULL.
    @property bool isNull() const @safe pure nothrow
    {
        return null_;
    }

    /// The bytes as the server sent them (binary or text format); null for NULL.
    @property immutable(ubyte)[] raw() const @safe pure nothrow
    {
        return null_ ? null : data;
    }

    private @property bool binary() const @safe pure nothrow
    {
        return column.format == ValueFormat.binary;
    }

    private @property const(char)[] text() const @safe pure nothrow
    {
        return cast(const(char)[]) data;
    }

    /++
    The value as PostgreSQL prints it; null for NULL.

    Throws: `ProtocolException` if a binary value is malformed.
    +/
    string getString() const @safe
    {
        if (null_)
            return null;
        if (!binary)
            return cast(string) data;
        switch (column.typeOid)
        {
        case Oid.text, Oid.varchar, Oid.bpchar, Oid.name, Oid.json, Oid.unknown:
            return cast(string) data;
        case Oid.jsonb:
            return jsonbText();
        case Oid.bool_:
            return fixed!ubyte() ? "t" : "f";
        case Oid.int2, Oid.int4, Oid.int8, Oid.oid:
            import std.conv : to;

            return column.typeOid == Oid.oid ? (cast(uint) integer()).to!string : integer().to!string;
        case Oid.float4:
            return formatFloat4(float4());
        case Oid.float8:
            return formatFloat8(float8());
        case Oid.numeric:
            return Numeric.decode(data).toString();
        case Oid.bytea:
            return byteaHex();
        case Oid.char_:
            return charText();
        case Oid.uuid:
            return getUUID().toString();
        case Oid.date:
            return formatDate(fixed!int());
        case Oid.time:
            return formatTime(fixed!long());
        case Oid.timetz:
            return formatTimeTz(timeTzParts().microseconds, timeTzParts().zoneWest);
        case Oid.timestamp:
            return formatTimestamp(fixed!long());
        case Oid.timestamptz:
            return formatTimestampTz(fixed!long(), timeZone);
        case Oid.interval:
            return getInterval().toString();
        default:
            throw new ClientException("No text for binary values of type " ~ typeName());
        }
    }

    /++
    The value as `bool`: `boolean`, or an integer (non-zero is true); text
    `t`/`f`, `true`/`false`, `1`/`0`.

    Throws: `ClientException` for NULL or other types.
    +/
    bool getBool() const @safe
    {
        notNull();
        if (binary)
        {
            if (column.typeOid == Oid.bool_)
                return fixed!ubyte() != 0;
            if (isIntegerType)
                return integer() != 0;
        }
        else
            switch (text)
        {
        case "t", "true", "1":
            return true;
        case "f", "false", "0":
            return false;
        default:
            break;
        }
        throw wrongType("bool");
    }

    /++
    The value as `long`: integer types, `oid`, an integral `numeric` in
    range, `boolean` (0/1); integer text.

    Throws: `ClientException` for NULL, other types, or values out of range.
    +/
    long getLong() const @safe
    {
        import std.conv : ConvException, to;

        notNull();
        if (binary)
        {
            if (isIntegerType)
                return integer();
            if (column.typeOid == Oid.bool_)
                return fixed!ubyte() != 0;
            if (column.typeOid == Oid.numeric)
            {
                const n = Numeric.decode(data);
                if (n.isIntegral)
                {
                    try
                        return n.toString().to!long; // integral: digits only, no point
                    catch (ConvException)
                        throw new ClientException("The numeric value " ~ n.toString() ~ " is out of long's range");
                }
                throw new ClientException("The numeric value " ~ n.toString() ~ " is not an integer");
            }
            throw wrongType("long");
        }
        try
            return text.to!long;
        catch (ConvException)
            throw wrongType("long");
    }

    /// The value as `int` (see `getLong`); throws `ClientException` if it is out of range.
    int getInt() const @safe
    {
        const v = getLong();
        if (v < int.min || v > int.max)
            throw new ClientException("The value is out of int's range");
        return cast(int) v;
    }

    /++
    The value as `double`: floating-point and integer types, `numeric`
    (rounded; NaN and infinities included); numeric text.

    Throws: `ClientException` for NULL or other types.
    +/
    double getDouble() const @safe
    {
        import std.conv : ConvException, to;

        notNull();
        if (binary)
        {
            switch (column.typeOid)
            {
            case Oid.float4:
                return float4();
            case Oid.float8:
                return float8();
            case Oid.numeric:
                return Numeric.decode(data).toDouble();
            default:
                if (isIntegerType)
                    return integer();
                throw wrongType("double");
            }
        }
        try
            return text.to!double;
        catch (ConvException)
            throw wrongType("double");
    }

    /++
    The value as an exact dbwire `Decimal`: `numeric` (with its display
    scale) and integer types; numeric text.

    Throws: `ClientException` for NULL, NaN, infinities, more than 76 digits, or other types.
    +/
    Decimal getDecimal() const @safe
    {
        notNull();
        if (binary)
        {
            if (column.typeOid == Oid.numeric)
                return Numeric.decode(data).toDecimal();
            if (isIntegerType)
                return Decimal.fromLong(integer());
            throw wrongType("Decimal");
        }
        try
            return Decimal.fromString(text);
        catch (Exception)
            throw wrongType("Decimal");
    }

    /++
    The value as bytes: the contents of a `bytea` (binary, or hex text),
    the 16 bytes of a `uuid`, the UTF-8 bytes of a text value.

    Throws: `ClientException` for NULL or other types.
    +/
    immutable(ubyte)[] getBytes() const @safe
    {
        notNull();
        if (binary)
        {
            switch (column.typeOid)
            {
            case Oid.bytea, Oid.uuid, Oid.text, Oid.varchar, Oid.bpchar, Oid.name, Oid.json, Oid.char_:
                return data;
            default:
                throw wrongType("bytes");
            }
        }
        if (column.typeOid == Oid.bytea)
            return decodeHex(text);
        return data;
    }

    /++
    The value as a `Date`: `date`, the date part of a `timestamp`; date text.

    Throws: `ClientException` for NULL, `infinity`, years out of `Date`'s range, or other types.
    +/
    Date getDate() const @safe
    {
        notNull();
        switch (column.typeOid)
        {
        case Oid.date:
            return dateFromPostgres(binary ? fixed!int() : parseDate(text));
        case Oid.timestamp:
            return dateTimeFromPostgres(binary ? fixed!long() : parseTimestamp(text)).date;
        default:
            if (!binary)
                return dateFromPostgres(parseDate(text));
            throw wrongType("Date");
        }
    }

    /++
    The value as a `DateTime` (the fraction of the second dropped, see
    `getMicrosecondsOfSecond`): `timestamp`; `timestamptz` in UTC; `date` at midnight.

    Throws: `ClientException` for NULL, infinities, years out of range, or other types.
    +/
    DateTime getDateTime() const @safe
    {
        notNull();
        switch (column.typeOid)
        {
        case Oid.timestamp, Oid.timestamptz:
            return dateTimeFromPostgres(timestampValue());
        case Oid.date:
            return DateTime(getDate());
        default:
            throw wrongType("DateTime");
        }
    }

    /++
    The value as a `SysTime` in UTC, microseconds included: `timestamptz`;
    `timestamp` taken as UTC; `date` at midnight UTC.

    Throws: `ClientException` for NULL, infinities, years outside 1 to 9999, or other types.
    +/
    SysTime getSysTime() const @safe
    {
        import std.datetime.timezone : UTC;

        notNull();
        switch (column.typeOid)
        {
        case Oid.timestamp, Oid.timestamptz:
            return sysTimeFromPostgres(timestampValue());
        case Oid.date:
            return SysTime(DateTime(getDate()), UTC());
        default:
            throw wrongType("SysTime");
        }
    }

    /++
    The microseconds within the second (0 to 999999) of a `time`, `timetz`,
    `timestamp` or `timestamptz`, which `TimeOfDay` and `DateTime` drop.

    Throws: `ClientException` for NULL or other types.
    +/
    int getMicrosecondsOfSecond() const @safe
    {
        notNull();
        switch (column.typeOid)
        {
        case Oid.time:
            return microsecondsOfSecond(binary ? fixed!long() : parseTime(text));
        case Oid.timetz:
            return microsecondsOfSecond(timeTzParts().microseconds);
        case Oid.timestamp, Oid.timestamptz:
            return microsecondsOfSecond(timestampValue());
        default:
            throw wrongType("microseconds");
        }
    }

    /++
    The value as a `TimeOfDay` (the fraction of the second dropped): `time`;
    the local time of a `timetz`.

    Throws: `ClientException` for NULL, 24:00:00, or other types.
    +/
    TimeOfDay getTimeOfDay() const @safe
    {
        notNull();
        switch (column.typeOid)
        {
        case Oid.time:
            return timeOfDayFromPostgres(binary ? fixed!long() : parseTime(text));
        case Oid.timetz:
            return timeOfDayFromPostgres(timeTzParts().microseconds);
        default:
            throw wrongType("TimeOfDay");
        }
    }

    /++
    The value as a `Duration`: `time` (since midnight), or an `interval`
    without months (days count as 24 hours).

    Throws: `ClientException` for NULL, intervals with months, or other types.
    +/
    Duration getDuration() const @safe
    {
        import core.time : days, usecs;

        notNull();
        if (column.typeOid == Oid.time)
            return usecs(binary ? fixed!long() : parseTime(text));
        if (column.typeOid == Oid.interval && binary)
        {
            const i = getInterval();
            if (i.months != 0)
                throw new ClientException("The interval " ~ i.toString() ~ " has months: no fixed Duration");
            return days(i.days) + usecs(i.microseconds);
        }
        throw wrongType("Duration");
    }

    /++
    The value as an `Interval` (months, days and microseconds apart).

    Throws: `ClientException` for NULL or other types.
    +/
    Interval getInterval() const @safe
    {
        notNull();
        if (column.typeOid != Oid.interval || !binary)
            throw wrongType("Interval");
        if (data.length != 16)
            throw new ProtocolException("Malformed interval value");
        return Interval(bigEndian!int(data[12 .. 16]), bigEndian!int(data[8 .. 12]), bigEndian!long(data[0 .. 8]));
    }

    /++
    The value as a `UUID`: `uuid`; UUID text.

    Throws: `ClientException` for NULL or other types.
    +/
    UUID getUUID() const @safe
    {
        notNull();
        if (binary)
        {
            if (column.typeOid != Oid.uuid)
                throw wrongType("UUID");
            if (data.length != 16)
                throw new ProtocolException("Malformed uuid value");
            ubyte[16] bytes = data[0 .. 16];
            return UUID(bytes);
        }
        try
            return UUID(text);
        catch (Exception)
            throw wrongType("UUID");
    }

    /++
    The value in a `Variant` holding its natural D type: `bool`, `short`,
    `int`, `long`, `uint` (`oid`), `float`, `double`, `Decimal` (`numeric`;
    a `string` for NaN, infinities or more than 76 digits), `string` (text
    types, JSON, and types without a decoder), `immutable(ubyte)[]`
    (`bytea`), `Date`, `TimeOfDay` (`time`), `DateTime` (`timestamp`),
    `SysTime` (`timestamptz`), `Interval`, `UUID`; an empty `Variant` for
    NULL. Infinite dates and timestamps, and times of 24:00:00, are strings.
    +/
    Variant getVariant() const @trusted
    {
        // Variant's copy constructor isn't @safe; the values put in it are plain data
        if (null_)
            return Variant();
        if (!binary)
            return Variant(getString());
        try
        {
            switch (column.typeOid)
            {
            case Oid.bool_:
                return Variant(getBool());
            case Oid.int2:
                return Variant(cast(short) integer());
            case Oid.int4:
                return Variant(cast(int) integer());
            case Oid.int8:
                return Variant(integer());
            case Oid.oid:
                return Variant(cast(uint) integer());
            case Oid.float4:
                return Variant(float4());
            case Oid.float8:
                return Variant(float8());
            case Oid.numeric:
                return Variant(getDecimal());
            case Oid.bytea:
                return Variant(data);
            case Oid.date:
                return Variant(getDate());
            case Oid.time:
                return Variant(getTimeOfDay());
            case Oid.timestamp:
                return Variant(getDateTime());
            case Oid.timestamptz:
                return Variant(getSysTime());
            case Oid.interval:
                return Variant(getInterval());
            case Oid.uuid:
                return Variant(getUUID());
            default:
                return Variant(getString());
            }
        }
        catch (ClientException)
            return Variant(getString()); // NaN, infinity, out of D's ranges
    }

    // --- helpers ---

    private void notNull() const @safe
    {
        if (null_)
            throw new ClientException("The value of column " ~ column.name ~ " is NULL");
    }

    private ClientException wrongType(string target) const @safe
    {
        return new ClientException("Column " ~ column.name ~ " (" ~ typeName() ~ (binary ? "" : ", text format")
                ~ ") can't be read as " ~ target);
    }

    private string typeName() const @safe
    {
        import std.conv : to;

        foreach (member; __traits(allMembers, Oid))
            if (__traits(getMember, Oid, member) == column.typeOid)
                return member[$ - 1] == '_' ? member[0 .. $ - 1] : member;
        return "type OID " ~ column.typeOid.to!string;
    }

    private @property bool isIntegerType() const @safe pure nothrow
    {
        const t = column.typeOid;
        return t == Oid.int2 || t == Oid.int4 || t == Oid.int8 || t == Oid.oid;
    }

    private T fixed(T)() const @safe
    {
        if (data.length != T.sizeof)
            throw new ProtocolException("Malformed " ~ typeName() ~ " value: " ~ T.sizeof.stringof ~ " bytes expected");
        return bigEndian!T(data);
    }

    private long integer() const @safe
    {
        switch (column.typeOid)
        {
        case Oid.int2:
            return fixed!short();
        case Oid.int4:
            return fixed!int();
        case Oid.oid:
            return cast(uint) fixed!int();
        default:
            return fixed!long();
        }
    }

    private float float4() const @safe
    {
        const bits = cast(uint) fixed!int();
        return (() @trusted => *cast(const(float)*)&bits)(); // reinterprets the 4 bytes
    }

    private double float8() const @safe
    {
        const bits = cast(ulong) fixed!long();
        return (() @trusted => *cast(const(double)*)&bits)(); // reinterprets the 8 bytes
    }

    private long timestampValue() const @safe
    {
        return binary ? fixed!long() : parseTimestamp(text);
    }

    private static struct TimeTz
    {
        long microseconds;
        int zoneWest;
    }

    private TimeTz timeTzParts() const @safe
    {
        if (data.length != 12)
            throw new ProtocolException("Malformed timetz value");
        return TimeTz(bigEndian!long(data[0 .. 8]), bigEndian!int(data[8 .. 12]));
    }

    private string jsonbText() const @safe
    {
        if (data.length == 0 || data[0] != 1)
            throw new ProtocolException("Unsupported jsonb format version");
        return cast(string) data[1 .. $];
    }

    private string byteaHex() const @safe pure
    {
        static immutable digits = "0123456789abcdef";
        auto text = new char[2 + data.length * 2];
        text[0 .. 2] = `\x`;
        foreach (i, b; data)
        {
            text[2 + 2 * i] = digits[b >> 4];
            text[3 + 2 * i] = digits[b & 15];
        }
        return text;
    }

    // "char": the byte itself, or \ooo for bytes with the high bit set; empty for 0
    private string charText() const @safe
    {
        import std.format : format;

        if (data.length != 1)
            throw new ProtocolException("Malformed \"char\" value");
        if (data[0] == 0)
            return "";
        if (data[0] >= 0x80)
            return format(`\%03o`, data[0]);
        return [cast(immutable(char)) data[0]];
    }
}

private T bigEndian(T)(scope const(ubyte)[] bytes) @safe pure nothrow
{
    ulong v;
    foreach (b; bytes[0 .. T.sizeof])
        v = (v << 8) | b;
    return cast(T) v;
}

// Decodes bytea's hex text (\x0102...).
private immutable(ubyte)[] decodeHex(const(char)[] text) @safe pure
{
    static int digit(char c)
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    if (text.length < 2 || text[0 .. 2] != `\x` || text.length % 2 != 0)
        throw new ClientException("Unsupported bytea text (hex format expected)");
    const half = text.length / 2;
    auto bytes = new ubyte[half - 1];
    foreach (i, ref b; bytes)
    {
        const hi = digit(text[2 + 2 * i]), lo = digit(text[3 + 2 * i]);
        if (hi < 0 || lo < 0)
            throw new ClientException("Invalid bytea hex text");
        b = cast(ubyte)(hi << 4 | lo);
    }
    return bytes;
}

// Values built from server bytes (captured with psql's binary COPY and the protocol).
@safe unittest
{
    import std.exception : assertThrown;

    Value v(uint oid, immutable(ubyte)[] bytes, ValueFormat format = ValueFormat.binary, bool isNull = false)
    {
        auto c = new ColumnInfo;
        c.name = "c";
        c.typeOid = oid;
        c.format = format;
        return Value(c, bytes, isNull, "UTC");
    }

    assert(v(Oid.int4, [0xFF, 0xFF, 0xFF, 0xFE]).getLong() == -2);
    assert(v(Oid.int2, [0x80, 0]).getString() == "-32768");
    assert(v(Oid.oid, [0xFF, 0xFF, 0xFF, 0xFF]).getString() == "4294967295");
    assert(v(Oid.bool_, [1]).getBool() && v(Oid.bool_, [0]).getString() == "f");
    assert(v(Oid.float8, [0x3F, 0xF8, 0, 0, 0, 0, 0, 0]).getDouble() == 1.5);
    assert(v(Oid.float4, [0x3F, 0xC0, 0, 0]).getString() == "1.5");
    assert(v(Oid.bytea, [0, 0xFF, 0x10]).getString() == `\x00ff10`);
    assert(v(Oid.bytea, cast(immutable(ubyte)[]) `\x00ff10`, ValueFormat.text).getBytes() == [
        0, 0xFF, 0x10
    ]);
    assert(v(Oid.char_, [0xE9]).getString() == `\351` && v(Oid.char_, ['a']).getString() == "a");
    assert(v(Oid.jsonb, cast(immutable(ubyte)[]) "\x01{\"a\": 1}").getString() == `{"a": 1}`);
    assert(v(Oid.date, [0, 0, 0x26, 0x4E]).getDate() == Date(2026, 11, 6));
    assert(v(Oid.interval, [0, 0, 0, 3, 0x6C, 0x97, 0xCA, 0x88, 0, 0, 0, 3, 0, 0, 0, 14]).getString()
            == "1 year 2 mons 3 days 04:05:06.789");
    assert(v(Oid.timetz, [0, 0, 0, 0x0A, 0x8B, 0xDA, 0x1C, 0x00, 0xFF, 0xFF, 0xB2, 0xA8]).getString()
            == "12:34:56+05:30");
    assert(v(Oid.int4, cast(immutable(ubyte)[]) "42", ValueFormat.text).getLong() == 42);
    assert(v(Oid.text, null, ValueFormat.binary, true).getString() is null);
    assertThrown!ClientException(v(Oid.text, null, ValueFormat.binary, true).getLong());
    assertThrown!ClientException(v(Oid.text, cast(immutable(ubyte)[]) "abc").getLong());
    assertThrown!ProtocolException(v(Oid.int4, [1, 2]).getLong());
    const variant = v(Oid.int8, [0, 0, 0, 0, 0, 0, 0, 7]).getVariant();
    assert((() @trusted => variant.get!long)() == 7);
}
