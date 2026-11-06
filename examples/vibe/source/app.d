/++
postgresql-native in a vibe.d application: tasks share a connection pool, and
waiting for the server suspends only the waiting task, not the thread.

Run with `dub run :example-vibe -- [connection string]` (see the basic
example; the `PG*` environment variables fill in what the string leaves out).
+/
module app;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.stdio : writefln;

import vibe.core.core : exitEventLoop, runEventLoop, runTask;
import vibe.core.task : Task;

import postgresql;

void main(string[] args)
{
    // Inside vibe.d tasks the pool's connections use vibe-core sockets automatically
    auto pool = new ConnectionPool(fromEnvironment(args.length > 1 ? args[1] : null), PoolOptions(4));

    // Runs one statement on a pooled connection
    void query(int n) nothrow
    {
        try
        {
            auto conn = pool.lockConnection();
            const value = conn.queryValue!int("SELECT ?::int * 10 FROM pg_sleep(0.5)", n);
            print("task %s: got %s", n, value);
        }
        catch (Exception e)
            print("task %s failed: %s", n, e.msg);
    }

    void work() nothrow
    {
        scope (exit)
            exitEventLoop();
        try
        {
            auto sw = StopWatch(AutoStart.yes);
            Task[] tasks;
            foreach (i; 0 .. 8)
                tasks ~= runTask(&query, i);
            foreach (t; tasks)
                t.join();
            // 8 half-second statements on 4 pooled connections: about one second in total
            print("8 statements in %s", sw.peek);
            pool.close();
        }
        catch (Exception e)
            print("error: %s", e.msg);
    }

    runTask(&work);
    runEventLoop();
}

/// `writefln` that never throws, for use in tasks.
void print(Args...)(string format, Args args) nothrow
{
    try
        writefln(format, args);
    catch (Exception)
    {
    }
}
