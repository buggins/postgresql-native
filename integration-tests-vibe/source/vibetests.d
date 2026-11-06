/// Fiber-mode tests that need vibe-core: waiting for the server doesn't block the event loop.
module vibetests;

import core.time : MonoTime, msecs, seconds;
import std.exception : collectException, enforce;

import vibe.core.core : runTask, sleep;

import postgresql;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, scalar, serverOptions;

/// Tests registered by the vibe.d runner.
immutable TestCase[] vibeTests = [
    TestCase("fiber: statements run concurrently", &testConcurrentStatements, true),
    TestCase("fiber: cancel from another task", &testCancelFromTask, true),
    TestCase("fiber: a pool shared by tasks", &testPoolTasks, true),
];

/// Three tasks with their own connections sleep 0.5 s on the server at the same time: about 0.5 s in all.
void testConcurrentStatements()
{
    const start = MonoTime.currTime;
    bool[3] ok;
    void work(size_t i) nothrow
    {
        try
        {
            auto conn = connectToServer();
            scope (exit)
                conn.close();
            conn.exec("SELECT pg_sleep(0.5)");
            ok[i] = true;
        }
        catch (Exception)
        {
        }
    }

    auto t0 = runTask(&work, size_t(0));
    auto t1 = runTask(&work, size_t(1));
    auto t2 = runTask(&work, size_t(2));
    t0.join();
    t1.join();
    t2.join();
    enforce(ok[0] && ok[1] && ok[2], "all tasks finished");
    enforce(MonoTime.currTime - start < 1400.msecs, "the tasks ran concurrently");
}

/// Another task cancels a running statement; the connection stays usable.
void testCancelFromTask()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    void cancelLater() nothrow
    {
        try
        {
            sleep(300.msecs);
            conn.cancel();
        }
        catch (Exception)
        {
        }
    }

    auto task = runTask(&cancelLater);
    const start = MonoTime.currTime;
    auto e = collectException!ServerException(conn.exec("SELECT pg_sleep(10)"));
    task.join();
    enforce(e !is null && e.sqlState == "57014", e is null ? "not cancelled" : e.msg);
    enforce(MonoTime.currTime - start < 5.seconds, "the cancel didn't stop the statement");
    enforce(scalar(conn, "SELECT 'after'") == "after", "usable after the cancel");
}

/++
Six tasks share a pool of two connections: they wait for each other without
blocking the event loop (about three rounds of 0.3 s).
+/
void testPoolTasks()
{
    PoolOptions p;
    p.maxConnections = 2;
    auto pool = new ConnectionPool(serverOptions(), p);
    scope (exit)
        pool.close();
    const start = MonoTime.currTime;
    bool[6] ok;
    void work(size_t i) nothrow
    {
        try
        {
            auto conn = pool.lockConnection();
            conn.exec("SELECT pg_sleep(0.3)");
            ok[i] = conn.queryValue!long("SELECT ?::int8", cast(long) i) == i;
        }
        catch (Exception)
        {
        }
    }

    import vibe.core.task : Task;

    Task[6] tasks;
    foreach (i, ref t; tasks)
        t = runTask(&work, i);
    foreach (t; tasks)
        t.join();
    foreach (i, b; ok)
        enforce(b, "task failed");
    const elapsed = MonoTime.currTime - start;
    enforce(elapsed >= 850.msecs && elapsed < 2.seconds, "two at a time, concurrently");
    enforce(pool.activeConnections == 0 && pool.idleConnections == 2, "both returned");
}
