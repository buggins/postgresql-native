/++
The high-level API: struct mapping, the connection pool, connection strings
(environment, password file, default TLS files, target_session_attrs).
+/
module integrationtests.highlevel;

import core.time : seconds;
import std.datetime.date : Date, DateTime;
import std.exception : assertThrown, collectException, enforce;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;

import postgresql;
import postgresql.userfiles : defaultPassFile, userDirectory;
import integrationtests.server;

private enum Mood
{
    sad,
    ok,
    happy,
}

private enum Level : short
{
    low = 1,
    high = 5,
}

private struct Item
{
    int id;
    @column("item_name") string name;
    Decimal price;
    Nullable!DateTime shipped;
    Mood mood; // a PostgreSQL enum column: by name
    Level level; // an int2 column: by value
    UUID tag;
    ubyte[] data;
    Date day;
    bool active;
    @ignore string note;
}

private struct Short
{
    int id;
    string itemName; // matches item_name? no: different name (checked below)
}

private struct Named
{
    int id;
    @column("ITEM_NAME") string name; // case-insensitive match
    Variant price;
}

/// query!T, queryRow!T, queryValue!T and insert, with every kind of field.
void testStructMapping()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("DROP TYPE IF EXISTS pg_temp.itest_mood");
    conn.exec("CREATE TYPE pg_temp.itest_mood AS ENUM ('sad', 'ok', 'happy')");
    conn.exec("CREATE TEMP TABLE itest_items (id int PRIMARY KEY, item_name text, price numeric(10, 2),"
            ~ " shipped timestamp, mood pg_temp.itest_mood, level int2, tag uuid, data bytea, day date,"
            ~ " active boolean NOT NULL DEFAULT false)");

    auto items = [
        Item(1, "apple", Decimal.fromString("1.50"), Nullable!DateTime(DateTime(2026, 11, 6, 12, 0, 0)),
                Mood.happy, Level.high, UUID("8ab3060e-2cba-4f23-b74c-b52db3bdfb46"), [1, 2, 3],
                Date(2026, 1, 2), true, "not stored"),
        Item(2, "pear", Decimal.fromString("0.99"), Nullable!DateTime.init, Mood.sad, Level.low, UUID.init, null,
                Date(1999, 12, 31), false),
    ];
    enforce(conn.insert("itest_items", items) == 2, "inserted");
    enforce(conn.insert("itest_items", Item(3, "plum", Decimal.fromString("2"))) == 1, "one struct");

    Item[] read;
    foreach (item; conn.query!Item("SELECT * FROM itest_items WHERE id <= ? ORDER BY id", 2))
        read ~= item;
    enforce(read.length == 2 && !conn.isBusy, "rows read");
    enforce(read[0].id == 1 && read[0].name == "apple" && read[0].price == Decimal.fromString("1.50"), "first row");
    enforce(read[0].shipped.get == DateTime(2026, 11, 6, 12, 0, 0) && read[0].mood == Mood.happy
            && read[0].level == Level.high, "first row (2)");
    enforce(read[0].tag == items[0].tag && read[0].data == [1, 2, 3] && read[0].day == Date(2026, 1, 2)
            && read[0].active && read[0].note.length == 0, "first row (3)");
    enforce(read[1].shipped.isNull && read[1].mood == Mood.sad && read[1].data.length == 0, "second row");
    enforce(conn.queryValue!string("SELECT mood::text FROM itest_items WHERE id = 1") == "happy", "enum by name");
    enforce(conn.queryValue!int("SELECT level FROM itest_items WHERE id = 1") == 5, "enum by value");

    const row = conn.queryRow!Item("SELECT * FROM itest_items WHERE item_name = ?", "plum");
    enforce(row.id == 3 && row.mood == Mood.sad && !conn.isBusy, "queryRow");
    auto e = collectException!ClientException(conn.queryRow!Item("SELECT * FROM itest_items WHERE id = 0"));
    enforce(e !is null && !conn.isBusy, "queryRow without rows");
    e = collectException!ClientException(conn.queryRow!Short("SELECT * FROM itest_items"));
    enforce(e !is null && !conn.isBusy, "a field without a column");
    const named = conn.queryRow!Named(`SELECT id, item_name AS "Item_Name", price FROM itest_items WHERE id = 1`);
    enforce(named.name == "apple" && named.price.get!Decimal == Decimal.fromString("1.50"), "case and Variant");

    enforce(conn.queryValue!long("SELECT count(*) FROM itest_items") == 3, "queryValue");
    enforce(conn.queryValue!(Nullable!DateTime)("SELECT shipped FROM itest_items WHERE id = 2").isNull, "NULL");
    e = collectException!ClientException(conn.queryValue!DateTime("SELECT shipped FROM itest_items WHERE id = 2"));
    enforce(e !is null, "NULL into a field that can't hold it");
    assertThrown!ClientException(conn.queryValue!int("SELECT 1 WHERE false"));
    assertThrown!ClientException(conn.queryValue!ubyte("SELECT 300"));

    // a Variant field inserted
    conn.exec("CREATE TEMP TABLE itest_named (id int, item_name text, price numeric)");
    enforce(conn.insert("itest_named", Named(7, "fig", Variant(Decimal.fromString("3.25")))) == 1, "Variant insert");
    enforce(conn.queryValue!string("SELECT price::text FROM itest_named") == "3.25", "Variant value");
}

private struct Numbered
{
    int id;
    string label;
}

/// Inserts of many rows: several statements, atomic outside and part of a transaction block.
void testBulkInsert()
{
    import std.algorithm.iteration : map;
    import std.conv : to;
    import std.range : iota;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMP TABLE itest_bulk (id int PRIMARY KEY, label text)");

    // a range, not an array: 2500 rows in 3 statements
    enforce(conn.insert("itest_bulk", iota(2500).map!(i => Numbered(i, i.to!string))) == 2500, "inserted");
    enforce(conn.queryValue!long("SELECT count(*) FROM itest_bulk") == 2500 && !conn.inTransaction, "all rows");

    // a duplicate in the last statement: nothing is inserted
    auto e = collectException!ServerException(conn.insert("itest_bulk",
            iota(5000, 7500)
            .map!(i => Numbered(i == 7400 ? 1 : i, "x"))));
    enforce(e !is null && e.sqlState == "23505", "duplicate refused");
    enforce(conn.queryValue!long("SELECT count(*) FROM itest_bulk") == 2500 && !conn.inTransaction, "atomic");

    // inside a transaction block the rows belong to it
    conn.begin();
    conn.insert("itest_bulk", iota(10_000, 11_500).map!(i => Numbered(i, "y")));
    enforce(conn.inTransaction, "still in the block");
    conn.rollback();
    enforce(conn.queryValue!long("SELECT count(*) FROM itest_bulk") == 2500, "rolled back with the block");
    enforce(conn.insert("itest_bulk", new Numbered[0]) == 0, "nothing to insert");
}

private final class PoolHolder
{
    PooledConnection conn;
}

// A borrowed connection in a transaction, held only by an object nobody references any more; returns its pid.
private int dropHolderInTransaction(ConnectionPool pool)
{
    auto holder = new PoolHolder;
    holder.conn = pool.lockConnection();
    holder.conn.begin();
    holder.conn.exec("SELECT 1");
    return holder.conn.processId;
}

// A PooledConnection collected by the GC: the connection is dropped (its session can't be reset in a
// finalizer), so the next borrower never gets the open transaction.
private void testPoolFinalizer(ConnectionPool pool)
{
    import core.memory : GC;

    const idleBefore = pool.idleConnections;
    const pid = dropHolderInTransaction(pool);
    foreach (i; 0 .. 3)
        GC.collect();
    if (pool.activeConnections != 0)
        return; // the GC still sees the holder (conservative stack scan): nothing to check
    enforce(pool.idleConnections == idleBefore - 1, "a collected connection is not reused");
    auto conn = pool.lockConnection();
    enforce(conn.processId != pid && !conn.inTransaction, "the next borrower gets a clean connection");
}

/++
The pool: connections reused with their session reset, statement caches
kept, limits and wait timeouts, broken connections dropped.
+/
void testPool()
{
    PoolOptions p;
    p.maxConnections = 2;
    p.waitTimeout = 1.seconds;
    auto pool = new ConnectionPool(serverOptions(), p);
    scope (exit)
        pool.close();

    int firstPid;
    {
        auto conn = pool.lockConnection();
        firstPid = conn.processId;
        conn.exec("SET search_path = pg_catalog");
        conn.exec("CREATE TEMP TABLE itest_pool (a int)");
        conn.exec("SELECT pg_advisory_lock(?)", 4242L);
        conn.exec("LISTEN itest_pool_channel");
        enforce(conn.queryValue!int("SELECT ?::int + 1", 1) == 2, "cached statement");
        conn.begin();
        collectException(conn.exec("SELECT 1/0"));
        enforce(conn.transactionFailed, "a failed block left open");
        enforce(pool.activeConnections == 1, "one active");
    }
    enforce(pool.activeConnections == 0 && pool.idleConnections == 1, "returned");
    {
        auto conn = pool.lockConnection();
        enforce(conn.processId == firstPid, "the same connection again");
        enforce(!conn.inTransaction, "transaction rolled back");
        enforce(scalar(conn, "SHOW search_path") != "pg_catalog", "parameters reset");
        enforce(scalar(conn, "SELECT count(*) FROM pg_class WHERE relname = 'itest_pool'") == "0",
                "temp table dropped");
        enforce(scalar(conn, "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()")
                == "0", "advisory lock released");
        enforce(scalar(conn, "SELECT count(*) FROM pg_listening_channels()") == "0", "unlistened");
        enforce(conn.cachedStatements > 0 && scalar(conn, "SELECT count(*) > 0 FROM pg_prepared_statements") == "t",
                "statement cache kept");
        enforce(conn.queryValue!int("SELECT ?::int + 1", 2) == 3, "cached statement still works");

        // the limit: a second connection, then a wait that times out
        auto second = pool.lockConnection();
        enforce(second.processId != firstPid && pool.activeConnections == 2, "second connection");
        auto e = collectException!ClientException(pool.lockConnection());
        enforce(e !is null, "no third connection");

        // a connection returned busy is closed
        auto r = second.query("SELECT generate_series(1, 10)");
        second.release();
        enforce(pool.idleConnections == 0 && !r.empty, "busy connection not reused");
    }
    enforce(pool.idleConnections == 1, "one idle");
    testPoolFinalizer(pool);

    // pool options in a connection string
    import std.conv : to;

    auto o = serverOptions();
    auto fromString = new ConnectionPool(
            "host=" ~ o.host ~ " port=" ~ o.port.to!string ~ " dbname=" ~ o.database
            ~ " user=" ~ o.user ~ " password='" ~ o.password ~ "' pool_max=1 pool_wait_timeout=0.2");
    scope (exit)
        fromString.close();
    auto c = fromString.lockConnection();
    enforce(c.isOpen && collectException!ClientException(fromString.lockConnection()) !is null, "pool_max=1");
}

/// target_session_attrs and load_balance_hosts against one primary server.
void testTargetSessionAttrs()
{
    auto o = serverOptions();
    o.targetSessionAttrs = TargetSessionAttrs.readWrite;
    new Connection(o).close();
    o.targetSessionAttrs = TargetSessionAttrs.primary;
    new Connection(o).close();
    o.targetSessionAttrs = TargetSessionAttrs.preferStandby;
    auto conn = new Connection(o);
    enforce(scalar(conn, "SELECT pg_is_in_recovery()") == "f", "prefer-standby falls back to the primary");
    conn.close();
    foreach (target; [TargetSessionAttrs.standby, TargetSessionAttrs.readOnly])
    {
        o.targetSessionAttrs = target;
        auto e = collectException!ConnectionException(new Connection(o));
        enforce(e !is null, "a primary is not a standby or read-only");
    }
    // default_transaction_read_only makes a primary read-only
    o.serverOptions = "-c default_transaction_read_only=on";
    o.targetSessionAttrs = TargetSessionAttrs.readOnly;
    new Connection(o).close();
    o.targetSessionAttrs = TargetSessionAttrs.readWrite;
    enforce(collectException!ConnectionException(new Connection(o)) !is null, "read-only is not read-write");

    // the next host is tried: an unreachable one, then the server
    o = serverOptions();
    o.hosts = [HostPort("127.0.0.1", 1), HostPort(serverHost(), serverPort())];
    o.targetSessionAttrs = TargetSessionAttrs.readWrite;
    o.hostSelection = HostSelection.random;
    foreach (i; 0 .. 4)
    {
        conn = new Connection(o);
        enforce(conn.host == HostPort(serverHost(), serverPort()), "the reachable host");
        conn.close();
    }
}

/// fromEnvironment (PG* variables), the password file, the default TLS files in ~/.postgresql.
void testEnvironmentAndUserFiles()
{
    import std.conv : to;
    import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment, thisProcessID;

    const saved = environment.toAA();
    void restore(string name)
    {
        if (auto v = name in saved)
            environment[name] = *v;
        else
            environment.remove(name);
    }

    const variables = [
        "PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD", "PGPASSFILE", "PGSSLMODE",
        "PGAPPNAME", "PGTZ", "HOME", "APPDATA"
    ];
    scope (exit)
        foreach (v; variables)
            restore(v);
    foreach (v; variables)
        environment.remove(v);

    const dir = buildPath(tempDir, "pgn-itest-" ~ thisProcessID.to!string);
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);

    // PG* variables
    environment["PGHOST"] = serverHost();
    environment["PGPORT"] = serverPort().to!string;
    environment["PGDATABASE"] = databaseName();
    environment["PGUSER"] = userName();
    environment["PGPASSWORD"] = password();
    environment["PGAPPNAME"] = "from-env";
    environment["PGTZ"] = "Asia/Kolkata";
    auto conn = new Connection(fromEnvironment("sslmode=disable"));
    enforce(scalar(conn, "SHOW application_name") == "from-env" && scalar(conn, "SHOW TimeZone") == "Asia/Kolkata"
            && !conn.isEncrypted, "options from the environment");
    conn.close();
    environment.remove("PGPASSWORD");

    // the password file
    const passFile = buildPath(dir, "pgpass");
    write(passFile, "# test\n*:*:*:nobody:x\n" ~ serverHost() ~ ":" ~ serverPort()
            .to!string ~ ":"
            ~ databaseName() ~ ":" ~ userName() ~ ":" ~ escapePassField(password()) ~ "\n");
    makePrivate(passFile);
    environment["PGPASSFILE"] = passFile;
    if (password().length)
    {
        conn = new Connection(fromEnvironment());
        enforce(scalar(conn, "SELECT current_user") == userName(), "password from the file");
        conn.close();
        auto o = serverOptions();
        o.password = null;
        o.passFile = buildPath(dir, "missing");
        auto e = collectException!ClientException(new Connection(o));
        enforce(e !is null, "no password without the file");
    }
    // the default file location, through HOME (APPDATA on Windows)
    version (Windows)
        environment["APPDATA"] = dir;
    else
        environment["HOME"] = dir;
    const defaultFile = defaultPassFile();
    mkdirRecurse(buildPath(dir, "postgresql"));
    write(defaultFile, readText(passFile));
    makePrivate(defaultFile);
    environment.remove("PGPASSFILE");
    if (password().length)
    {
        auto o = serverOptions();
        o.password = null;
        conn = new Connection(o);
        enforce(scalar(conn, "SELECT current_user") == userName(), "password from the default file");
        conn.close();
    }

    if (!serverSetUp())
        return;
    // client certificate and CA from the user directory: certuser logs in with sslmode=require
    const userDir = userDirectory();
    mkdirRecurse(userDir);
    write(buildPath(userDir, "postgresql.crt"), readText(tlsFile("client.crt")));
    write(buildPath(userDir, "postgresql.key"), readText(tlsFile("client.key")));
    write(buildPath(userDir, "root.crt"), readText(tlsFile("ca.pem")));
    makePrivate(buildPath(userDir, "postgresql.key"));
    auto c = userOptions("certuser", SslMode.require, "");
    conn = new Connection(c);
    enforce(conn.isEncrypted && scalar(conn, "SELECT current_user") == "certuser", "default client certificate");
    conn.close();
    // root.crt makes sslmode=require verify the certificate (another home: TLS contexts are cached by file name)
    const otherHome = buildPath(dir, "other");
    version (Windows)
        environment["APPDATA"] = otherHome;
    else
        environment["HOME"] = otherHome;
    mkdirRecurse(userDirectory());
    write(buildPath(userDirectory(), "root.crt"), readText(tlsFile("other-ca.pem")));
    auto e = collectException!ConnectionException(new Connection(c));
    enforce(e !is null, "verified against root.crt");
    // root.crl: revocation checks with the default files (a third home, for the context cache)
    version (Windows)
        environment["APPDATA"] = buildPath(dir, "third");
    else
        environment["HOME"] = buildPath(dir, "third");
    mkdirRecurse(userDirectory());
    write(buildPath(userDirectory(), "root.crt"), readText(tlsFile("ca.pem")));
    write(buildPath(userDirectory(), "root.crl"), readText(tlsFile("crl-revoked.pem")));
    auto s = serverOptions(SslMode.require);
    auto revoked = collectException!ConnectionException(new Connection(s));
    enforce(revoked !is null, "root.crl: a revoked certificate accepted");
    write(buildPath(userDirectory(), "root.crl"), readText(tlsFile("crl-none.pem")));
    s.tls.crlFile = tlsFile("crl-none.pem"); // the same content under another name: a new TLS context
    new Connection(s).close();
}

private string escapePassField(string s)
{
    import std.array : replace;

    return s.replace(`\`, `\\`).replace(":", `\:`);
}

private void makePrivate(string path)
{
    version (Posix)
    {
        import std.conv : octal;
        import std.file : setAttributes;

        setAttributes(path, octal!"600");
    }
}

/// hostaddr (connect to an address, keep the host name) and connection services (pg_service.conf).
void testHostaddrAndServices()
{
    import std.conv : to;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : environment, thisProcessID;
    import std.socket : getAddress;

    // the server's address, so hostaddr can be numeric
    const ip = serverHost() == "localhost" ? "127.0.0.1" : getAddress(serverHost())[0].toAddrString();

    // the name is reported and used; the connection goes to the address
    auto o = serverOptions(SslMode.disable);
    o.host = "pg.invalid"; // a name that can't be resolved: only hostaddr can reach the server
    o.hostAddress = ip;
    auto conn = new Connection(o);
    enforce(conn.host == HostPort("pg.invalid", serverPort()) && conn.address == HostPort(ip, serverPort()),
            "host name and address");
    enforce(scalar(conn, "SELECT 1") == "1", "connected through hostaddr");
    conn.close();

    // failover: an unreachable address first, the names follow their addresses
    o = serverOptions(SslMode.disable);
    o.hosts = [HostPort("first.invalid", 1), HostPort("second.invalid", serverPort())];
    o.hostAddress = "127.0.0.1," ~ ip;
    conn = new Connection(o);
    enforce(conn.host.host == "second.invalid" && conn.address.host == ip, "failover with hostaddr");
    conn.close();
    o.hostAddress = ip;
    enforce(collectException!ClientException(new Connection(o)) !is null, "one address for two hosts");

    // the password file is looked up by the host name, not the address
    const dir = buildPath(tempDir, "pgn-itest-svc-" ~ thisProcessID.to!string);
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    if (password().length)
    {
        const passFile = buildPath(dir, "pgpass");
        write(passFile, "named.invalid:" ~ serverPort().to!string ~ ":*:" ~ userName() ~ ":" ~ password() ~ "\n");
        version (Posix)
        {
            import std.conv : octal;
            import std.file : setAttributes;

            setAttributes(passFile, octal!"600");
        }
        o = serverOptions(SslMode.disable);
        o.host = "named.invalid";
        o.hostAddress = ip;
        o.password = null;
        o.passFile = passFile;
        new Connection(o).close();
    }

    // TLS checks the certificate against the host name, not the address
    if (serverSetUp())
    {
        o = serverOptions(SslMode.verifyFull);
        o.tls.caFile = tlsFile("ca.pem");
        o.host = "localhost"; // in the certificate
        o.hostAddress = ip;
        conn = new Connection(o);
        enforce(conn.isEncrypted, "verify-full with hostaddr");
        conn.close();
        o.host = "wrong.invalid";
        enforce(collectException!ConnectionException(new Connection(o)) !is null, "name checked, not the address");
    }

    // services: keywords from the service file; the string's win
    const serviceFile = buildPath(dir, "pg_service.conf");
    write(serviceFile, "# test services\n[itest]\nhost=" ~ serverHost() ~ "\nport=" ~ serverPort()
            .to!string
            ~ "\ndbname=" ~ databaseName() ~ "\nuser=" ~ userName() ~ "\npassword=" ~ password()
            ~ "\nsslmode=disable\napplication_name=from-service\n");
    import std.array : replace;

    const quotedFile = serviceFile.replace(`\`, `\\`); // a backslash escapes in key=value strings
    conn = new Connection("service=itest servicefile=" ~ quotedFile);
    enforce(scalar(conn, "SHOW application_name") == "from-service", "service");
    conn.close();
    conn = new Connection("service=itest servicefile=" ~ quotedFile ~ " application_name=from-string");
    enforce(scalar(conn, "SHOW application_name") == "from-string", "the string wins");
    conn.close();
    enforce(collectException!ClientException(
            new Connection("service=missing servicefile=" ~ quotedFile)) !is null,
            "unknown service");

    // PGSERVICE / PGSERVICEFILE: the service wins over the other PG* variables
    const saved = environment.toAA();
    scope (exit)
        foreach (v; ["PGSERVICE", "PGSERVICEFILE", "PGAPPNAME"])
        {
            if (auto value = v in saved)
                environment[v] = *value;
            else
                environment.remove(v);
        }
    environment["PGSERVICE"] = "itest";
    environment["PGSERVICEFILE"] = serviceFile;
    environment["PGAPPNAME"] = "from-env";
    conn = new Connection(fromEnvironment());
    enforce(scalar(conn, "SHOW application_name") == "from-service", "PGSERVICE");
    conn.close();
}
