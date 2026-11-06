/++
Parameters and statements: D values for each parameter type, placeholders,
NULLs, the statement cache, prepared statements, several result sets.
+/
module integrationtests.params;

import std.conv : to;
import std.exception : assertThrown, collectException, enforce;

import postgresql;
import integrationtests.server;
import integrationtests.types : firstRow;

/// D values of each kind round-trip through parameters with explicit and inferred types.
void testParameterTypes()
{
    import core.time : hours, minutes, usecs;
    import std.datetime : Date, DateTime, SysTime, TimeOfDay, UTC;
    import std.typecons : Nullable;
    import std.uuid : UUID;

    auto conn = connectToServer();
    scope (exit)
        conn.close();

    // explicit casts
    auto row = firstRow(conn, "SELECT $1::int2, $2::int4, $3::int8, $4::float4, $5::float8, $6::numeric, $7::text, "
            ~ "$8::bytea, $9::bool, $10::uuid, $11::jsonb, $12::oid", short(-5), 123_456, 9_000_000_000L, 1.5f,
            -2.25, Decimal.fromString("12345.678"), "héllo 世界", cast(const(ubyte)[])[0, 1, 255], true,
            UUID("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"), `{"a": [1, 2]}`, 4_000_000_000U);
    enforce(row.getLong(0) == -5 && row.getInt(1) == 123_456 && row.getLong(2) == 9_000_000_000L, "integers");
    enforce(row.getDouble(3) == 1.5 && row.getDouble(4) == -2.25 && row.getString(5) == "12345.678", "numbers");
    enforce(row.getString(6) == "héllo 世界" && row.getBytes(7) == [0, 1, 255] && row.getBool(8), "text, bytea, bool");
    enforce(row.getUUID(9).toString() == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11" && row.getString(
            10) == `{"a": [1, 2]}`
            && row.getLong(11) == 4_000_000_000L, "uuid, jsonb, oid");

    row = firstRow(conn, "SELECT $1::date, $2::timestamp, $3::timestamptz, $4::time, $5::interval, $6::interval",
            Date(2026, 11, 6), DateTime(2026, 11, 6, 12, 34, 56), SysTime(DateTime(2026, 11, 6, 10, 0, 0),
            1234.usecs, UTC()), TimeOfDay(23, 59, 58), 26.hours + 3.minutes, Interval(14, 3, 5_000_000));
    enforce(row.getDate(0) == Date(2026, 11, 6) && row.getDateTime(1) == DateTime(2026, 11, 6, 12, 34, 56), "dates");
    enforce(row.getSysTime(2).toISOExtString() == "2026-11-06T10:00:00.001234Z", "timestamptz");
    enforce(row.getTimeOfDay(3) == TimeOfDay(23, 59, 58) && row.getString(4) == "26:03:00"
            && row.getString(5) == "1 year 2 mons 3 days 00:00:05", "time and intervals");

    // inferred types: the table's column types drive the encoding
    conn.exec("CREATE TEMP TABLE itest_params (i2 int2, i4 int4, i8 int8, f4 float4, f8 float8, n numeric(12, 3), "
            ~ "t text, b bytea, bo bool, d date, ts timestamp, tz timestamptz, tm time, iv interval, u uuid, j jsonb)");
    const inserted = conn.exec("INSERT INTO itest_params VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", 1,
            2, 3, 4, 5, 6, "7", cast(const(ubyte)[])[8], true, Date(2026, 1, 9), DateTime(2026, 1, 10, 0, 0, 0),
            SysTime(DateTime(2026, 1, 11, 0, 0, 0), UTC()), TimeOfDay(12, 0, 0), 13.hours,
            UUID("00000000-0000-0000-0000-000000000014"), `{"x": 15}`);
    enforce(inserted == 1, "INSERT count");
    // values given as other D types: strings parsed by the server, numbers converted
    conn.exec("INSERT INTO itest_params VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", "21", 22L, 23.0, 24,
            "25", 26.5, 27, "\\x1c", "true", "2026-01-29", "2026-01-30 00:00:00", "2026-01-31 00:00:00+00",
            "12:00:00", "33 hours", "00000000-0000-0000-0000-000000000034", `{"x": 35}`);
    auto r = conn.query("SELECT i2, i4, i8, f4, f8, n, t, b, d, iv, j FROM itest_params ORDER BY i2");
    auto first = r.front;
    enforce(first.getLong(0) == 1 && first.getString(5) == "6.000" && first.getString(7) == `\x08`
            && first.getDate(8) == Date(2026, 1, 9) && first.getString(9) == "13:00:00", "first row");
    r.popFront();
    auto second = r.front;
    enforce(second.getLong(0) == 21 && second.getLong(2) == 23 && second.getString(5) == "26.500"
            && second.getString(6) == "27" && second.getBytes(7) == [0x1C] && second.getString(9) == "33:00:00"
            && second.getString(10) == `{"x": 35}`, "second row");
    r.close();

    // NULLs
    row = firstRow(conn, "SELECT $1::int4, $2::text, $3::date", null, Nullable!string.init, Nullable!Date());
    enforce(row.isNull(0) && row.isNull(1) && row.isNull(2), "NULLs");
    row = firstRow(conn, "SELECT $1::int4 + 1", Nullable!int(41));
    enforce(row.getInt(0) == 42, "Nullable with a value");

    // Variant parameters
    import std.variant : Variant;

    row = firstRow(conn, "SELECT $1::int8, $2::text, $3::date", Variant(7L), Variant("v"), Variant(Date(2026, 2, 3)));
    enforce(row.getLong(0) == 7 && row.getString(1) == "v" && row.getDate(2) == Date(2026, 2, 3), "Variant");

    // a parameter whose type the server can't infer is text
    row = firstRow(conn, "SELECT $1", 5);
    enforce(row.columns[0].typeOid == Oid.text && row.getString(0) == "5", "untyped parameter as text");

    // large values
    auto big = new ubyte[1 << 20];
    foreach (i, ref b; big)
        b = cast(ubyte)(i * 7);
    row = firstRow(conn, "SELECT $1::bytea, length($1::bytea), $2::text", cast(const(ubyte)[]) big, "x".repeatString(
            100_000));
    enforce(row.getBytes(0) == big && row.getInt(1) == 1 << 20 && row.getString(2).length == 100_000, "large values");
}

private string repeatString(string s, size_t n)
{
    string r;
    r.reserve(s.length * n);
    foreach (i; 0 .. n)
        r ~= s;
    return r;
}

/// Placeholders: ?, ??, $n reused, rewriting switched off; errors before and after sending keep the connection usable.
void testPlaceholdersAndErrors()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto row = firstRow(conn, "SELECT ?::int + ?::int, '?', $$?$$ /* ? */ -- ?\n", 1, 2);
    enforce(row.getInt(0) == 3 && row.getString(1) == "?" && row.getString(2) == "?", "? outside quotes only");
    row = firstRow(conn, "SELECT '{\"a\": 1}'::jsonb ?? 'a', ?::int", 5);
    enforce(row.getBool(0) && row.getInt(1) == 5, "?? is a literal ?");
    row = firstRow(conn, "SELECT $1::int * 2, $1::int + 1", 10);
    enforce(row.getInt(0) == 20 && row.getInt(1) == 11, "$1 used twice");
    row = firstRow(conn, "SELECT '{\"a\": 1}'::jsonb ? 'a'"); // no parameters: nothing rewritten
    enforce(row.getBool(0), "jsonb ? without parameters");

    auto o = serverOptions();
    o.rewritePlaceholders = false;
    auto raw = new Connection(o);
    scope (exit)
        raw.close();
    enforce(firstRow(raw, "SELECT '{\"a\": 1}'::jsonb ? 'a', $1::int", 3).getInt(1) == 3, "rewriting off");

    // errors found by the client: the connection stays usable
    assertThrown!ClientException(conn.query("SELECT $1::int2", 70_000)); // out of range
    assertThrown!ClientException(conn.query("SELECT $1::int, $2::int", 1)); // too few values
    assertThrown!ClientException(conn.query("SELECT 1", 1)); // too many
    enforce(firstRow(conn, "SELECT 'usable'").getString(0) == "usable", "usable after client errors");
    // errors from the server, at parse and at execution
    auto e = collectException!ServerException(conn.query("SELECT * FROM itest_nope WHERE a = ?", 1));
    enforce(e !is null && e.sqlState == "42P01", "parse error");
    e = collectException!ServerException(conn.exec("SELECT 1 / $1::int", 0));
    enforce(e !is null && e.sqlState == "22012", "execution error");
    e = collectException!ServerException(conn.exec("SELECT $1::int", "not a number"));
    enforce(e !is null && e.sqlState == "22P02", "invalid text for the type");
    const after = firstRow(conn, "SELECT ?::text", "still usable").getString(0);
    enforce(after == "still usable", "usable after server errors");

    // INSERT ... RETURNING and exec counts
    conn.exec("CREATE TEMP TABLE itest_ret (id serial PRIMARY KEY, name text)");
    auto ret = conn.query("INSERT INTO itest_ret (name) VALUES (?), (?) RETURNING id, name", "a", "b");
    int count;
    foreach (r; ret)
        count++;
    enforce(count == 2 && ret.commandTag == "INSERT 0 2", "RETURNING");
    enforce(conn.exec("UPDATE itest_ret SET name = ? WHERE id > ?", "z", 0) == 2, "UPDATE count");
    enforce(conn.exec("DELETE FROM itest_ret WHERE name = ?", "nobody") == 0, "DELETE count");
}

/// The statement cache: reuse, eviction, invalidation by ALTER TABLE and DISCARD ALL, cache off.
void testStatementCache()
{
    auto o = serverOptions();
    o.statementCacheSize = 2;
    auto conn = new Connection(o);
    scope (exit)
        conn.close();
    long serverStatements()
    {
        return firstRow(conn, "SELECT count(*) FROM pg_prepared_statements WHERE name LIKE 'pgn_s%'").getLong(0);
    }

    foreach (i; 0 .. 3)
        enforce(firstRow(conn, "SELECT ?::int + 1", i).getInt(0) == i + 1, "cached statement");
    enforce(conn.cachedStatements == 1, "one statement cached");
    firstRow(conn, "SELECT ?::int + 2", 0);
    firstRow(conn, "SELECT ?::int + 3", 0); // evicts the least recently used ones
    enforce(conn.cachedStatements == 2 && serverStatements() <= 2, "evicted statements closed on the server");

    // a cached statement invalidated by ALTER TABLE is parsed again (outside a transaction)
    conn.exec("CREATE TEMP TABLE itest_cache (a int)");
    conn.exec("INSERT INTO itest_cache VALUES (1)");
    enforce(firstRow(conn, "SELECT * FROM itest_cache WHERE a = ?", 1).length == 1, "one column");
    conn.exec("ALTER TABLE itest_cache ADD COLUMN b text DEFAULT 'x'");
    auto row = firstRow(conn, "SELECT * FROM itest_cache WHERE a = ?", 1);
    enforce(row.length == 2 && row.getString(1) == "x", "re-parsed after ALTER TABLE");

    // DISCARD ALL drops the server's statements: the cache follows
    conn.exec("DISCARD ALL");
    enforce(conn.cachedStatements == 0, "cache cleared by DISCARD ALL");
    enforce(firstRow(conn, "SELECT * FROM pg_class WHERE relname = ?", "pg_class").length > 0, "after DISCARD ALL");

    // a statement dropped behind the cache's back is parsed again too
    firstRow(conn, "SELECT ?::int * 10", 1);
    conn.querySimple("DEALLOCATE ALL").close();
    enforce(firstRow(conn, "SELECT ?::int * 10", 2).getInt(0) == 20, "after DEALLOCATE ALL");

    // no cache: the unnamed statement each time
    auto u = serverOptions();
    u.statementCacheSize = 0;
    auto uncached = new Connection(u);
    scope (exit)
        uncached.close();
    foreach (i; 0 .. 3)
        enforce(firstRow(uncached, "SELECT ?::int", i).getInt(0) == i, "uncached");
    enforce(uncached.cachedStatements == 0 && firstRow(uncached, "SELECT count(*) FROM pg_prepared_statements")
            .getLong(0) == 0, "nothing prepared");
}

/// Prepared statements: types, columns, many executions, exec, close.
void testPreparedStatements()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMP TABLE itest_prep (id int, name text)");
    auto insert = conn.prepare("INSERT INTO itest_prep VALUES (?, ?)");
    enforce(insert.parameterTypes == [uint(Oid.int4), uint(Oid.text)], "insert parameter types");
    enforce(insert.columns.length == 0, "insert statement: no columns");
    foreach (i; 0 .. 100)
        enforce(insert.exec(i, "n" ~ i.to!string) == 1, "insert");
    insert.close();

    auto select = conn.prepare("SELECT id, name FROM itest_prep WHERE id < $1 ORDER BY id");
    enforce(select.columns.length == 2 && select.columns[1].name == "name" && select.parameterTypes == [
        uint(Oid.int4)
    ],
    "select statement");
    foreach (limit; [0, 5, 50])
    {
        auto r = select.query(limit);
        int count;
        foreach (row; r)
        {
            enforce(row.getInt(0) == count && row.getString(1) == "n" ~ count.to!string, "row");
            count++;
        }
        enforce(count == limit, "rows below the limit");
    }
    assertThrown!ClientException(select.query("a", "b")); // two values for one parameter
    select.close();
    assertThrown!ClientException(select.query(1));
    enforce(firstRow(conn, "SELECT count(*) FROM pg_prepared_statements WHERE name LIKE 'pgn_p%'")
            .getLong(0) == 0,
            "closed statements freed on the server");
    assertThrown!ServerException(conn.prepare("SELEC 1"));
    enforce(firstRow(conn, "SELECT 'ok'").getString(0) == "ok", "usable after a failed prepare");
}

/// Several result sets from one simple query.
void testMultipleResults()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.querySimple("SELECT 1 AS a; SET application_name = 'multi'; SELECT 'x' AS b, 'y' AS c "
            ~ "UNION ALL SELECT 'z', 'w'; SELECT 42 WHERE false");
    enforce(r.columns[0].name == "a" && r.front.getInt(0) == 1, "first result");
    r.popFront();
    enforce(r.empty && r.commandTag == "SELECT 1", "first result ended");
    enforce(conn.isBusy, "busy: another result follows");
    enforce(r.nextResult(), "second result with rows");
    enforce(r.columns.length == 2 && r.columns[1].name == "c", "second result columns");
    string[] values;
    foreach (row; r)
        values ~= row.getString(0) ~ row.getString(1);
    enforce(values == ["xy", "zw"] && r.commandTag == "SELECT 2", "second result rows");
    enforce(r.nextResult() && r.empty && r.commandTag == "SELECT 0", "third result: no rows");
    enforce(!r.nextResult() && !conn.isBusy, "no more results");
    enforce(conn.parameterStatus("application_name") == "multi", "the SET in between ran");

    // a statement without rows first
    r = conn.querySimple("SET application_name = 'again'; SELECT 5");
    enforce(r.empty && r.commandTag == "SET" && r.nextResult() && r.front.getInt(0) == 5, "rows after a SET");
    r.close();
    enforce(!conn.isBusy, "closed");

    // an error in a later statement is thrown when the earlier rows end
    r = conn.querySimple("SELECT 1; SELECT 1/0; SELECT 3");
    auto e = collectException!ServerException({
        while (!r.empty)
            r.popFront();
        r.nextResult();
    }());
    enforce(e !is null && e.sqlState == "22012" && !conn.isBusy, "error in the second statement");
    enforce(firstRow(conn, "SELECT 'fine'").getString(0) == "fine", "usable");
}
