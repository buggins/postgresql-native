/++
Connecting: startup, session information, authentication methods, TLS
modes, client certificates, revocation lists, protocol versions, failover,
Unix-domain sockets.

The tests of authentication methods and TLS need the server prepared by
`integration-tests/setup-server.sh` (`POSTGRES_SETUP=1`); they pass without
checking anything otherwise.
+/
module integrationtests.connect;

import std.exception : assertThrown, collectException, enforce;

import postgresql;
import integrationtests.server;

/// Connect, read the session information, ping, close.
void testConnect()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    enforce(conn.isOpen && !conn.isBusy, "open and ready");
    enforce(conn.serverVersionNumber >= 130_000, "server version " ~ conn.serverVersion);
    enforce(conn.processId > 0, "process ID");
    enforce(conn.transactionStatus == TransactionStatus.idle, "idle");
    enforce(conn.parameterStatus("client_encoding") == "UTF8", "client_encoding");
    enforce(conn.parameterStatus("DateStyle").length >= 3 && conn.parameterStatus("DateStyle")[0 .. 3] == "ISO",
            "DateStyle");
    enforce(conn.parameterStatus("application_name") == "postgresql-native", "application_name");
    enforce(conn.parameterStatus("integer_datetimes") == "on", "integer_datetimes");
    enforce(conn.protocolVersion == protocol30, "protocol 3.0 by default");
    import std.conv : to;

    enforce(scalar(conn, "SELECT pg_backend_pid()") == conn.processId.to!string, "pg_backend_pid");
    conn.ping();
    conn.close();
    enforce(!conn.isOpen, "closed");
    assertThrown!ClientException(conn.ping());
    conn.close(); // again: nothing
}

/// Connection strings: URI and key=value, run-time parameters and options sent at startup.
void testConnectionStrings()
{
    import std.conv : to;
    import std.uri : encodeComponent;

    const hostPort = serverHost() ~ ":" ~ serverPort().to!string;
    enum query = "?application_name=itest%20uri&options=-c%20search_path%3Dpg_catalog";
    auto conn = new Connection("postgresql://" ~ encodeComponent(userName()) ~ ":" ~ encodeComponent(
            password())
            ~ "@" ~ hostPort ~ "/" ~ databaseName() ~ query);
    scope (exit)
        conn.close();
    enforce(conn.parameterStatus("application_name") == "itest uri", "application_name from the URI");
    enforce(scalar(conn, "SHOW search_path") == "pg_catalog", "options from the URI");

    auto kv = new Connection("host=" ~ serverHost() ~ " port=" ~ serverPort()
            .to!string ~ " dbname=" ~ databaseName() ~ " user=" ~ userName() ~ " password='" ~ password() ~ "'");
    scope (exit)
        kv.close();
    enforce(scalar(kv, "SELECT current_database()") == databaseName(), "key=value");

    auto o = serverOptions();
    o.runtimeParameters = ["TimeZone": "Asia/Kathmandu", "statement_timeout": "12345"];
    auto rp = new Connection(o);
    scope (exit)
        rp.close();
    enforce(rp.parameterStatus("TimeZone") == "Asia/Kathmandu", "TimeZone reported");
    enforce(scalar(rp, "SHOW statement_timeout") == "12345ms", "statement_timeout set");
}

/// Wrong password, unknown database, missing password.
void testLoginErrors()
{
    auto o = serverOptions();
    o.password = "wrong";
    auto e = collectException!ServerException(new Connection(o));
    enforce(e !is null && e.sqlState == "28P01" && e.error.isFatal, e is null ? "accepted" : e.msg);

    o = serverOptions();
    o.database = "no_such_database";
    e = collectException!ServerException(new Connection(o));
    enforce(e !is null && e.sqlState == "3D000", e is null ? "accepted" : e.msg);

    o = serverOptions();
    o.password = null; // the server asks for one (md5 or scram-sha-256 rule)
    assertThrown!ClientException(new Connection(o));
}

/// The authentication methods: SCRAM-SHA-256, MD5, cleartext, trust; require_auth.
void testAuthMethods()
{
    if (!serverSetUp())
        return;
    void check(string user, AuthMethod expected, SslMode mode = SslMode.disable)
    {
        auto conn = new Connection(userOptions(user, mode, user == "trustuser" ? "" : null));
        scope (exit)
            conn.close();
        enforce(conn.authMethod == expected, user ~ ": unexpected authentication method");
        enforce(scalar(conn, "SELECT current_user") == user, user ~ ": current_user");
    }

    check("scramuser", AuthMethod.scramSha256);
    check("md5user", AuthMethod.md5);
    check("clearuser", AuthMethod.cleartext, SslMode.require);
    check("trustuser", AuthMethod.none);

    // wrong passwords
    foreach (user; ["scramuser", "md5user", "clearuser"])
    {
        auto e = collectException!ServerException(new Connection(userOptions(user, SslMode.disable, "wrong")));
        enforce(e !is null && e.sqlState == "28P01", user ~ ": wrong password accepted");
    }

    // require_auth refuses before any credentials are sent
    auto o = userOptions("md5user");
    o.requireAuth = "scram-sha-256";
    assertThrown!ClientException(new Connection(o));
    o = userOptions("clearuser");
    o.requireAuth = "!password";
    assertThrown!ClientException(new Connection(o));
    o = userOptions("trustuser", SslMode.disable, "");
    o.requireAuth = "scram-sha-256,md5";
    assertThrown!ClientException(new Connection(o)); // "none" is not in the list
    o = userOptions("scramuser");
    o.requireAuth = "scram-sha-256,md5";
    new Connection(o).close();

    // SASLprep: the server stored the prepared form of the password
    new Connection(userOptions("saslpuser", SslMode.disable, "I­X pass")).close();
    new Connection(userOptions("saslpuser", SslMode.disable, "IX pass")).close();

    // channel binding (tls-server-end-point): SCRAM-SHA-256-PLUS over TLS
    o = userOptions("scramuser", SslMode.require);
    o.channelBinding = ChannelBinding.require;
    auto bound = new Connection(o);
    enforce(bound.authMethod == AuthMethod.scramSha256Plus, "channel_binding=require: SCRAM-SHA-256-PLUS");
    bound.close();
    o.channelBinding = ChannelBinding.prefer; // the default: bound when possible
    bound = new Connection(o);
    enforce(bound.authMethod == AuthMethod.scramSha256Plus, "channel_binding=prefer over TLS");
    bound.close();
    o.channelBinding = ChannelBinding.disable;
    auto unbound = new Connection(o);
    enforce(unbound.authMethod == AuthMethod.scramSha256, "channel_binding=disable");
    unbound.close();
    // without TLS there is nothing to bind to: require refuses, prefer logs in without
    o = userOptions("scramuser", SslMode.disable);
    o.channelBinding = ChannelBinding.require;
    enforce(collectException!ClientException(new Connection(o)) !is null, "require without TLS");
    o.channelBinding = ChannelBinding.prefer;
    unbound = new Connection(o);
    enforce(unbound.authMethod == AuthMethod.scramSha256, "prefer without TLS");
    unbound.close();
}

/// TLS: the sslmode values, certificate verification, client certificates, direct TLS.
void testTls()
{
    if (!serverSetUp())
        return;
    Connection open(ConnectionOptions o)
    {
        return new Connection(o);
    }

    auto conn = open(serverOptions(SslMode.require));
    enforce(conn.isEncrypted && conn.tlsVersion.length && conn.tlsCipher.length, "require: encrypted");
    enforce(scalar(conn, "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()") == "t", "pg_stat_ssl");
    conn.close();
    conn = open(serverOptions(SslMode.prefer));
    enforce(conn.isEncrypted, "prefer: encrypted when the server offers TLS");
    conn.close();
    conn = open(serverOptions(SslMode.disable));
    enforce(!conn.isEncrypted, "disable: plain");
    conn.close();

    // verification against the test CA
    auto o = serverOptions(SslMode.verifyFull);
    o.host = "localhost";
    o.tls.caFile = tlsFile("ca.pem");
    open(o).close();
    o.host = "127.0.0.1"; // the certificate has the IP address too
    open(o).close();
    o.tls.serverName = "db.example.com"; // a name the certificate doesn't have
    assertThrown!ConnectionException(open(o));
    o.tls.serverName = null;
    o.sslMode = SslMode.verifyCa;
    o.tls.serverName = "db.example.com"; // verify-ca doesn't check the name
    open(o).close();
    o.tls.serverName = null;
    o.tls.caFile = tlsFile("other-ca.pem");
    assertThrown!ConnectionException(open(o));
    o.sslMode = SslMode.require; // with a CA file, require verifies the chain like verify-ca
    assertThrown!ConnectionException(open(o));
    o.tls.caFile = null;
    open(o).close(); // require without a CA file: not verified

    // certificate revocation lists: sslcrl (a file) and sslcrldir (hashed names)
    {
        import std.algorithm.searching : canFind;

        auto r = serverOptions(SslMode.verifyFull);
        r.host = "localhost";
        r.tls.caFile = tlsFile("ca.pem");
        r.tls.crlFile = tlsFile("crl-none.pem");
        open(r).close();
        r.tls.crlFile = tlsFile("crl-revoked.pem");
        auto revoked = collectException!ConnectionException(open(r));
        enforce(revoked !is null && revoked.msg.canFind("revoked"),
                revoked is null ? "a revoked certificate accepted" : revoked.msg);
        r.tls.crlFile = null;
        r.tls.crlDir = tlsFile("crls");
        open(r).close();
        // the keywords of a connection string
        string keywords(string crlKeyword, string file)
        {
            import std.array : replace;
            import std.conv : to;

            string q(string v)
            {
                return "'" ~ v.replace(`\`, `\\`).replace("'", `\'`) ~ "'";
            }

            return "host=localhost port=" ~ serverPort()
                .to!string ~ " dbname=" ~ q(databaseName()) ~ " user="
                ~ q(userName()) ~ " password=" ~ q(
                        password()) ~ " sslmode=verify-full sslrootcert="
                ~ q(
                        tlsFile("ca.pem")) ~ " " ~ crlKeyword ~ "=" ~ q(file);
        }

        open(ConnectionOptions.parse(keywords("sslcrldir", tlsFile("crls")))).close();
        assertThrown!ConnectionException(open(ConnectionOptions.parse(keywords("sslcrl",
                tlsFile("crl-revoked.pem")))));
        // sslmode=require without a CA file verifies nothing: the CRL doesn't matter
        auto q = serverOptions(SslMode.require);
        q.tls.crlFile = tlsFile("crl-revoked.pem");
        open(q).close();
    }

    // a TLS-only user (hostssl): refused without TLS, allow retries with TLS
    auto e = collectException!ServerException(open(userOptions("tlsuser", SslMode.disable)));
    enforce(e !is null && e.sqlState == "28000", e is null ? "tlsuser without TLS accepted" : e.msg);
    conn = open(userOptions("tlsuser", SslMode.allow));
    enforce(conn.isEncrypted, "allow: retried with TLS");
    conn.close();

    // client certificate (cert authentication)
    auto c = userOptions("certuser", SslMode.verifyFull, "");
    c.host = "localhost";
    c.tls.caFile = tlsFile("ca.pem");
    c.tls.certFile = tlsFile("client.crt");
    c.tls.keyFile = tlsFile("client.key");
    conn = open(c);
    enforce(conn.authMethod == AuthMethod.none && scalar(conn, "SELECT current_user") == "certuser", "cert login");
    conn.close();
    c.tls.certFile = null;
    c.tls.keyFile = null;
    auto ce = collectException(open(c));
    enforce(ce !is null, "cert login without a certificate accepted");

    // direct TLS: PostgreSQL 17 and later
    auto version_ = connectToServer();
    const major = version_.serverVersionNumber / 10_000;
    version_.close();
    auto d = serverOptions(SslMode.require);
    d.sslNegotiation = SslNegotiation.direct;
    if (major >= 17)
    {
        conn = open(d);
        enforce(conn.isEncrypted, "direct TLS");
        conn.close();
    }
    else
        assertThrown!ConnectionException(open(d));
    d.sslMode = SslMode.prefer;
    assertThrown!ClientException(open(d)); // direct needs require or stricter
}

/++
Unix-domain sockets (`host=<socket directory>`, needs `POSTGRES_SOCKET_DIR`):
no TLS whatever sslmode says, requirepeer, failover from a missing
directory to TCP. Thread mode and fiber mode (vibe-core).
+/
void testUnixSockets()
{
    import std.algorithm.searching : canFind;
    import std.conv : to;

    const dir = socketDirectory();
    if (dir.length == 0)
        return;
    version (Posix)
    {
        auto o = serverOptions(SslMode.require); // ignored on Unix-domain sockets, as libpq
        o.host = dir;
        o.port = socketPort();
        auto conn = new Connection(o);
        enforce(!conn.isEncrypted, "no TLS over a Unix-domain socket");
        enforce(scalar(conn, "SELECT inet_server_addr() IS NULL") == "t", "connected over a Unix-domain socket");
        enforce(conn.host.host == dir, "Connection.host is the socket directory");
        conn.close();

        // the same from connection strings: key=value and a URI with the directory percent-encoded
        import std.uri : encodeComponent;

        auto viaUri = ConnectionOptions.parse("postgresql://" ~ encodeComponent(
                userName()) ~ ":"
                ~ encodeComponent(password()) ~ "@" ~ encodeComponent(dir) ~ ":" ~ socketPort()
                    .to!string
                    ~ "/" ~ databaseName());
        conn = new Connection(viaUri);
        enforce(scalar(conn, "SELECT inet_server_addr() IS NULL") == "t", "URI with a socket directory");
        conn.close();

        // requirepeer: the user that owns the socket runs the server
        import core.sys.posix.sys.stat : stat_t, stat;
        import std.string : toStringz;
        import dbwire.io.unixsocket : dbwireUserName = userName;

        stat_t st;
        const socket = socketPath(dir, socketPort());
        enforce((() @trusted => stat(socket.toStringz, &st))() == 0, "stat " ~ socket);
        string owner;
        try
            owner = dbwireUserName(st.st_uid);
        catch (ClientException)
            owner = "uid " ~ st.st_uid.to!string; // a container user unknown on the host
        o.requirePeer = owner;
        new Connection(o).close();
        o.requirePeer = "no-such-user-pgnative";
        auto e = collectException!ClientException(new Connection(o));
        enforce(e !is null && e.msg.canFind("requirepeer"), e is null ? "requirepeer not checked" : e.msg);
        o.requirePeer = null;

        // failover: a directory without a server, then TCP
        auto f = serverOptions(SslMode.disable);
        f.hosts = [
            HostPort("/nonexistent-pgnative", socketPort()), HostPort(serverHost(), serverPort())
        ];
        conn = new Connection(f);
        enforce(conn.host.host == serverHost(), "failover from the socket to TCP");
        conn.close();
    }
}

/// max_protocol_version=3.2: used by PostgreSQL 18, negotiated down to 3.0 by older servers.
void testProtocolVersion()
{
    auto o = serverOptions();
    o.maxProtocolVersion = ProtocolVersion.v32;
    auto conn = new Connection(o);
    scope (exit)
        conn.close();
    const expected = conn.serverVersionNumber >= 180_000 ? protocol32 : protocol30;
    enforce(conn.protocolVersion == expected, "negotiated protocol version");
    enforce(scalar(conn, "SELECT 'ok'") == "ok", "queries after the negotiation");
}

/// Several hosts: an unreachable one is skipped.
void testFailover()
{
    auto o = serverOptions();
    o.hosts = [HostPort("127.0.0.1", 1), HostPort(serverHost(), serverPort())];
    auto conn = new Connection(o);
    scope (exit)
        conn.close();
    enforce(conn.host == HostPort(serverHost(), serverPort()), "connected to the second host");

    o.hosts = [HostPort("127.0.0.1", 1), HostPort("127.0.0.1", 2)];
    auto e = collectException!ConnectionException(new Connection(o));
    enforce(e !is null, "no host reachable");
}
