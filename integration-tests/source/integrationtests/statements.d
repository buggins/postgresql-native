/++
Statements in depth: transactions and savepoints, timeouts, cancel when idle,
pipelines.
+/
module integrationtests.statements;

import std.conv : to;
import std.exception : assertThrown, collectException, enforce;

import postgresql;
import integrationtests.server;
import integrationtests.types : firstRow;

/// begin/commit/rollback, isolation levels, read-only blocks, savepoints, failed blocks.
void testTransactions()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMP TABLE itest_tx (id int PRIMARY KEY)");

    conn.begin();
    enforce(conn.inTransaction && !conn.transactionFailed, "in a block");
    conn.exec("INSERT INTO itest_tx VALUES (?)", 1);
    conn.rollback();
    enforce(!conn.inTransaction && firstRow(conn, "SELECT count(*) FROM itest_tx").getLong(0) == 0, "rolled back");

    conn.begin(IsolationLevel.serializable);
    enforce(firstRow(conn, "SHOW transaction_isolation").getString(0) == "serializable", "serializable");
    conn.exec("INSERT INTO itest_tx VALUES (?)", 1);
    conn.commit();
    enforce(firstRow(conn, "SELECT count(*) FROM itest_tx").getLong(0) == 1, "committed");

    conn.begin(IsolationLevel.repeatableRead, true);
    enforce(firstRow(conn, "SHOW transaction_isolation").getString(0) == "repeatable read"
            && firstRow(conn, "SHOW transaction_read_only").getString(0) == "on", "repeatable read, read only");
    // (temporary tables may be written in a read-only block, so create a permanent one)
    auto e = collectException!ServerException(conn.exec("CREATE TABLE itest_never_ro (a int)"));
    enforce(e !is null && e.sqlState == "25006", "read-only block refuses writes");
    enforce(conn.transactionFailed, "failed block");
    e = collectException!ServerException(conn.exec("SELECT 1"));
    enforce(e !is null && e.sqlState == "25P02", "statements refused in a failed block");
    conn.rollback();
    enforce(!conn.inTransaction, "rollback ends a failed block");

    conn.begin(IsolationLevel.serializable, true, true);
    enforce(firstRow(conn, "SHOW transaction_deferrable").getString(0) == "on", "deferrable");
    conn.commit();

    // savepoints: roll back part of a block, recover from an error
    conn.begin();
    conn.exec("INSERT INTO itest_tx VALUES (?)", 10);
    conn.savepoint("before \"dup\"");
    collectException(conn.exec("INSERT INTO itest_tx VALUES (?)", 10)); // duplicate key
    enforce(conn.transactionFailed, "failed after the duplicate");
    conn.rollbackTo("before \"dup\"");
    enforce(conn.inTransaction && !conn.transactionFailed, "recovered by ROLLBACK TO SAVEPOINT");
    conn.exec("INSERT INTO itest_tx VALUES (?)", 11);
    conn.savepoint("sp2");
    conn.exec("INSERT INTO itest_tx VALUES (?)", 12);
    conn.releaseSavepoint("sp2");
    conn.commit();
    enforce(firstRow(conn, "SELECT string_agg(id::text, ',' ORDER BY id) FROM itest_tx")
            .getString(0) == "1,10,11,12",
            "savepoint results");

    // COMMIT of a failed block: the server rolls back and reports ROLLBACK
    conn.begin();
    conn.exec("INSERT INTO itest_tx VALUES (?)", 20);
    collectException(conn.exec("SELECT 1/0"));
    conn.commit();
    enforce(!conn.inTransaction && firstRow(conn, "SELECT count(*) FROM itest_tx WHERE id = 20")
            .getLong(0) == 0,
            "a failed block is rolled back by COMMIT");

    // session defaults
    conn.setSessionDefaults(IsolationLevel.repeatableRead);
    enforce(firstRow(conn, "SHOW default_transaction_isolation").getString(0) == "repeatable read", "session default");
    conn.setSessionDefaults(IsolationLevel.default_);
    enforce(firstRow(conn, "SHOW default_transaction_isolation").getString(0) == "read committed", "back to default");
}

/// statement_timeout set at startup cancels long statements; the connection stays usable.
void testStatementTimeout()
{
    import core.time : MonoTime, msecs, seconds;

    auto o = serverOptions();
    o.statementTimeout = 300.msecs;
    auto conn = new Connection(o);
    scope (exit)
        conn.close();
    enforce(firstRow(conn, "SHOW statement_timeout").getString(0) == "300ms", "statement_timeout");
    const start = MonoTime.currTime;
    auto e = collectException!ServerException(conn.exec("SELECT pg_sleep(5)"));
    enforce(e !is null && e.sqlState == "57014", e is null ? "not cancelled" : e.msg);
    enforce(MonoTime.currTime - start < 3.seconds, "cancelled in time");
    enforce(firstRow(conn, "SELECT 'after'").getString(0) == "after", "usable after the timeout");
    conn.cancel(); // idle: nothing happens
    enforce(firstRow(conn, "SELECT 'idle cancel'").getString(0) == "idle cancel", "cancel when idle");
}

/// Pipelines: one round trip, results in order, error semantics of both modes, no cache.
void testPipelines()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMP TABLE itest_pipe (id int PRIMARY KEY, name text)");

    auto p = conn.pipeline();
    const a = p.add("INSERT INTO itest_pipe VALUES (?, ?)", 1, "one");
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 2, "two");
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 3, "three");
    const q = p.add("SELECT id, name FROM itest_pipe WHERE id >= ? ORDER BY id", 2);
    p.add("SELECT 'no parameters'");
    enforce(p.length == 5, "five statements");
    auto results = p.run();
    enforce(p.length == 0 && results.length == 5 && results[a].affectedRows == 1, "results");
    enforce(results[q].rows.length == 2 && results[q].rows[0].getString(1) == "two" && results[q].columns.length == 2,
            "rows of a pipelined query");
    enforce(results[4].rows[0].getString(0) == "no parameters" && !conn.isBusy, "statement without parameters");

    // transaction mode: an error skips the rest and rolls the batch back
    p = conn.pipeline();
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 10, "ten");
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 1, "duplicate");
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 11, "eleven");
    results = p.run();
    enforce(!results[0].failed && results[1].failed && results[1].error.sqlState == "23505" && results[2].skipped,
            "error and skipped");
    assertThrown!ServerException(results[1].throwIfFailed());
    enforce(firstRow(conn, "SELECT count(*) FROM itest_pipe WHERE id IN (10, 11)").getLong(0) == 0,
            "the batch was rolled back");

    // independent mode: only the failing statement is lost
    p = conn.pipeline(PipelineMode.independent);
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 20, "twenty");
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 1, "duplicate");
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 21, "twenty-one");
    results = p.run();
    enforce(!results[0].failed && results[1].failed && !results[2].failed && !results[2].skipped, "independent");
    enforce(firstRow(conn, "SELECT count(*) FROM itest_pipe WHERE id IN (20, 21)").getLong(0) == 2, "kept");

    // inside a transaction block the pipeline's statements belong to the block
    conn.begin();
    p = conn.pipeline();
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 30, "thirty");
    p.add("SELECT count(*) FROM itest_pipe");
    p.run();
    enforce(conn.inTransaction, "still in the block");
    conn.rollback();
    enforce(firstRow(conn, "SELECT count(*) FROM itest_pipe WHERE id = 30").getLong(0) == 0, "rolled back with it");

    // a statement that can't be parsed: nothing runs
    p = conn.pipeline();
    p.add("INSERT INTO itest_pipe VALUES (?, ?)", 40, "forty");
    p.add("SELEC nonsense");
    auto e = collectException!ServerException(p.run());
    enforce(e !is null && e.sqlState == "42601", "parse error");
    enforce(firstRow(conn, "SELECT count(*) FROM itest_pipe WHERE id = 40").getLong(0) == 0, "nothing ran");
    // values that don't fit: nothing is sent
    p = conn.pipeline();
    p.add("SELECT ?::int2", 100_000);
    assertThrown!ClientException(p.run());
    enforce(firstRow(conn, "SELECT 'usable'").getString(0) == "usable", "usable after failed pipelines");

    // more new statements than the statement cache holds: those it evicts are closed after the pipeline
    {
        auto small = serverOptions();
        small.statementCacheSize = 2;
        auto cached = new Connection(small);
        scope (exit)
            cached.close();
        foreach (round; 0 .. 2)
        {
            p = cached.pipeline();
            foreach (i; 0 .. 3)
                p.add("SELECT ?::int + " ~ (round * 3 + i).to!string, 1);
            results = p.run();
            foreach (i, r; results)
                enforce(r.rows[0].getInt(0) == 1 + round * 3 + i, "cache eviction in a pipeline");
        }
        const kept = firstRow(cached, "SELECT count(*) FROM pg_prepared_statements").getLong(0);
        enforce(kept <= 3 && !cached.isBusy, "evicted statements closed: " ~ kept.to!string);
    }

    // many statements, the same SQL repeated, without a statement cache
    auto o = serverOptions();
    o.statementCacheSize = 0;
    auto uncached = new Connection(o);
    scope (exit)
        uncached.close();
    p = uncached.pipeline();
    foreach (i; 0 .. 500)
        p.add("SELECT ?::int * 2", i);
    results = p.run();
    foreach (i, r; results)
        enforce(r.rows[0].getInt(0) == i * 2, "result " ~ i.to!string);
    const left = firstRow(uncached, "SELECT count(*) FROM pg_prepared_statements").getLong(0);
    enforce(left == 0, "temporary statements closed");
}
