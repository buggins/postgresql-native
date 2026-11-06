/++
COPY FROM STDIN / TO STDOUT in text, CSV and binary formats; LISTEN/NOTIFY.
+/
module integrationtests.copynotify;

import core.time : msecs, MonoTime, seconds;
import std.datetime.date : Date, DateTime;
import std.exception : assertThrown, collectException, enforce;
import std.typecons : Nullable;

import postgresql;
import integrationtests.server;
import integrationtests.types : firstRow;

private struct Item
{
    int id;
    string name;
    Decimal price;
    Nullable!DateTime added;
    int[] tags;
    ubyte[] data;
}

private enum createItems = "CREATE TEMP TABLE itest_copy (id int PRIMARY KEY, name text, price numeric(12, 2),"
    ~ " added timestamp, tags int[], data bytea)";

/// COPY FROM STDIN: rows in text, CSV and binary, raw data, structs, errors, abort.
void testCopyIn()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec(createItems);
    const tricky = "tab\there, new\nline, back\\slash, \"quotes\", comma, \\N";

    // text rows
    auto copy = conn.copyIn("COPY itest_copy FROM STDIN");
    enforce(copy.format == CopyFormat.text && copy.columnCount == 6 && conn.isBusy, "text copy started");
    copy.writeRow(1, tricky, Decimal.fromString("1.50"), DateTime(2026, 11, 6, 12, 0, 0), [1, 2], cast(ubyte[])[
        0, 255
    ]);
    copy.writeRow(2, null, null, null, null, null);
    assertThrown!ClientException(copy.writeRow(3, "too few"));
    enforce(copy.finish() == 2 && !conn.isBusy, "two rows loaded");
    auto row = firstRow(conn, "SELECT name, price, added, tags, data FROM itest_copy WHERE id = 1");
    enforce(row.getString(0) == tricky && row.getString(1) == "1.50" && row.get!DateTime(2) == DateTime(2026, 11, 6,
            12, 0, 0) && row.get!(int[])(3) == [1, 2] && row.getBytes(4) == [0, 255], "text values");
    enforce(firstRow(conn, "SELECT name IS NULL AND tags IS NULL FROM itest_copy WHERE id = 2").getBool(0), "NULLs");

    // raw text data
    copy = conn.copyIn("COPY itest_copy (id, name) FROM STDIN");
    copy.write("3\tthree\n4\t\\N\n");
    copy.write(cast(const(ubyte)[]) "5\tfive\n");
    enforce(copy.finish() == 3, "raw data");

    // CSV rows: quoted values, empty string vs NULL
    copy = conn.copyIn("COPY itest_copy (id, name) FROM STDIN WITH (FORMAT csv)", CopyFormat.csv);
    copy.writeRow(10, tricky);
    copy.writeRow(11, "");
    copy.writeRow(12, null);
    enforce(copy.finish() == 3, "CSV rows");
    enforce(conn.queryValue!string("SELECT name FROM itest_copy WHERE id = 10") == tricky, "CSV text");
    enforce(firstRow(conn, "SELECT name = '', name IS NULL FROM itest_copy WHERE id IN (11, 12) ORDER BY id")
            .getBool(0), "CSV empty string");
    enforce(conn.queryValue!(Nullable!string)("SELECT name FROM itest_copy WHERE id = 12").isNull, "CSV NULL");

    // binary rows through copyInto (column types looked up)
    copy = conn.copyInto("itest_copy", ["id", "name", "price", "added", "tags", "data"]);
    enforce(copy.format == CopyFormat.binary, "binary copy");
    copy.writeRow(20, tricky, Decimal.fromString("-12345.67"), DateTime(1999, 12, 31, 23, 59, 59), [
        3, 4, 5
    ],
    cast(ubyte[])[1, 2, 3]);
    copy.writeRow(21, null, Decimal.fromString("0"), Nullable!DateTime.init, new int[0], null);
    enforce(copy.finish() == 2, "binary rows");
    row = firstRow(conn, "SELECT name, price::text, added, tags, data FROM itest_copy WHERE id = 20");
    enforce(row.getString(0) == tricky && row.getString(1) == "-12345.67" && row.get!(int[])(3) == [
        3, 4, 5
    ]
        && row.getBytes(4) == [1, 2, 3], "binary values");

    // structs: many rows, several CopyData messages
    import std.algorithm.iteration : map;
    import std.conv : to;
    import std.range : iota;

    const loaded = conn.copyInsert("itest_copy", iota(1000, 21_000).map!(i => Item(i, "item " ~ i.to!string,
            Decimal.fromString(i.to!string ~ ".25"), Nullable!DateTime.init, [i], null)));
    enforce(loaded == 20_000 && conn.queryValue!long(
            "SELECT count(*) FROM itest_copy WHERE id >= 1000") == 20_000,
            "copyInsert");
    enforce(conn.queryValue!string("SELECT price::text FROM itest_copy WHERE id = 20999") == "20999.25",
            "struct value");

    // a server error: nothing is loaded, the connection stays usable
    auto e = collectException!ServerException(conn.copyInsert("itest_copy", [Item(30), Item(1)]));
    enforce(e !is null && e.sqlState == "23505" && !conn.isBusy, "duplicate key");
    enforce(conn.queryValue!long("SELECT count(*) FROM itest_copy WHERE id = 30") == 0, "nothing loaded");
    // a malformed row noticed while writing
    copy = conn.copyIn("COPY itest_copy (id) FROM STDIN");
    e = collectException!ServerException(() {
        copy.write("not a number\n");
        foreach (i; 0 .. 200_000)
            copy.write("40\n");
        copy.finish();
    }());
    enforce(e !is null && e.sqlState == "22P02" && copy.isDone && !conn.isBusy, "malformed row");
    assertThrown!ClientException(copy.write("41\n"));

    // notices while copying (a trigger): read without waiting for other messages
    conn.exec("CREATE TEMP TABLE itest_copy_notice (id int)");
    conn.exec("CREATE FUNCTION pg_temp.itest_notice() RETURNS trigger LANGUAGE plpgsql AS"
            ~ " $$BEGIN IF NEW.id % 1000 = 0 THEN RAISE NOTICE 'row %', NEW.id; END IF; RETURN NEW; END$$");
    conn.exec("CREATE TRIGGER itest_notice BEFORE INSERT ON itest_copy_notice FOR EACH ROW"
            ~ " EXECUTE FUNCTION pg_temp.itest_notice()");
    size_t notices;
    void countNotice(ServerMessage notice)
    {
        notices += notice.message.length > 0;
    }

    conn.onNotice = &countNotice;
    copy = conn.copyIn("COPY itest_copy_notice FROM STDIN");
    foreach (i; 1 .. 200_001)
        copy.writeRow(i);
    enforce(copy.finish() == 200_000 && notices == 200, "notices during COPY");
    conn.onNotice = null;

    // abort
    copy = conn.copyIn("COPY itest_copy (id) FROM STDIN");
    copy.writeRow(50);
    copy.abort();
    enforce(!conn.isBusy && conn.queryValue!long("SELECT count(*) FROM itest_copy WHERE id = 50") == 0, "aborted");

    // a value without a binary form
    conn.exec("CREATE TEMP TABLE itest_copy_point (p point, r int4range)");
    copy = conn.copyInto("itest_copy_point", ["r"]);
    enforce(collectException!ClientException(copy.writeRow(Range!int(1, 3))) !is null, "no binary form");
    copy.abort();
    copy = conn.copyInto("itest_copy_point", ["p", "r"], CopyFormat.text);
    copy.writeRow(Point(1, 2), Range!int(1, 3));
    enforce(copy.finish() == 1, "text copy of any type");

    // not a COPY FROM STDIN
    enforce(collectException!ClientException(conn.copyIn("SELECT 1")) !is null && !conn.isBusy, "not a copy");
    enforce(collectException!ServerException(conn.copyIn("COPY nonexistent FROM STDIN")) !is null, "server error");
}

/// COPY TO STDOUT: raw data, rows in text, CSV and binary, close.
void testCopyOut()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("SET TimeZone = 'UTC'");
    enum query = "SELECT i, CASE WHEN i % 3 = 0 THEN NULL ELSE E'v\\t' || i || E'\\n\"x\",\\\\' END,"
        ~ " i * 1.5, ARRAY[i, i + 1], '2026-11-06 12:00:00+00'::timestamptz FROM generate_series(1, 100) i";

    // text: rows parsed, then typed by columnTypes
    auto copy = conn.copyOut("COPY (" ~ query ~ ") TO STDOUT");
    enforce(copy.format == CopyFormat.text && copy.columnCount == 5, "text copy");
    copy.columnTypes([Oid.int4, Oid.text, Oid.numeric, 1007, Oid.timestamptz]);
    size_t n;
    foreach (row; copy)
    {
        n++;
        const i = row.getInt(0);
        enforce(i == n, "order");
        if (i % 3 == 0)
            enforce(row.isNull(1), "NULL");
        else
            enforce(row.getString(1) == "v\t" ~ row.getString(0) ~ "\n\"x\",\\", "text unescaped");
        enforce(row.get!(int[])(3) == [i, i + 1] && row.getSysTime(4).hour == 12, "typed text values");
    }
    enforce(n == 100 && copy.isDone && copy.rowCount == 100 && !conn.isBusy, "all rows");

    // CSV
    copy = conn.copyOut("COPY (" ~ query ~ ") TO STDOUT WITH (FORMAT csv)", CopyFormat.csv);
    n = 0;
    foreach (row; copy)
    {
        n++;
        if (n % 3)
            enforce(row.getString(1) == "v\t" ~ row.getString(0) ~ "\n\"x\",\\", "CSV value");
        else
            enforce(row.isNull(1), "CSV NULL");
    }
    enforce(n == 100, "CSV rows");

    // binary: decoded with the column types
    copy = conn.copyOut("COPY (" ~ query ~ ") TO STDOUT WITH (FORMAT binary)");
    enforce(copy.format == CopyFormat.binary, "binary copy");
    copy.columnTypes([Oid.int4, Oid.text, Oid.numeric, 1007, Oid.timestamptz]);
    n = 0;
    foreach (row; copy)
    {
        n++;
        enforce(row.getInt(0) == n && row.getDouble(2) == n * 1.5
                && row.get!(int[])(3) == [cast(int) n, cast(int) n + 1], "binary values");
        enforce(row.getString(4) == "2026-11-06 12:00:00+00", "binary timestamptz");
    }
    enforce(n == 100 && copy.rowCount == 100, "binary rows");

    // raw data, and close in the middle
    const text = conn.copyOut("COPY (SELECT i FROM generate_series(1, 3) i) TO STDOUT").readText();
    enforce(text == "1\n2\n3\n", "readText");
    copy = conn.copyOut("COPY (SELECT i FROM generate_series(1, 100000) i) TO STDOUT");
    enforce(copy.readChunk() == cast(const(ubyte)[]) "1\n", "first chunk");
    copy.close();
    enforce(!conn.isBusy && conn.queryValue!int("SELECT 7") == 7, "usable after close");

    enforce(collectException!ClientException(conn.copyOut("SELECT 1")) !is null && !conn.isBusy, "not a copy");
}

private import std.conv : to;

/// LISTEN/NOTIFY: waiting with a timeout, delivery with other responses, callbacks, unlisten.
void testListenNotify()
{
    auto listener = connectToServer();
    scope (exit)
        listener.close();
    auto sender = connectToServer();
    scope (exit)
        sender.close();

    listener.listen("itest Channel");
    sender.notify("itest Channel", "hello");
    auto n = listener.waitForNotification(5.seconds);
    enforce(!n.isNull && n.get.channel == "itest Channel" && n.get.payload == "hello"
            && n.get.processId == sender.processId, "notification received");

    // timeout
    const start = MonoTime.currTime;
    enforce(listener.waitForNotification(200.msecs).isNull, "nothing to receive");
    const waited = MonoTime.currTime - start;
    enforce(waited >= 200.msecs && waited < 2.seconds, "waited for the timeout");

    // delivered with the response to another statement, and by pollNotifications
    sender.notify("itest Channel", "with a query");
    sender.exec("SELECT pg_sleep(0.1)");
    listener.exec("SELECT 1");
    const taken = listener.takeNotifications();
    enforce(taken.length == 1 && taken[0].payload == "with a query", "with a response");
    sender.notify("itest Channel", "polled");
    const deadline = MonoTime.currTime + 5.seconds;
    Notification[] polled;
    while (polled.length == 0 && MonoTime.currTime < deadline)
        polled = listener.pollNotifications();
    enforce(polled.length == 1 && polled[0].payload == "polled", "pollNotifications");

    // inside a transaction: delivered at commit
    sender.begin();
    sender.notify("itest Channel", "committed");
    enforce(listener.waitForNotification(300.msecs).isNull, "not before the commit");
    sender.commit();
    enforce(listener.waitForNotification(5.seconds).get.payload == "committed", "after the commit");

    // a callback
    Notification[] seen;
    listener.onNotification = (Notification x) { seen ~= x; };
    sender.notify("itest Channel", "callback");
    n = listener.waitForNotification(5.seconds);
    enforce(!n.isNull && n.get.payload == "callback" && seen.length == 1 && listener.takeNotifications()
            .length == 0,
            "onNotification");
    listener.onNotification = null;

    // unlisten
    listener.unlisten("itest Channel");
    sender.notify("itest Channel", "not heard");
    enforce(listener.waitForNotification(300.msecs).isNull, "unlistened");
    listener.listen("a");
    listener.listen("b");
    listener.unlistenAll();
    enforce(listener.queryValue!long("SELECT count(*) FROM pg_listening_channels()") == 0, "unlistenAll");

    // a payload too long
    assertThrown!ServerException(sender.notify("x", new char[8000].idup));
    // a busy connection can't wait
    auto r = listener.query("SELECT generate_series(1, 3)");
    assertThrown!ClientException(listener.waitForNotification(10.msecs));
    r.close();

    // over TLS
    if (serverSetUp())
    {
        auto tls = connectToServer(SslMode.require);
        scope (exit)
            tls.close();
        tls.listen("tls");
        sender.notify("tls", "secure");
        enforce(tls.waitForNotification(5.seconds).get.payload == "secure", "TLS");
    }
}
