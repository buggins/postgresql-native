/++
More types: arrays, ranges and multiranges, composite types, enums and
domains, network and bit-string types, geometric types, extension types
(hstore, citext) and the types read as text.
+/
module integrationtests.moretypes;

import std.datetime.date : Date, DateTime;
import std.exception : assertThrown, collectException, enforce;
import std.format : format;
import std.typecons : Nullable, tuple;

import postgresql;
import integrationtests.server;
import integrationtests.types : firstRow;

/++
Runs `SELECT v FROM (<values>) t(v)` twice: with the extended protocol (the
values decoded from binary) and the simple protocol (the server's own output
text). The client's `getString` must equal the server's text, row by row.
+/
size_t compareOutput(Connection conn, string values, string what)
{
    const sql = "SELECT v FROM (" ~ values ~ ") t(v)";
    string[] server;
    auto simple = conn.querySimple(sql);
    foreach (row; simple)
        server ~= row.getString(0);
    size_t i;
    foreach (row; conn.query(sql))
    {
        enforce(row.columns[0].format == ValueFormat.binary, what ~ ": not decoded from binary");
        enforce(i < server.length, what ~ ": more rows");
        const mine = row.getString(0);
        enforce(mine == server[i], format("%s: client '%s', server '%s'", what, mine, server[i]));
        i++;
    }
    enforce(i == server.length, what ~ ": fewer rows");
    return i;
}

/// Arrays: text of every shape, typed reads, parameters, text format.
void testArrays()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("SET TimeZone = 'Asia/Kolkata'");
    compareOutput(conn, "VALUES (ARRAY[1,2,3]), ('{}'::int[]), (ARRAY[NULL::int]), ('[0:2]={1,2,3}'::int[]),"
            ~ " (ARRAY[[1,2],[3,4],[5,6]]), ('{{{1},{2}},{{3},{4}}}'::int[]), ('[-2:-1][3:4]={{1,2},{3,4}}'::int[])",
            "int4[]");
    compareOutput(conn, `VALUES (ARRAY['a b', NULL, '', 'NULL', 'null', 'x"y', 'b\c', '{}', ',', 'plain',`
            ~ ` E'tab\there'])`,
            "text[]");
    compareOutput(conn, "VALUES (ARRAY[1.5::float8, 'nan', '-infinity', 0.1]), (ARRAY[-0::float8])", "float8[]");
    compareOutput(conn, "VALUES (ARRAY[1.50::numeric, 'NaN', -0.001, 12345678901234567890123]),"
            ~ " (ARRAY[NULL::numeric])", "numeric[]");
    compareOutput(conn, "VALUES (ARRAY['\\x00ff'::bytea, '']), (ARRAY[NULL::bytea])", "bytea[]");
    compareOutput(conn, "VALUES (ARRAY[true, NULL, false])", "bool[]");
    compareOutput(conn, "VALUES (ARRAY['2026-11-06'::date, 'infinity', '0044-03-15 BC'])", "date[]");
    compareOutput(conn, "VALUES (ARRAY['2026-11-06 12:34:56.789+00'::timestamptz, '1999-12-31 23:59:59+05:45']),"
            ~ " (ARRAY['-infinity'::timestamptz])", "timestamptz[]");
    compareOutput(conn, "VALUES (ARRAY['1 year 2 mons'::interval, '-3 days 04:05:06'])", "interval[]");
    compareOutput(conn, "VALUES (ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid])", "uuid[]");
    compareOutput(conn, `VALUES (ARRAY['{"a": [1, "x y"]}'::jsonb, 'null']), (ARRAY['{"b":1}'::json]::text[]::jsonb[])`,
            "jsonb[]");
    compareOutput(conn, "VALUES (ARRAY[box '(1,1),(0,0)', box '(3,3),(2,2)'])", "box[] (; delimiter)");
    compareOutput(conn, "VALUES (ARRAY['a'::\"char\", 'b'])", "\"char\"[]");
    compareOutput(conn, "VALUES (ARRAY['x'::varchar, 'y z'])", "varchar[]");
    compareOutput(conn, "VALUES (ARRAY['nm'::name])", "name[]");
    compareOutput(conn, "VALUES (ARRAY[int4range(1, 3), 'empty'])", "int4range[]");
    compareOutput(conn, "VALUES (ARRAY[numrange(1.5, NULL)])", "numrange[]");

    // quoting: strings of every printable ASCII character, spaces, quotes, braces, backslashes
    enum generated = "SELECT string_agg(chr(32 + (i * j * 7 + j) % 95), '') AS s FROM generate_series(1, 300) i,"
        ~ " generate_series(1, 9) j GROUP BY i";
    compareOutput(conn, "SELECT ARRAY[s, ' ' || s, s || E'\\t', upper(s), 'null', ''] FROM (" ~ generated ~ ") x",
            "text[] quoting");
    conn.exec("DROP TYPE IF EXISTS pg_temp.itest_q");
    conn.exec("CREATE TYPE pg_temp.itest_q AS (a text, b text, c text, d text, e int)");
    compareOutput(conn, "SELECT ROW(s, NULL, '', s || '\"', 1)::pg_temp.itest_q FROM (" ~ generated ~ ") x",
            "record quoting");
    compareOutput(conn, "SELECT ARRAY[ROW(s, s, s, s, 2)::pg_temp.itest_q] FROM (" ~ generated ~ ") x",
            "record[] quoting");
    auto stress = conn.query("SELECT ARRAY[s, ''], s FROM (" ~ generated ~ ") x");
    foreach (r; stress)
        enforce(r.get!(string[])(0) == [r.getString(1), ""], "text[] round trip");
    string[] all;
    foreach (r; conn.query("SELECT s FROM (" ~ generated ~ ") x"))
        all ~= r.getString(0);
    enforce(firstRow(conn, "SELECT ?::text[] = ARRAY(SELECT s FROM (" ~ generated ~ ") x)", all)
            .getBool(0),
            "text[] parameter round trip");

    // typed reads
    auto row = firstRow(conn, "SELECT ARRAY[1, NULL, 3], ARRAY[[1,2],[3,4]], ARRAY['a', NULL]::text[], '{}'::int[],"
            ~ " ARRAY['2026-11-06'::date], '[0:1]={5,6}'::int8[], NULL::int[]");
    enforce(row.get!(Nullable!int[])(0) == [Nullable!int(1), Nullable!int.init, Nullable!int(3)], "Nullable!int[]");
    assertThrown!ClientException(row.get!(int[])(0)); // a NULL element
    enforce(row.get!(int[][])(1) == [[1, 2], [3, 4]], "int[][]");
    assertThrown!ClientException(row.get!(int[])(1)); // two dimensions
    const strings = row.get!(string[])(2);
    enforce(strings.length == 2 && strings[0] == "a" && strings[1] is null, "string[] with NULL");
    enforce(row.get!(int[])(3).length == 0 && row.get!(Date[])(4) == [Date(2026, 11, 6)], "empty, Date[]");
    const a = row.getArray(5);
    enforce(a.lengths == [2] && a.lowerBounds == [0] && a[1].getLong() == 6, "lower bounds");
    enforce(row.get!(long[])(6) is null && row.get!(Nullable!(int[]))(6).isNull, "NULL array");

    // parameters: binary for built-in element types, text otherwise
    enforce(firstRow(conn, "SELECT ?::int[]", [1, 2, 3]).getString(0) == "{1,2,3}", "int[] parameter");
    enforce(firstRow(conn, "SELECT ?::int8[]", [[1L, 2], [3L, 4]]).getString(0) == "{{1,2},{3,4}}", "2-D parameter");
    enforce(firstRow(conn, "SELECT ?::text[]", ["a b", `q"x`, "", "{x}"])
            .getString(0) == `{"a b","q\"x","","{x}"}`,
            "text[] parameter");
    enforce(firstRow(conn, "SELECT ?::int[]", [Nullable!int(1), Nullable!int.init])
            .getString(0) == "{1,NULL}",
            "NULL elements");
    enforce(firstRow(conn, "SELECT ?::numeric[]", [Decimal.fromString("1.50")])
            .getString(0) == "{1.50}",
            "numeric[] (text)");
    enforce(firstRow(conn, "SELECT ?::date[]", [Date(2026, 1, 2)]).getString(0) == "{2026-01-02}", "date[]");
    enforce(firstRow(conn, "SELECT 3 = ANY(?)", [1, 2, 3]).getBool(0), "= ANY(array parameter)");
    enforce(firstRow(conn, "SELECT cardinality(?::int[])", new int[0]).getLong(0) == 0, "empty array parameter");
    assertThrown!ClientException(conn.query("SELECT ?::int[]", [[1, 2], [3]]));
    enforce(firstRow(conn, "SELECT ?::box[]", [Box(Point(1, 1), Point(0, 0))]).getString(0) == "{(1,1),(0,0)}",
            "box[] parameter");

    // text format (simple protocol): parsed
    auto simple = conn.querySimple(`SELECT ARRAY[[1,2],[3,4]], ARRAY['a b', NULL, 'q"x']`);
    enforce(simple.front.get!(int[][])(0) == [[1, 2], [3, 4]], "text array");
    const texts = simple.front.get!(string[])(1);
    enforce(texts.length == 3 && texts[0] == "a b" && texts[1] is null && texts[2] == `q"x`, "text array of text");
    simple.close();
}

/// Ranges and multiranges: text, typed reads, parameters.
void testRanges()
{
    import core.time : hours;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("SET TimeZone = 'Europe/Lisbon'");
    compareOutput(conn, "VALUES (int4range(1, 5)), (int4range(1, 5, '[]')), ('empty'::int4range), (int4range(NULL, 3)),"
            ~ " (int4range(NULL, NULL)), (int4range(-5, NULL))", "int4range");
    compareOutput(conn, "VALUES (int8range(1, 9000000000))", "int8range");
    compareOutput(conn, "VALUES (numrange(1.5, 2.25, '(]')), (numrange(NULL, 0))", "numrange");
    compareOutput(conn, "VALUES (daterange('2020-01-01', '2020-02-01')), (daterange('2020-01-01', 'infinity', '[]'))",
            "daterange");
    compareOutput(conn, "VALUES (tsrange('2020-01-01', '2020-01-02 12:30:00.5')), (tsrange('-infinity', NULL))",
            "tsrange");
    compareOutput(conn, "VALUES (tstzrange('2020-01-01 00:00+00', '2020-07-01 00:00+00'))", "tstzrange");

    auto row = firstRow(conn, "SELECT int4range(1, 10), 'empty'::int4range, int8range(NULL, 5),"
            ~ " tsrange('2020-01-01', '2020-01-02'), numrange(1.5, 2.5, '[]')");
    const r = row.get!(Range!int)(0);
    enforce(r.lower == 1 && r.upper == 10 && r.lowerInclusive && !r.upperInclusive && !r.empty, "Range!int");
    enforce(row.get!(Range!int)(1).empty, "empty range");
    const half = row.get!(Range!long)(2);
    enforce(half.lowerInfinite && !half.upperInfinite && half.upper == 5, "unbounded below");
    enforce(row.get!(Range!DateTime)(3).upper == DateTime(2020, 1, 2), "Range!DateTime");
    const n = row.get!(Range!Decimal)(4);
    enforce(n.lower == Decimal.fromString("1.5") && n.upperInclusive, "Range!Decimal");
    enforce(row.getRange(0).lower.getLong() == 1, "getRange");

    // parameters
    enforce(firstRow(conn, "SELECT ?::int4range", Range!int(3, 7, true, true))
            .getString(0) == "[3,8)",
            "Range!int parameter (canonical)");
    enforce(firstRow(conn, "SELECT ?::tsrange", Range!DateTime(DateTime(2020, 1, 1), DateTime(2020, 1, 1, 12)))
            .getString(0) == `["2020-01-01 00:00:00","2020-01-01 12:00:00")`, "Range!DateTime parameter");
    enforce(firstRow(conn, "SELECT ?::numrange", Range!Decimal.from(Decimal.fromString("2.5")))
            .getString(0)
            == "[2.5,)", "unbounded parameter");
    enforce(firstRow(conn, "SELECT ?::int4range", Range!int.emptyRange()).getString(0) == "empty", "empty parameter");
    enforce(firstRow(conn, "SELECT int4range(1, 10) @> ?::int", 5).getBool(0), "contains");

    if (conn.serverVersionNumber < 140_000)
        return; // multiranges: PostgreSQL 14
    compareOutput(conn, "VALUES ('{[1,3),[5,7)}'::int4multirange), ('{}'::int4multirange)", "int4multirange");
    compareOutput(conn, "VALUES ('{[2020-01-01,2020-02-01)}'::datemultirange)", "datemultirange");
    compareOutput(conn, "VALUES ('{(,5)}'::int8multirange)", "int8multirange");
    compareOutput(conn, "VALUES ('{[\"2020-01-01 00:00:00\",\"2020-01-02 00:00:00\")}'::tsmultirange)", "tsmultirange");
    const multi = firstRow(conn, "SELECT '{[1,3),[5,7)}'::int4multirange").get!(Range!int[])(0);
    enforce(multi.length == 2 && multi[1].lower == 5, "Range!int[] from a multirange");
    enforce(firstRow(conn, "SELECT ?::int4multirange::text", "{[1,3)}").getString(0) == "{[1,3)}", "text parameter");
    compareOutput(conn, "VALUES (ARRAY['{[1,2)}'::int4multirange])", "multirange[]");
}

private enum Mood
{
    sad,
    ok,
    happy,
}

private struct Address
{
    string street;
    int number;
    Nullable!string city;
}

private struct Person
{
    string name;
    Address home;
    int[] scores;
    Mood mood;
}

/// Composite types, records, enums, domains.
void testCompositesEnumsDomains()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("DROP TYPE IF EXISTS pg_temp.itest_person, pg_temp.itest_address, pg_temp.itest_mood CASCADE");
    conn.exec("CREATE TYPE pg_temp.itest_mood AS ENUM ('sad', 'ok', 'happy')");
    conn.exec("CREATE TYPE pg_temp.itest_address AS (street text, number int, city text)");
    conn.exec("CREATE TYPE pg_temp.itest_person AS (name text, home pg_temp.itest_address, scores int[],"
            ~ " mood pg_temp.itest_mood)");
    conn.exec("CREATE DOMAIN pg_temp.itest_posint AS int CHECK (VALUE > 0)");
    conn.exec("CREATE TEMP TABLE itest_people (id int, p pg_temp.itest_person, moods pg_temp.itest_mood[],"
            ~ " d pg_temp.itest_posint, ds pg_temp.itest_posint[])");
    conn.exec("INSERT INTO itest_people VALUES (1, ROW('Ann', ROW('Main St', 5, NULL), '{1,2}', 'happy'),"
            ~ " '{sad,happy}', 7, '{1,2}')");

    // decoded from binary (the types are looked up) and written as the server does
    compareOutput(conn, "SELECT p FROM itest_people", "composite");
    compareOutput(conn, "SELECT moods FROM itest_people", "enum[]");
    compareOutput(conn, "SELECT ds FROM itest_people", "domain[]");
    compareOutput(conn, "VALUES (ROW('a b \"q\"', NULL, '')::pg_temp.itest_address),"
            ~ " (ROW('(x)', 1, 'b\\c')::pg_temp.itest_address)",
            "composite quoting");
    compareOutput(conn, "VALUES (ARRAY[ROW('x', 1, 'y')::pg_temp.itest_address, NULL])", "composite[]");

    auto row = firstRow(conn, "SELECT p, moods, d, ds, ROW(1, 'two') FROM itest_people");
    const person = row.get!Person(0);
    enforce(person.name == "Ann" && person.home.street == "Main St" && person.home.number == 5
            && person.home.city.isNull && person.scores == [1, 2] && person.mood == Mood.happy,
            "struct from composite");
    const record = row.getRecord(0);
    enforce(record.names == ["name", "home", "scores", "mood"] && record["mood"].getString() == "happy", "names");
    enforce(row.get!(Mood[])(1) == [Mood.sad, Mood.happy] && row.get!(string[])(1) == [
        "sad", "happy"
    ], "enum[]");
    enforce(row.get!int(2) == 7 && row.get!(int[])(3) == [1, 2], "domains");
    // an anonymous record: text, fields in order
    const anonymous = row.get!(Tuple2)(4);
    enforce(anonymous.a == 1 && anonymous.b == "two" && row.getRecord(4).names.length == 0, "record");
    enforce(row.columns[0].type.name == "itest_person" && row.columns[0].format == ValueFormat.binary, "type info");

    // parameters: structs as composite values, enums by name, domain arrays
    conn.exec("INSERT INTO itest_people (id, p, moods) VALUES (?, ?, ?)", 2,
            Person("Bob", Address("Side \"St\"", 7, Nullable!string("Town")), [3], Mood.ok), [
        Mood.ok, Mood.sad
    ]);
    const bob = conn.queryValue!Person("SELECT p FROM itest_people WHERE id = 2");
    enforce(bob.home.street == `Side "St"` && bob.home.city.get == "Town" && bob.mood == Mood.ok, "struct parameter");
    enforce(conn.queryValue!string("SELECT moods::text FROM itest_people WHERE id = 2") == "{ok,sad}", "enum[] param");
    enforce(conn.queryValue!long("SELECT count(*) FROM itest_people WHERE moods @> ?", [Mood.happy]) == 1,
            "enum[] in a condition");
    assertThrown!ServerException(conn.exec("INSERT INTO itest_people (id, d) VALUES (3, ?)", -1)); // domain check

    // struct mapping with composite and array fields
    static struct PersonRow
    {
        int id;
        Person p;
        Nullable!(Mood[]) moods;
    }

    PersonRow[] people;
    foreach (pr; conn.query!PersonRow("SELECT id, p, moods FROM itest_people ORDER BY id"))
        people ~= pr;
    enforce(people.length == 2 && people[1].p.name == "Bob" && people[0].moods.get == [
        Mood.sad, Mood.happy
    ],
    "query!T with composite fields");

    // a type changed after the lookup: clearTypeCache picks the change up
    conn.exec("CREATE TYPE pg_temp.itest_pair AS (x int)");
    enforce(conn.queryValue!string("SELECT ROW(1)::pg_temp.itest_pair::text") == "(1)", "pair");
    compareOutput(conn, "VALUES (ROW(1)::pg_temp.itest_pair)", "pair");
    conn.exec("ALTER TYPE pg_temp.itest_pair ADD ATTRIBUTE y int");
    conn.clearTypeCache();
    compareOutput(conn, "VALUES (ROW(1, 2)::pg_temp.itest_pair)", "pair after ALTER TYPE");
}

private struct Tuple2
{
    int a;
    string b;
}

/// inet, cidr, macaddr, macaddr8, bit, varbit.
void testNetworkAndBits()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    compareOutput(conn, "VALUES ('192.168.0.1/24'::inet), ('10.0.0.1'), ('::ffff:1.2.3.4'), ('2001:db8::1/64'),"
            ~ " ('::1'), ('::'), ('::2'), ('::0.1.2.3'), ('::ffff:0:1'), ('1:0:0:2:0:0:0:3'), ('1:0:2:0:3:0:4:0'),"
            ~ " ('0:0:1::'), ('::1:0:0:0:0'), ('fe80::1:2:3:4'), ('1.2.3.4/32'), ('0.0.0.0/0')", "inet");
    compareOutput(conn, "VALUES ('10.0.0.0/8'::cidr), ('1.2.3.4/32'), ('::/0'), ('2001:db8::/32'), ('::1/128')",
            "cidr");
    compareOutput(conn, "VALUES ('08:00:2b:01:02:03'::macaddr), ('ff:ff:ff:ff:ff:ff')", "macaddr");
    compareOutput(conn, "VALUES ('08:00:2b:01:02:03:04:05'::macaddr8), ('08:00:2b:01:02:03'::macaddr8)", "macaddr8");
    compareOutput(conn, "VALUES (B'1010'::bit(4)), (B'0'::bit(1)), (B'110000101'::bit(9))", "bit");
    compareOutput(conn, "VALUES (B''::varbit), (B'101'::varbit), (B'1111111111111111'::varbit)", "varbit");
    compareOutput(conn, "VALUES ('0/0'::pg_lsn), ('16/B374D848'), ('FFFFFFFF/FFFFFFFF')", "pg_lsn");

    auto row = firstRow(conn, "SELECT '192.168.0.1/24'::inet, '2001:db8::/32'::cidr, '08:00:2b:01:02:03'::macaddr,"
            ~ " B'101'::varbit, '16/B374D848'::pg_lsn");
    const ip = row.getInet(0);
    enforce(ip.address == [192, 168, 0, 1] && ip.prefix == 24 && !ip.isCidr, "Inet");
    enforce(row.getInet(1).isCidr && row.getInet(1).isIPv6, "cidr");
    enforce(row.getBytes(2) == [8, 0, 0x2b, 1, 2, 3], "macaddr bytes");
    enforce(row.getBitString(3).length == 3 && row.getBitString(3)[0] && !row.getBitString(3)[1], "BitString");
    enforce(row.get!ulong(4) == 0x16_B374D848, "pg_lsn as ulong");

    enforce(firstRow(conn, "SELECT ?::inet", Inet.parse("10.1.2.3/8")).getString(0) == "10.1.2.3/8", "Inet parameter");
    enforce(firstRow(conn, "SELECT ?::cidr", Inet.parse("10.0.0.0/8")).getString(0) == "10.0.0.0/8", "cidr parameter");
    enforce(firstRow(conn, "SELECT ?::inet <<= '10.0.0.0/8'", Inet.parse("10.9.9.9")).getBool(0), "inet operator");
    enforce(firstRow(conn, "SELECT ?::varbit", BitString.parse("1101")).getString(0) == "1101", "BitString parameter");
    enforce(firstRow(conn, "SELECT ?::macaddr", "08-00-2b-01-02-03").getString(0) == "08:00:2b:01:02:03", "macaddr");
    auto simple = conn.querySimple("SELECT '::ffff:1.2.3.4/120'::inet, B'01'::bit(2)");
    enforce(simple.front.getInet(0).prefix == 120 && simple.front.getBitString(1).toString() == "01", "text format");
    simple.close();
}

/// point, line, lseg, box, path, polygon, circle.
void testGeometric()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    compareOutput(conn, "VALUES (point '(1.5,2)'), (point '(-0,1)'), (point '(nan,infinity)'), (point '(0.1,1e20)'),"
            ~ " (point '(1e-310,-infinity)')", "point");
    compareOutput(conn, "VALUES (line '{1,-1,0}'), (line '{0,1,-3}')", "line");
    compareOutput(conn, "VALUES (lseg '[(0,0),(1,1)]')", "lseg");
    compareOutput(conn, "VALUES (box '(0,0),(2,3)'), (box '(1,2),(-3,-4)')", "box");
    compareOutput(conn, "VALUES (path '((0,0),(1,1),(2,0))'), (path '[(0,0),(1,1)]')", "path");
    compareOutput(conn, "VALUES (polygon '((0,0),(1,1),(2,0))'), (polygon '((1,2))')", "polygon");
    compareOutput(conn, "VALUES (circle '<(1,2),3>'), (circle '<(1,2),0.5>')", "circle");

    auto row = firstRow(conn, "SELECT point '(1,2)', box '(0,0),(2,3)', path '[(0,0),(1,1)]', circle '<(1,2),3>',"
            ~ " polygon '((0,0),(1,1),(2,0))', lseg '[(0,0),(1,1)]', line '{1,-1,0}'");
    enforce(row.get!Point(0) == Point(1, 2) && row.get!Box(1) == Box(Point(2, 3), Point(0, 0)), "point, box");
    enforce(!row.get!Path(2).closed && row.get!Path(2).points.length == 2, "path");
    enforce(row.get!Circle(3).radius == 3 && row.get!Polygon(4).points.length == 3, "circle, polygon");
    enforce(row.get!LineSegment(5).end == Point(1, 1) && row.get!Line(6) == Line(1, -1, 0), "lseg, line");
    assertThrown!ClientException(row.get!Point(1));

    enforce(firstRow(conn, "SELECT ?::point", Point(0.1, -2)).getString(0) == "(0.1,-2)", "point parameter");
    enforce(firstRow(conn, "SELECT ?::polygon", Polygon([Point(0, 0), Point(1, 1), Point(1, 0)])).getString(
            0)
            == "((0,0),(1,1),(1,0))", "polygon parameter");
    enforce(firstRow(conn, "SELECT ?::circle", Circle(Point(1, 1), 2)).getString(0) == "<(1,1),2>", "circle");
    enforce(firstRow(conn, "SELECT ?::path", Path([Point(1, 1), Point(2, 2)], false)).getString(
            0) == "[(1,1),(2,2)]",
            "path parameter");
    enforce(firstRow(conn, "SELECT circle '<(0,0),5>' @> ?::point", Point(1, 1)).getBool(0), "contains a point");
    auto simple = conn.querySimple("SELECT box '(1,1),(0,0)'");
    enforce(simple.front.get!Box(0) == Box(Point(1, 1), Point(0, 0)), "text format");
    simple.close();
}

/// hstore and citext (contrib extensions), and the types read as text.
void testExtensionAndTextTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE EXTENSION IF NOT EXISTS hstore");
    conn.exec("CREATE EXTENSION IF NOT EXISTS citext");
    compareOutput(conn, `VALUES ('a=>1, "b c"=>NULL, "q\"x"=>"", x=>"y\\z"'::hstore), (''::hstore)`, "hstore");
    compareOutput(conn, "VALUES ('MiXeD Case'::citext), (''::citext)", "citext");
    compareOutput(conn, "VALUES (ARRAY['a=>1'::hstore])", "hstore[]");

    auto row = firstRow(conn, "SELECT 'a=>1, b=>NULL'::hstore, 'Hello'::citext, 'Hello'::citext = 'HELLO'");
    const map = row.get!(Nullable!string[string])(0);
    enforce(map["a"].get == "1" && map["b"].isNull, "hstore map");
    enforce(row.get!(string[string])(0)["a"] == "1" && row.getHstore(0).length == 2, "hstore");
    enforce(row.getString(1) == "Hello" && row.getBool(2), "citext");
    const back = firstRow(conn, "SELECT ?::hstore -> 'k'", ["k": `v "1"`]).getString(0);
    enforce(back == `v "1"`, "hstore parameter");
    enforce(firstRow(conn, "SELECT ?::citext = 'ABC'", "abc").getBool(0), "citext parameter");

    // read as text: the server's own text
    auto text = firstRow(conn, "SELECT 12.5::money, '<a>x</a>'::xml, 'a fat cat'::tsvector, 'fat & rat'::tsquery,"
            ~ " '(0,1)'::tid, '42'::xid, 'pg_class'::regclass");
    enforce(text.columns[0].format == ValueFormat.text && text.getString(0) == "$12.50", "money");
    enforce(text.getString(1) == "<a>x</a>" && text.getString(2) == "'a' 'cat' 'fat'", "xml, tsvector");
    enforce(text.getString(3) == "'fat' & 'rat'" && text.getString(4) == "(0,1)" && text.getString(
            6) == "pg_class",
            "tsquery, tid, regclass");
}

/// PostGIS geometry and geography (when the server has the extension): EWKB bytes and their text.
void testPostgis()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    if (conn.queryValue!long("SELECT count(*) FROM pg_available_extensions WHERE name = 'postgis'") == 0)
        return; // not installed: nothing to test
    conn.exec("CREATE EXTENSION IF NOT EXISTS postgis");
    compareOutput(conn, "VALUES ('SRID=4326;POINT(1 2)'::geometry), ('LINESTRING(0 0, 1 1)'), ('POLYGON EMPTY'),"
            ~ " ('POINT ZM(1 2 3 4)')", "geometry");
    compareOutput(conn, "VALUES ('POINT(1 2)'::geography)", "geography");
    compareOutput(conn, "VALUES (ARRAY['POINT(1 2)'::geometry])", "geometry[]");
    const wkb = firstRow(conn, "SELECT 'POINT(1 2)'::geometry").getBytes(0);
    enforce(wkb.length == 21 && wkb[0] == 1, "EWKB bytes");
    enforce(firstRow(conn, "SELECT ST_AsText(ST_GeomFromWKB(?))", wkb).getString(0) == "POINT(1 2)", "WKB parameter");
    enforce(firstRow(conn, "SELECT ST_X(?::geometry)", "POINT(3 4)").getDouble(0) == 3, "WKT parameter");
    auto simple = conn.querySimple("SELECT 'POINT(1 2)'::geometry");
    enforce(simple.front.getBytes(0) == wkb, "bytes from the text format");
    simple.close();
}
