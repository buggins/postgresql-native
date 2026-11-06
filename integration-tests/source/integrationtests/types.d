/++
Data types: binary values decoded by the client against the server's own
text (`v::text`), and the typed getters.
+/
module integrationtests.types;

import std.conv : to;
import std.exception : assertThrown, enforce;
import std.format : format;

import postgresql;
import integrationtests.server;

/// The first row of `sql`; the result is closed.
Row firstRow(Connection conn, string sql)
{
    auto r = conn.query(sql);
    scope (exit)
        r.close();
    enforce(!r.empty, "no row");
    return r.front;
}

/++
Runs `SELECT v, v::text FROM (<values>) t(v)`: the decoded binary value's
`getString` must equal the server's text, row by row. Returns the row count.
+/
size_t compareText(Connection conn, string values, string what)
{
    auto r = conn.query("SELECT v, v::text FROM (" ~ values ~ ") t(v)");
    size_t rows;
    foreach (row; r)
    {
        rows++;
        enforce(row.columns[0].format == ValueFormat.binary, what ~ ": not decoded from binary");
        const mine = row.getString(0);
        const server = row.getString(1);
        enforce(mine == server, format("%s: client '%s', server '%s'", what, mine, server));
    }
    return rows;
}

/// Integers, booleans, oid, text types, bytea, "char", uuid, json, jsonb.
void testScalarTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    compareText(conn, "VALUES ('-32768'::int2), (0::int2), (32767::int2)", "int2");
    compareText(conn, "VALUES ('-2147483648'::int4), (42), (2147483647)", "int4");
    compareText(conn, "VALUES ('-9223372036854775808'::int8), (0::int8), (9223372036854775807::int8)", "int8");
    compareText(conn, "VALUES (0::oid), (4294967295::oid)", "oid");
    // bool::text is 'true'/'false', but a bool column's text is 't'/'f': compare with the simple protocol
    auto simpleBools = conn.querySimple("SELECT true, false");
    enforce(simpleBools.front.getString(0) == "t" && simpleBools.front.getString(1) == "f", "bool text");
    simpleBools.close();
    auto bools = firstRow(conn, "SELECT true, false");
    enforce(bools.getString(0) == "t" && bools.getString(1) == "f", "bool decoded");
    compareText(conn, "VALUES (''::text), ('Grüße, мир, 世界 🎉'::text), (E'tab\\there')", "text");
    compareText(conn, "VALUES ('x'::varchar(10)), ('ab'::char(5)), ('nm'::name)", "varchar/char/name");
    compareText(conn, "VALUES (''::bytea), ('\\x00ff10'::bytea), (decode(repeat('ab', 1000), 'hex'))", "bytea");
    compareText(conn, "VALUES ('a'::\"char\"), (E'\\\\351'::\"char\"), (''::\"char\")", "\"char\"");
    compareText(conn, "VALUES ('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid), (gen_random_uuid())", "uuid");
    compareText(conn, "VALUES ('{\"b\": [1, 2.5, null], \"a\":\"x\"}'::json), ('[]'::json)", "json");
    compareText(conn, "VALUES ('{\"b\": [1, 2.5, null], \"a\":\"x\"}'::jsonb), ('\"text\"'::jsonb), ('{}'::jsonb)",
            "jsonb");

    auto row = firstRow(conn, "SELECT 7::int2, -8::int4, 9000000000::int8, 4000000000::oid, true, 'héllo'::text, "
            ~ "'\\x0102'::bytea, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, NULL::int4");
    enforce(row.getLong(0) == 7 && row.getInt(1) == -8 && row.getLong(2) == 9_000_000_000L
            && row.getLong(3) == 4_000_000_000L, "integers");
    assertThrown!ClientException(row.getInt(2)); // out of int's range
    enforce(row.getBool(4) && row.getLong(4) == 1 && row.getString(5) == "héllo", "bool and text");
    enforce(row.getBytes(6) == [1, 2] && row.getUUID(7)
            .toString() == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11",
            "bytea and uuid");
    enforce(row.getBytes(7).length == 16 && row.isNull(8) && row.getString(8) is null, "uuid bytes and NULL");
    assertThrown!ClientException(row.getLong(8));
    assertThrown!ClientException(row.getDate(0));
}

/// float4 and float8: shortest exact text, special values, many random magnitudes.
void testFloats()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    compareText(conn, "VALUES ('NaN'::float8), ('Infinity'), ('-Infinity'), ('-0'), (0), (1e15), (1e14), "
            ~ "(0.0001), (0.00001), (1.7976931348623157e308), (5e-324), (2.2250738585072014e-308), (0.1), (-1.25)",
            "float8 specials");
    compareText(conn, "VALUES ('NaN'::float4), ('Infinity'), ('-0'), (1e6), (1e5), (3.4028235e38), (1e-45), "
            ~ "(1.1), (16777217)", "float4 specials");
    const n8 = compareText(conn, "SELECT (random() - 0.5) * power(10::float8, floor(random() * 600) - 300) "
            ~ "FROM generate_series(1, 20000)", "float8 random");
    const n4 = compareText(conn, "SELECT ((random() - 0.5) * power(10::float8, floor(random() * 70) - 35))::float4 "
            ~ "FROM generate_series(1, 20000)", "float4 random");
    enforce(n8 == 20_000 && n4 == 20_000, "rows");

    auto row = firstRow(conn, "SELECT 1.5::float8, -2.5::float4, 'NaN'::float8, 3::int4");
    enforce(row.getDouble(0) == 1.5 && row.getDouble(1) == -2.5 && row.getDouble(2) != row.getDouble(2)
            && row.getDouble(3) == 3, "getDouble");
    assertThrown!ClientException(row.getLong(0));
}

/// numeric: exact text and Decimal, scale kept, NaN, infinities (14+), many digits.
void testNumeric()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    const infinities = conn.serverVersionNumber >= 140_000 ? ", ('Infinity'), ('-Infinity')" : "";
    compareText(conn, "VALUES (0::numeric), (0.00), (-1.50), (123456789.123456789), (1e-20), (1e30), ('NaN'), "
            ~ "(-0.0001), (99999999999999999999999999999999999999.9999), (1234.5678e100), (0.1e-100)" ~ infinities,
            "numeric");
    compareText(conn, "SELECT round((random() - 0.5)::numeric * 10::numeric ^ (floor(random() * 60) - 30)::int, "
            ~ "(floor(random() * 40))::int) FROM generate_series(1, 5000)", "numeric random");

    auto row = firstRow(conn, "SELECT 1.50::numeric(10, 2), 123::numeric, 'NaN'::numeric, 2.5::numeric, "
            ~ "1e100::numeric");
    enforce(row.getDecimal(0).toFixedString() == "1.50" && row.getDecimal(1).toString() == "123", "Decimal");
    enforce(row.getLong(1) == 123 && row.getDouble(3) == 2.5, "long and double");
    assertThrown!ClientException(row.getLong(3)); // not an integer
    assertThrown!ClientException(row.getDecimal(2)); // NaN
    assertThrown!ClientException(row.getDecimal(4)); // 101 digits
    enforce(row.getString(4) == "1" ~ "0".repeat(100), "long numeric as text");
}

private string repeat(string s, size_t n)
{
    string r;
    foreach (i; 0 .. n)
        r ~= s;
    return r;
}

/// Dates, times, timestamps (several time zones), intervals; the typed getters.
void testDateTimes()
{
    import core.time : hours, minutes, seconds, usecs;
    import std.datetime : Date, DateTime, SysTime, TimeOfDay, UTC;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    compareText(conn, "VALUES ('2026-11-06'::date), ('0001-01-01'), ('0044-03-15 BC'), ('4713-01-01 BC'), "
            ~ "('5874897-12-31'), ('10000-01-01'), ('infinity'), ('-infinity'), ('2000-02-29')", "date");
    compareText(conn, "SELECT '2000-01-01'::date + (random() * 4000000 - 2000000)::int FROM generate_series(1, 2000)",
            "date random");
    compareText(conn, "VALUES ('12:34:56'::time), ('00:00:00.000001'), ('24:00:00'), ('23:59:59.999999')", "time");
    compareText(conn, "VALUES ('12:34:56+05:30'::timetz), ('12:34:56.5-08'), ('00:00:00+00'), "
            ~ "('23:59:59.999999+14:59:59'), ('01:02:03-15:59')", "timetz");
    compareText(conn, "VALUES ('2026-11-06 12:34:56.789'::timestamp), ('2026-11-06 00:00:00'), "
            ~ "('0001-01-01 00:00:00 BC'), ('294276-12-31 23:59:59.999999'), ('4713-01-01 00:00:00 BC'), "
            ~ "('infinity'), ('-infinity')", "timestamp");
    compareText(conn, "SELECT '2000-01-01'::timestamp + random() * interval '200000 days' - interval '100000 days' "
            ~ "FROM generate_series(1, 2000)", "timestamp random");
    // Phobos's zones give times before a zone's first transition the offset after it instead of the
    // local mean time (Asia/Kathmandu before 1920), and ignore the rule for times after the last
    // transition in the file (DST after 2037; buggins/dbwire#33): the values here are between those
    foreach (zone; [
        "UTC", "Asia/Kathmandu", "America/St_Johns", "Europe/Lisbon", "Australia/Lord_Howe"
    ])
    {
        conn.exec("SET TimeZone = '" ~ zone ~ "'");
        compareText(conn, "VALUES ('2026-11-06 12:34:56.5+00'::timestamptz), ('1930-01-01 00:00:00+00'), "
                ~ "('2026-07-01 00:00:00+00'), ('1985-01-01 00:00:00+00'), ('2038-01-19 03:14:08+00'), "
                ~ "('infinity'), ('-infinity')", "timestamptz " ~ zone);
        compareText(conn, "SELECT '1970-01-01'::timestamptz + random() * interval '24000 days' "
                ~ "FROM generate_series(1, 1000)", "timestamptz random " ~ zone);
    }
    conn.exec("SET TimeZone = 'UTC'");
    const infinityIntervals = conn.serverVersionNumber >= 170_000 ? ", ('infinity'), ('-infinity')" : "";
    compareText(conn, "VALUES ('0'::interval), ('1 second'), ('-1 second'), ('1.5 seconds'), ('1 day'), ('-1 day'), "
            ~ "('1 mon'), ('14 mons'), ('1 year 2 mons 3 days 04:05:06.789'), ('-1 year -2 mons +3 days -04:05:06'), "
            ~ "('1 day -1 second'), ('100:00:00'), ('-0.000001 s'), ('2 years'), ('25 hours'), ('1 mon -1 day'), "
            ~ "('-178000000 years'), ('9999999:59:59.999999')" ~ infinityIntervals, "interval");

    auto row = firstRow(conn, "SELECT '2026-11-06'::date, '12:34:56.25'::time, "
            ~ "'2026-11-06 12:34:56.789001'::timestamp, "
            ~ "'2026-11-06 12:34:56.789001+02'::timestamptz, '1 day 02:00:00'::interval, '1 mon'::interval, "
            ~ "'12:34:56.5+05:30'::timetz, 'infinity'::date");
    enforce(row.getDate(0) == Date(2026, 11, 6) && row.getSysTime(0) == SysTime(DateTime(2026, 11, 6), UTC()), "date");
    enforce(row.getTimeOfDay(1) == TimeOfDay(12, 34, 56) && row.getMicrosecondsOfSecond(1) == 250_000
            && row.getDuration(1) == 12.hours + 34.minutes + 56.seconds + 250_000.usecs, "time");
    enforce(row.getDateTime(2) == DateTime(2026, 11, 6, 12, 34, 56) && row.getMicrosecondsOfSecond(2) == 789_001
            && row.getDate(2) == Date(2026, 11, 6), "timestamp");
    enforce(row.getSysTime(3).toISOExtString() == "2026-11-06T10:34:56.789001Z", "timestamptz");
    enforce(row.getDuration(4) == 26.hours && row.getInterval(5) == Interval(1, 0, 0), "interval");
    assertThrown!ClientException(row.getDuration(5)); // months
    enforce(row.getTimeOfDay(6) == TimeOfDay(12, 34, 56) && row.getMicrosecondsOfSecond(6) == 500_000, "timetz");
    assertThrown!ClientException(row.getDate(7)); // infinity
    enforce(row.getString(7) == "infinity", "infinity text");
}

/// Types without a binary decoder come as text; getVariant gives natural D types; querySimple values.
void testTextFallbackAndVariants()
{
    import std.datetime : Date, SysTime, TimeOfDay;
    import std.uuid : UUID;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto row = firstRow(conn, "SELECT '192.168.0.1/24'::inet, ARRAY[1, 2], '(1,2)'::point, 'abc'::xml");
    enforce(row.columns[0].format == ValueFormat.text && row.getString(0) == "192.168.0.1/24", "inet as text");
    enforce(row.getString(1) == "{1,2}" && row.getString(2) == "(1,2)" && row.getString(3) == "abc", "text fallback");

    row = firstRow(conn, "SELECT 1::int2, 2::int4, 3::int8, 1.5::float4, 2.5::float8, 1.25::numeric, 'x'::text, "
            ~ "'\\x01'::bytea, '2026-11-06'::date, '01:02:03'::time, now(), gen_random_uuid(), true, NULL::int4, "
            ~ "'NaN'::numeric, 'infinity'::date");
    enforce(row.getVariant(0).type == typeid(short) && row.getVariant(1).type == typeid(int)
            && row.getVariant(2).type == typeid(long), "integer variants");
    enforce(row.getVariant(3).type == typeid(float) && row.getVariant(4).type == typeid(double)
            && row.getVariant(5).type == typeid(Decimal), "number variants");
    enforce(row.getVariant(6).type == typeid(string) && row.getVariant(7)
            .type == typeid(immutable(ubyte)[])
            && row.getVariant(8).type == typeid(Date) && row.getVariant(9).type == typeid(TimeOfDay), "other variants");
    enforce(row.getVariant(10).type == typeid(SysTime) && row.getVariant(11).type == typeid(UUID)
            && row.getVariant(12).type == typeid(bool) && !row.getVariant(13).hasValue, "more variants");
    enforce(row.getVariant(14).type == typeid(string) && row.getVariant(15).type == typeid(string), "NaN, infinity");

    // the same values through the simple protocol (text): the getters parse them
    auto simple = conn.querySimple("SELECT 42::int8, 1.50::numeric, '2026-11-06 12:34:56.5+02'::timestamptz, "
            ~ "'2026-11-06'::date, '\\x0a0b'::bytea, true, 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, 2.5::float8");
    const s = simple.front;
    enforce(s.columns[0].format == ValueFormat.text && s.getLong(0) == 42 && s.getDecimal(1)
            .toFixedString() == "1.50",
            "text numbers");
    enforce(s.getSysTime(2).toISOExtString() == "2026-11-06T10:34:56.5Z" && s.getDate(3) == Date(2026, 11, 6),
            "text dates");
    enforce(s.getBytes(4) == [10, 11] && s.getBool(5) && s.getUUID(6)
            .toString()[0 .. 8] == "a0eebc99"
            && s.getDouble(7) == 2.5, "text bytea, bool, uuid, float");
    simple.close();
}
