/++
Prepared statements: the per-connection statement cache and `PreparedStatement`.

A statement is parsed once (Parse and Describe), which gives its parameter
types and its columns; then each execution is one round trip (Bind,
Execute, Sync). `Connection.query` and `exec` with parameters keep the
statements of recent SQL texts in a cache (least recently used ones are
closed when it is full); `Connection.prepare` makes a statement the caller
owns.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.statement;

import postgresql.connection : Connection;
import postgresql.exception : ClientException;
import postgresql.params : encodeParam, hasVariant, Param;
import postgresql.result : ColumnInfo, QueryResult;

@safe:

/// What the server told about a parsed statement.
package struct StatementInfo
{
    /// Statement name on the server ("" for the unnamed statement).
    string name;
    /// The SQL text as parsed (placeholders already rewritten).
    string sql;
    /// The parameter types the server inferred (ParameterDescription).
    uint[] parameterTypes;
    /// The columns (RowDescription), with the result format chosen for each; empty if no rows.
    ColumnInfo[] columns;
}

/// Encodes the arguments for the parameter types of a statement.
package alias ParamEncoder = Param[]delegate(const(uint)[] types) @safe;

/++
Makes the encoder for `args`: checks their number against the statement's
parameters and encodes each for its type.
+/
package ParamEncoder makeEncoder(Args...)(Args args)
{
    // the values are copied into an object: a closure can't hold values with destructors (Variant)
    auto holder = new ArgsHolder!Args;
    static foreach (i; 0 .. Args.length)
    {
        static if (hasVariant!(Args[i]))
            (() @trusted { holder.args[i] = args[i]; })(); // a Variant copy: it holds a plain value
        else
            holder.args[i] = args[i];
    }
    return &holder.encode;
}

private final class ArgsHolder(Args...)
{
    Args args;

    static if (hasVariant!Args)
        enum attributes = "@trusted"; // copies of Variant values, which hold plain values
    else
        enum attributes = "@safe";

    mixin("Param[] encode(const(uint)[] types) " ~ attributes ~ q{
    {
        import std.conv : to;

        if (types.length != Args.length)
            throw new ClientException("The statement has " ~ types.length.to!string ~ " parameter(s), but "
                    ~ Args.length.to!string ~ " value(s) were given");
        Param[] params;
        params.reserve(Args.length);
        static foreach (i; 0 .. Args.length)
            params ~= encodeParam(args[i], types[i]);
        return params;
    }
    });
}

/++
The statements of the most recently used SQL texts, by text. When full, the
least recently used one is dropped and its name returned to be closed on
the server.
+/
package final class StatementCache
{
    private static struct Entry
    {
        StatementInfo info;
        ulong lastUse;
    }

    private Entry[string] entries;
    private ulong clock;
    /// The most statements kept.
    size_t capacity;

    this(size_t capacity) pure nothrow
    {
        this.capacity = capacity;
    }

    /// The statement for `sql`, or null.
    StatementInfo* get(string sql) nothrow
    {
        if (auto e = sql in entries)
        {
            e.lastUse = ++clock;
            return &e.info;
        }
        return null;
    }

    /// Adds a statement; returns the name of the one dropped to make room, or null.
    string put(StatementInfo info)
    {
        string evicted;
        if (entries.length >= capacity && info.sql !in entries)
        {
            string oldest;
            ulong oldestUse = ulong.max;
            foreach (sql, ref e; entries)
                if (e.lastUse < oldestUse)
                {
                    oldestUse = e.lastUse;
                    oldest = sql;
                }
            evicted = entries[oldest].info.name;
            entries.remove(oldest);
        }
        entries[info.sql] = Entry(info, ++clock);
        return evicted;
    }

    /// Forgets the statement for `sql`; returns its name, or null if it wasn't cached.
    string remove(string sql) nothrow
    {
        if (auto e = sql in entries)
        {
            const name = e.info.name;
            entries.remove(sql);
            return name;
        }
        return null;
    }

    /// Forgets every statement (after `DISCARD ALL` or `DEALLOCATE ALL`, which closed them on the server).
    void clear() nothrow
    {
        entries = null;
    }

    /// Number of statements kept.
    @property size_t length() const pure nothrow
    {
        return entries.length;
    }
}

unittest
{
    auto cache = new StatementCache(2);
    assert(cache.put(StatementInfo("s1", "a")) is null && cache.put(StatementInfo("s2", "b")) is null);
    assert(cache.get("a").name == "s1"); // a is now the most recent
    assert(cache.put(StatementInfo("s3", "c")) == "s2" && cache.get("b") is null && cache.length == 2);
    assert(cache.remove("a") == "s1" && cache.remove("a") is null);
    cache.clear();
    assert(cache.length == 0);
}

/++
A statement parsed once on the server and run any number of times with
different parameter values (`Connection.prepare`).

Placeholders are `$1`, `$2`, ..., or `?` (rewritten like in `Connection.query`).
The statement belongs to its connection; `close` frees it on the server
(with the next request).
+/
final class PreparedStatement
{
    private Connection conn;
    private StatementInfo info;
    private bool closed;

    package this(Connection conn, StatementInfo info) pure nothrow
    {
        this.conn = conn;
        this.info = info;
    }

    /// The SQL text as sent to the server (with `?` rewritten).
    @property string sql() const pure nothrow
    {
        return info.sql;
    }

    /// The parameter types the server inferred (OIDs, see `postgresql.types.oids.Oid`).
    @property const(uint)[] parameterTypes() const pure nothrow
    {
        return info.parameterTypes;
    }

    /// The columns of the result; empty for a statement that returns no rows.
    @property const(ColumnInfo)[] columns() const pure nothrow
    {
        return info.columns;
    }

    /++
    Runs the statement with `args` and returns its rows.

    Throws: `ClientException` for a wrong number of values, values that don't
    fit the parameter types, or a closed statement; `ServerException`.
    +/
    QueryResult query(Args...)(Args args)
    {
        checkOpen();
        static if (hasVariant!Args)
            return (() @trusted => conn.runStatement(info, makeEncoder(args)))(); // Variant copies
        else
            return conn.runStatement(info, makeEncoder(args));
    }

    /// Runs the statement with `args` and returns the number of rows it affected (see `Connection.exec`).
    ulong exec(Args...)(Args args)
    {
        static if (hasVariant!Args)
            return (() @trusted => Connection.drainCount(query(args)))(); // Variant copies
        else
            return Connection.drainCount(query(args));
    }

    /// Frees the statement on the server. Calling it again does nothing.
    void close() nothrow
    {
        if (closed)
            return;
        closed = true;
        conn.closeStatementLater(info.name);
    }

    private void checkOpen() const
    {
        if (closed)
            throw new ClientException("The prepared statement is closed");
    }
}
