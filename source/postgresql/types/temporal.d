/++
Dates, times, timestamps and intervals: binary values and their text as
PostgreSQL prints it (`DateStyle=ISO`, `IntervalStyle=postgres`).

Binary formats (integer date-times, the only kind since PostgreSQL 10):
$(UL
    $(LI `date`: int32 days since 2000-01-01; int32 max/min are `infinity`/`-infinity`.)
    $(LI `time`: int64 microseconds since midnight (up to 24:00:00).)
    $(LI `timetz`: the same, then int32 zone offset in seconds $(I west) of UTC.)
    $(LI `timestamp`, `timestamptz`: int64 microseconds since 2000-01-01 00:00
        (UTC for `timestamptz`); int64 max/min are `infinity`/`-infinity`.)
    $(LI `interval`: int64 microseconds, int32 days, int32 months.)
)

The proleptic Gregorian calendar is used throughout; years before 1 are
printed with ` BC` (year 0 is 1 BC).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.types.temporal;

import std.datetime.date : Date, DateTime, TimeOfDay;
import std.datetime.systime : SysTime;

import postgresql.exception : ClientException;

@safe:

/// Days from 1970-01-01 to 2000-01-01, PostgreSQL's epoch.
enum long postgresEpochDays = 10_957;
/// Microseconds in a day.
enum long microsecondsPerDay = 86_400_000_000L;

/// `date` values that mean `infinity` and `-infinity`.
enum int dateInfinity = int.max;
/// ditto
enum int dateNegativeInfinity = int.min;
/// `timestamp`/`timestamptz` values that mean `infinity` and `-infinity`.
enum long timestampInfinity = long.max;
/// ditto
enum long timestampNegativeInfinity = long.min;

/++
An `interval`: months, days and microseconds are kept apart, as PostgreSQL
does (a month has no fixed number of days, nor a day of hours across DST changes).
+/
struct Interval
{
    /// Months (years are 12 months).
    int months;
    /// Days.
    int days;
    /// Microseconds (hours, minutes, seconds).
    long microseconds;

    /// The interval as PostgreSQL prints it (`IntervalStyle=postgres`), e.g. `1 year 2 mons 3 days 04:05:06.789`.
    string toString() const pure
    {
        return formatInterval(this);
    }
}

/// A calendar date with a year of any size (astronomical numbering: 0 is 1 BC).
struct CivilDate
{
    /// Year.
    long year;
    /// Month, 1 to 12.
    int month;
    /// Day, 1 to 31.
    int day;
}

/// The calendar date `days` days after 1970-01-01 (negative before).
CivilDate civilFromDays(long days) pure nothrow
{
    // Count from 0000-03-01 in 400-year eras of 146097 days; March-based years put the leap day last.
    days += 719_468;
    const era = (days >= 0 ? days : days - 146_096) / 146_097;
    const dayOfEra = days - era * 146_097; // 0 .. 146096
    const yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365; // 0 .. 399
    const dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100); // 0 .. 365
    const monthIndex = (5 * dayOfYear + 2) / 153; // 0 = March .. 11 = February
    CivilDate d;
    d.day = cast(int)(dayOfYear - (153 * monthIndex + 2) / 5 + 1);
    d.month = cast(int)(monthIndex < 10 ? monthIndex + 3 : monthIndex - 9);
    d.year = yearOfEra + era * 400 + (d.month <= 2 ? 1 : 0);
    return d;
}

/// The number of days from 1970-01-01 to `date` (negative before).
long daysFromCivil(CivilDate date) pure nothrow
{
    const year = date.year - (date.month <= 2 ? 1 : 0);
    const era = (year >= 0 ? year : year - 399) / 400;
    const yearOfEra = year - era * 400;
    const monthIndex = date.month > 2 ? date.month - 3 : date.month + 9;
    const dayOfYear = (153 * monthIndex + 2) / 5 + date.day - 1;
    const dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear;
    return era * 146_097 + dayOfEra - 719_468;
}

unittest
{
    assert(civilFromDays(0) == CivilDate(1970, 1, 1) && daysFromCivil(CivilDate(1970, 1, 1)) == 0);
    assert(civilFromDays(postgresEpochDays) == CivilDate(2000, 1, 1));
    assert(civilFromDays(-719_528) == CivilDate(0, 1, 1)); // 1 BC
    foreach (long d; [
        -2_000_000_000L, -1_000_000, -719_529, -1, 1, 59, 60, 11_016, 2_000_000_000L
    ])
        assert(daysFromCivil(civilFromDays(d)) == d);
}

/++
The text of a `date`: `2026-11-06`, `0044-03-15 BC`, `infinity`.
+/
string formatDate(int pgDays) pure
{
    if (pgDays == dateInfinity)
        return "infinity";
    if (pgDays == dateNegativeInfinity)
        return "-infinity";
    const d = civilFromDays(pgDays + postgresEpochDays);
    return datePart(d) ~ (d.year <= 0 ? " BC" : "");
}

/++
The text of a `time` (microseconds since midnight): `12:34:56`, `00:00:00.000001`, `24:00:00`.
+/
string formatTime(long microseconds) pure
{
    import std.format : format;

    const seconds = microseconds / 1_000_000;
    return format("%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) ~ fraction(
            microseconds % 1_000_000);
}

/++
The text of a `timetz`: the time, then the offset (`zoneWest` is in seconds
west of UTC, as on the wire): `12:34:56+05:30`, `12:34:56.5-08`.
+/
string formatTimeTz(long microseconds, int zoneWest) pure
{
    return formatTime(microseconds) ~ formatOffset(-cast(long) zoneWest);
}

/++
The text of a `timestamp`: `2026-11-06 12:34:56.789`, `0001-01-01 00:00:00 BC`, `infinity`.
+/
string formatTimestamp(long microseconds) pure
{
    if (microseconds == timestampInfinity)
        return "infinity";
    if (microseconds == timestampNegativeInfinity)
        return "-infinity";
    long days = microseconds / microsecondsPerDay;
    long time = microseconds % microsecondsPerDay;
    if (time < 0)
    {
        days--;
        time += microsecondsPerDay;
    }
    const d = civilFromDays(days + postgresEpochDays);
    return datePart(d) ~ " " ~ formatTime(time) ~ (d.year <= 0 ? " BC" : "");
}

/++
The text of a `timestamptz` in the time zone `zoneName` (the session's
`TimeZone`): `2026-11-06 18:19:56.5+05:45`. Historical offsets keep their
seconds (`+05:41:16`). Points in time outside the years 1 to 9999 use the
zone's offset at the nearest end of that range.
+/
string formatTimestampTz(long microseconds, string zoneName)
{
    import dbwire.types.timezone : resolveTimeZone;

    if (microseconds == timestampInfinity || microseconds == timestampNegativeInfinity)
        return formatTimestamp(microseconds);
    const offset = offsetSeconds(microseconds, resolveTimeZone(zoneName));
    const local = microseconds + offset * 1_000_000;
    const text = formatTimestamp(local);
    // the offset goes before a " BC" suffix
    if (text.length > 3 && text[$ - 3 .. $] == " BC")
        return text[0 .. $ - 3] ~ formatOffset(offset) ~ " BC";
    return text ~ formatOffset(offset);
}

/++
The text of an `interval` (`IntervalStyle=postgres`): `1 year 2 mons 3 days
04:05:06.789`, `-1 years -2 mons +3 days -04:05:06`, `00:00:00`; `infinity`
and `-infinity` (PostgreSQL 17 and later).
+/
string formatInterval(const Interval value) pure
{
    import std.format : format;
    import std.math : abs;

    if (value.months == int.max && value.days == int.max && value.microseconds == long.max)
        return "infinity";
    if (value.months == int.min && value.days == int.min && value.microseconds == long.min)
        return "-infinity";
    string text;
    bool zero = true; // nothing printed yet
    bool previousNegative; // the last part printed was negative
    void part(long amount, string unit)
    {
        if (amount == 0)
            return;
        text ~= format("%s%s%d %s%s", zero ? "" : " ", previousNegative && amount > 0 ? "+" : "", amount, unit,
                amount != 1 ? "s" : "");
        previousNegative = amount < 0;
        zero = false;
    }

    part(value.months / 12, "year");
    part(value.months % 12, "mon");
    part(value.days, "day");
    if (zero || value.microseconds != 0)
    {
        const negative = value.microseconds < 0;
        // long.min has no positive counterpart; it is -infinity's, handled above with the other fields
        const us = negative ? -value.microseconds : value.microseconds;
        const seconds = us / 1_000_000;
        text ~= format("%s%s%02d:%02d:%02d", zero ? "" : " ", negative ? "-" : previousNegative ? "+" : "",
                seconds / 3600, seconds / 60 % 60, seconds % 60) ~ fraction(us % 1_000_000);
    }
    return text;
}

///
unittest
{
    assert(formatDate(0) == "2000-01-01" && formatDate(9806) == "2026-11-06" && formatDate(int.max) == "infinity");
    assert(formatDate(-730_119) == "0001-01-01" && formatDate(-746_117) == "0044-03-15 BC");
    assert(formatDate(-2_451_507) == "4713-01-01 BC" && formatDate(2_145_031_948) == "5874897-12-31");
    assert(formatTime(45_296_000_000) == "12:34:56" && formatTime(1) == "00:00:00.000001");
    assert(formatTime(microsecondsPerDay) == "24:00:00" && formatTime(45_296_500_000) == "12:34:56.5");
    assert(formatTimeTz(45_296_000_000, -19_800) == "12:34:56+05:30" && formatTimeTz(45_296_500_000, 28_800)
            == "12:34:56.5-08");
    assert(formatTimeTz(0, 0) == "00:00:00+00" && formatTimeTz(86_399_999_999, -53_999) == "23:59:59.999999+14:59:59");
    assert(formatTimestamp(0) == "2000-01-01 00:00:00" && formatTimestamp(-1) == "1999-12-31 23:59:59.999999");
    assert(formatTimestamp(-63_113_904_000_000_000) == "0001-01-01 00:00:00 BC");
    assert(formatTimestamp(long.min) == "-infinity");
    assert(formatTimestampTz(0, "UTC") == "2000-01-01 00:00:00+00");

    assert(Interval(0, 0, 0).toString() == "00:00:00" && Interval(0, 0, 1_500_000).toString() == "00:00:01.5");
    assert(Interval(0, 0, -1_000_000).toString() == "-00:00:01" && Interval(0, -1, 0).toString() == "-1 days");
    assert(Interval(14, 3, 14_706_789_000).toString() == "1 year 2 mons 3 days 04:05:06.789");
    assert(Interval(-14, 3, -14_706_000_000).toString() == "-1 years -2 mons +3 days -04:05:06");
    assert(Interval(0, 1, -1_000_000).toString() == "1 day -00:00:01" && Interval(1, -1, 0)
            .toString() == "1 mon -1 days");
    assert(Interval(0, 0, 360_000_000_000).toString() == "100:00:00" && Interval(24, 0, 0).toString() == "2 years");
    assert(Interval(0, 0, -1).toString() == "-00:00:00.000001");
    assert(Interval(int.max, int.max, long.max).toString() == "infinity");
}

/++
A `date` as a D `Date`.

Throws: `ClientException` for `infinity`/`-infinity` or a year outside D's range (-32768 to 32767).
+/
Date dateFromPostgres(int pgDays)
{
    if (pgDays == dateInfinity || pgDays == dateNegativeInfinity)
        throw new ClientException("The date is " ~ formatDate(pgDays) ~ ": not a Date");
    const d = civilFromDays(pgDays + postgresEpochDays);
    if (d.year < short.min || d.year > short.max)
        throw new ClientException("The date " ~ formatDate(pgDays) ~ " is out of Date's range");
    return Date(cast(int) d.year, d.month, d.day);
}

/// A D `Date` as a `date` value (days since 2000-01-01).
int dateToPostgres(Date date) pure nothrow
{
    return cast(int)(daysFromCivil(CivilDate(date.year, date.month, date.day)) - postgresEpochDays);
}

/++
A `timestamptz` (or a `timestamp` read as UTC) as a `SysTime` in UTC, keeping its microseconds.

Throws: `ClientException` for `infinity`/`-infinity` or a year outside 1 to 9999.
+/
SysTime sysTimeFromPostgres(long microseconds)
{
    import std.datetime.timezone : UTC;

    if (microseconds == timestampInfinity || microseconds == timestampNegativeInfinity)
        throw new ClientException("The timestamp is " ~ formatTimestamp(microseconds) ~ ": not a SysTime");
    if (microseconds < minSysTimeMicros || microseconds > maxSysTimeMicros)
        throw new ClientException("The timestamp " ~ formatTimestamp(microseconds) ~ " is outside the years 1 to 9999");
    return SysTime(postgresEpochStdTime + microseconds * 10, UTC());
}

/// A `SysTime` as microseconds since 2000-01-01 UTC (sub-microsecond parts are truncated).
long sysTimeToPostgres(SysTime time) pure nothrow
{
    const hnsecs = time.stdTime - postgresEpochStdTime;
    return hnsecs >= 0 ? hnsecs / 10 : -((-hnsecs + 9) / 10);
}

/++
A `timestamp` as a `DateTime` (the fraction of the second dropped; see
`microsecondsOfSecond`).

Throws: `ClientException` for `infinity`/`-infinity` or a year outside D's range.
+/
DateTime dateTimeFromPostgres(long microseconds)
{
    if (microseconds == timestampInfinity || microseconds == timestampNegativeInfinity)
        throw new ClientException("The timestamp is " ~ formatTimestamp(microseconds) ~ ": not a DateTime");
    long days = microseconds / microsecondsPerDay;
    long time = microseconds % microsecondsPerDay;
    if (time < 0)
    {
        days--;
        time += microsecondsPerDay;
    }
    const d = civilFromDays(days + postgresEpochDays);
    if (d.year < short.min || d.year > short.max)
        throw new ClientException("The timestamp " ~ formatTimestamp(microseconds) ~ " is out of DateTime's range");
    const seconds = time / 1_000_000;
    return DateTime(cast(int) d.year, d.month, d.day, cast(int)(seconds / 3600), cast(int)(seconds / 60 % 60),
            cast(int)(seconds % 60));
}

/// The microseconds within the second of a `timestamp`/`timestamptz`/`time` value (0 to 999999).
int microsecondsOfSecond(long microseconds) pure nothrow
{
    const r = microseconds % 1_000_000;
    return cast(int)(r < 0 ? r + 1_000_000 : r);
}

/// A `DateTime` (plus microseconds) as a `timestamp` value.
long dateTimeToPostgres(DateTime value, int microseconds = 0) pure nothrow
{
    const days = daysFromCivil(CivilDate(value.year, value.month, value.day)) - postgresEpochDays;
    const seconds = (value.hour * 60L + value.minute) * 60 + value.second;
    return days * microsecondsPerDay + seconds * 1_000_000 + microseconds;
}

/++
A `time` as a `TimeOfDay` (the fraction of the second dropped).

Throws: `ClientException` for 24:00:00, which `TimeOfDay` can't hold.
+/
TimeOfDay timeOfDayFromPostgres(long microseconds)
{
    if (microseconds < 0 || microseconds >= microsecondsPerDay)
        throw new ClientException("The time " ~ formatTime(microseconds) ~ " is out of TimeOfDay's range");
    const seconds = microseconds / 1_000_000;
    return TimeOfDay(cast(int)(seconds / 3600), cast(int)(seconds / 60 % 60), cast(int)(seconds % 60));
}

unittest
{
    import core.time : usecs;
    import std.exception : assertThrown;

    assert(dateFromPostgres(9806) == Date(2026, 11, 6) && dateToPostgres(Date(2026, 11, 6)) == 9806);
    assert(dateFromPostgres(-730_120) == Date(0, 12, 31) && dateToPostgres(Date(-43, 3, 15)) == -746_117);
    assertThrown!ClientException(dateFromPostgres(int.max));
    assertThrown!ClientException(dateFromPostgres(2_145_031_948));

    const t = sysTimeFromPostgres(847_283_696_789_001);
    assert(t.toISOExtString() == "2026-11-06T12:34:56.789001Z" && sysTimeToPostgres(t) == 847_283_696_789_001);
    assert(sysTimeToPostgres(sysTimeFromPostgres(-1)) == -1);
    assert(sysTimeToPostgres(sysTimeFromPostgres(0) - 1.usecs / 2) == -1); // truncated toward the past
    assertThrown!ClientException(sysTimeFromPostgres(long.max));
    assert(dateTimeFromPostgres(847_283_696_789_001) == DateTime(2026, 11, 6, 12, 34, 56));
    assert(microsecondsOfSecond(847_283_696_789_001) == 789_001 && microsecondsOfSecond(-1) == 999_999);
    assert(dateTimeToPostgres(DateTime(2026, 11, 6, 12, 34, 56), 789_001) == 847_283_696_789_001);
    assert(dateTimeFromPostgres(-1) == DateTime(1999, 12, 31, 23, 59, 59));
    assert(timeOfDayFromPostgres(45_296_000_001) == TimeOfDay(12, 34, 56));
    assertThrown!ClientException(timeOfDayFromPostgres(microsecondsPerDay));
}

/++
Parses the text of a `date` (`2026-11-06`, `0044-03-15 BC`, `infinity`) into
days since 2000-01-01.

Throws: `ClientException` if the text is not in that form.
+/
int parseDate(const(char)[] text)
{
    if (text == "infinity")
        return dateInfinity;
    if (text == "-infinity")
        return dateNegativeInfinity;
    size_t pos;
    const d = readDate(text, pos);
    const bc = readBc(text, pos);
    if (pos != text.length)
        throw invalid("date", text);
    return cast(int)(daysFromCivil(bc ? CivilDate(1 - d.year, d.month, d.day) : d) - postgresEpochDays);
}

/++
Parses the text of a `time` (`12:34:56`, `12:34:56.5`) into microseconds since midnight.

Throws: `ClientException` if the text is not in that form.
+/
long parseTime(const(char)[] text)
{
    size_t pos;
    const t = readTime(text, pos);
    if (pos != text.length)
        throw invalid("time", text);
    return t;
}

/++
Parses the text of a `timestamp` (`2026-11-06 12:34:56.789`, `... BC`,
`infinity`) into microseconds since 2000-01-01, or of a `timestamptz`
(`2026-11-06 18:19:56.5+05:45`) into microseconds since 2000-01-01 UTC.

Throws: `ClientException` if the text is not in that form.
+/
long parseTimestamp(const(char)[] text)
{
    if (text == "infinity")
        return timestampInfinity;
    if (text == "-infinity")
        return timestampNegativeInfinity;
    size_t pos;
    const d = readDate(text, pos);
    if (pos >= text.length || (text[pos] != ' ' && text[pos] != 'T'))
        throw invalid("timestamp", text);
    pos++;
    const time = readTime(text, pos);
    long offset;
    if (pos < text.length && (text[pos] == '+' || text[pos] == '-'))
        offset = readOffset(text, pos);
    const bc = readBc(text, pos);
    if (pos != text.length)
        throw invalid("timestamp", text);
    const days = daysFromCivil(bc ? CivilDate(1 - d.year, d.month, d.day) : d) - postgresEpochDays;
    return days * microsecondsPerDay + time - offset * 1_000_000;
}

unittest
{
    import std.exception : assertThrown;

    assert(parseDate("2026-11-06") == 9806 && parseDate("0044-03-15 BC") == -746_117 && parseDate("infinity") == int
            .max);
    assert(parseTime("12:34:56.5") == 45_296_500_000 && parseTime("24:00:00") == microsecondsPerDay);
    assert(parseTimestamp("2026-11-06 12:34:56.789001") == 847_283_696_789_001);
    assert(parseTimestamp("2026-11-06 18:19:56.789001+05:45") == 847_283_696_789_001);
    assert(parseTimestamp("1999-12-31 23:59:59.999999") == -1 && parseTimestamp("-infinity") == long.min);
    assert(parseTimestamp("0001-01-01 00:00:00 BC") == -63_113_904_000_000_000);
    assert(parseTimestamp("1900-01-01 05:41:16+05:41:16") == parseTimestamp("1900-01-01 00:00:00"));
    foreach (bad; [
        "", "2026-11", "2026-13-01", "2026-11-06x", "12:34", "2026-11-06 12:34:56+5:30:1:1"
    ])
    {
        assertThrown!ClientException(parseDate(bad));
        assertThrown!ClientException(parseTimestamp(bad));
    }
    assertThrown!ClientException(parseTime("1:2:3"));
}

private:

// std time (hnsecs since 0001-01-01 UTC) of 2000-01-01 and the microseconds range of SysTime years 1..9999
enum long postgresEpochStdTime = 630_822_816_000_000_000L;
enum long minSysTimeMicros = -postgresEpochStdTime / 10;
enum long maxSysTimeMicros = (3_155_378_975_999_999_999L - postgresEpochStdTime) / 10;

string datePart(CivilDate d) pure
{
    import std.format : format;

    const year = d.year <= 0 ? 1 - d.year : d.year;
    return format("%04d-%02d-%02d", year, d.month, d.day);
}

// ".ffffff" without trailing zeros; empty for 0
string fraction(long microseconds) pure
{
    import std.format : format;

    if (microseconds == 0)
        return null;
    auto text = format(".%06d", microseconds);
    while (text[$ - 1] == '0')
        text = text[0 .. $ - 1];
    return text;
}

// "+05:30", "-08", "+00", "+05:41:16"
string formatOffset(long seconds) pure
{
    import std.format : format;

    const sign = seconds < 0 ? "-" : "+";
    const s = seconds < 0 ? -seconds : seconds;
    auto text = format("%s%02d", sign, s / 3600);
    if (s % 3600 != 0)
        text ~= format(":%02d", s / 60 % 60);
    if (s % 60 != 0)
        text ~= format(":%02d", s % 60);
    return text;
}

// The zone's UTC offset in seconds at a point in time (microseconds since 2000-01-01 UTC).
long offsetSeconds(long microseconds, immutable(std.datetime.timezone.TimeZone) zone)
{
    const clamped = microseconds < minSysTimeMicros ? minSysTimeMicros : microseconds > maxSysTimeMicros
        ? maxSysTimeMicros : microseconds;
    return zone.utcOffsetAt(postgresEpochStdTime + clamped * 10).total!"seconds";
}

ClientException invalid(string type, const(char)[] text) pure
{
    return new ClientException("Invalid " ~ type ~ " text '" ~ text.idup ~ "'");
}

// digits at text[pos ..], at least `min` and at most `max` of them
long readNumber(const(char)[] text, ref size_t pos, size_t min, size_t max) pure
{
    long v;
    size_t n;
    while (pos < text.length && n < max && text[pos] >= '0' && text[pos] <= '9')
    {
        v = v * 10 + (text[pos++] - '0');
        n++;
    }
    if (n < min)
        throw invalid("date/time", text);
    return v;
}

void expect(const(char)[] text, ref size_t pos, char c) pure
{
    if (pos >= text.length || text[pos] != c)
        throw invalid("date/time", text);
    pos++;
}

CivilDate readDate(const(char)[] text, ref size_t pos) pure
{
    CivilDate d;
    d.year = readNumber(text, pos, 4, 9);
    expect(text, pos, '-');
    d.month = cast(int) readNumber(text, pos, 2, 2);
    expect(text, pos, '-');
    d.day = cast(int) readNumber(text, pos, 2, 2);
    if (d.month < 1 || d.month > 12 || d.day < 1 || d.day > 31)
        throw invalid("date", text);
    return d;
}

long readTime(const(char)[] text, ref size_t pos) pure
{
    const h = readNumber(text, pos, 2, 2);
    expect(text, pos, ':');
    const m = readNumber(text, pos, 2, 2);
    expect(text, pos, ':');
    const s = readNumber(text, pos, 2, 2);
    long us;
    if (pos < text.length && text[pos] == '.')
    {
        pos++;
        const start = pos;
        us = readNumber(text, pos, 1, 6);
        foreach (i; pos - start .. 6)
            us *= 10;
        while (pos < text.length && text[pos] >= '0' && text[pos] <= '9')
            pos++; // beyond microseconds
    }
    if (h > 24 || m > 59 || s > 60)
        throw invalid("time", text);
    return ((h * 60 + m) * 60 + s) * 1_000_000 + us;
}

// [+-]HH[:MM[:SS]] in seconds east of UTC
long readOffset(const(char)[] text, ref size_t pos) pure
{
    const negative = text[pos++] == '-';
    long seconds = readNumber(text, pos, 2, 2) * 3600;
    if (pos < text.length && text[pos] == ':')
    {
        pos++;
        seconds += readNumber(text, pos, 2, 2) * 60;
        if (pos < text.length && text[pos] == ':')
        {
            pos++;
            seconds += readNumber(text, pos, 2, 2);
        }
    }
    return negative ? -seconds : seconds;
}

bool readBc(const(char)[] text, ref size_t pos) pure nothrow
{
    if (text.length - pos == 3 && text[pos .. $] == " BC")
    {
        pos = text.length;
        return true;
    }
    return false;
}

import std.datetime.timezone;
