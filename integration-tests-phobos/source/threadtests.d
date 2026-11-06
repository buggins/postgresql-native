/// Thread-mode tests: connections used by several threads at once.
module threadtests;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.exception : collectException, enforce;

import postgresql;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar, serverSetUp;

/// Tests registered by the thread runner.
immutable TestCase[] threadTests = [
    TestCase("thread: one connection per thread", &testThreads, true),
    TestCase("thread: cancel from another thread", &testCancelFromThread, true),
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
