/++
A connection to a PostgreSQL server.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.connection;

import core.time : Duration;

import std.range.primitives : ElementType, empty, front, isInputRange, popFront;
import std.traits : Unqual;

import dbwire.client.hosts : connectFirst, HostPort, orderHosts;
import dbwire.client.pool : Poolable;
import dbwire.io.backend : backendFor, IoBackend;
import dbwire.io.transport : Transport;
import dbwire.tls.transport : TlsContext, TlsOptions, TlsTransport;

import postgresql.auth;
import postgresql.exception;
import postgresql.protocol.codes;
import postgresql.protocol.messages;
import postgresql.result;
import postgresql.params : hasVariant, Param, rewritePlaceholders;
import postgresql.mapping : fieldPositions, hasVariantField, insertSql, mappedFields, readStruct, readValue,
    RowRange, RowsEncoder;
import postgresql.pipeline;
import postgresql.settings;
import postgresql.statement;
import postgresql.types.oids : Oid;
import postgresql.types.pgtype : PgType;

@safe:

/// The authentication method the server used for the session.
enum AuthMethod
{
    none, /// no password asked (`trust`, `peer`, certificate-only, ...)
    cleartext, /// `password`: the password was sent as is
    md5, /// `md5`
    scramSha256, /// `scram-sha-256`
    scramSha256Plus, /// `scram-sha-256` with channel binding
}

/// A NOTIFY received on a channel the session listens to.
struct Notification
{
    /// Process ID of the session that sent it.
    int processId;
    /// The channel.
    string channel;
    /// The payload; empty if none.
    string payload;
}

/++
A connection to a PostgreSQL server.

One call at a time: a `QueryResult` holds the connection until it is read to
the end or closed. Network errors, malformed data and `FATAL` errors close the
connection.
+/
final class Connection : Poolable
{
    package enum State
    {
        closed,
        ready,
        busy,
    }

    package State state = State.closed;
    package ConnectionOptions options;
    private IoBackend backend;
    private Transport transport;
    private TlsTransport tls;
    package MessageStream stream;
    private HostPort connectedHost;
    private HostPort attemptHost; // the host being connected to
    private string[string] parameters;
    private int backendPid;
    private immutable(ubyte)[] cancelKey;
    private TransactionStatus txStatus = TransactionStatus.idle;
    private uint protocol = protocol30;
    private AuthMethod auth;
    private Notification[] notifications;
    private StatementCache cache; // null when statementCacheSize is 0
    private string[] pendingCloses; // statements to close with the next extended-protocol request
    private ulong statementCounter;
    private PgType[uint] types; // data types of the database, looked up (see resolveColumns)
    private bool[uint] missingTypes; // OIDs pg_type didn't know
    private bool typeQueryPrepared; // the pg_type query statement exists in the session
    private Encryption encryptionUsed; // how the session was encrypted, for cancel requests
    private bool responseDone = true; // ReadyForQuery of the current request was read
    private ServerMessage pendingError; // the first error of the current response
    private bool hasPendingError;

    /++
    Called with each notice (NoticeResponse: warnings, `RAISE NOTICE`
    output, ...); may be null.
    +/
    void delegate(ServerMessage notice) @safe onNotice;

    /++
    Connects and logs in.

    Throws: `ConnectionException` if no server can be reached or TLS fails;
    `ServerException` if the server rejects the login; `ClientException` for
    invalid options (e.g. OpenSSL missing when TLS is required, or an
    authentication method that `requireAuth` forbids).
    +/
    this(ConnectionOptions options)
    {
        this.options = options;
        if (options.statementCacheSize > 0)
            cache = new StatementCache(options.statementCacheSize);
        connect();
    }

    /// Connects with a connection string (see `ConnectionOptions.parse`).
    this(string connectionString)
    {
        this(ConnectionOptions.parse(connectionString));
    }

    /// Whether the connection is open (it may be busy).
    @property bool isOpen() const pure nothrow
    {
        return state != State.closed;
    }

    /// Whether a result is still being read.
    @property bool isBusy() const pure nothrow
    {
        return state == State.busy;
    }

    /// The host connected to.
    @property HostPort host() const pure nothrow
    {
        return connectedHost;
    }

    /// Whether the connection is encrypted with TLS.
    @property bool isEncrypted() const pure nothrow
    {
        return tls !is null;
    }

    /// The TLS protocol version (e.g. `TLSv1.3`), or null without TLS.
    @property string tlsVersion()
    {
        return tls is null ? null : tls.protocolVersion;
    }

    /// The TLS cipher suite, or null without TLS.
    @property string tlsCipher()
    {
        return tls is null ? null : tls.cipher;
    }

    /// The authentication method the server used.
    @property AuthMethod authMethod() const pure nothrow
    {
        return auth;
    }

    /// The protocol version in use: `protocol30` or `protocol32`.
    @property uint protocolVersion() const pure nothrow
    {
        return protocol;
    }

    /// The server's process ID for this session (`pg_backend_pid()`).
    @property int processId() const pure nothrow
    {
        return backendPid;
    }

    /// The transaction status after the last command.
    @property TransactionStatus transactionStatus() const pure nothrow
    {
        return txStatus;
    }

    /++
    The current value of a run-time parameter the server reports (ParameterStatus):
    `server_version`, `server_encoding`, `TimeZone`, `DateStyle`, `IntervalStyle`,
    `integer_datetimes`, `standard_conforming_strings`, `application_name`,
    `is_superuser`, `session_authorization`, `in_hot_standby` (14+), ...;
    null if not reported.
    +/
    string parameterStatus(string name) const pure nothrow
    {
        if (auto p = name in parameters)
            return *p;
        return null;
    }

    /// The server version as text, e.g. `"18.6 (Debian 18.6-1.pgdg13+2)"`.
    @property string serverVersion() const pure nothrow
    {
        return parameterStatus("server_version");
    }

    /// The server version as a number, like `server_version_num`: 180006 for 18.6, 90624 for 9.6.24.
    @property uint serverVersionNumber() const pure
    {
        return parseServerVersion(serverVersion);
    }

    /// The notifications received so far and not taken yet; taking them clears the list.
    Notification[] takeNotifications() pure nothrow
    {
        auto n = notifications;
        notifications = null;
        return n;
    }

    /++
    Runs one or more SQL statements with the simple query protocol and
    returns the number of rows the last one affected (`INSERT`, `UPDATE`,
    `DELETE`, `MERGE`, `SELECT`, `COPY`, ...; 0 for other commands). Rows are
    discarded.

    Throws: `ServerException` (the first error; the statements after it don't
    run, and the connection stays usable unless the error is fatal).
    +/
    ulong exec(string sql)
    {
        startSimpleQuery(sql);
        string lastTag;
        guarded({
            for (;;)
            {
                auto m = nextMessage();
                switch (m.type)
                {
                case BackendMessage.commandComplete:
                    lastTag = m.body.readCString();
                    noteCommandTag(lastTag);
                    break;
                case BackendMessage.readyForQuery:
                    readyForQuery(m);
                    return;
                default:
                    handleResponseMessage(m);
                }
            }
        });
        throwPendingError();
        return affectedRows(lastTag);
    }

    /++
    Runs one SQL statement and returns its rows, read as the result is
    iterated (extended query protocol). Values of the types this client
    decodes come in binary format, the others in text; the getters on each
    row convert them (see `postgresql.value.Value`).

    `args` are the values of the placeholders: `$1`, `$2`, ..., or `?`
    (rewritten to `$n` unless `ConnectionOptions.rewritePlaceholders` is
    off; `??` is a literal `?`). Each value is encoded for the parameter type
    the server infers (see `postgresql.params`).

    The statement is parsed once and kept in the connection's statement
    cache (`ConnectionOptions.statementCacheSize`), so running the same SQL
    again is one round trip. Several statements in one string are refused
    by the server: use `querySimple` or `exec` without parameters for those.

    Throws: `ClientException` for a wrong number of values or values that
    don't fit the parameter types; `ServerException`, from here or from the result.
    +/
    QueryResult query(Args...)(string sql, Args args)
    {
        static if (Args.length == 0)
            return runSql(sql, null);
        else
        {
            size_t count;
            const text = options.rewritePlaceholders ? rewritePlaceholders(sql, count) : sql;
            static if (hasVariant!Args)
                return (() @trusted => runSql(text, makeEncoder(args)))(); // Variant copies
            else
                return runSql(text, makeEncoder(args));
        }
    }

    /++
    Runs one SQL statement with parameters (see `query`) and returns the
    number of rows it affected (`INSERT`, `UPDATE`, `DELETE`, `MERGE`,
    `SELECT`, ...; 0 for other commands). Rows are discarded.

    Throws: `ClientException`, `ServerException`.
    +/
    ulong exec(Args...)(string sql, Args args) if (Args.length > 0)
    {
        static if (hasVariant!Args)
            return (() @trusted => drainCount(query(sql, args)))(); // Variant copies
        else
            return drainCount(query(sql, args));
    }

    /++
    Runs one SQL statement (see `query`) and returns its rows as structs of
    type `T` (see `postgresql.mapping`): an input range that holds the
    connection until all rows are read or it is closed.

    Throws: `ClientException` if a field has no column, or a value can't be
    read into its field; as `query`.
    +/
    RowRange!T query(T, Args...)(string sql, Args args) if (is(T == struct))
    {
        static if (hasVariant!Args)
            return (() @trusted => RowRange!T(query(sql, args)))(); // Variant copies
        else
            return RowRange!T(query(sql, args));
    }

    /++
    The first row of a query as a `T` (see `query!T`); the other rows are discarded.

    Throws: `ClientException` if there is no row, a field has no column or a
    value can't be read into its field; as `query`.
    +/
    T queryRow(T, Args...)(string sql, Args args) if (is(T == struct))
    {
        static if (hasVariant!Args)
            auto result = (() @trusted => query(sql, args))(); // Variant copies
        else
            auto result = query(sql, args);
        scope (exit)
            result.close();
        const positions = fieldPositions!T(result);
        if (result.empty)
            throw new ClientException("The query returned no rows");
        static if (hasVariantField!T)
            return (() @trusted => readStruct!T(result, positions))(); // Variant copies
        else
            return readStruct!T(result, positions);
    }

    /++
    The first column of the first row of a query, as a `T` (a field type of
    `postgresql.mapping`; `Nullable!T` to tell NULL apart), e.g.
    `queryValue!long("SELECT count(*) FROM t")`.

    Throws: `ClientException` if there is no row, or the value can't be
    converted (NULL included, unless `T` can hold it); as `query`.
    +/
    T queryValue(T, Args...)(string sql, Args args)
    {
        static if (hasVariant!Args)
            auto result = (() @trusted => query(sql, args))(); // Variant copies
        else
            auto result = query(sql, args);
        scope (exit)
            result.close();
        if (result.empty || result.columns.length == 0)
            throw new ClientException("The query returned no value");
        static if (hasVariant!T)
            return (() @trusted => readValue!T(result.front[0]))(); // Variant copies
        else
            return readValue!T(result.front[0]);
    }

    /++
    Inserts structs as rows of `table`: one column per mapped field (see
    `postgresql.mapping`), with multi-row `INSERT ... VALUES` statements of up
    to 1000 rows (fewer for structs with more than 65 fields: at most 65535
    parameters each).

    The insert is atomic: outside a transaction block, an insert that needs
    several statements runs in a transaction of its own; inside one, the rows
    are part of it. `table` is used as given (e.g. `orders` or
    `sales.orders`); column names as `sqlColumnName` writes them.

    Returns: the number of rows inserted.
    Throws: `ServerException` if the server refuses a row (then no row is
    inserted, outside a transaction block); `ClientException` for a value
    that can't be sent.
    +/
    ulong insert(R)(string table, R rows) if (isInputRange!R && is(ElementType!R == struct))
    {
        import std.algorithm.comparison : min;

        alias E = Unqual!(ElementType!R);
        enum width = mappedFields!E.length;
        static assert(width > 0, E.stringof ~ " has no mapped fields");
        enum batchRows = min(1000, 65_535 / width);

        auto encoder = new RowsEncoder!E;
        ulong inserted;
        bool began;
        scope (failure)
        {
            if (began && state == State.ready && txStatus != TransactionStatus.idle)
            {
                try
                    rollback();
                catch (Exception)
                {
                }
            }
        }
        for (;;)
        {
            encoder.rows.length = 0;
            while (!rows.empty && encoder.rows.length < batchRows)
            {
                static if (hasVariantField!E)
                    (() @trusted { encoder.rows ~= rows.front; })(); // Variant copies
                else
                    encoder.rows ~= rows.front;
                rows.popFront();
            }
            if (encoder.rows.length == 0)
                break;
            if (!rows.empty && !began && !inTransaction)
            {
                begin();
                began = true;
            }
            inserted += drainCount(runSql(insertSql!E(table, encoder.rows.length), &encoder.encode));
            if (rows.empty)
                break;
        }
        if (began)
            commit();
        return inserted;
    }

    /// ditto
    ulong insert(T)(string table, T row) if (is(T == struct) && !isInputRange!T)
    {
        static if (hasVariantField!T)
            return (() @trusted => insert(table, [row]))(); // Variant copies
        else
            return insert(table, [row]);
    }

    /++
    Parses a statement on the server for running it many times (see
    `PreparedStatement`). Placeholders are `$1`, `$2`, ..., or `?`.

    Throws: `ServerException` if the server can't parse it.
    +/
    PreparedStatement prepare(string sql)
    {
        size_t count;
        const text = options.rewritePlaceholders ? rewritePlaceholders(sql, count) : sql;
        startRequest();
        auto info = describeStatement(text, nextStatementName("pgn_p"));
        sync(); // ends the Parse/Describe batch
        finishResponse();
        return new PreparedStatement(this, info);
    }

    /// Number of statements in the statement cache.
    @property size_t cachedStatements() const pure nothrow
    {
        return cache is null ? 0 : cache.length;
    }

    /// Reads a result to its end and returns the affected-row count of its command tag.
    package static ulong drainCount(QueryResult r)
    {
        while (!r.empty)
            r.popFront();
        return affectedRows(r.commandTag);
    }

    // Closes a statement on the server with the next extended-protocol request.
    package void closeStatementLater(string name) nothrow
    {
        if (state != State.closed && name.length)
            pendingCloses ~= name;
    }

    // Runs `sql` (one statement) through the statement cache.
    private QueryResult runSql(string sql, ParamEncoder encode)
    {
        foreach (attempt; 0 .. 2)
        {
            startRequest();
            bool cached;
            StatementInfo info;
            if (cache !is null)
            {
                if (auto hit = cache.get(sql))
                {
                    info = *hit;
                    cached = true;
                }
            }
            if (!cached)
            {
                info = describeStatement(sql, cache !is null ? nextStatementName("pgn_s") : "");
                if (cache !is null)
                    closeStatementLater(cache.put(info));
            }
            auto outcome = execute(info, encode, cached && attempt == 0);
            if (!outcome.retry)
                return outcome.result;
            // the cached statement was invalidated (schema change, DISCARD ALL): parse it again
            closeStatementLater(cache.remove(sql));
        }
        assert(false, "a second attempt never asks to retry");
    }

    // Runs a prepared statement (PreparedStatement.query).
    package QueryResult runStatement(StatementInfo info, ParamEncoder encode)
    {
        startRequest();
        return execute(info, encode, false).result;
    }

    /++
    Binds and executes a parsed statement: Bind, Execute, Sync (after any
    pending Close messages), then reads up to BindComplete. When
    `mayRetry` and the server reports that the statement no longer exists
    or that its result type changed outside a transaction block, the
    outcome asks for a retry instead.
    +/
    private static struct Outcome
    {
        QueryResult result;
        bool retry;
    }

    private Outcome execute(StatementInfo info, ParamEncoder encode, bool mayRetry)
    {
        Param[] params;
        try
            params = encode is null ? checkNoParameters(info) : encode(info.parameterTypes);
        catch (ClientException e)
        {
            // a Parse/Describe of this request may be waiting for its Sync
            sync();
            finishResponse();
            throw e;
        }
        bool failed;
        guarded({
            MessageBuilder b;
            appendPendingCloses(b);
            appendBindExecute(b, info, params);
            b.begin(FrontendMessage.sync);
            b.finish();
            stream.send(b.data);

            for (;;)
            {
                auto m = nextMessage();
                if (m.type == BackendMessage.bindComplete)
                    return;
                handleResponseMessage(m);
                if (m.type == BackendMessage.errorResponse)
                {
                    failed = true;
                    return;
                }
            }
        });
        if (failed)
        {
            const error = pendingError;
            try
                finishResponse();
            catch (ServerException e)
            {
                const invalidated = error.sqlState == "26000" || error.sqlState == "0A000";
                if (mayRetry && invalidated && txStatus == TransactionStatus.idle)
                    return Outcome(null, true);
                throw e;
            }
        }
        return Outcome(new QueryResult(this, info.columns, null, false), false);
    }

    // Bind (unnamed portal) and Execute (all rows) for a parsed statement.
    private void appendBindExecute(ref MessageBuilder b, const StatementInfo info, const Param[] params)
    {
        b.begin(FrontendMessage.bind);
        b.putCString(""); // the unnamed portal
        b.putCString(info.name);
        b.putInt16(cast(short) params.length);
        foreach (p; params)
            b.putInt16(p.format);
        b.putInt16(cast(short) params.length);
        foreach (p; params)
        {
            if (p.isNull)
                b.putInt32(-1);
            else
            {
                if (p.data.length > int.max)
                    throw new ClientException("A parameter value is longer than 2 GB");
                b.putInt32(cast(int) p.data.length);
                b.putBytes(p.data);
            }
        }
        b.putInt16(cast(short) info.columns.length);
        foreach (c; info.columns)
            b.putInt16(c.format);
        b.finish();
        b.begin(FrontendMessage.execute);
        b.putCString("");
        b.putInt32(0); // all rows
        b.finish();
    }

    private static Param[] checkNoParameters(const StatementInfo info)
    {
        import std.conv : to;

        if (info.parameterTypes.length)
            throw new ClientException(
                    "The statement has " ~ info.parameterTypes.length.to!string
                    ~ " parameter(s), but no values were given");
        return null;
    }

    /++
    Parses and describes `sql` as statement `name` (Parse, Describe, Flush;
    after any pending Close messages) and reads the parameter types and
    columns. No Sync is sent on success: the caller binds or syncs next.

    Throws: `ServerException` (after the Sync and the rest of the response).
    +/
    private StatementInfo describeStatement(string sql, string name)
    {
        StatementInfo info;
        info.name = name;
        info.sql = sql;
        bool failed;
        guarded({
            MessageBuilder b;
            appendPendingCloses(b);
            b.begin(FrontendMessage.parse);
            b.putCString(name);
            b.putCString(sql);
            b.putInt16(0); // the server infers parameter types
            b.finish();
            b.begin(FrontendMessage.describe);
            b.putByte('S');
            b.putCString(name);
            b.finish();
            b.begin(FrontendMessage.flush);
            b.finish();
            stream.send(b.data);

            // ParseComplete, ParameterDescription, then RowDescription or NoData
            for (;;)
            {
                auto m = nextMessage();
                switch (m.type)
                {
                case BackendMessage.parameterDescription:
                    auto body = m.body;
                    const count = body.readInt16();
                    if (count < 0)
                        throw new ProtocolException("Invalid parameter count");
                    info.parameterTypes = new uint[count];
                    foreach (ref t; info.parameterTypes)
                        t = cast(uint)
                        body.readInt32();
                    break;
                case BackendMessage.rowDescription:
                    info.columns = parseRowDescription(m.body);
                    return;
                case BackendMessage.noData:
                    return;
                case BackendMessage.errorResponse:
                    handleResponseMessage(m);
                    failed = true;
                    return;
                default:
                    handleResponseMessage(m);
                }
            }
        });
        if (failed)
        {
            sync(); // the server skips everything up to a Sync
            finishResponse(); // throws the server's error
            throw new ProtocolException("The server reported a failure without an error");
        }
        resolveColumns([info.columns]);
        return info;
    }

    private void sync()
    {
        guarded({ MessageBuilder b; b.begin(FrontendMessage.sync); b.finish(); stream.send(b.data); });
    }

    private void appendPendingCloses(ref MessageBuilder b)
    {
        foreach (name; pendingCloses)
        {
            b.begin(FrontendMessage.close);
            b.putByte('S');
            b.putCString(name);
            b.finish();
        }
        pendingCloses = null; // closing a statement that doesn't exist is not an error
    }

    private string nextStatementName(string prefix)
    {
        import std.conv : to;

        return prefix ~ (++statementCounter).to!string;
    }

    // DISCARD ALL and DEALLOCATE ALL drop every prepared statement of the session.
    private void noteCommandTag(string tag) nothrow
    {
        if (tag == "DISCARD ALL" || tag == "DEALLOCATE ALL")
        {
            if (cache !is null)
                cache.clear();
            pendingCloses = null;
            typeQueryPrepared = false;
        }
    }

    // --- data types of the database ---

    /++
    Forgets the data types of the database the connection has looked up
    (enums, composite types, domains, ...), so they are looked up again when
    next met: after `ALTER TYPE` changed a composite type, for example.
    Statements in the statement cache keep the types they were described with.
    +/
    void clearTypeCache() pure nothrow
    {
        types = null;
        missingTypes = null;
    }

    // Sets the type and the result format of each column: types of the database are looked up first (one round
    // trip, in the middle of the extended-protocol exchange, before the Bind).
    private void resolveColumns(ColumnInfo[][] lists)
    {
        import std.algorithm.searching : canFind;
        import postgresql.types.pgtype : builtinType;

        uint[] unknown;
        foreach (columns; lists)
            foreach (c; columns)
                if (builtinType(c.typeOid) is null && (c.typeOid in types) is null
                        && (c.typeOid in missingTypes) is null && !unknown.canFind(c.typeOid))
                    unknown ~= c.typeOid;
        if (unknown.length)
            lookUpTypes(unknown);
        foreach (columns; lists)
            foreach (ref c; columns)
            {
                const t = typeOf(c.typeOid);
                c.type = t;
                c.format = t !is null && t.binaryDecodable ? ValueFormat.binary : ValueFormat.text;
            }
    }

    // Sets the types of columns of the simple protocol (text format) that the connection knows; no lookup.
    private void knownTypes(ColumnInfo[] columns) nothrow
    {
        foreach (ref c; columns)
            c.type = typeOf(c.typeOid);
    }

    // The type with OID `oid`: built-in, or looked up; null if unknown.
    private const(PgType) typeOf(uint oid) nothrow
    {
        import postgresql.types.pgtype : builtinType;

        if (auto t = builtinType(oid))
            return t;
        if (auto t = oid in types)
            return *t;
        return null;
    }

    private static struct TypeRow
    {
        string name;
        char kind; // pg_type.typtype, or 'a' for arrays
        uint element; // array element, domain base, range subtype, multirange's range
        char delimiter;
        string[] fieldNames;
        uint[] fieldTypes;
    }

    // Looks up types in pg_type, and the types they are made of, until all are known.
    private void lookUpTypes(uint[] oids)
    {
        import std.algorithm.searching : canFind;
        import postgresql.types.pgtype : builtinType, TypeKind;

        TypeRow[uint] rows;
        while (oids.length)
        {
            foreach (oid, row; queryTypes(oids))
                rows[oid] = row;
            uint[] next;
            void need(uint oid)
            {
                if (oid != 0 && builtinType(oid) is null && (oid in types) is null && (oid in rows) is null
                        && (oid in missingTypes) is null && !next.canFind(oid))
                    next ~= oid;
            }

            foreach (oid; oids)
            {
                auto row = oid in rows;
                if (row is null)
                {
                    missingTypes[oid] = true;
                    continue;
                }
                need(row.element);
                foreach (f; row.fieldTypes)
                    need(f);
            }
            oids = next;
        }

        PgType build(uint oid)
        {
            if (auto t = builtinType(oid))
                return t;
            if (auto t = oid in types)
                return *t;
            auto row = oid in rows;
            if (row is null)
                return null;
            TypeKind kind;
            switch (row.kind)
            {
            case 'a':
                kind = TypeKind.array;
                break;
            case 'c':
                kind = TypeKind.composite;
                break;
            case 'd':
                kind = TypeKind.domain;
                break;
            case 'e':
                kind = TypeKind.enum_;
                break;
            case 'r':
                kind = TypeKind.range;
                break;
            case 'm':
                kind = TypeKind.multirange;
                break;
            case 'p':
                kind = TypeKind.pseudo;
                break;
            default:
                kind = TypeKind.base;
            }
            auto t = new PgType(oid, row.name, kind, row.element ? build(row.element) : null, row.delimiter);
            types[oid] = t;
            t.fieldNames = row.fieldNames;
            foreach (f; row.fieldTypes)
                t.fieldTypes ~= build(f);
            return t;
        }

        foreach (oid, _; rows)
            build(oid);
    }

    // Runs the pg_type query for `oids` (Bind, Execute, Flush; the statement is prepared once per session).
    private TypeRow[uint] queryTypes(const uint[] oids)
    {
        TypeRow[uint] result;
        bool failed;
        guarded({
            MessageBuilder b;
            if (!typeQueryPrepared)
            {
                // a statement of that name left from before a DISCARD is closed first (no error if none)
                b.begin(FrontendMessage.close);
                b.putByte('S');
                b.putCString(typeQueryName);
                b.finish();
                b.begin(FrontendMessage.parse);
                b.putCString(typeQueryName);
                b.putCString(typeQuerySql(serverVersionNumber >= 140_000));
                b.putInt16(0);
                b.finish();
            }
            b.begin(FrontendMessage.bind);
            b.putCString("");
            b.putCString(typeQueryName);
            b.putInt16(1);
            b.putInt16(1); // the parameter in binary: oid[]
            b.putInt16(1);
            auto array = oidArray(oids);
            b.putInt32(cast(int) array.length);
            b.putBytes(array);
            b.putInt16(1);
            b.putInt16(1); // all results in binary
            b.finish();
            b.begin(FrontendMessage.execute);
            b.putCString("");
            b.putInt32(0);
            b.finish();
            b.begin(FrontendMessage.flush);
            b.finish();
            stream.send(b.data);

            static ColumnInfo[] columns;
            if (columns is null)
            {
                import postgresql.types.pgtype : builtinType;

                foreach (oid; [Oid.oid, Oid.name, Oid.text, Oid.oid, Oid.char_, 1009u, 1028u])
                {
                    ColumnInfo c;
                    c.typeOid = oid;
                    c.format = ValueFormat.binary;
                    c.type = builtinType(oid);
                    columns ~= c;
                }
            }
            for (;;)
            {
                auto m = nextMessage();
                switch (m.type)
                {
                case BackendMessage.parseComplete, BackendMessage.closeComplete:
                    break;
                case BackendMessage.bindComplete:
                    typeQueryPrepared = true;
                    break;
                case BackendMessage.dataRow:
                    const row = parseDataRow(m.body, columns);
                    TypeRow t;
                    t.name = row.getString(1);
                    const kind = row.getString(2);
                    t.kind = kind.length ? kind[0] : 'b';
                    t.element = row.get!uint(3);
                    const delimiter = row.getString(4);
                    t.delimiter = delimiter.length ? delimiter[0] : ',';
                    t.fieldNames = row.get!(string[])(5);
                    t.fieldTypes = row.get!(uint[])(6);
                    result[row.get!uint(0)] = t;
                    break;
                case BackendMessage.commandComplete:
                    return;
                case BackendMessage.errorResponse:
                    handleResponseMessage(m);
                    failed = true;
                    return;
                default:
                    handleResponseMessage(m);
                }
            }
        });
        if (failed)
        {
            sync();
            finishResponse(); // throws the server's error
            throw new ProtocolException("The server reported a failure without an error");
        }
        return result;
    }

    // An oid[] in binary format.
    private static immutable(ubyte)[] oidArray(const uint[] oids) pure
    {
        ubyte[] data;
        void int32(uint v)
        {
            data ~= [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
        }

        int32(1); // dimensions
        int32(0); // no NULLs
        int32(Oid.oid);
        int32(cast(uint) oids.length);
        int32(1); // lower bound
        foreach (oid; oids)
        {
            int32(4);
            int32(oid);
        }
        return (() @trusted => cast(immutable) data)(); // not referenced elsewhere
    }

    private enum typeQueryName = "pgn_types";

    // The pg_type query: name, kind ('a' for arrays), element/base/subtype/range, delimiter, composite fields.
    private static string typeQuerySql(bool multiranges) pure
    {
        enum multirangeCase = " WHEN t.typtype = 'm' THEN"
            ~ " (SELECT r.rngtypid FROM pg_catalog.pg_range r WHERE r.rngmultitypid = t.oid)";
        return "SELECT t.oid, t.typname, CASE WHEN t.typelem <> 0 AND t.typlen = -1 THEN 'a' ELSE t.typtype::text END,"
            ~ " CASE WHEN t.typtype = 'd' THEN t.typbasetype"
            ~ " WHEN t.typtype = 'r' THEN (SELECT r.rngsubtype FROM pg_catalog.pg_range r WHERE r.rngtypid = t.oid)"
            ~ (
                    multiranges ? multirangeCase : "") ~ " ELSE t.typelem END,"
            ~ " t.typdelim,"
            ~ " ARRAY(SELECT a.attname::text FROM pg_catalog.pg_attribute a"
            ~ " WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum),"
            ~ " ARRAY(SELECT a.atttypid FROM pg_catalog.pg_attribute a"
            ~ " WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum)"
            ~ " FROM pg_catalog.pg_type t WHERE t.oid = ANY($1::pg_catalog.oid[])";
    }

    /++
    Runs one or more SQL statements with the simple query protocol and
    returns the rows of the first one, read as the result is iterated. All
    values are in text format (the getters parse them). The rest of the
    response is read and discarded when the result ends.

    Throws: `ServerException`, from here or from the result.
    +/
    QueryResult querySimple(string sql)
    {
        startSimpleQuery(sql);
        ColumnInfo[] columns;
        string tag;
        bool rowsDone;
        guarded({
            for (;;)
            {
                auto m = nextMessage();
                switch (m.type)
                {
                case BackendMessage.rowDescription:
                    columns = parseRowDescription(m.body);
                    knownTypes(columns);
                    return;
                case BackendMessage.commandComplete:
                    tag = m.body.readCString();
                    noteCommandTag(tag);
                    rowsDone = true;
                    return;
                case BackendMessage.emptyQueryResponse:
                    rowsDone = true;
                    return;
                case BackendMessage.readyForQuery:
                    readyForQuery(m);
                    rowsDone = true;
                    return;
                case BackendMessage.errorResponse:
                    handleResponseMessage(m);
                    rowsDone = true;
                    return;
                default:
                    handleResponseMessage(m);
                }
            }
        });
        return new QueryResult(this, columns, tag, rowsDone);
    }

    // --- pipelines ---

    /++
    A pipeline for this connection: statements sent together and answered
    in order (see `postgresql.pipeline`).
    +/
    Pipeline pipeline(PipelineMode mode = PipelineMode.transaction)
    {
        return new Pipeline(this, mode);
    }

    // Runs the statements of a pipeline (Pipeline.run).
    package PipelineResult[] runPipeline(string[] sqls, ParamEncoder[] encoders, bool transactional)
    {
        startRequest();
        auto infos = new StatementInfo[sqls.length];
        size_t[] toDescribe;
        string[] temporary; // statement names to close afterwards when there is no cache
        size_t[string] described; // SQL text -> index of the statement described in this pipeline
        foreach (i, sql; sqls)
        {
            if (cache !is null)
                if (auto hit = cache.get(sql))
                {
                    infos[i] = *hit;
                    continue;
                }
            if (auto earlier = sql in described)
                continue; // filled in after the description below
            infos[i].sql = sql;
            infos[i].name = nextStatementName(cache !is null ? "pgn_s" : "pgn_t");
            if (cache is null)
                temporary ~= infos[i].name;
            described[sql] = i;
            toDescribe ~= i;
        }
        scope (exit)
            foreach (name; temporary)
                closeStatementLater(name);

        if (toDescribe.length)
            describeStatements(infos, toDescribe);
        foreach (i, sql; sqls)
            if (infos[i].name.length == 0 && infos[i].columns.length == 0 && infos[i].parameterTypes.length == 0)
                if (auto first = sql in described)
                    infos[i] = infos[*first];

        // encode everything before sending anything
        auto params = new Param[][sqls.length];
        try
            foreach (i; 0 .. sqls.length)
                params[i] = encoders[i] is null ? checkNoParameters(infos[i]) : encoders[i](infos[i].parameterTypes);
                catch (ClientException e)
                {
                    if (toDescribe.length)
                    {
                        sync();
                        finishResponse();
                    }
                    else
                        state = State.ready;
                    throw e;
                }

        auto results = new PipelineResult[sqls.length];
        guarded({
            MessageBuilder b;
            appendPendingCloses(b);
            foreach (i, info; infos)
            {
                appendBindExecute(b, info, params[i]);
                if (!transactional)
                {
                    b.begin(FrontendMessage.sync);
                    b.finish();
                }
            }
            if (transactional)
            {
                b.begin(FrontendMessage.sync);
                b.finish();
            }
            stream.send(b.data);

            const zone = parameterStatus("TimeZone");
            bool aborted;
            foreach (i, info; infos)
            {
                auto r = &results[i];
                r.columns = info.columns;
                if (aborted)
                {
                    r.skipped = true;
                    continue;
                }
                readStatement: for (;;)
                {
                    auto m = nextMessage();
                    switch (m.type)
                    {
                    case BackendMessage.bindComplete:
                        break;
                    case BackendMessage.dataRow:
                        r.rows ~= parseDataRow(m.body, info.columns, zone);
                        break;
                    case BackendMessage.commandComplete:
                        r.commandTag = m.body.readCString();
                        noteCommandTag(r.commandTag);
                        break readStatement;
                    case BackendMessage.emptyQueryResponse, BackendMessage.portalSuspended:
                        break readStatement;
                    case BackendMessage.errorResponse:
                        r.failed = true;
                        r.error = ServerMessage.parse(m.body);
                        if (r.error.isFatal)
                        {
                            close();
                            throw new ServerException(r.error);
                        }
                        if (cache !is null && (r.error.sqlState == "26000" || r.error.sqlState == "0A000"))
                            closeStatementLater(cache.remove(info.sql));
                        aborted = transactional;
                        break readStatement;
                    default:
                        throw new ProtocolException("Unexpected message '" ~ m.type ~ "' in a pipeline");
                    }
                }
                if (!transactional)
                    readSyncPoint(i + 1 == infos.length);
            }
            if (transactional)
                readSyncPoint(true);
        });
        return results;
    }

    // Reads up to the ReadyForQuery of a Sync; the connection stays busy unless it is the last one.
    private void readSyncPoint(bool last)
    {
        for (;;)
        {
            auto m = nextMessage();
            if (m.type == BackendMessage.readyForQuery)
            {
                readyForQuery(m);
                if (!last)
                {
                    state = State.busy;
                    responseDone = false;
                }
                return;
            }
            if (m.type != BackendMessage.commandComplete && m.type != BackendMessage.emptyQueryResponse)
                throw new ProtocolException("Unexpected message '" ~ m.type ~ "' before ReadyForQuery");
        }
    }

    // Parses and describes several statements in one round trip (pipelines); throws the first parse error.
    private void describeStatements(StatementInfo[] infos, const size_t[] indexes)
    {
        bool failed;
        guarded({
            MessageBuilder b;
            appendPendingCloses(b);
            foreach (i; indexes)
            {
                b.begin(FrontendMessage.parse);
                b.putCString(infos[i].name);
                b.putCString(infos[i].sql);
                b.putInt16(0);
                b.finish();
                b.begin(FrontendMessage.describe);
                b.putByte('S');
                b.putCString(infos[i].name);
                b.finish();
            }
            b.begin(FrontendMessage.flush);
            b.finish();
            stream.send(b.data);
            foreach (i; indexes)
            {
                describing: for (;;)
                {
                    auto m = nextMessage();
                    switch (m.type)
                    {
                    case BackendMessage.parameterDescription:
                        auto body = m.body;
                        const count = body.readInt16();
                        if (count < 0)
                            throw new ProtocolException("Invalid parameter count");
                        infos[i].parameterTypes = new uint[count];
                        foreach (ref t; infos[i].parameterTypes)
                            t = cast(uint)
                            body.readInt32();
                        break;
                    case BackendMessage.rowDescription:
                        infos[i].columns = parseRowDescription(m.body);
                        break describing;
                    case BackendMessage.noData:
                        break describing;
                    case BackendMessage.errorResponse:
                        handleResponseMessage(m);
                        failed = true;
                        return;
                    default:
                        handleResponseMessage(m);
                    }
                }
            }
        });
        if (failed)
        {
            sync();
            finishResponse(); // throws the parse error
            throw new ProtocolException("The server reported a failure without an error");
        }
        ColumnInfo[][] lists;
        foreach (i; indexes)
            lists ~= infos[i].columns;
        resolveColumns(lists);
        foreach (i; indexes)
        {
            if (cache !is null)
                closeStatementLater(cache.put(infos[i]));
        }
    }

    // --- transactions ---

    /++
    Starts a transaction block (`BEGIN`), with an isolation level, read-only
    and deferrable (for `serializable` read-only transactions) when given.

    Throws: `ServerException` (e.g. a warning-free `BEGIN` inside a block is
    only a notice, so the server's state decides: check `inTransaction`).
    +/
    void begin(IsolationLevel level = IsolationLevel.default_, bool readOnly = false, bool deferrable = false)
    {
        exec("BEGIN" ~ transactionModes(level, readOnly, deferrable));
    }

    /// Commits the transaction block (`COMMIT`); a failed block is rolled back by the server.
    void commit()
    {
        exec("COMMIT");
    }

    /// Rolls the transaction block back (`ROLLBACK`).
    void rollback()
    {
        exec("ROLLBACK");
    }

    /// Sets a savepoint (`SAVEPOINT name`) in the current transaction block.
    void savepoint(string name)
    {
        exec("SAVEPOINT " ~ quoteIdentifier(name));
    }

    /// Rolls back to a savepoint (`ROLLBACK TO SAVEPOINT name`); also ends a failed state since it.
    void rollbackTo(string name)
    {
        exec("ROLLBACK TO SAVEPOINT " ~ quoteIdentifier(name));
    }

    /// Forgets a savepoint, keeping its changes (`RELEASE SAVEPOINT name`).
    void releaseSavepoint(string name)
    {
        exec("RELEASE SAVEPOINT " ~ quoteIdentifier(name));
    }

    /++
    Sets the defaults of the session's later transactions
    (`SET SESSION CHARACTERISTICS AS TRANSACTION ...`).
    +/
    void setSessionDefaults(IsolationLevel level, bool readOnly = false, bool deferrable = false)
    {
        exec("SET SESSION CHARACTERISTICS AS TRANSACTION" ~ (level == IsolationLevel.default_
                ? " ISOLATION LEVEL READ COMMITTED" : "") ~ transactionModes(level, readOnly, deferrable, true));
    }

    /// Whether a transaction block is open (it may be failed).
    @property bool inTransaction() const pure nothrow
    {
        return txStatus != TransactionStatus.idle;
    }

    /// Whether the transaction block is failed: statements are refused until `rollback` (or `rollbackTo`).
    @property bool transactionFailed() const pure nothrow
    {
        return txStatus == TransactionStatus.failed;
    }

    private static string transactionModes(IsolationLevel level, bool readOnly, bool deferrable,
            bool explicitWrite = false) pure
    {
        string s;
        final switch (level)
        {
        case IsolationLevel.default_:
            break;
        case IsolationLevel.readUncommitted:
            s ~= " ISOLATION LEVEL READ UNCOMMITTED";
            break;
        case IsolationLevel.readCommitted:
            s ~= " ISOLATION LEVEL READ COMMITTED";
            break;
        case IsolationLevel.repeatableRead:
            s ~= " ISOLATION LEVEL REPEATABLE READ";
            break;
        case IsolationLevel.serializable:
            s ~= " ISOLATION LEVEL SERIALIZABLE";
            break;
        }
        if (readOnly)
            s ~= (s.length ? "," : "") ~ " READ ONLY";
        else if (explicitWrite)
            s ~= (s.length ? "," : "") ~ " READ WRITE";
        if (deferrable)
            s ~= (s.length ? "," : "") ~ " DEFERRABLE";
        else if (explicitWrite)
            s ~= (s.length ? "," : "") ~ " NOT DEFERRABLE";
        return s;
    }

    // --- cancel ---

    /++
    Asks the server to cancel the statement running on this connection: a
    CancelRequest sent over a second connection (encrypted like this one).
    The statement then fails with a `ServerException` of SQLSTATE 57014,
    and the connection stays usable.

    This is the one method that may be called from another thread or task
    while the connection is busy. It does nothing if no request is running.
    Like every PostgreSQL client's cancel, it races with the end of the
    statement: if that ends first, the cancel may hit the next statement
    of the session, or nothing.

    Throws: `ConnectionException` if the server can't be reached.
    +/
    void cancel()
    {
        import dbwire.io.backend : IoMode;

        if (state != State.busy || cancelKey.length == 0)
            return;
        auto io = backendFor(IoMode.auto_); // the caller's context: another thread or task
        auto endpoint = connectedHost;
        auto raw = options.transportFactory !is null
            ? options.transportFactory(endpoint.host, endpoint.port, options.connectTimeout) : io.connect(
                    endpoint.host, endpoint.port, options.connectTimeout);
        Transport t = raw;
        scope (exit)
            t.close();
        raw.setTimeouts(options.connectTimeout, options.connectTimeout);
        if (encryptionUsed != Encryption.none)
        {
            const direct = encryptionUsed == Encryption.direct;
            if (!direct)
            {
                static immutable ubyte[8] sslRequest = [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F];
                raw.write(sslRequest[]);
                ubyte[1] answer;
                if (raw.read(answer[]) != 1 || answer[0] != 'S' || raw.dataAvailable())
                    throw new ConnectionException("The server refused TLS for the cancel request");
            }
            auto opts = tlsOptions(direct);
            t = new TlsTransport(raw, io, TlsContext.client(opts), endpoint.host, opts, options.connectTimeout);
        }
        MessageBuilder b;
        b.begin(0);
        b.putInt32(RequestCode.cancel);
        b.putInt32(backendPid);
        b.putBytes(cancelKey);
        b.finish();
        t.write(b.data);
        // the server answers nothing and closes the connection once it has handled the request
        try
        {
            ubyte[1] none;
            t.read(none[]);
        }
        catch (ConnectionException)
        {
        }
    }

    /++
    Makes the session as a new one would be, except for the prepared
    statements of the statement cache, which stay valid: rolls back an open
    transaction, then does what `DISCARD ALL` does but `DEALLOCATE ALL`
    (closes cursors, resets the session authorization and all run-time
    parameters to their startup values, stops listening, releases advisory
    locks, drops temporary tables and sequence state). Without a statement
    cache it runs `DISCARD ALL`. Untaken notifications are dropped.
    `ConnectionPool` calls it when a connection is returned.

    Throws: `ServerException`, `ConnectionException`.
    +/
    void resetSession()
    {
        if (txStatus != TransactionStatus.idle)
            exec("ROLLBACK");
        if (cache is null)
            exec("DISCARD ALL");
        else
            exec("CLOSE ALL; SET SESSION AUTHORIZATION DEFAULT; RESET ALL; UNLISTEN *; "
                    ~ "SELECT pg_catalog.pg_advisory_unlock_all(); DISCARD SEQUENCES; DISCARD TEMP");
        notifications = null;
    }

    /// Checks that the server answers (an empty query).
    void ping()
    {
        exec("");
    }

    /// Closes the connection, telling the server first when possible. Calling it again does nothing.
    void close() nothrow
    {
        if (state == State.closed)
            return;
        const wasReady = state == State.ready;
        state = State.closed;
        if (wasReady)
        {
            try
            {
                static immutable ubyte[5] terminate = [FrontendMessage.terminate, 0, 0, 0, 4];
                stream.send(terminate[]);
            }
            catch (Exception)
            {
            }
        }
        if (transport !is null)
            transport.close();
    }

    // --- results ---

    /// Reads the next row of the current result; `has` is false at its end (CommandComplete or an error).
    package void nextRow(const(ColumnInfo)[] columns, string timeZone, ref Row row, ref bool has, ref string tag)
    {
        has = false;
        guarded({
            for (;;)
            {
                auto m = nextMessage();
                switch (m.type)
                {
                case BackendMessage.dataRow:
                    row = parseDataRow(m.body, columns, timeZone);
                    has = true;
                    return;
                case BackendMessage.commandComplete:
                    tag = m.body.readCString();
                    noteCommandTag(tag);
                    return;
                case BackendMessage.emptyQueryResponse, BackendMessage.portalSuspended:
                    return;
                case BackendMessage.readyForQuery:
                    readyForQuery(m);
                    return;
                case BackendMessage.errorResponse:
                    handleResponseMessage(m);
                    return;
                default:
                    handleResponseMessage(m);
                }
            }
        });
    }

    /++
    After the rows of one statement: reads on to the next statement that
    returns rows (true, its columns in `columns`) or to the end of the
    response (false).
    +/
    package bool nextResult(ref ColumnInfo[] columns)
    {
        bool found;
        if (state == State.closed)
            return false;
        guarded({
            while (!responseDone)
            {
                auto m = nextMessage();
                switch (m.type)
                {
                case BackendMessage.rowDescription:
                    columns = parseRowDescription(m.body);
                    knownTypes(columns);
                    found = true;
                    return;
                case BackendMessage.commandComplete:
                    noteCommandTag(m.body.readCString());
                    break;
                case BackendMessage.readyForQuery:
                    readyForQuery(m);
                    break;
                default:
                    handleResponseMessage(m);
                }
            }
        });
        return found;
    }

    /++
    Reads the rest of the current response up to ReadyForQuery, discarding
    rows, then throws the first error of the response, if any.
    +/
    package void finishResponse()
    {
        if (state == State.closed)
            return;
        guarded({
            while (!responseDone)
            {
                auto m = nextMessage();
                if (m.type == BackendMessage.readyForQuery)
                    readyForQuery(m);
                else
                    handleResponseMessage(m);
            }
        });
        throwPendingError();
    }

    // --- message handling ---

    // Marks the connection busy with a new request.
    private void startRequest()
    {
        checkReady();
        state = State.busy;
        responseDone = false;
        hasPendingError = false;
    }

    private void startSimpleQuery(string sql)
    {
        MessageBuilder b;
        b.begin(FrontendMessage.query);
        b.putCString(sql);
        b.finish();
        startRequest();
        guarded({ stream.send(b.data); });
    }

    /// Reads the next message, handling asynchronous ones (notices, parameter changes, notifications).
    private Message nextMessage()
    {
        for (;;)
        {
            auto m = stream.read();
            switch (m.type)
            {
            case BackendMessage.noticeResponse:
                notice(ServerMessage.parse(m.body));
                break;
            case BackendMessage.parameterStatus:
                auto b = m.body;
                const name = b.readCString();
                parameters[name] = b.readCString();
                break;
            case BackendMessage.notificationResponse:
                auto b = m.body;
                Notification n;
                n.processId = b.readInt32();
                n.channel = b.readCString();
                n.payload = b.readCString();
                notifications ~= n;
                break;
            default:
                return m;
            }
        }
    }

    // Handles a message of a response that the caller doesn't need.
    private void handleResponseMessage(Message m)
    {
        switch (m.type)
        {
        case BackendMessage.errorResponse:
            const error = ServerMessage.parse(m.body);
            if (error.isFatal)
            {
                close();
                throw new ServerException(error);
            }
            if (!hasPendingError)
            {
                pendingError = error;
                hasPendingError = true;
            }
            break;
        case BackendMessage.rowDescription, BackendMessage.dataRow, BackendMessage.commandComplete,
            BackendMessage.emptyQueryResponse, BackendMessage.parseComplete, BackendMessage.bindComplete,
            BackendMessage.closeComplete, BackendMessage.parameterDescription, BackendMessage.noData,
            BackendMessage.portalSuspended:
            break; // results not asked for, extended-protocol acknowledgements
        case BackendMessage.copyInResponse:
            // COPY FROM STDIN needs data the caller didn't give: abort it (the server answers with an error)
            MessageBuilder b;
            b.begin(FrontendMessage.copyFail);
            b.putCString("COPY FROM STDIN is not supported by this call");
            b.finish();
            stream.send(b.data);
            break;
        case BackendMessage.copyOutResponse, BackendMessage.copyData, BackendMessage.copyDone:
            break; // COPY TO STDOUT data not asked for
        default:
            throw new ProtocolException("Unexpected message '" ~ m.type ~ "' from the server");
        }
    }

    private void readyForQuery(Message m)
    {
        auto b = m.body;
        const status = b.readByte();
        if (status != 'I' && status != 'T' && status != 'E')
            throw new ProtocolException("Invalid transaction status in ReadyForQuery");
        txStatus = cast(TransactionStatus) status;
        responseDone = true;
        state = State.ready;
    }

    private void throwPendingError()
    {
        if (hasPendingError)
        {
            hasPendingError = false;
            throw new ServerException(pendingError);
        }
    }

    private void notice(ServerMessage n)
    {
        if (onNotice !is null)
            onNotice(n);
    }

    /++
    Runs `action`. A `ServerException` leaves the connection as the server
    left it; any other exception means the stream is in an unknown state, so
    the connection is closed.
    +/
    package void guarded(scope void delegate() @safe action)
    {
        try
            action();
        catch (ServerException e)
            throw e;
        catch (Exception e)
        {
            close();
            throw e;
        }
    }

    package void checkReady() const
    {
        if (state == State.closed)
            throw new ClientException("The connection is closed");
        if (state == State.busy)
            throw new ClientException("The connection is busy: read or close the previous query result first");
    }

    // --- connecting ---

    private void connect()
    {
        backend = backendFor(options.ioMode);
        auto hosts = options.hosts.length ? options.hosts.dup : [
            HostPort(options.host, options.port)
        ];
        foreach (ref h; hosts)
            h.port = ConnectionOptions.effectivePort(h.port);
        auto ordered = orderHosts(hosts, options.hostSelection);
        auto target = options.targetSessionAttrs;
        void tryHost(HostPort endpoint) @safe
        {
            connectTo(endpoint);
            checkSession(target);
        }

        if (target == TargetSessionAttrs.preferStandby)
        {
            // as libpq: a standby first, then any server
            target = TargetSessionAttrs.standby;
            try
            {
                connectedHost = connectFirst(ordered, &tryHost, "PostgreSQL");
                return;
            }
            catch (ConnectionException)
                target = TargetSessionAttrs.any;
        }
        connectedHost = connectFirst(ordered, &tryHost, "PostgreSQL");
    }

    // Closes the connection with a ConnectionException (so the next host is tried) if
    // the session doesn't match `target`.
    private void checkSession(TargetSessionAttrs target)
    {
        final switch (target)
        {
        case TargetSessionAttrs.any:
            return;
        case TargetSessionAttrs.readWrite, TargetSessionAttrs.readOnly:
            const readOnly = isReadOnly();
            if (readOnly == (target == TargetSessionAttrs.readWrite))
                rejectSession(readOnly ? "read-only" : "not read-only", target);
            return;
        case TargetSessionAttrs.primary, TargetSessionAttrs.standby, TargetSessionAttrs.preferStandby:
            const standby = isStandby();
            if (standby == (target == TargetSessionAttrs.primary))
                rejectSession(standby ? "a standby" : "not a standby", target);
            return;
        }
    }

    private void rejectSession(string state, TargetSessionAttrs target)
    {
        import std.conv : to;

        close();
        throw new ConnectionException("The server at " ~ attemptHost.toString() ~ " is " ~ state
                ~ " (target_session_attrs " ~ target.to!string ~ ")");
    }

    // Whether the session doesn't accept writes by default: a hot standby or
    // default_transaction_read_only on (reported from PostgreSQL 14, else asked).
    private bool isReadOnly()
    {
        auto standby = "in_hot_standby" in parameters;
        auto defaultReadOnly = "default_transaction_read_only" in parameters;
        if (standby && defaultReadOnly)
            return *standby == "on" || *defaultReadOnly == "on";
        return queryText("SHOW transaction_read_only") == "on";
    }

    // Whether the server is in recovery (in_hot_standby from PostgreSQL 14, else asked).
    private bool isStandby()
    {
        if (auto standby = "in_hot_standby" in parameters)
            return *standby == "on";
        return queryText("SELECT pg_catalog.pg_is_in_recovery()") == "t";
    }

    // The first value of a simple query.
    private string queryText(string sql)
    {
        auto r = querySimple(sql);
        scope (exit)
            r.close();
        if (r.empty)
            throw new ProtocolException("No row for " ~ sql);
        return r.front.getString(0);
    }

    private enum Encryption
    {
        none, /// plain TCP
        sslRequest, /// SSLRequest, then TLS if the server agrees
        direct, /// TLS from the first byte (PostgreSQL 17+)
    }

    private void connectTo(HostPort endpoint)
    {
        const mode = options.sslMode;
        if (options.sslNegotiation == SslNegotiation.direct)
        {
            if (mode < SslMode.require)
                throw new ClientException("sslnegotiation=direct needs sslmode=require, verify-ca or verify-full");
            attempt(endpoint, Encryption.direct);
            return;
        }
        final switch (mode)
        {
        case SslMode.disable:
            attempt(endpoint, Encryption.none);
            break;
        case SslMode.allow:
            try
                attempt(endpoint, Encryption.none);
            catch (ServerException e)
            {
                // the server refused the unencrypted connection (e.g. a hostssl-only pg_hba.conf entry)
                if (!tlsAvailable())
                    throw e;
                attempt(endpoint, Encryption.sslRequest);
            }
            break;
        case SslMode.prefer:
            if (!tlsAvailable())
            {
                attempt(endpoint, Encryption.none);
                break;
            }
            try
                attempt(endpoint, Encryption.sslRequest);
            catch (TlsHandshakeFailed)
                attempt(endpoint, Encryption.none); // as libpq: retry without TLS
            break;
        case SslMode.require, SslMode.verifyCa, SslMode.verifyFull:
            attempt(endpoint, Encryption.sslRequest);
            break;
        }
    }

    // Whether OpenSSL and the TLS settings work, for the modes where TLS is optional.
    private bool tlsAvailable()
    {
        try
        {
            TlsContext.client(tlsOptions(false));
            return true;
        }
        catch (ClientException)
            return false;
    }

    private TlsOptions tlsOptions(bool direct)
    {
        import postgresql.userfiles : userDirectory, userFile;

        TlsOptions t = options.tls;
        // libpq's defaults: the files in ~/.postgresql, when they exist
        if (t.caFile.length == 0)
            t.caFile = userFile("root.crt");
        if (t.certFile.length == 0)
        {
            import std.path : buildPath;

            t.certFile = userFile("postgresql.crt");
            if (t.certFile.length && t.keyFile.length == 0)
                t.keyFile = buildPath(userDirectory(), "postgresql.key");
        }
        if (t.caFile == "system")
        {
            if (options.sslMode != SslMode.verifyFull)
                throw new ClientException("sslrootcert=system needs sslmode=verify-full");
            t.caFile = null;
        }
        final switch (options.sslMode)
        {
        case SslMode.disable, SslMode.allow, SslMode.prefer:
            t.skipVerify = true;
            break;
        case SslMode.require:
            // as libpq: a CA file given means verify-ca
            t.skipVerify = t.caFile.length == 0;
            t.skipNameCheck = true;
            break;
        case SslMode.verifyCa:
            t.skipNameCheck = true;
            break;
        case SslMode.verifyFull:
            break;
        }
        if (direct)
            t.alpn = ["postgresql"];
        return t;
    }

    private void attempt(HostPort endpoint, Encryption encryption)
    {
        auto raw = options.transportFactory !is null
            ? options.transportFactory(endpoint.host, endpoint.port, options.connectTimeout) : backend.connect(
                    endpoint.host, endpoint.port, options.connectTimeout);
        transport = raw;
        tls = null;
        attemptHost = endpoint;
        state = State.busy;
        scope (failure)
            close();
        raw.setTimeouts(options.connectTimeout, options.connectTimeout);

        if (encryption == Encryption.sslRequest)
        {
            static immutable ubyte[8] sslRequest = [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F];
            raw.write(sslRequest[]);
            ubyte[1] answer;
            if (raw.read(answer[]) != 1)
                throw new ConnectionException("The server closed the connection after the SSLRequest");
            if (answer[0] == 'S')
            {
                // Bytes after the 'S' before the handshake were not protected by TLS (CVE-2021-23222)
                if (raw.dataAvailable())
                    throw new ProtocolException("Unencrypted data received after the server agreed to TLS");
                startTls(raw, endpoint, false);
            }
            else if (answer[0] == 'N')
            {
                if (options.sslMode >= SslMode.require)
                    throw new ConnectionException("The server does not support TLS, but sslmode requires it");
            }
            else
                throw new ProtocolException("Invalid answer to the SSLRequest");
        }
        else if (encryption == Encryption.direct)
            startTls(raw, endpoint, true);

        stream = new MessageStream(transport);
        startup();
        transport.setTimeouts(options.receiveTimeout, options.sendTimeout);
        encryptionUsed = tls is null ? Encryption.none : encryption;
        state = State.ready;
    }

    private void startTls(Transport raw, HostPort endpoint, bool direct)
    {
        auto t = tlsOptions(direct);
        auto context = TlsContext.client(t);
        try
            tls = new TlsTransport(raw, backend, context, endpoint.host, t, options.connectTimeout);
        catch (ConnectionException e)
            throw new TlsHandshakeFailed("TLS handshake with " ~ endpoint.toString() ~ " failed: " ~ e.msg);
        transport = tls;
        if (direct && tls.alpnProtocol != "postgresql")
            throw new ConnectionException("The server did not select the ALPN protocol 'postgresql' for direct TLS");
    }

    private void startup()
    {
        import std.process : environment;

        string user = options.user;
        if (user.length == 0)
            user = environment.get("USER", environment.get("USERNAME", ""));
        if (user.length == 0)
            throw new ClientException("No user name given");

        MessageBuilder b;
        b.begin(0);
        b.putInt32(options.maxProtocolVersion == ProtocolVersion.v32 ? protocol32 : protocol30);
        void param(string name, string value)
        {
            b.putCString(name);
            b.putCString(value);
        }

        param("user", user);
        param("database", options.database.length ? options.database : user);
        if (options.applicationName.length)
            param("application_name", options.applicationName);
        param("client_encoding", "UTF8");
        param("DateStyle", "ISO");
        if (options.serverOptions.length)
            param("options", options.serverOptions);
        if (options.statementTimeout > Duration.zero)
        {
            import std.conv : to;

            param("statement_timeout", options.statementTimeout
                    .total!"msecs"
                    .to!string);
        }
        foreach (name, value; options.runtimeParameters)
            param(name, value);
        b.putByte(0);
        b.finish();
        stream.send(b.data);
        protocol = options.maxProtocolVersion == ProtocolVersion.v32 ? protocol32 : protocol30;

        authenticate(user);

        // ParameterStatus, BackendKeyData and notices, up to ReadyForQuery
        for (;;)
        {
            auto m = stream.read();
            switch (m.type)
            {
            case BackendMessage.parameterStatus:
                auto p = m.body;
                const name = p.readCString();
                parameters[name] = p.readCString();
                break;
            case BackendMessage.backendKeyData:
                auto k = m.body;
                backendPid = k.readInt32();
                const key = k.readRest();
                if (key.length < 4 || key.length > 256)
                    throw new ProtocolException("Invalid cancel key length");
                cancelKey = key.idup;
                break;
            case BackendMessage.noticeResponse:
                notice(ServerMessage.parse(m.body));
                break;
            case BackendMessage.negotiateProtocolVersion:
                negotiateVersion(m);
                break;
            case BackendMessage.errorResponse:
                throw new ServerException(ServerMessage.parse(m.body));
            case BackendMessage.readyForQuery:
                readyForQuery(m);
                return;
            default:
                throw new ProtocolException("Unexpected message '" ~ m.type ~ "' during startup");
            }
        }
    }

    private void negotiateVersion(Message m)
    {
        auto b = m.body;
        // The newest version the server supports: a full version (major << 16 | minor) from
        // PostgreSQL 13 (checked), just the minor version in the protocol documentation
        const value = cast(uint) b.readInt32();
        if (value > 0xFFFF && value >> 16 != 3)
            throw new ProtocolException("Invalid NegotiateProtocolVersion");
        const minor = value & 0xFFFF;
        if (minor > (protocol & 0xFFFF))
            throw new ProtocolException("Invalid NegotiateProtocolVersion");
        protocol = protocol30 | minor;
    }

    private void authenticate(string user)
    {
        const requirement = parseRequireAuth(options.requireAuth);
        void allow(string method, string description)
        {
            if (!requirement.allows(method))
                throw new ClientException(
                        "The server asks for " ~ description
                        ~ " authentication, which require_auth doesn't allow");
            if (options.channelBinding == ChannelBinding.require && method != "scram-sha-256")
                throw new ClientException(
                        "channel_binding=require, but the server asks for " ~ description
                        ~ " authentication");
        }

        void sendPassword(scope const(char)[] text)
        {
            MessageBuilder b;
            b.begin(FrontendMessage.password);
            b.putCString(text);
            b.finish();
            stream.send(b.data);
        }

        string password = options.password;
        void needPassword()
        {
            import postgresql.userfiles : passwordFromFile;

            if (password.length == 0)
                password = passwordFromFile(options.passFile, attemptHost.host, attemptHost.port,
                        options.database.length ? options.database : user, user);
            if (password.length == 0)
                throw new ClientException("The server asks for a password, but none was given");
        }

        ScramClient scram;
        bool scramStarted, scramVerified;
        auth = AuthMethod.none;
        for (;;)
        {
            auto m = stream.read();
            switch (m.type)
            {
            case BackendMessage.authentication:
                auto body = m.body;
                const code = body.readInt32();
                switch (code)
                {
                case AuthRequest.ok:
                    if (scramStarted && !scramVerified)
                        throw new ProtocolException(
                                "The server ended SCRAM authentication without proving the password");
                    if (auth == AuthMethod.none)
                        allow("none", "no");
                    return;
                case AuthRequest.cleartextPassword:
                    allow("password", "cleartext password");
                    needPassword();
                    sendPassword(password);
                    auth = AuthMethod.cleartext;
                    break;
                case AuthRequest.md5Password:
                    allow("md5", "MD5 password");
                    needPassword();
                    sendPassword(md5PasswordResponse(user, password, body.readBytes(4)));
                    auth = AuthMethod.md5;
                    break;
                case AuthRequest.sasl:
                    allow("scram-sha-256", "SCRAM");
                    needPassword();
                    scram = startScram(body, password);
                    scramStarted = true;
                    break;
                case AuthRequest.saslContinue:
                    if (!scramStarted)
                        throw new ProtocolException("SASL challenge without a SASL exchange");
                    sendSaslResponse(cast(const(char)[]) scram.clientFinalMessage(cast(const(char)[])
                            body.readRest()));
                    break;
                case AuthRequest.saslFinal:
                    if (!scramStarted)
                        throw new ProtocolException("SASL outcome without a SASL exchange");
                    scram.verifyServerFinal(cast(const(char)[])
                            body.readRest());
                    scramVerified = true;
                    break;
                case AuthRequest.kerberosV5:
                    throw new ClientException("The server asks for Kerberos V5 authentication, which is not supported");
                case AuthRequest.gss, AuthRequest.gssContinue:
                    throw new ClientException("The server asks for GSSAPI authentication, which is not supported");
                case AuthRequest.sspi:
                    throw new ClientException("The server asks for SSPI authentication, which is not supported");
                case AuthRequest.scmCredential:
                    throw new ClientException("The server asks for SCM credentials, which are not supported");
                default:
                    throw new ProtocolException("Unknown authentication request");
                }
                break;
            case BackendMessage.errorResponse:
                throw new ServerException(ServerMessage.parse(m.body));
            case BackendMessage.negotiateProtocolVersion:
                negotiateVersion(m);
                break;
            case BackendMessage.noticeResponse:
                notice(ServerMessage.parse(m.body));
                break;
            default:
                throw new ProtocolException("Unexpected message '" ~ m.type ~ "' during authentication");
            }
        }
    }

    // Chooses the SASL mechanism and sends the SASLInitialResponse.
    private ScramClient startScram(MessageBody body, string password)
    {
        import std.algorithm.searching : canFind;

        string[] mechanisms;
        for (;;)
        {
            const name = body.readCString();
            if (name.length == 0)
                break;
            mechanisms ~= name;
        }
        const offeredPlus = mechanisms.canFind(scramSha256Plus);
        const binding = offeredPlus && options.channelBinding != ChannelBinding.disable ? channelBindingData() : null;
        ScramClient scram;
        string mechanism;
        if (binding.length)
        {
            mechanism = scramSha256Plus;
            scram = ScramClient(password, mechanism, binding);
            auth = AuthMethod.scramSha256Plus;
        }
        else
        {
            if (options.channelBinding == ChannelBinding.require)
                throw new ClientException(offeredPlus
                        ? "channel_binding=require, but channel binding is not available for this connection"
                        : "channel_binding=require, but the server doesn't offer SCRAM-SHA-256-PLUS");
            if (!mechanisms.canFind(scramSha256))
                throw new ClientException("The server offers no supported SASL mechanism");
            mechanism = scramSha256;
            // 'y': the client could bind but the server didn't offer it (a downgrade would show)
            scram = ScramClient(password, mechanism, null, tls !is null && !offeredPlus
                    && channelBindingSupported);
            auth = AuthMethod.scramSha256;
        }
        const first = scram.clientFirstMessage();
        MessageBuilder b;
        b.begin(FrontendMessage.password);
        b.putCString(mechanism);
        b.putInt32(cast(int) first.length);
        b.putBytes(cast(const(ubyte)[]) first);
        b.finish();
        stream.send(b.data);
        return scram;
    }

    private void sendSaslResponse(scope const(char)[] data)
    {
        MessageBuilder b;
        b.begin(FrontendMessage.password);
        b.putBytes(cast(const(ubyte)[]) data);
        b.finish();
        stream.send(b.data);
    }

    // Whether this build can compute tls-server-end-point (needs dbwire's TlsTransport.peerCertificate).
    private enum bool channelBindingSupported = __traits(hasMember, TlsTransport, "peerCertificate");

    // The tls-server-end-point data for the current TLS connection, or null.
    private const(ubyte)[] channelBindingData()
    {
        if (tls is null)
            return null;
        static if (channelBindingSupported)
        {
            const der = tls.peerCertificate;
            if (der.length == 0)
                return null;
            try
                return tlsServerEndPoint(der);
            catch (ClientException)
                return null; // no single hash for the certificate's signature: no binding
        }
        else
            return null;
    }
}

/// Thrown internally when the TLS handshake fails, so `sslmode=prefer` can retry without TLS.
private class TlsHandshakeFailed : ConnectionException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/++
The number of rows a command tag reports: `INSERT 0 5` → 5, `UPDATE 3` → 3,
`SELECT 2` → 2; 0 for tags without a count (`CREATE TABLE`, `BEGIN`, ...).
+/
ulong affectedRows(string tag) pure
{
    import std.algorithm.searching : startsWith;
    import std.conv : ConvException, to;
    import std.string : lastIndexOf;

    static immutable counted = [
        "INSERT ", "UPDATE ", "DELETE ", "SELECT ", "MERGE ", "MOVE ", "FETCH ", "COPY "
    ];
    foreach (prefix; counted)
        if (tag.startsWith(prefix))
        {
            const space = tag.lastIndexOf(' ');
            try
                return tag[space + 1 .. $].to!ulong;
            catch (ConvException)
                return 0;
        }
    return 0;
}

///
unittest
{
    assert(affectedRows("INSERT 0 5") == 5 && affectedRows("UPDATE 3") == 3 && affectedRows("SELECT 0") == 0);
    assert(affectedRows("CREATE TABLE") == 0 && affectedRows("COPY 10") == 10 && affectedRows("MERGE 2") == 2);
    assert(affectedRows("") == 0);
}

/++
The server version as a number from the `server_version` text: 180006 for
`18.6 (Debian ...)`, 130023 for `13.23`, 90624 for `9.6.24`; 0 if it can't be read.
+/
uint parseServerVersion(string text) pure
{
    import std.algorithm.searching : until;
    import std.array : array, split;
    import std.ascii : isDigit;
    import std.conv : ConvException, to;

    uint[] parts;
    foreach (p; text.until!(c => !isDigit(c) && c != '.').array.split("."))
    {
        if (p.length == 0)
            break;
        try
            parts ~= p.to!uint;
        catch (ConvException)
            return 0;
    }
    if (parts.length == 0)
        return 0;
    if (parts[0] >= 10)
        return parts[0] * 10_000 + (parts.length > 1 ? parts[1] : 0);
    return parts[0] * 10_000 + (parts.length > 1 ? parts[1] * 100 : 0) + (parts.length > 2 ? parts[2] : 0);
}

///
unittest
{
    assert(parseServerVersion("18.6 (Debian 18.6-1.pgdg13+2)") == 180_006);
    assert(parseServerVersion("13.23") == 130_023 && parseServerVersion("9.6.24") == 90_624);
    assert(parseServerVersion("17beta1") == 170_000 && parseServerVersion("") == 0);
}
