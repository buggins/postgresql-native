/++
Simple queries: text results, command tags, several statements, errors and
notices, transaction status, the busy and fatal-error rules.
+/
module integrationtests.basic;

import std.exception : assertThrown, collectException, enforce;

import postgresql;
import integrationtests.server;

/// Rows in text format, NULLs, Unicode, column metadata, command tags.
void testSimpleQuery()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT 42 AS answer, 'Grüße, мир, 世界' AS text, NULL::int AS nothing, true AS yes, "
            ~ "1.5::numeric(5, 2) AS amount, '2026-11-06'::date AS day");
    enforce(r.columns.length == 6 && r.columns[0].name == "answer" && r.columns[0].typeOid == 23, "columns");
    enforce(r.columns[4].typeOid == 1700 && r.columns[4].typeModifier == ((5 << 16) | 2) + 4, "numeric modifier");
    enforce(!r.empty, "a row");
    const row = r.front;
    enforce(row.getString("answer") == "42" && row.getString(1) == "Grüße, мир, 世界", "values");
    enforce(row.isNull(2) && row.getString(2) is null, "NULL");
    enforce(row.getString(3) == "t" && row.getString(4) == "1.50" && row.getString(5) == "2026-11-06", "text formats");
    r.popFront();
    enforce(r.empty && r.commandTag == "SELECT 1", "end and tag");
    enforce(!conn.isBusy, "free after the last row");

    // many rows, streamed
    r = conn.query("SELECT g, repeat('x', g % 100) FROM generate_series(1, 20000) g");
    long sum, count;
    import std.conv : to;

    foreach (row2; r)
    {
        sum += row2.getString(0).to!long;
        count++;
    }
    enforce(count == 20_000 && sum == 200_010_000L && r.commandTag == "SELECT 20000", "streamed rows");

    // a statement without rows, an empty query
    r = conn.query("SET application_name = 'renamed'");
    enforce(r.empty && r.columns.length == 0 && r.commandTag == "SET", "statement without rows");
    enforce(conn.parameterStatus("application_name") == "renamed", "ParameterStatus update");
    r = conn.query("");
    enforce(r.empty, "empty query");
}

/// exec: affected rows, several statements, the rows of the first statement of a multi-statement query.
void testExec()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("DROP TABLE IF EXISTS itest_exec");
    scope (exit)
        conn.exec("DROP TABLE IF EXISTS itest_exec");
    enforce(conn.exec("CREATE TABLE itest_exec (id int PRIMARY KEY, name text)") == 0, "CREATE");
    enforce(conn.exec("INSERT INTO itest_exec SELECT g, 'n' || g FROM generate_series(1, 10) g") == 10, "INSERT");
    enforce(conn.exec("UPDATE itest_exec SET name = 'even' WHERE id % 2 = 0") == 5, "UPDATE");
    enforce(conn.exec("DELETE FROM itest_exec WHERE id > 8; SELECT * FROM itest_exec") == 8, "last statement counts");

    auto r = conn.query("SELECT count(*) FROM itest_exec; SELECT 'second'");
    enforce(r.front.getString(0) == "8", "first statement's rows");
    r.close();
    enforce(!conn.isBusy && scalar(conn, "SELECT 'next'") == "next", "rest discarded");
}

/// Errors: fields, the connection stays usable, failed transactions, errors in the middle of rows.
void testErrors()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto e = collectException!ServerException(conn.exec("SELEC 1"));
    enforce(e !is null && e.sqlState == "42601" && e.error.position == 1 && e.error.severityNonLocalized == "ERROR",
            "syntax error fields");
    e = collectException!ServerException(conn.query("SELECT * FROM itest_no_such_table"));
    enforce(e !is null && e.sqlState == "42P01" && e.error.position == 15, "error from query()");
    enforce(scalar(conn, "SELECT 'usable'") == "usable", "usable after errors");

    // the statements after a failing one don't run
    e = collectException!ServerException(conn.exec("SELECT 1/0; CREATE TEMP TABLE itest_never (a int)"));
    enforce(e !is null && e.sqlState == "22012", "division by zero");
    enforce(scalar(conn, "SELECT to_regclass('itest_never') IS NULL") == "t", "later statements skipped");

    // a failed transaction block
    conn.exec("BEGIN");
    enforce(conn.transactionStatus == TransactionStatus.inTransaction, "in transaction");
    collectException(conn.exec("SELECT 1/0"));
    enforce(conn.transactionStatus == TransactionStatus.failed, "failed transaction");
    e = collectException!ServerException(conn.exec("SELECT 1"));
    enforce(e !is null && e.sqlState == "25P02", "commands rejected in a failed transaction");
    conn.exec("ROLLBACK");
    enforce(conn.transactionStatus == TransactionStatus.idle, "idle after ROLLBACK");

    // an error after some rows: thrown while iterating, the connection stays usable
    auto r = conn.query("SELECT 10 / (3 - g) FROM generate_series(1, 5) g");
    int rows;
    e = collectException!ServerException({
        foreach (row; r)
            rows++;
    }());
    enforce(e !is null && e.sqlState == "22012" && rows <= 2, "error in the middle of the rows");
    enforce(!conn.isBusy && scalar(conn, "SELECT 'after'") == "after", "usable after an error in the rows");

    // error details: constraint and table names
    conn.exec("CREATE TEMP TABLE itest_unique (id int PRIMARY KEY)");
    conn.exec("INSERT INTO itest_unique VALUES (1)");
    e = collectException!ServerException(conn.exec("INSERT INTO itest_unique VALUES (1)"));
    enforce(e !is null && e.sqlState == "23505" && e.error.tableName == "itest_unique"
            && e.error.constraintName == "itest_unique_pkey" && e.error.detail.length, "unique violation fields");
}

/// Notices go to onNotice; RAISE NOTICE with a hint and detail.
void testNotices()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    ServerMessage[] notices;
    conn.onNotice = (ServerMessage n) { notices ~= n; };
    conn.exec("DO $$ BEGIN RAISE NOTICE 'hello %', 42 USING HINT = 'a hint', DETAIL = 'some detail'; END $$");
    enforce(notices.length == 1 && notices[0].message == "hello 42" && notices[0].hint == "a hint"
            && notices[0].detail == "some detail" && notices[0].severityNonLocalized == "NOTICE", "notice fields");
    conn.exec("DROP TABLE IF EXISTS itest_never_existed");
    enforce(notices.length == 2 && notices[1].sqlState == "00000", "notice from DROP IF EXISTS");
}

/// A result holds the connection; a FATAL error closes it.
void testBusyAndFatal()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto r = conn.query("SELECT g FROM generate_series(1, 3) g");
    enforce(conn.isBusy, "busy while a result is open");
    assertThrown!ClientException(conn.exec("SELECT 1"));
    r.close();
    enforce(!conn.isBusy && scalar(conn, "SELECT 'free'") == "free", "free after close");

    // a session terminated by the server
    auto e = collectException!ServerException(conn.exec("SELECT pg_terminate_backend(pg_backend_pid())"));
    enforce(e !is null && e.error.isFatal && e.sqlState == "57P01", e is null ? "not terminated" : e.msg);
    enforce(!conn.isOpen, "closed after a FATAL error");
    assertThrown!ClientException(conn.exec("SELECT 1"));
}
