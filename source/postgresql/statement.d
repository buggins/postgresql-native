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
import postgresql.params : checkVariantParam, hasVariant, nullValue, putParam;
import postgresql.protocol.messages : MessageBuilder;
import postgresql.result : ColumnInfo, QueryResult;

import std.meta : staticMap;
import std.variant : Variant;

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

/++
Writes the parameter part of a Bind message (the format codes, then the
values) for the parameter types of a statement.
+/
package alias ParamEncoder = void delegate(const(uint)[] types, ref MessageBuilder b) @safe;

/++
Writes the parameter part of a Bind message for `args`, encoded for
`types`; checks their number first.
+/
package void putArgs(Args...)(ref MessageBuilder b, const(uint)[] types, ref Args args)
{
    checkParameterCount(types.length, Args.length);
    const formats = beginParameters(b, Args.length);
    static foreach (i; 0 .. Args.length)
        setFormat(b, formats, i, putParam(b, args[i], types[i]));
}

/// Fills in the format code of parameter `i` (see `beginParameters`) from what `putParam` returned.
package void setFormat(ref MessageBuilder b, size_t formats, size_t i, short written) @safe pure nothrow
{
    b.patchInt16(formats + 2 * i, written == nullValue ? 0 : written);
}

/++
Starts the parameter part of a Bind message for `count` values: returns
the position of the format codes, which `patchInt16` fills in as the
values are written.
+/
package size_t beginParameters(ref MessageBuilder b, size_t count) @safe pure nothrow
{
    b.putInt16(cast(short) count); // a uint16 on the server
    const formats = b.skip(2 * count);
    b.putInt16(cast(short) count);
    return formats;
}

/// Throws `ClientException` unless as many values as parameters were given.
package void checkParameterCount(size_t parameters, size_t values) @safe pure
{
    import std.conv : to;

    if (parameters != values)
        throw new ClientException("The statement has " ~ parameters.to!string ~ " parameter(s), but "
                ~ values.to!string ~ " value(s) were given");
}

/++
Makes an encoder that keeps a copy of `args`, for use after the call (pipelines).
+/
package ParamEncoder makeEncoder(Args...)(auto ref Args args)
{
    // the values are copied into an object: a closure can't hold values with destructors (Variant)
    auto holder = new ArgsHolder!Args(args);
    return &holder.encode;
}

/++
Writes the parameter part of a Bind message for values known only at run
time: each `Variant` holds a parameter type of `encodeParam` (an empty
`Variant` or `null`: NULL).
+/
package void putVariants(ref MessageBuilder b, const(uint)[] types, const Variant[] values)
{
    import postgresql.params : putVariant;

    checkParameterCount(types.length, values.length);
    const formats = beginParameters(b, values.length);
    foreach (i, ref v; values)
        setFormat(b, formats, i, putVariant(b, v, types[i]));
}

private final class ArgsHolder(Args...)
{
    staticMap!(Stored, Args) args;

    this(ref Args args)
    {
        static foreach (i; 0 .. Args.length)
        {
            static if (hasVariant!(Args[i]))
            {
                checkVariantParam(args[i]);
                (() @trusted { this.args[i] = cast() args[i]; })(); // a Variant copy: it holds a plain value
            }
            else
                this.args[i] = args[i]; // initialized here: `Args` may be const
        }
    }

    void encode(const(uint)[] types, ref MessageBuilder b)
    {
        putArgs(b, types, args);
    }
}

// How ArgsHolder keeps an argument of type T: a Variant as a mutable copy, which the constructor assigns.
private template Stored(T)
{
    static if (hasVariant!T)
        alias Stored = Variant;
    else
        alias Stored = T;
}

// A Variant is copied for a pipeline only when it holds a type putVariant encodes
@system unittest
{
    import std.exception : assertThrown;

    static struct Evil
    {
        int x;
        this(this)
        {
        }
    }

    auto plain = Variant(5);
    assert(makeEncoder(plain) !is null && makeEncoder(Variant()) !is null);
    auto evil = Variant(Evil(1));
    assertThrown!ClientException(makeEncoder(evil));
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
    QueryResult query(Args...)(auto ref Args args)
    {
        checkOpen();
        void encode(const(uint)[] types, ref MessageBuilder b)
        {
            putArgs(b, types, args);
        }

        return conn.runStatement(info, &encode);
    }

    /++
    Runs the statement with values known at run time, one `Variant` per
    parameter (an empty `Variant` or `null` for NULL), and returns its rows.

    Throws: as `query`.
    +/
    QueryResult query(const Variant[] args)
    {
        checkOpen();
        void encode(const(uint)[] types, ref MessageBuilder b)
        {
            putVariants(b, types, args);
        }

        return conn.runStatement(info, &encode);
    }

    /// ditto, returning the number of rows affected (see `Connection.exec`).
    ulong exec(const Variant[] args)
    {
        return Connection.drainCount(query(args));
    }

    /// Runs the statement with `args` and returns the number of rows it affected (see `Connection.exec`).
    ulong exec(Args...)(auto ref Args args)
    {
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
