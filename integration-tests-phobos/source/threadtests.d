/// Thread-mode tests: connections used by several threads at once.
module threadtests;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.exception : collectException, enforce;

import postgresql;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar, serverOptions, serverSetUp;

/// Tests registered by the thread runner.
immutable TestCase[] threadTests = [
    TestCase("thread: one connection per thread", &testThreads, true),
    TestCase("thread: cancel from another thread", &testCancelFromThread, true),
    TestCase("thread: a pool shared by threads", &testPoolThreads, true),
    TestCase("thread: a notification from another thread", &testNotifyFromThread, true),
];

/// Four threads, each with its own connection, run queries at the same time.
void testThreads()
{
    import core.atomic : atomicOp;

    shared int done;
    shared int failed;
    Thread[] threads;
    foreach (i; 0 .. 4)
    {
        threads ~= new Thread({
            try
            {
                auto conn = connectToServer();
                scope (exit)
                    conn.close();
                foreach (k; 0 .. 20)
                    if (scalar(conn, "SELECT count(*) FROM generate_series(1, 1000)") != "1000")
                        atomicOp!"+="(failed, 1);
                atomicOp!"+="(done, 1);
            }
            catch (Exception)
                atomicOp!"+="(failed, 1);
        });
        threads[$ - 1].start();
    }
    foreach (t; threads)
        t.join();
    enforce(done == 4 && failed == 0, "threads failed");
}

/++
`Connection.cancel` from another thread stops a running statement (SQLSTATE
57014), over plain and TLS connections; the connection stays usable; cancels
racing with short statements leave it in step.
+/
void testCancelFromThread()
{
    void check(SslMode mode)
    {
        auto conn = connectToServer(mode);
        scope (exit)
            conn.close();
        auto canceller = new Thread({ Thread.sleep(300.msecs); conn.cancel(); });
        canceller.start();
        const start = MonoTime.currTime;
        auto e = collectException!ServerException(conn.exec("SELECT pg_sleep(10)"));
        canceller.join();
        enforce(e !is null && e.sqlState == "57014", e is null ? "not cancelled" : e.msg);
        enforce(MonoTime.currTime - start < 5.seconds, "the cancel didn't stop the statement");
        enforce(scalar(conn, "SELECT 'after'") == "after", "usable after the cancel");

        // cancels racing with short statements: each statement succeeds or is cancelled
        foreach (i; 0 .. 20)
        {
            auto racer = new Thread({ conn.cancel(); });
            racer.start();
            try
                conn.exec("SELECT pg_sleep(0.01)");
            catch (ServerException x)
                enforce(x.sqlState == "57014", x.msg);
            racer.join();
        }
        // a late cancel may hit the next statement: the connection still works afterwards
        try
            enforce(scalar(conn, "SELECT 'last'") == "last", "after the races");
        catch (ServerException x)
            enforce(x.sqlState == "57014", x.msg);
        enforce(scalar(conn, "SELECT 'done'") == "done", "usable after the races");
    }

    check(SslMode.disable);
    if (serverSetUp())
        check(SslMode.require);
}

/// Eight threads share a pool of three connections; each statement waits for a free one.
void testPoolThreads()
{
    import core.atomic : atomicOp;

    PoolOptions p;
    p.maxConnections = 3;
    auto pool = new ConnectionPool(serverOptions(), p);
    scope (exit)
        pool.close();
    shared int done;
    shared int failed;
    Thread[] threads;
    foreach (i; 0 .. 8)
    {
        threads ~= new Thread({
            try
            {
                foreach (k; 0 .. 10)
                {
                    auto conn = pool.lockConnection();
                    if (conn.queryValue!long("SELECT count(*) FROM generate_series(1, ?)", 100 + k) != 100 + k)
                        atomicOp!"+="(failed, 1);
                }
                atomicOp!"+="(done, 1);
            }
            catch (Exception)
                atomicOp!"+="(failed, 1);
        });
        threads[$ - 1].start();
    }
    foreach (t; threads)
        t.join();
    enforce(done == 8 && failed == 0, "threads failed");
    enforce(pool.activeConnections == 0 && pool.idleConnections <= 3, "all returned, at most 3 opened");
}

/// waitForNotification without a time limit returns when another thread's connection notifies.
void testNotifyFromThread()
{
    auto listener = connectToServer();
    scope (exit)
        listener.close();
    listener.listen("itest_thread");
    auto notifier = new Thread({
        Thread.sleep(300.msecs);
        auto sender = connectToServer();
        scope (exit)
            sender.close();
        sender.notify("itest_thread", "from a thread");
    });
    notifier.start();
    const start = MonoTime.currTime;
    const n = listener.waitForNotification();
    notifier.join();
    enforce(n.get.payload == "from a thread" && MonoTime.currTime - start >= 300.msecs, "notified");
}
