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
import postgresql.types.pgtype;
import postgresql.types.textformat;
import postgresql.types.network : Inet, macAddressText, parseMacAddress;
import postgresql.types.geometric;
import postgresql.types.bitstring : BitString;
import postgresql.types.ranges : isRange, Range;

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

    /// The value's data type; null if the client doesn't know it (see `ColumnInfo.type`).
    @property const(PgType) type() const @safe nothrow
    {
        return column.type !is null ? column.type : builtinType(column.typeOid);
    }

    // The built-in type whose decoder reads the value (domains: their base type's; enums: text).
    private @property uint codec() const @safe nothrow
    {
        const t = type;
        return t is null ? column.typeOid : t.codec;
    }

    // The kind of the value's type, domains looked through (base for unknown types).
    private @property TypeKind kind() const @safe nothrow
    {
        const t = type;
        return t is null ? TypeKind.base : t.withoutDomain.kind;
    }

    /// The bytes as the server sent them (binary or text format); null for NULL.
    @property immutable(ubyte)[] raw() const @safe pure nothrow
    {
        return null_ ? null : data;
    }

    // Whether the value is in a binary form to decode. The binary form of text types (text, varchar, char(n),
    // name, enums, citext) is their text, so they are read as text: getLong parses '17', getBool 't'.
    private @property bool binary() const @safe nothrow
    {
        if (column.format != ValueFormat.binary)
            return false;
        switch (codec)
        {
        case Oid.text, Oid.varchar, Oid.bpchar, Oid.name, Oid.unknown:
            return false;
        default:
            return true;
        }
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
        final switch (kind)
        {
        case TypeKind.array:
            return arrayText();
        case TypeKind.range:
            return rangeText(getRange());
        case TypeKind.multirange:
            return multirangeText();
        case TypeKind.composite:
            return recordText();
        case TypeKind.base, TypeKind.enum_, TypeKind.domain, TypeKind.pseudo:
            break;
        }
        switch (codec)
        {
        case Oid.text, Oid.varchar, Oid.bpchar, Oid.name, Oid.json, Oid.unknown:
            return cast(string) data;
        case Oid.inet, Oid.cidr:
            return Inet.fromBinary(data).toString();
        case Oid.macaddr, Oid.macaddr8:
            return macAddressText(macBytes());
        case Oid.bit, Oid.varbit:
            return BitString.fromBinary(data).toString();
        case Oid.point:
            return geometricFromBinary!Point(data).toString();
        case Oid.line:
            return geometricFromBinary!Line(data).toString();
        case Oid.lseg:
            return geometricFromBinary!LineSegment(data).toString();
        case Oid.box:
            return geometricFromBinary!Box(data).toString();
        case Oid.path:
            return geometricFromBinary!Path(data).toString();
        case Oid.polygon:
            return geometricFromBinary!Polygon(data).toString();
        case Oid.circle:
            return geometricFromBinary!Circle(data).toString();
        case Oid.pgLsn:
            import std.format : format;

            const lsn = cast(ulong) fixed!long();
            return format("%X/%X", lsn >> 32, lsn & 0xFFFF_FFFF);
        case hstoreCodec:
            return hstoreText(getHstorePairs());
        case postgisCodec:
            return upperHex(data);
        case Oid.jsonb:
            return jsonbText();
        case Oid.bool_:
            return fixed!ubyte() ? "t" : "f";
        case Oid.int2, Oid.int4, Oid.int8, Oid.oid:
            import std.conv : to;

            return codec == Oid.oid ? (cast(uint) integer()).to!string : integer().to!string;
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
            if (codec == Oid.bool_)
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
            if (codec == Oid.bool_)
                return fixed!ubyte() != 0;
            if (codec == Oid.numeric)
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
            switch (codec)
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
            if (codec == Oid.numeric)
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
    the 16 bytes of a `uuid`, the 6 or 8 of a `macaddr`/`macaddr8`, the EWKB
    of a PostGIS `geometry`/`geography`, the UTF-8 bytes of a text value.

    Throws: `ClientException` for NULL or other types.
    +/
    immutable(ubyte)[] getBytes() const @safe
    {
        notNull();
        if (binary)
        {
            switch (codec)
            {
            case Oid.bytea, Oid.uuid, Oid.text, Oid.varchar, Oid.bpchar, Oid.name, Oid.json, Oid.char_:
                return data;
            case Oid.macaddr, Oid.macaddr8:
                return macBytes();
            case postgisCodec:
                return data;
            default:
                throw wrongType("bytes");
            }
        }
        if (codec == Oid.bytea)
            return decodeHex(text);
        if (codec == Oid.macaddr || codec == Oid.macaddr8)
            return parseMacAddress(cast(string) data);
        if (codec == postgisCodec)
            return decodeHex(`\x` ~ text);
        return data;
    }

    /++
    The value as a `Date`: `date`, the date part of a `timestamp`; date text.

    Throws: `ClientException` for NULL, `infinity`, years out of `Date`'s range, or other types.
    +/
    Date getDate() const @safe
    {
        notNull();
        switch (codec)
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
        switch (codec)
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
        switch (codec)
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
        switch (codec)
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
        switch (codec)
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
        if (codec == Oid.time)
            return usecs(binary ? fixed!long() : parseTime(text));
        if (codec == Oid.interval && binary)
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
        if (codec != Oid.interval || !binary)
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
            if (codec != Oid.uuid)
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
    `SysTime` (`timestamptz`), `Interval`, `UUID`, `Inet` (`inet`, `cidr`),
    `BitString`, the geometric structs (`Point`, ...); an empty `Variant` for
    NULL. Infinite dates and timestamps, times of 24:00:00, arrays, ranges,
    composite values and the other types are strings (their text).
    +/
    Variant getVariant() const @trusted
    {
        // Variant's copy constructor isn't @safe; the values put in it are plain data
        if (null_)
            return Variant();
        if (!binary || kind != TypeKind.base)
            return Variant(getString());
        try
        {
            switch (codec)
            {
            case Oid.inet, Oid.cidr:
                return Variant(getInet());
            case Oid.bit, Oid.varbit:
                return Variant(getBitString());
            case Oid.point:
                return Variant(get!Point());
            case Oid.line:
                return Variant(get!Line());
            case Oid.lseg:
                return Variant(get!LineSegment());
            case Oid.box:
                return Variant(get!Box());
            case Oid.path:
                return Variant(get!Path());
            case Oid.polygon:
                return Variant(get!Polygon());
            case Oid.circle:
                return Variant(get!Circle());
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

    /++
    The value as an array: its dimensions and elements, which are `Value`s
    of the element type. Binary and text values alike.

    Throws: `ClientException` for NULL or values that aren't arrays.
    +/
    ArrayValue getArray() const @safe
    {
        notNull();
        const t = type;
        if (kind != TypeKind.array)
            throw wrongType("array");
        const element = t.withoutDomain.element;
        ArrayValue a;
        if (!binary)
        {
            auto parts = parseArrayText(cast(string) data, element is null ? ',' : element.delimiter);
            a.lengths = parts.lengths;
            a.lowerBounds = parts.lowerBounds;
            const info = partInfo(element, ValueFormat.text, 0);
            a.elements = new Value[parts.elements.length];
            foreach (i, e; parts.elements)
                a.elements[i] = Value(info, cast(immutable(ubyte)[]) e, e is null, timeZone);
            return a;
        }
        auto r = Reader(data, "array");
        const dims = r.int32();
        r.int32(); // has NULLs
        const elementOid = cast(uint) r.int32();
        if (dims < 0 || dims > 6)
            throw new ProtocolException("Malformed array value: " ~ "dimensions");
        size_t total = dims > 0 ? 1 : 0;
        a.lengths = new int[dims];
        a.lowerBounds = new int[dims];
        foreach (d; 0 .. dims)
        {
            a.lengths[d] = r.int32();
            a.lowerBounds[d] = r.int32();
            if (a.lengths[d] < 0 || total * a.lengths[d] > data.length)
                throw new ProtocolException("Malformed array value: " ~ "lengths");
            total *= a.lengths[d];
        }
        const info = partInfo(element !is null ? element : builtinType(elementOid), ValueFormat.binary, elementOid);
        a.elements = new Value[total];
        foreach (ref e; a.elements)
        {
            const p = r.part();
            e = Value(info, p.bytes, p.isNull, timeZone);
        }
        r.end();
        return a;
    }

    /++
    The value as a range: emptiness, bounds (`Value`s of the subtype) and
    their inclusivity. See `get!(Range!T)` for typed ranges.

    Throws: `ClientException` for NULL or values that aren't ranges.
    +/
    RangeValue getRange() const @safe
    {
        notNull();
        if (kind != TypeKind.range)
            throw wrongType("range");
        return rangeFrom(data, binary, type.withoutDomain.element);
    }

    /++
    The value as a multirange: its ranges, in order.

    Throws: `ClientException` for NULL or values that aren't multiranges.
    +/
    RangeValue[] getMultirange() const @safe
    {
        notNull();
        if (kind != TypeKind.multirange)
            throw wrongType("multirange");
        const rangeType = type.withoutDomain.element;
        const subtype = rangeType is null ? null : rangeType.element;
        RangeValue[] ranges;
        if (!binary)
        {
            foreach (text; parseMultirangeText(cast(string) data))
                ranges ~= rangeFrom(cast(immutable(ubyte)[]) text, false, subtype);
            return ranges;
        }
        auto r = Reader(data, "multirange");
        const count = r.int32();
        if (count < 0 || count > data.length)
            throw new ProtocolException("Malformed multirange value");
        foreach (i; 0 .. count)
        {
            const p = r.part();
            if (p.isNull)
                throw new ProtocolException("Malformed multirange value");
            ranges ~= rangeFrom(p.bytes, true, subtype);
        }
        r.end();
        return ranges;
    }

    /++
    The value as a record: the fields of a composite value (`Value`s of their
    types) and, for a composite type the connection knows, their names. See
    `get!S` for structs.

    Throws: `ClientException` for NULL or values that aren't composite.
    +/
    RecordValue getRecord() const @safe
    {
        notNull();
        if (kind != TypeKind.composite)
            throw wrongType("record");
        const t = type.withoutDomain;
        RecordValue record;
        record.names = t.fieldNames;
        if (!binary)
        {
            const fields = parseRecordText(cast(string) data);
            record.fields = new Value[fields.length];
            foreach (i, f; fields)
            {
                const fieldType = i < t.fieldTypes.length ? t.fieldTypes[i] : null;
                record.fields[i] = Value(partInfo(fieldType, ValueFormat.text, 0, fieldName(t, i)),
                        cast(immutable(ubyte)[]) f, f is null, timeZone);
            }
            if (record.names.length != fields.length)
                record.names = null;
            return record;
        }
        auto r = Reader(data, "record");
        const count = r.int32();
        if (count < 0 || count > data.length)
            throw new ProtocolException("Malformed record value");
        record.fields = new Value[count];
        foreach (i, ref f; record.fields)
        {
            const oid = cast(uint) r.int32();
            const p = r.part();
            const known = i < t.fieldTypes.length && t.fieldTypes[i]!is null && t.fieldTypes[i].oid == oid
                ? t.fieldTypes[i] : builtinType(oid);
            f = Value(partInfo(known, ValueFormat.binary, oid, fieldName(t, i)), p.bytes, p.isNull, timeZone);
        }
        r.end();
        if (record.names.length != count)
            record.names = null;
        return record;
    }

    /++
    The value as an `Inet`: `inet`, `cidr`; their text.

    Throws: `ClientException` for NULL or other types.
    +/
    Inet getInet() const @safe
    {
        notNull();
        if (codec != Oid.inet && codec != Oid.cidr)
            throw wrongType("Inet");
        return binary ? Inet.fromBinary(data) : Inet.parse(cast(string) data, codec == Oid.cidr);
    }

    /++
    The value as a `BitString`: `bit`, `varbit`; their text.

    Throws: `ClientException` for NULL or other types.
    +/
    BitString getBitString() const @safe
    {
        notNull();
        if (codec != Oid.bit && codec != Oid.varbit)
            throw wrongType("BitString");
        return binary ? BitString.fromBinary(data) : BitString.parse(cast(string) data);
    }

    /++
    The value of an `hstore` (extension type): its keys and values (null
    for NULL values), in the server's order.

    Throws: `ClientException` for NULL or other types.
    +/
    HstorePair[] getHstore() const @safe
    {
        notNull();
        if (codec != hstoreCodec)
            throw wrongType("hstore");
        return getHstorePairs();
    }

    /++
    The value converted to `T`: any type with a getter (`bool`, integers,
    floating point, strings, `ubyte[]`, `Decimal`, `Date`, `TimeOfDay`,
    `DateTime`, `SysTime`, `Duration`, `Interval`, `UUID`, `Variant`,
    `Inet`, `BitString`, `Point`, `Line`, `LineSegment`, `Box`, `Path`,
    `Polygon`, `Circle`, `ArrayValue`, `RangeValue`, `RecordValue`), and:
    $(UL
    $(LI enums: from numbers, or from text (and PostgreSQL enums) by member name or value;)
    $(LI `Nullable!T`: null for NULL;)
    $(LI D arrays (`int[]`, `string[]`, `Nullable!int[]`, `int[][]` for two dimensions, ...) from arrays;)
    $(LI `Range!T` from ranges, `Range!T[]` from multiranges;)
    $(LI `string[string]` and `Nullable!string[string]` from `hstore`;)
    $(LI other structs from composite values: fields by name (`@column`, `@ignore`) when the type's
        field names are known, else in order.)
    )
    Integers are range-checked; `ulong` also reads `numeric` values above
    `long.max`. NULL throws, except for types that hold it (`Nullable`,
    `string`, `ubyte[]`, `Variant`, arrays: null).

    Throws: `ClientException` if the value can't be converted.
    +/
    T get(T)() const
    {
        import std.conv : ConvException, to;
        import std.traits : isDynamicArray, isFloatingPoint, isIntegral, isSomeString, OriginalType, Unqual;
        import std.typecons : Nullable;

        alias U = Unqual!T;
        static if (is(U : Nullable!N, N))
            return isNull ? T.init : T(get!N());
        else static if (is(U == Variant))
            return getVariant();
        else static if (is(U == enum))
        {
            notNull();
            if (codec == Oid.int2 || codec == Oid.int4 || codec == Oid.int8 || codec == Oid.oid
                    || codec == Oid.numeric)
            {
                const n = getLong();
                foreach (member; __traits(allMembers, U))
                    if (__traits(getMember, U, member) == n)
                        return __traits(getMember, U, member);
                throw new ClientException(n.to!string ~ " is not a value of " ~ T.stringof);
            }
            // the member's name, or its value (as text)
            const text = getString();
            try
                return text.to!U;
            catch (ConvException)
            {
            }
            foreach (member; __traits(allMembers, U))
                if ((cast(OriginalType!U) __traits(getMember, U, member)).to!string == text)
                    return __traits(getMember, U, member);
            throw new ClientException("'" ~ text ~ "' is not a value of " ~ T.stringof);
        }
        else static if (is(U == bool))
            return getBool();
        else static if (isIntegral!U)
        {
            static if (is(U == ulong))
            {
                if (!isNull && (codec == Oid.numeric || codec == Oid.pgLsn))
                {
                    if (codec == Oid.pgLsn)
                        return binary ? cast(ulong) fixed!long() : parseLsn(cast(string) data);
                    try
                        return getString().to!ulong;
                    catch (ConvException)
                        throw new ClientException("Value " ~ getString() ~ " does not fit in ulong");
                }
            }
            const n = getLong();
            static if (U.min == 0)
                const below = n < 0; // (comparing with ulong's 0 would compare as unsigned)
            else
                const below = n < U.min;
            if (below || (U.max <= long.max && n > cast(long) U.max))
                throw new ClientException("Value " ~ n.to!string ~ " does not fit in " ~ U.stringof);
            return cast(T) n;
        }
        else static if (isFloatingPoint!U)
            return cast(T) getDouble();
        else static if (isSomeString!U)
            return getString().to!T;
        else static if (is(U : const(ubyte)[]))
        {
            if (isNull)
                return null;
            static if (is(immutable(ubyte)[] : U))
                return getBytes();
            else
                return getBytes().dup;
        }
        else static if (is(U == Decimal))
            return getDecimal();
        else static if (is(U == Date))
            return getDate();
        else static if (is(U == TimeOfDay))
            return getTimeOfDay();
        else static if (is(U == Duration))
            return getDuration();
        else static if (is(U == Interval))
            return getInterval();
        else static if (is(U == DateTime))
            return getDateTime();
        else static if (is(U == SysTime))
            return getSysTime();
        else static if (is(U == UUID))
            return getUUID();
        else static if (is(U == Inet))
            return getInet();
        else static if (is(U == BitString))
            return getBitString();
        else static if (isGeometric!U)
        {
            notNull();
            const expected = geometricOid!U;
            if (codec != expected)
                throw wrongType(U.stringof);
            return binary ? geometricFromBinary!U(data) : parseGeometric!U(cast(string) data);
        }
        else static if (is(U == ArrayValue))
            return getArray();
        else static if (is(U == RangeValue))
            return getRange();
        else static if (is(U == RecordValue))
            return getRecord();
        else static if (isRange!U)
            return typedRange!U(getRange());
        else static if (is(U : V[K], V, K))
        {
            static assert(is(K == string) && (is(V == string) || is(V == Nullable!string)),
                    "Only string[string] and Nullable!string[string] (hstore) are read as associative arrays");
            if (isNull)
                return null;
            U map;
            foreach (pair; getHstore())
            {
                static if (is(V == string))
                    map[pair.key] = pair.value;
                else
                    map[pair.key] = pair.value is null ? V.init : V(pair.value);
            }
            return map;
        }
        else static if (isDynamicArray!U)
        {
            alias E = Unqual!(typeof(U.init[0]));
            if (isNull)
                return null;
            static if (isRange!E)
            {
                if (kind == TypeKind.multirange)
                {
                    E[] list;
                    foreach (r; getMultirange())
                        list ~= typedRange!E(r);
                    return cast(T) list;
                }
            }
            const a = getArray();
            if (a.elements.length == 0)
                return T.init;
            enum depth = arrayDepth!U;
            if (a.lengths.length != depth)
                throw new ClientException("The array has " ~ a.lengths.length.to!string ~ " dimension(s), "
                        ~ T.stringof ~ " has " ~ depth.to!string);
            size_t at;
            return cast(T) buildArray!U(a, 0, at);
        }
        else static if (is(U == struct))
        {
            import postgresql.attributes : columnNames, findName, mappedFields;

            notNull();
            const record = getRecord();
            enum names = columnNames!U;
            // by name if every field is found, else in order
            size_t[names.length] positions;
            bool byName = record.names.length > 0;
            foreach (i, name; names)
            {
                const p = byName ? findName(record.names, name) : -1;
                if (p < 0)
                    byName = false;
                else
                    positions[i] = p;
            }
            if (!byName)
            {
                if (record.fields.length < names.length)
                    throw new ClientException("The record has " ~ record.fields.length.to!string ~ " field(s), "
                            ~ U.stringof ~ " needs " ~ names.length.to!string);
                foreach (i, ref p; positions)
                    p = i;
            }
            U value;
            static foreach (i, name; mappedFields!U)
            {
                try
                    __traits(getMember, value, name) = record.fields[positions[i]].get!(typeof(__traits(getMember,
                            U, name)))();
                catch (ClientException e)
                    throw new ClientException(U.stringof ~ "." ~ name ~ ": " ~ e.msg);
            }
            return value;
        }
        else
            static assert(0, "Values can't be read as " ~ T.stringof);
    }

    // The array (or nested arrays) of `A` from `a`, starting at dimension `level` and element `at`.
    private static A buildArray(A)(const ArrayValue a, size_t level, ref size_t at)
    {
        import std.traits : Unqual;

        alias E = Unqual!(typeof(A.init[0]));
        auto list = new E[a.lengths[level]];
        foreach (ref item; list)
        {
            static if (arrayDepth!E > 0)
                item = buildArray!E(a, level + 1, at);
            else
                item = a.elements[at++].get!E();
        }
        return cast(A) list;
    }

    private static R typedRange(R)(const RangeValue r)
    {
        alias T = typeof(R.init.lower);
        R result;
        result.empty = r.empty;
        result.lowerInclusive = r.lowerInclusive;
        result.upperInclusive = r.upperInclusive;
        result.lowerInfinite = r.lowerInfinite;
        result.upperInfinite = r.upperInfinite;
        if (!r.empty && !r.lowerInfinite)
            result.lower = r.lower.get!T();
        if (!r.empty && !r.upperInfinite)
            result.upper = r.upper.get!T();
        return result;
    }

    // A ColumnInfo for the parts (elements, fields, bounds) of this value.
    private const(ColumnInfo)* partInfo(const(PgType) partType, ValueFormat format, uint oid,
            string name = null) const @safe
    {
        auto info = new ColumnInfo;
        info.name = name.length ? name : column.name;
        info.typeOid = partType !is null ? partType.oid : oid;
        info.typeModifier = -1;
        info.format = format;
        info.type = partType;
        return info;
    }

    private static string fieldName(const PgType t, size_t i) @safe pure nothrow
    {
        return i < t.fieldNames.length ? t.fieldNames[i] : null;
    }

    private RangeValue rangeFrom(immutable(ubyte)[] bytes, bool isBinary, const(PgType) subtype) const @safe
    {
        RangeValue r;
        if (!isBinary)
        {
            const parts = parseRangeText(cast(string) bytes);
            r.empty = parts.empty;
            if (r.empty)
                return r;
            r.lowerInclusive = parts.lowerInclusive;
            r.upperInclusive = parts.upperInclusive;
            r.lowerInfinite = parts.lower is null;
            r.upperInfinite = parts.upper is null;
            const info = partInfo(subtype, ValueFormat.text, 0);
            if (!r.lowerInfinite)
                r.lower = Value(info, cast(immutable(ubyte)[]) parts.lower, false, timeZone);
            if (!r.upperInfinite)
                r.upper = Value(info, cast(immutable(ubyte)[]) parts.upper, false, timeZone);
            return r;
        }
        // flags: empty 0x01, [ 0x02, ] 0x04, no lower 0x08, no upper 0x10 (NULL bounds 0x20, 0x40)
        auto reader = Reader(bytes, "range");
        const flags = reader.byte_();
        r.empty = (flags & 0x01) != 0;
        r.lowerInclusive = (flags & 0x02) != 0;
        r.upperInclusive = (flags & 0x04) != 0;
        r.lowerInfinite = (flags & 0x28) != 0;
        r.upperInfinite = (flags & 0x50) != 0;
        const info = partInfo(subtype, ValueFormat.binary, 0);
        if (!r.empty && !r.lowerInfinite)
            r.lower = Value(info, reader.part().bytes, false, timeZone);
        if (!r.empty && !r.upperInfinite)
            r.upper = Value(info, reader.part().bytes, false, timeZone);
        reader.end();
        return r;
    }

    private string arrayText() const @safe
    {
        import std.conv : to;

        const a = getArray();
        if (a.elements.length == 0)
            return "{}";
        const element = type.withoutDomain.element;
        const delimiter = element is null ? ',' : element.delimiter;
        string text;
        foreach (d; 0 .. a.lengths.length)
            if (a.lowerBounds[d] != 1)
            {
                foreach (k; 0 .. a.lengths.length)
                    text ~= "[" ~ a.lowerBounds[k].to!string ~ ":" ~ (a.lowerBounds[k] + a.lengths[k] - 1).to!string
                        ~ "]";
                text ~= "=";
                break;
            }
        // row-major: before element i, as many braces close and open as dimensions start a sub-array at i
        size_t starts(size_t i)
        {
            size_t count, stride = 1;
            foreach_reverse (d; 0 .. a.lengths.length)
            {
                stride *= a.lengths[d];
                if (i % stride != 0)
                    break;
                count++;
            }
            return count;
        }

        foreach (i, e; a.elements)
        {
            const n = starts(i);
            if (i > 0)
            {
                foreach (k; 0 .. n)
                    text ~= "}";
                text ~= delimiter;
            }
            foreach (k; 0 .. n)
                text ~= "{";
            text ~= e.isNull ? "NULL" : quoteArrayElement(e.getString(), delimiter);
        }
        foreach (k; 0 .. a.lengths.length)
            text ~= "}";
        return text;
    }

    private static string rangeText(const RangeValue r) @safe
    {
        if (r.empty)
            return "empty";
        return (r.lowerInclusive ? "[" : "(") ~ (r.lowerInfinite ? "" : quoteRangeBound(r.lower.getString())) ~ ","
            ~ (
                    r.upperInfinite ? "" : quoteRangeBound(r.upper.getString())) ~ (r.upperInclusive ? "]" : ")");
    }

    private string multirangeText() const @safe
    {
        string text = "{";
        foreach (i, r; getMultirange())
            text ~= (i ? "," : "") ~ rangeText(r);
        return text ~ "}";
    }

    private string recordText() const @safe
    {
        string text = "(";
        foreach (i, f; getRecord().fields)
            text ~= (i ? "," : "") ~ (f.isNull ? "" : quoteRecordField(f.getString()));
        return text ~ ")";
    }

    private HstorePair[] getHstorePairs() const @safe
    {
        if (!binary)
            return parseHstoreText(cast(string) data);
        auto r = Reader(data, "hstore");
        const count = r.int32();
        if (count < 0 || count > data.length)
            throw new ProtocolException("Malformed hstore value");
        auto pairs = new HstorePair[count];
        foreach (ref p; pairs)
        {
            const key = r.part();
            if (key.isNull)
                throw new ProtocolException("Malformed hstore value");
            p.key = cast(string) key.bytes;
            const value = r.part();
            p.value = value.isNull ? null : value.bytes.length ? cast(string) value.bytes : "";
        }
        r.end();
        return pairs;
    }

    private static string hstoreText(const HstorePair[] pairs) @safe
    {
        string text;
        foreach (i, p; pairs)
            text ~= (i ? ", " : "") ~ quoteHstore(p.key) ~ "=>" ~ (p.value is null ? "NULL" : quoteHstore(p.value));
        return text;
    }

    private immutable(ubyte)[] macBytes() const @safe
    {
        if (data.length != (codec == Oid.macaddr ? 6 : 8))
            throw new ProtocolException("Malformed " ~ typeName() ~ " value");
        return data;
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

        if (const t = type)
            return t.name;
        return "type OID " ~ column.typeOid.to!string;
    }

    private @property bool isIntegerType() const @safe nothrow
    {
        const t = codec;
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
        switch (codec)
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

/// An array value: its dimensions and elements (see `Value.getArray`).
struct ArrayValue
{
    /// The length of each dimension; empty for an empty array.
    int[] lengths;
    /// The lower bound (first index) of each dimension: 1 unless the array was built otherwise.
    int[] lowerBounds;
    /// The elements in row-major order.
    Value[] elements;

    /// Number of elements (all dimensions).
    @property size_t length() const @safe pure nothrow
    {
        return elements.length;
    }

    /// Element `i` in row-major order.
    Value opIndex(size_t i) const @safe pure nothrow
    {
        return elements[i];
    }
}

/// A range value (see `Value.getRange`).
struct RangeValue
{
    /// Whether the range is empty.
    bool empty;
    /// Whether the bounds are included.
    bool lowerInclusive, upperInclusive;
    /// Whether a bound is missing (unbounded).
    bool lowerInfinite, upperInfinite;
    /// The bounds; unused when infinite or empty.
    Value lower, upper;
}

/// A composite value (see `Value.getRecord`).
struct RecordValue
{
    /// The field names, when the type is known (not for `record`); else empty.
    const(string)[] names;
    /// The fields.
    Value[] fields;

    /// Number of fields.
    @property size_t length() const @safe pure nothrow
    {
        return fields.length;
    }

    /// Field `i`.
    Value opIndex(size_t i) const @safe pure nothrow
    {
        return fields[i];
    }

    /++
    The field named `name` (exact, else ignoring case).

    Throws: `ClientException` if there is none.
    +/
    Value opIndex(string name) const @safe
    {
        import postgresql.attributes : findName;

        const i = findName(names, name);
        if (i < 0)
            throw new ClientException("The record has no field '" ~ name ~ "'");
        return fields[i];
    }
}

// The number of array dimensions of D type `T` (strings and ubyte[] are values, not arrays).
private template arrayDepth(T)
{
    import std.traits : isDynamicArray, isSomeString;
    import postgresql.types.ranges : isRange;

    static if (isDynamicArray!T && !isSomeString!T && !is(T : const(ubyte)[]))
        enum arrayDepth = 1 + arrayDepth!(typeof(T.init[0]));
    else
        enum arrayDepth = 0;
}

// The OID of a geometric type.
private template geometricOid(T)
{
    static if (is(T == Point))
        enum geometricOid = Oid.point;
    else static if (is(T == Line))
        enum geometricOid = Oid.line;
    else static if (is(T == LineSegment))
        enum geometricOid = Oid.lseg;
    else static if (is(T == Box))
        enum geometricOid = Oid.box;
    else static if (is(T == Path))
        enum geometricOid = Oid.path;
    else static if (is(T == Polygon))
        enum geometricOid = Oid.polygon;
    else
        enum geometricOid = Oid.circle;
}

// Reads the parts of binary container values (arrays, ranges, records, hstore).
private struct Reader
{
    immutable(ubyte)[] data;
    string what;
    size_t at;

    this(immutable(ubyte)[] data, string what) @safe pure nothrow
    {
        this.data = data;
        this.what = what;
    }

    int int32() @safe pure
    {
        if (at + 4 > data.length)
            throw new ProtocolException("Malformed " ~ what ~ " value");
        const v = bigEndian!int(data[at .. at + 4]);
        at += 4;
        return v;
    }

    ubyte byte_() @safe pure
    {
        if (at >= data.length)
            throw new ProtocolException("Malformed " ~ what ~ " value");
        return data[at++];
    }

    static struct Part
    {
        immutable(ubyte)[] bytes;
        bool isNull;
    }

    // an int32 length (-1: NULL) and that many bytes
    Part part() @safe pure
    {
        const length = int32();
        if (length == -1)
            return Part(null, true);
        if (length < 0 || at + length > data.length)
            throw new ProtocolException("Malformed " ~ what ~ " value");
        auto bytes = data[at .. at + length];
        at += length;
        return Part(bytes, false);
    }

    void end() @safe pure
    {
        if (at != data.length)
            throw new ProtocolException("Malformed " ~ what ~ " value");
    }
}

// pg_lsn text: two hexadecimal halves, `16/B374D848`.
private ulong parseLsn(string text) @safe pure
{
    import std.conv : ConvException, to;
    import std.string : indexOf;

    const slash = text.indexOf('/');
    try
    {
        if (slash > 0)
            return text[0 .. slash].to!ulong(16) << 32 | text[slash + 1 .. $].to!ulong(16);
    }
    catch (ConvException)
    {
    }
    throw new ClientException("Invalid pg_lsn '" ~ text ~ "'");
}

private T bigEndian(T)(scope const(ubyte)[] bytes) @safe pure nothrow
{
    ulong v;
    foreach (b; bytes[0 .. T.sizeof])
        v = (v << 8) | b;
    return cast(T) v;
}

// Uppercase hexadecimal digits (PostGIS's text of EWKB).
private string upperHex(scope const(ubyte)[] data) @safe pure
{
    static immutable digits = "0123456789ABCDEF";
    auto text = new char[data.length * 2];
    foreach (i, b; data)
    {
        text[2 * i] = digits[b >> 4];
        text[2 * i + 1] = digits[b & 15];
    }
    return (() @trusted => cast(string) text)(); // not referenced elsewhere
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
