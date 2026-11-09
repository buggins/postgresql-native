/++
Connection pool for thread mode and fiber mode.

Example:
---
auto pool = new ConnectionPool("postgresql://app:secret@db/sales?pool_max=8");
// In any thread, or in any vibe.d task:
{
    auto conn = pool.lockConnection();       // waits if all 8 are in use
    conn.exec("INSERT INTO log VALUES (now(), ?)", "x");
}                                            // returned to the pool here
---

In thread mode all threads share one set of connections. In fiber mode each
thread has its own set, because a vibe.d connection cannot move between event
loops; the limits apply per thread. Which mode a call uses follows
`ConnectionOptions.ioMode`, as for single connections.

A returned connection gets its session reset (`Connection.resetSession`):
an open transaction is rolled back, and run-time parameters, temporary
tables, advisory locks and `LISTEN`s are cleared, while the prepared
statements of its statement cache stay (which saves parsing). A connection
whose reset fails is closed. Idle connections are checked lazily, when
connections are taken or returned, so the pool needs no background thread or
timer.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.pool;

import dbwire.client.pool : PoolCore, PoolLease, Poolable;
import postgresql.connection : Connection;
import postgresql.settings : ConnectionOptions;

/// Pool limits and connection reuse rules; from `dbwire.client.pool` (package dbwire), re-exported here.
public import dbwire.client.pool : PoolOptions;

/++
A pool of connections to one database (or one set of failover hosts).

`lockConnection` hands out a `PooledConnection`, which returns the connection
when it goes out of scope. Connections that are closed, broken, or still busy
with an unread result when returned are not reused.

The pool logic is `dbwire.client.pool.PoolCore`; this class opens
`Connection`s for it.
+/
final class ConnectionPool
{
    private PoolCore core;

    /++
    Creates an empty pool; connections are opened on demand.

    Params:
        connectionOptions = options for every connection of the pool.
        poolOptions = pool limits.
    Throws: `ClientException` if `poolOptions.maxConnections` is 0.
    +/
    this(ConnectionOptions connectionOptions, PoolOptions poolOptions = PoolOptions.init) @safe
    {
        // the caller's arrays may change later
        connectionOptions.hosts = connectionOptions.hosts.dup;
        connectionOptions.runtimeParameters = connectionOptions.runtimeParameters.dup;
        Poolable open() @safe
        {
            return new Connection(connectionOptions);
        }

        core = new PoolCore(poolOptions, connectionOptions.ioMode, &open);
    }

    /++
    Creates a pool from a connection string (a URI or `key=value` string, see
    `ConnectionOptions.parse`) with the pool parameters among its keywords:
    `pool_max`, `pool_wait_timeout`, `pool_max_idle_time`, `pool_max_lifetime`,
    `pool_ping_after_idle` (see `PoolOptions.fromParams`).

    Throws: `ClientException` for an invalid connection string.
    +/
    this(string connectionString) @safe
    {
        string[string] connection, pool;
        splitPoolParams(connectionString, connection, pool);
        this(ConnectionOptions.fromParams(connection), PoolOptions.fromParams(pool));
    }

    /++
    Takes a connection from the pool, opening a new one if none is idle and
    the limit allows it; otherwise waits up to `PoolOptions.waitTimeout`.

    Throws: `ClientException` if the pool is closed or no connection became
    free in time; connection errors when a new connection cannot be opened.
    +/
    PooledConnection lockConnection() @safe
    {
        return PooledConnection(core.acquire());
    }

    /// Number of idle connections available to the caller (its thread's set in fiber mode).
    @property size_t idleConnections() @safe
    {
        return core.idleConnections;
    }

    /// Number of connections handed out to the caller's context and not yet returned.
    @property size_t activeConnections() @safe
    {
        return core.activeConnections;
    }

    /++
    Closes all idle connections and stops handing out new ones. Connections in
    use are closed when they are returned. In fiber mode, the idle connections
    of other threads are closed by those threads when they next use the pool.
    +/
    void close() @safe
    {
        core.close();
    }
}

/++
A connection taken from a `ConnectionPool`. It behaves like the `Connection`
itself and returns it to the pool when it goes out of scope (or on `release`).
It cannot be copied.
+/
struct PooledConnection
{
    private PoolLease lease;
    private Connection conn;

    @disable this(this);

    ~this() @safe
    {
        release();
    }

    private this(PoolLease lease) @safe
    {
        import std.algorithm.mutation : move;

        // the pool's factory only creates Connections
        conn = cast(Connection) lease.connection();
        this.lease = move(lease);
    }

    /// The pooled connection. Null after `release`.
    @property Connection connection() @safe pure nothrow
    {
        return conn;
    }

    ///
    alias connection this;

    /++
    Returns the connection to the pool now, after resetting its session
    (`Connection.resetSession`; a connection whose reset fails is closed) and
    clearing `onNotice` and `onNotification`, which belong to this user.
    Calling it again does nothing.
    +/
    void release() @safe
    {
        if (conn !is null)
        {
            conn.onNotice = null;
            conn.onNotification = null;
        }
        if (conn !is null && conn.isOpen && !conn.isBusy)
        {
            try
                conn.resetSession();
            catch (Exception)
                conn.close();
        }
        conn = null;
        lease.release();
    }
}

/// The keywords of a connection string, split into connection and pool (`pool_*`) keywords.
private void splitPoolParams(string connectionString, out string[string] connection, out string[string] pool) @safe
{
    import std.algorithm.searching : startsWith;
    import std.string : strip;
    import postgresql.settings : parseKeywordValue, parseUri;

    const s = connectionString.strip;
    const all = s.startsWith("postgresql://") || s.startsWith("postgres://") ? parseUri(s) : parseKeywordValue(s);
    foreach (key, value; all)
    {
        if (key.startsWith("pool_"))
            pool[key] = value;
        else
            connection[key] = value;
    }
}

@safe unittest
{
    string[string] c, p;
    splitPoolParams("postgresql://u@h/db?pool_max=4&sslmode=disable", c, p);
    assert(p == ["pool_max": "4"] && c["sslmode"] == "disable" && c["host"] == "h");
    splitPoolParams("host=h pool_wait_timeout=2", c, p);
    assert(p == ["pool_wait_timeout": "2"] && c == ["host": "h"]);
    assert(PoolOptions.fromParams(["pool_max": "4"]).maxConnections == 4);
}
