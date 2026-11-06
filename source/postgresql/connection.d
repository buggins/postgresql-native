/++
A connection to a PostgreSQL server.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.connection;

import core.time : Duration;

import dbwire.client.hosts : connectFirst, HostPort, orderHosts;
import dbwire.io.backend : backendFor, IoBackend;
import dbwire.io.transport : Transport;
import dbwire.tls.transport : TlsContext, TlsOptions, TlsTransport;

import postgresql.auth;
import postgresql.exception;
import postgresql.protocol.codes;
import postgresql.protocol.messages;
import postgresql.result;
import postgresql.settings;

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
final class Connection
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
    private string[string] parameters;
    private int backendPid;
    private immutable(ubyte)[] cancelKey;
    private TransactionStatus txStatus = TransactionStatus.idle;
    private uint protocol = protocol30;
    private AuthMethod auth;
    private Notification[] notifications;
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
    Runs a query with the simple query protocol and returns its rows, read as
    the result is iterated. Values come in text format. For several
    statements, the rows of the first one are returned and the rest of the
    response is read and discarded when the result ends.

    Throws: `ServerException`, from here or from the result.
    +/
    QueryResult query(string sql)
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
                    return;
                case BackendMessage.commandComplete:
                    tag = m.body.readCString();
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
    package void nextRow(const(ColumnInfo)[] columns, ref Row row, ref bool has, ref string tag)
    {
        has = false;
        guarded({
            for (;;)
            {
                auto m = nextMessage();
                switch (m.type)
                {
                case BackendMessage.dataRow:
                    row = parseDataRow(m.body, columns);
                    has = true;
                    return;
                case BackendMessage.commandComplete:
                    tag = m.body.readCString();
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

    private void startSimpleQuery(string sql)
    {
        checkReady();
        MessageBuilder b;
        b.begin(FrontendMessage.query);
        b.putCString(sql);
        b.finish();
        state = State.busy;
        responseDone = false;
        hasPendingError = false;
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
            BackendMessage.emptyQueryResponse:
            break; // results not asked for
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
        void tryHost(HostPort endpoint) @safe
        {
            connectTo(endpoint);
        }

        connectedHost = connectFirst(orderHosts(hosts, options.hostSelection), &tryHost, "PostgreSQL");
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
        TlsOptions t = options.tls;
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

        void needPassword()
        {
            if (options.password.length == 0)
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
                    sendPassword(options.password);
                    auth = AuthMethod.cleartext;
                    break;
                case AuthRequest.md5Password:
                    allow("md5", "MD5 password");
                    needPassword();
                    sendPassword(md5PasswordResponse(user, options.password, body.readBytes(4)));
                    auth = AuthMethod.md5;
                    break;
                case AuthRequest.sasl:
                    allow("scram-sha-256", "SCRAM");
                    needPassword();
                    scram = startScram(body);
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
    private ScramClient startScram(MessageBody body)
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
            scram = ScramClient(options.password, mechanism, binding);
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
            scram = ScramClient(options.password, mechanism, null, tls !is null && !offeredPlus
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
