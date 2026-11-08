/++
Connection options and connection strings.

Connection strings use libpq's syntax and keywords: URIs
(`postgresql://user:password@host:port/dbname?sslmode=require`, also
`postgres://`) and `key=value` strings (`host=db1 dbname=app sslmode=require`).
`service=name` takes keywords from a connection service file
(`pg_service.conf`, see `postgresql.userfiles.serviceParams`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module postgresql.settings;

import core.time : Duration, seconds;

import dbwire.io.transport : Transport;

import postgresql.exception : ClientException;

public import dbwire.client.hosts : HostPort, HostSelection;
public import dbwire.io.backend : IoMode;
public import dbwire.tls.transport : TlsOptions, TlsVersion;

@safe:

/// The default PostgreSQL port.
enum ushort defaultPort = 5432;

/++
Whether and how to use TLS (libpq's `sslmode`).
+/
enum SslMode
{
    /// Never use TLS.
    disable,
    /// Connect without TLS; if the server refuses that, connect again with TLS (not verified).
    allow,
    /// Use TLS if the server supports it, without verifying the certificate; else connect without. The default.
    prefer,
    /++
    Require TLS. The certificate is verified only if a CA file (`sslrootcert`)
    is given; then as `verifyCa`, as libpq does.
    +/
    require,
    /// Require TLS and a certificate signed by a trusted CA.
    verifyCa,
    /// Require TLS, a certificate signed by a trusted CA, and the host name in the certificate.
    verifyFull,
}

/// How TLS starts (libpq's `sslnegotiation`).
enum SslNegotiation
{
    /// Ask the server first (SSLRequest), then start TLS. Works with every version.
    postgres,
    /// Start TLS right away, with ALPN `postgresql` (PostgreSQL 17 and later); needs `sslmode=require` or stricter.
    direct,
}

/// Whether to use SCRAM channel binding (libpq's `channel_binding`).
enum ChannelBinding
{
    /// Never.
    disable,
    /// When the connection uses TLS and the server offers SCRAM-SHA-256-PLUS. The default.
    prefer,
    /// Always: fail if the server doesn't authenticate with SCRAM-SHA-256-PLUS.
    require,
}

/// The highest protocol version to ask for (libpq's `max_protocol_version`).
enum ProtocolVersion
{
    /// 3.0: every server since PostgreSQL 7.4. The default.
    v30,
    /// 3.2 (PostgreSQL 18): longer cancel keys. Older servers answer with 3.0.
    v32,
}

/// Which servers to accept, by session state (libpq's `target_session_attrs`).
enum TargetSessionAttrs
{
    /// Any server. The default.
    any,
    /// A server that accepts writes (not a standby, `default_transaction_read_only` off).
    readWrite,
    /// A server that doesn't accept writes by default (a standby, or `default_transaction_read_only` on).
    readOnly,
    /// A primary server (not in recovery).
    primary,
    /// A standby server (in recovery).
    standby,
    /// A standby if one of the hosts is; else any server.
    preferStandby,
}

/// Creates the raw transport to a host instead of the I/O backend (tests, tunnels, logging).
alias TransportFactory = Transport delegate(string host, ushort port, Duration timeout) @safe;

/++
Everything needed to connect.
+/
struct ConnectionOptions
{
    /++
    Host name or IP address, if `hosts` is empty. A name that starts with `/`
    is the directory of the server's Unix-domain socket
    (`/var/run/postgresql` connects to `/var/run/postgresql/.s.PGSQL.5432`);
    one that starts with `@` names a Linux abstract socket (thread mode only).
    Unlike libpq, the default is `localhost` over TCP, not a socket directory.
    +/
    string host = "localhost";
    /// Port, if `hosts` is empty; 0 means 5432.
    ushort port;
    /// Hosts to try in turn (failover); a port of 0 means 5432.
    HostPort[] hosts;
    /++
    Numeric IP addresses to connect to instead of looking the host names up
    (libpq's `hostaddr`): one, or a comma-separated list with one address per
    host (`hosts`). The names still serve TLS name checks, the password file
    and messages; without names, the addresses are used for those.
    +/
    string hostAddress;
    /// The order in which `hosts` are tried (libpq's `load_balance_hosts`: `disable` or `random`).
    HostSelection hostSelection = HostSelection.inOrder;
    /++
    Which servers to accept: hosts whose session doesn't match are skipped
    (the next host is tried).
    +/
    TargetSessionAttrs targetSessionAttrs = TargetSessionAttrs.any;
    /++
    The operating-system user the server must run as, checked on Unix-domain
    sockets (libpq's `requirepeer`); empty: not checked. Ignored over TCP.
    +/
    string requirePeer;
    /// User name.
    string user;
    /++
    Password. When empty and the server asks for one, it is looked up in
    the password file (`passFile`).
    +/
    string password;
    /++
    The password file (libpq's `passfile`), with lines
    `host:port:database:user:password` (`*` matches anything; `\:` and
    `\\` escape). Empty: `~/.pgpass` (`%APPDATA%\postgresql\pgpass.conf`
    on Windows). On POSIX systems a file that the group or others may read
    is ignored, as libpq does.
    +/
    string passFile;
    /// Database; empty means the same as the user name.
    string database;
    /// `application_name` reported to the server (shown in `pg_stat_activity`).
    string applicationName = "postgresql-native";
    /// Command-line options for the server process (libpq's `options`), e.g. `-c search_path=app`.
    string serverOptions;
    /// Run-time parameters set at startup (e.g. `["TimeZone": "UTC"]`).
    string[string] runtimeParameters;

    /// Whether to use TLS. Default `prefer`, as libpq.
    SslMode sslMode = SslMode.prefer;
    /// How TLS starts.
    SslNegotiation sslNegotiation = SslNegotiation.postgres;
    /++
    TLS details: `caFile` (libpq's `sslrootcert`), `certFile`/`keyFile`
    (`sslcert`/`sslkey`, client certificate), `keyPassword` (`sslpassword`),
    `serverName`, `minVersion`/`maxVersion` (`ssl_min_protocol_version`,
    `ssl_max_protocol_version`), `crlFile`/`crlDir` (`sslcrl`/`sslcrldir`,
    certificate revocation lists). Verification follows `sslMode`;
    `skipVerify` and `skipNameCheck` are set from it.

    As libpq, the files default to those in `~/.postgresql`
    (`%APPDATA%\postgresql` on Windows) when they exist: `root.crt` (then
    `sslmode=require` verifies the certificate, as `verifyCa`),
    `root.crl` (when neither `crlFile` nor `crlDir` is set),
    `postgresql.crt` and `postgresql.key`.

    TLS is never used over Unix-domain sockets, whatever `sslMode` says
    (as libpq).
    +/
    TlsOptions tls;
    /// Whether to use SCRAM channel binding.
    ChannelBinding channelBinding = ChannelBinding.prefer;
    /++
    The authentication methods the server may use (libpq's `require_auth`):
    a comma-separated list of `password`, `md5`, `scram-sha-256`, `none`
    (and `gss`, `sspi`, which this client doesn't support), or the same list
    with each method prefixed by `!` to forbid them. Empty: any method.
    +/
    string requireAuth;
    /// The highest protocol version to ask for.
    ProtocolVersion maxProtocolVersion = ProtocolVersion.v30;

    /++
    How many statements of `Connection.query`/`exec` with parameters the
    connection keeps prepared, by SQL text (keyword `statement_cache_size`).
    0 parses every statement again (the unnamed statement), as needed behind
    poolers that don't keep prepared statements (PgBouncer in transaction
    mode before 1.21).
    +/
    size_t statementCacheSize = 100;
    /++
    Whether `?` placeholders are rewritten to `$1`, `$2`, ... when a query
    has parameters (keyword `rewrite_placeholders`); `??` is a literal `?`.
    +/
    bool rewritePlaceholders = true;

    /// Time allowed to connect, start TLS and log in; zero waits forever (`connect_timeout=0`, as in libpq).
    Duration connectTimeout = 15.seconds;
    /// Time allowed for each write.
    Duration sendTimeout = 300.seconds;
    /// Time allowed for each read; zero waits forever. A read that times out closes the connection.
    Duration receiveTimeout;
    /++
    The server's `statement_timeout`, set at startup: a statement running
    longer is cancelled by the server (SQLSTATE 57014) and the connection
    stays usable. Zero keeps the server's setting.
    +/
    Duration statementTimeout;

    /// Threads (blocking sockets) or vibe.d fibers; `auto_` picks vibe.d inside a vibe.d task.
    IoMode ioMode = IoMode.auto_;
    /// Creates the raw transport instead of the I/O backend; may be null.
    TransportFactory transportFactory;

    /// The port to use for `port` (0 means the default).
    static ushort effectivePort(ushort port) pure nothrow
    {
        return port ? port : defaultPort;
    }

    /++
    Options from a connection string: a URI (`postgresql://...` or
    `postgres://...`) or a `key=value` string.

    Throws: `ClientException` if the string is malformed or has an unknown
    keyword or an invalid value.
    +/
    static ConnectionOptions parse(string connectionString)
    {
        import std.algorithm.searching : startsWith;

        if (connectionString.startsWith("postgresql://") || connectionString.startsWith("postgres://"))
            return fromParams(parseUri(connectionString));
        return fromParams(parseKeywordValue(connectionString));
    }

    /++
    Options from libpq keywords (`host`, `port`, `dbname`, `user`, `password`,
    `sslmode`, ...), e.g. as ddbc passes them. `host` and `port` may list
    several hosts separated by commas.

    Throws: `ClientException` for an unknown keyword or an invalid value.
    +/
    static ConnectionOptions fromParams(const string[string] given)
    {
        import dbwire.client.dsn : parseFlag, parseSeconds;
        import std.array : split;
        import std.conv : ConvException, to;
        import std.string : strip, toLower;

        string[string] params;
        foreach (key, value; given)
            params[key] = value;
        applyService(params);
        ConnectionOptions o;
        string[] hostList, portList, addressList;
        foreach (key, value; params)
        {
            switch (key)
            {
            case "hostaddr":
                addressList = value.split(",");
                foreach (ref a; addressList)
                {
                    a = a.strip;
                    if (!isNumericAddress(a))
                        throw new ClientException("hostaddr '" ~ a ~ "' is not a numeric IP address");
                }
                o.hostAddress = value;
                break;
            case "host":
                hostList = value.split(",");
                break;
            case "load_balance_hosts":
                o.hostSelection = parseKeyword!HostSelection(key, value, ["disable", "random"]);
                break;
            case "target_session_attrs":
                o.targetSessionAttrs = parseKeyword!TargetSessionAttrs(key, value, [
                    "any", "read-write", "read-only", "primary", "standby", "prefer-standby"
                ]);
                break;
            case "passfile":
                o.passFile = value;
                break;
            case "requirepeer":
                o.requirePeer = value;
                break;
            case "sslcrl":
                o.tls.crlFile = value;
                break;
            case "sslcrldir":
                o.tls.crlDir = value;
                break;
            case "ssl_min_protocol_version":
                o.tls.minVersion = parseTlsVersion(key, value);
                break;
            case "ssl_max_protocol_version":
                if (value.length)
                    o.tls.maxVersion = parseTlsVersion(key, value);
                break;
            case "port":
                portList = value.split(",");
                break;
            case "user":
                o.user = value;
                break;
            case "password":
                o.password = value;
                break;
            case "dbname":
                o.database = value;
                break;
            case "application_name":
                o.applicationName = value;
                break;
            case "options":
                o.serverOptions = value;
                break;
            case "sslmode":
                o.sslMode = parseKeyword!SslMode(key, value, [
                    "disable", "allow", "prefer", "require", "verify-ca", "verify-full"
                ]);
                break;
            case "sslnegotiation":
                o.sslNegotiation = parseKeyword!SslNegotiation(key, value, ["postgres", "direct"]);
                break;
            case "sslrootcert":
                o.tls.caFile = value;
                break;
            case "sslcert":
                o.tls.certFile = value;
                break;
            case "sslkey":
                o.tls.keyFile = value;
                break;
            case "sslpassword":
                o.tls.keyPassword = value;
                break;
            case "sslsni":
                break; // SNI is always sent for host names
            case "channel_binding":
                o.channelBinding = parseKeyword!ChannelBinding(key, value, [
                    "disable", "prefer", "require"
                ]);
                break;
            case "require_auth":
                cast(void) parseRequireAuth(value); // validates
                o.requireAuth = value;
                break;
            case "max_protocol_version":
                o.maxProtocolVersion = parseKeyword!ProtocolVersion(key, value == "latest" ? "3.2" : value, [
                    "3.0", "3.2"
                ]);
                break;
            case "connect_timeout":
                o.connectTimeout = parseSeconds(key, value); // 0: no limit
                break;
            case "client_encoding":
                if (value.toLower != "utf8" && value.toLower != "utf-8")
                    throw new ClientException("Only client_encoding=UTF8 is supported");
                break;
            case "statement_cache_size":
                try
                    o.statementCacheSize = value.strip.to!size_t;
                catch (ConvException)
                    throw new ClientException("Invalid statement_cache_size '" ~ value ~ "'");
                break;
            case "rewrite_placeholders":
                o.rewritePlaceholders = parseFlag(key, value);
                break;
            case "io_mode":
                o.ioMode = parseKeyword!IoMode(key, value, ["auto", "phobos", "vibe"]);
                break;
            default:
                throw new ClientException("Unknown connection keyword '" ~ key ~ "'");
            }
        }
        if (addressList.length)
        {
            // hostaddr alone: the addresses are the names too
            if (hostList.length == 0)
                hostList = addressList;
            else if (hostList.length != addressList.length)
                throw new ClientException("'hostaddr' must list one address per host");
        }
        if (hostList.length > 1 || portList.length > 1)
        {
            if (portList.length > 1 && portList.length != hostList.length)
                throw new ClientException("'port' must list one port, or one per host");
            foreach (i, h; hostList)
            {
                const port = portList.length > 1 ? portList[i] : portList.length ? portList[0] : "";
                o.hosts ~= HostPort(h.strip, parsePort(port));
            }
        }
        else
        {
            if (hostList.length)
                o.host = hostList[0].strip;
            if (portList.length)
                o.port = parsePort(portList[0]);
        }
        return o;
    }
}

///
unittest
{
    auto o = ConnectionOptions.parse("postgresql://app:s%40cret@db.example.com:6432/sales?sslmode=verify-full"
            ~ "&sslrootcert=/etc/ca.pem&application_name=report");
    assert(o.user == "app" && o.password == "s@cret" && o.host == "db.example.com" && o.port == 6432);
    assert(o.database == "sales" && o.sslMode == SslMode.verifyFull && o.tls.caFile == "/etc/ca.pem");
    assert(o.applicationName == "report");

    o = ConnectionOptions.parse("host=db1,db2 port=5433 dbname='my db' user=app sslmode=disable");
    assert(o.hosts == [HostPort("db1", 5433), HostPort("db2", 5433)] && o.database == "my db");
    assert(o.sslMode == SslMode.disable);
}

unittest
{
    import std.exception : assertThrown;

    auto o = ConnectionOptions.parse("postgres://h1:1,h2:2/");
    assert(o.hosts == [HostPort("h1", 1), HostPort("h2", 2)] && o.database.length == 0);
    o = ConnectionOptions.parse("postgresql://u:p@/db");
    assert(o.user == "u" && o.password == "p" && o.database == "db" && o.hosts.length == 0 && o.host == "localhost");
    o = ConnectionOptions.parse("postgresql:///db?host=localhost&port=5999&channel_binding=require");
    assert(o.host == "localhost" && o.port == 5999 && o.database == "db"
            && o.channelBinding == ChannelBinding.require);
    o = ConnectionOptions.parse("postgresql://[::1]:5432/x?max_protocol_version=latest&connect_timeout=3");
    assert(o.host == "::1" && o.maxProtocolVersion == ProtocolVersion.v32 && o.connectTimeout == 3.seconds);
    assert(ConnectionOptions.parse("postgresql://h?connect_timeout=0").connectTimeout == Duration.zero);
    o = ConnectionOptions.parse("postgresql://h?sslnegotiation=direct&sslmode=require&require_auth=!password,!md5");
    assert(o.sslNegotiation == SslNegotiation.direct && o.requireAuth == "!password,!md5");
    assertThrown!ClientException(ConnectionOptions.parse("postgresql://h?sslmode=sometimes"));
    assertThrown!ClientException(ConnectionOptions.parse("postgresql://h?nonsense=1"));
    assertThrown!ClientException(ConnectionOptions.parse("postgresql://h?require_auth=password,!md5"));
    assertThrown!ClientException(ConnectionOptions.parse("host=a,b port=1,2,3"));
    assertThrown!ClientException(ConnectionOptions.parse("host=h client_encoding=LATIN1"));
    assertThrown!ClientException(ConnectionOptions.parse("host='unterminated"));
    o = ConnectionOptions.parse("host=h target_session_attrs=read-write ssl_min_protocol_version=TLSv1.3 passfile=/p");
    assert(o.targetSessionAttrs == TargetSessionAttrs.readWrite && o.tls.minVersion == TlsVersion.tls13);
    assert(o.passFile == "/p");
    assertThrown!ClientException(ConnectionOptions.parse("host=h ssl_min_protocol_version=TLSv1.1"));
    // revocation lists, Unix-domain sockets
    o = ConnectionOptions.parse("host=/var/run/postgresql requirepeer=postgres sslcrl=/c.pem sslcrldir=/crls");
    assert(o.host == "/var/run/postgresql" && o.requirePeer == "postgres");
    assert(o.tls.crlFile == "/c.pem" && o.tls.crlDir == "/crls");
    o = ConnectionOptions.parse("postgresql://%2Fvar%2Frun%2Fpostgresql:5433/db");
    assert(o.host == "/var/run/postgresql" && o.port == 5433 && o.database == "db");
    o = ConnectionOptions.parse("postgresql:///db?host=/tmp");
    assert(o.host == "/tmp" && o.database == "db");
    assertThrown!ClientException(ConnectionOptions.parse("host=h target_session_attrs=master"));
}

/++
Options from the `PG*` environment variables, as libpq reads them
(`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGPASSFILE`,
`PGSSLMODE`, `PGSSLROOTCERT`, `PGTARGETSESSIONATTRS`, ...; `PGTZ` sets the
session's `TimeZone`), overridden by the keywords of `connectionString`
(a URI or `key=value` string; may be empty).

`parse` and `fromParams` don't read the environment.

Throws: `ClientException` as `parse`, also for invalid values in the environment.
+/
ConnectionOptions fromEnvironment(string connectionString = null)
{
    import std.algorithm.searching : startsWith;
    import std.process : environment;
    import std.string : strip;

    // as libpq: the string's keywords, then a service's (PGSERVICE), then the environment's
    string[string] params;
    const s = connectionString.strip;
    if (s.length)
        params = s.startsWith("postgresql://") || s.startsWith("postgres://") ? parseUri(s) : parseKeywordValue(s);
    if ("service" !in params)
        if (const service = environment.get("PGSERVICE"))
            params["service"] = service;
    applyService(params);
    foreach (variable, keyword; environmentKeywords)
    {
        const value = environment.get(variable);
        if (value !is null && keyword !in params)
            params[keyword] = value;
    }
    auto o = ConnectionOptions.fromParams(params);
    const tz = environment.get("PGTZ");
    if (tz.length)
        o.runtimeParameters["TimeZone"] = tz;
    return o;
}

/++
Replaces the `service` keyword (and `servicefile`) by the keywords of that
connection service, for those `params` doesn't have (see
`postgresql.userfiles.serviceParams`).

Throws: `ClientException` if the service is not defined.
+/
private void applyService(ref string[string] params)
{
    import postgresql.userfiles : serviceParams;

    const name = params.get("service", null);
    const file = params.get("servicefile", null);
    params.remove("service");
    params.remove("servicefile");
    if (name.length == 0)
        return;
    foreach (key, value; serviceParams(name, file))
        if (key !in params)
            params[key] = value;
}

/++
Whether `host` names the directory of a Unix-domain socket (it starts with
`/`) or a Linux abstract socket (it starts with `@`), not a host name.
+/
bool isSocketDirectory(string host) pure nothrow
{
    return host.length && (host[0] == '/' || host[0] == '@');
}

/++
The path of the server's socket in the socket directory `host` for `port`:
`<host>/.s.PGSQL.<port>`, with a zero byte for the `@` of an abstract
socket.
+/
string socketPath(string host, ushort port) pure
{
    import std.conv : to;

    auto dir = host;
    while (dir.length > 1 && dir[$ - 1] == '/')
        dir = dir[0 .. $ - 1];
    if (dir.length && dir[0] == '@')
        dir = "\0" ~ dir[1 .. $];
    return (dir == "/" ? "" : dir) ~ "/.s.PGSQL." ~ ConnectionOptions.effectivePort(port).to!string;
}

///
unittest
{
    assert(isSocketDirectory("/var/run/postgresql") && isSocketDirectory("@pg") && !isSocketDirectory("db"));
    assert(socketPath("/var/run/postgresql", 0) == "/var/run/postgresql/.s.PGSQL.5432");
    assert(socketPath("/tmp/", 5433) == "/tmp/.s.PGSQL.5433");
    assert(socketPath("@pg", 5432) == "\0pg/.s.PGSQL.5432");
}

/// Whether `text` is a numeric IPv4 or IPv6 address (not a name).
private bool isNumericAddress(string text) pure nothrow
{
    import std.ascii : isDigit, isHexDigit;

    if (text.length == 0)
        return false;
    bool colon, dot;
    foreach (c; text)
    {
        if (c == ':')
            colon = true;
        else if (c == '.')
            dot = true;
        else if (!(colon ? isHexDigit(c) : isDigit(c) || isHexDigit(c)))
            return false;
    }
    if (colon)
        return true; // IPv6, possibly with a dotted tail
    if (!dot)
        return false;
    foreach (c; text)
        if (c != '.' && !isDigit(c))
            return false;
    return true;
}

unittest
{
    assert(isNumericAddress("127.0.0.1") && isNumericAddress("::1") && isNumericAddress("2001:db8::ffff:1.2.3.4"));
    assert(!isNumericAddress("localhost") && !isNumericAddress("db1.example") && !isNumericAddress(""));
}

// hostaddr: one address per host; alone, the addresses are the names
unittest
{
    import std.exception : assertThrown;

    auto o = ConnectionOptions.parse("host=db.example hostaddr=10.0.0.5");
    assert(o.host == "db.example" && o.hostAddress == "10.0.0.5");
    o = ConnectionOptions.parse("hostaddr=127.0.0.1");
    assert(o.host == "127.0.0.1" && o.hostAddress == "127.0.0.1");
    o = ConnectionOptions.parse("host=a,b hostaddr=10.0.0.1,::1 port=5432,5433");
    assert(o.hosts == [HostPort("a", 5432), HostPort("b", 5433)] && o.hostAddress == "10.0.0.1,::1");
    assertThrown!ClientException(ConnectionOptions.parse("host=a,b hostaddr=10.0.0.1"));
    assertThrown!ClientException(ConnectionOptions.parse("hostaddr=db.example"));
}

// Services: the string's keywords win over the service's, which win over the environment's
@system unittest
{
    import std.conv : to;
    import std.exception : assertThrown;
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import std.process : environment, thisProcessID;

    const file = buildPath(tempDir, "pgn-settings-service-" ~ thisProcessID.to!string);
    write(file, "[sales]\nhost=svc.example\ndbname=sales\napplication_name=from-service\nsslmode=require\n");
    scope (exit)
        remove(file);
    import std.array : replace;

    const quoted = file.replace(`\`, `\\`); // a backslash escapes in key=value strings (Windows paths)
    auto o = ConnectionOptions.parse("service=sales servicefile=" ~ quoted ~ " application_name=from-string");
    assert(o.host == "svc.example" && o.database == "sales" && o.applicationName == "from-string");
    assert(o.sslMode == SslMode.require);
    assertThrown!ClientException(ConnectionOptions.parse("service=nope servicefile=" ~ quoted));

    const saved = environment.toAA();
    scope (exit)
        foreach (v; ["PGSERVICE", "PGSERVICEFILE", "PGAPPNAME", "PGDATABASE", "PGHOST"])
        {
            if (auto value = v in saved)
                environment[v] = *value;
            else
                environment.remove(v);
        }
    environment["PGSERVICE"] = "sales";
    environment["PGSERVICEFILE"] = file;
    environment["PGAPPNAME"] = "from-env";
    environment["PGDATABASE"] = "envdb";
    environment.remove("PGHOST");
    o = fromEnvironment("dbname=stringdb");
    assert(o.database == "stringdb" && o.applicationName == "from-service" && o.host == "svc.example");
}

/// The `PG*` environment variables `fromEnvironment` reads, and their keywords.
private immutable string[string] environmentKeywords;

shared static this()
{
    environmentKeywords = [
        "PGHOST": "host",
        "PGHOSTADDR": "hostaddr",
        "PGPORT": "port",
        "PGDATABASE": "dbname",
        "PGUSER": "user",
        "PGPASSWORD": "password",
        "PGPASSFILE": "passfile",
        "PGOPTIONS": "options",
        "PGAPPNAME": "application_name",
        "PGSSLMODE": "sslmode",
        "PGSSLNEGOTIATION": "sslnegotiation",
        "PGSSLCERT": "sslcert",
        "PGSSLKEY": "sslkey",
        "PGSSLROOTCERT": "sslrootcert",
        "PGSSLCRL": "sslcrl",
        "PGSSLCRLDIR": "sslcrldir",
        "PGREQUIREPEER": "requirepeer",
        "PGSSLSNI": "sslsni",
        "PGSSLMINPROTOCOLVERSION": "ssl_min_protocol_version",
        "PGSSLMAXPROTOCOLVERSION": "ssl_max_protocol_version",
        "PGCHANNELBINDING": "channel_binding",
        "PGREQUIREAUTH": "require_auth",
        "PGMAXPROTOCOLVERSION": "max_protocol_version",
        "PGCONNECT_TIMEOUT": "connect_timeout",
        "PGCLIENTENCODING": "client_encoding",
        "PGTARGETSESSIONATTRS": "target_session_attrs",
        "PGLOADBALANCEHOSTS": "load_balance_hosts",
    ];
}

///
@system unittest
{
    import std.process : environment;

    const saved = environment.toAA();
    scope (exit)
    {
        foreach (variable, _; environmentKeywords)
        {
            if (auto v = variable in saved)
                environment[variable] = *v;
            else
                environment.remove(variable);
        }
        if (auto v = "PGTZ" in saved)
            environment["PGTZ"] = *v;
        else
            environment.remove("PGTZ");
    }
    foreach (variable, _; environmentKeywords)
        environment.remove(variable);
    environment["PGHOST"] = "db1,db2";
    environment["PGPORT"] = "5433";
    environment["PGUSER"] = "app";
    environment["PGSSLMODE"] = "require";
    environment["PGTZ"] = "Europe/Lisbon";
    auto o = fromEnvironment("postgresql://other@/sales?sslmode=verify-full");
    assert(o.hosts == [HostPort("db1", 5433), HostPort("db2", 5433)]);
    assert(o.user == "other" && o.database == "sales" && o.sslMode == SslMode.verifyFull);
    assert(o.runtimeParameters["TimeZone"] == "Europe/Lisbon");
    o = fromEnvironment("dbname=x target_session_attrs=prefer-standby load_balance_hosts=random");
    assert(o.user == "app" && o.sslMode == SslMode.require && o.database == "x");
    assert(o.targetSessionAttrs == TargetSessionAttrs.preferStandby && o.hostSelection == HostSelection.random);
}

/++
Parses a `key=value` connection string (libpq's conninfo): pairs separated by
spaces, values in single quotes when they contain spaces or quotes, `\'` and
`\\` escapes.

Throws: `ClientException` if the string is malformed.
+/
string[string] parseKeywordValue(string text)
{
    import std.ascii : isWhite;

    string[string] result;
    size_t i;
    void skipSpaces()
    {
        while (i < text.length && isWhite(text[i]))
            i++;
    }

    for (;;)
    {
        skipSpaces();
        if (i >= text.length)
            break;
        const keyStart = i;
        while (i < text.length && text[i] != '=' && !isWhite(text[i]))
            i++;
        const key = text[keyStart .. i];
        skipSpaces();
        if (i >= text.length || text[i] != '=' || key.length == 0)
            throw new ClientException("Missing '=' after '" ~ key ~ "' in the connection string");
        i++;
        skipSpaces();
        string value;
        if (i < text.length && text[i] == '\'')
        {
            i++;
            bool closed;
            while (i < text.length)
            {
                if (text[i] == '\\' && i + 1 < text.length)
                {
                    value ~= text[i + 1];
                    i += 2;
                }
                else if (text[i] == '\'')
                {
                    i++;
                    closed = true;
                    break;
                }
                else
                    value ~= text[i++];
            }
            if (!closed)
                throw new ClientException("Unterminated quoted value in the connection string");
        }
        else
        {
            while (i < text.length && !isWhite(text[i]))
            {
                if (text[i] == '\\' && i + 1 < text.length)
                    i++;
                value ~= text[i++];
            }
        }
        result[key] = value;
    }
    return result;
}

/++
Parses a `postgresql://` or `postgres://` URI into libpq keywords. The hosts
may be omitted (`postgresql:///dbname`, then `localhost` unless `host=` is in
the query).

Throws: `ClientException` if the URI is malformed.
+/
string[string] parseUri(string uri)
{
    import dbwire.client.dsn : Dsn;
    import std.algorithm.searching : startsWith;
    import std.array : join;

    string scheme = uri.startsWith("postgres://") ? "postgres" : "postgresql";
    string text = uri;
    // a URI without hosts (`postgresql:///db`, `postgresql://user@/db`): let Dsn see a placeholder host
    import std.string : indexOfAny, lastIndexOf;

    const authorityStart = scheme.length + 3;
    auto authorityEnd = text.indexOfAny("/?", authorityStart);
    if (authorityEnd < 0)
        authorityEnd = text.length;
    const at = text[0 .. authorityEnd].lastIndexOf('@');
    const hostStart = at >= cast(ptrdiff_t) authorityStart ? at + 1 : authorityStart;
    const noHost = hostStart == authorityEnd;
    if (noHost)
        text = text[0 .. hostStart] ~ "localhost" ~ text[hostStart .. $];
    const dsn = Dsn.parse(text, scheme);

    string[string] result;
    if (dsn.hasUser)
        result["user"] = dsn.user;
    if (dsn.hasPassword)
        result["password"] = dsn.password;
    if (dsn.path.length)
        result["dbname"] = dsn.path;
    if (!noHost)
    {
        import std.conv : to;

        string[] hosts, ports;
        bool anyPort;
        foreach (h; dsn.hosts)
        {
            hosts ~= decodeHost(h.host);
            ports ~= h.port ? h.port.to!string : "";
            anyPort = anyPort || h.port != 0;
        }
        result["host"] = hosts.join(",");
        if (anyPort)
        {
            foreach (ref p; ports)
                if (p.length == 0)
                    p = defaultPort.to!string;
            result["port"] = ports.join(",");
        }
    }
    foreach (key, value; dsn.params)
        result[key] = value;
    return result;
}

// A URI host, percent-decoded: a socket directory is written `%2Fvar%2Frun%2Fpostgresql`.
private string decodeHost(string host)
{
    import std.algorithm.searching : canFind;
    import std.uri : decodeComponent, URIException;

    if (!host.canFind('%'))
        return host;
    try
        return decodeComponent(host);
    catch (URIException)
        throw new ClientException("Invalid percent-encoding in the host '" ~ host ~ "'");
}

/// Whether and which authentication methods are allowed (`ConnectionOptions.requireAuth`).
struct AuthRequirement
{
    /// The methods named, e.g. `["scram-sha-256", "md5"]`.
    string[] methods;
    /// Whether the list forbids them (`!method`) instead of requiring one of them.
    bool negated;

    /// Whether `method` (`password`, `md5`, `scram-sha-256`, `none`, ...) may be used.
    bool allows(string method) const pure nothrow
    {
        import std.algorithm.searching : canFind;

        if (methods.length == 0)
            return true;
        return methods.canFind(method) != negated;
    }
}

/++
Parses a `require_auth` value.

Throws: `ClientException` for an unknown method, or a list mixing required
and forbidden methods.
+/
AuthRequirement parseRequireAuth(string value)
{
    import std.algorithm.searching : canFind;
    import std.array : split;
    import std.string : strip;

    AuthRequirement r;
    if (value.strip.length == 0)
        return r;
    bool first = true;
    foreach (part; value.split(","))
    {
        auto m = part.strip;
        const neg = m.length && m[0] == '!';
        if (neg)
            m = m[1 .. $];
        if (!first && neg != r.negated)
            throw new ClientException("require_auth can't mix required and forbidden ('!') methods");
        r.negated = neg;
        first = false;
        if (!["password", "md5", "scram-sha-256", "gss", "sspi", "none"].canFind(m))
            throw new ClientException("Unknown require_auth method '" ~ m ~ "'");
        r.methods ~= m;
    }
    return r;
}

///
unittest
{
    assert(parseRequireAuth("scram-sha-256").allows("scram-sha-256"));
    assert(!parseRequireAuth("scram-sha-256").allows("md5"));
    assert(!parseRequireAuth("scram-sha-256").allows("none"));
    assert(parseRequireAuth("!password").allows("none") && !parseRequireAuth("!password").allows("password"));
    assert(parseRequireAuth("").allows("password"));
}

/// Transaction isolation levels (`Connection.begin`).
enum IsolationLevel
{
    /// The session's default (`default_transaction_isolation`, normally read committed).
    default_,
    /// Read uncommitted (PostgreSQL runs it as read committed).
    readUncommitted,
    /// Read committed.
    readCommitted,
    /// Repeatable read (snapshot isolation).
    repeatableRead,
    /// Serializable.
    serializable,
}

/++
`name` as a quoted SQL identifier: `"name"`, with embedded double quotes doubled.

Throws: `ClientException` for an empty name or one with a NUL character.
+/
string quoteIdentifier(string name) pure
{
    import std.array : replace;
    import std.string : indexOf;

    if (name.length == 0 || name.indexOf('\0') >= 0)
        throw new ClientException("Invalid identifier");
    return `"` ~ name.replace(`"`, `""`) ~ `"`;
}

///
unittest
{
    assert(quoteIdentifier("sp1") == `"sp1"` && quoteIdentifier(`a"b`) == `"a""b"`);
}

private:

E parseKeyword(E)(string key, string value, const string[] names)
{
    foreach (i, n; names)
        if (n == value)
            return cast(E) i;
    throw new ClientException("Invalid " ~ key ~ " '" ~ value ~ "'");
}

TlsVersion parseTlsVersion(string key, string value)
{
    switch (value)
    {
    case "TLSv1.2":
        return TlsVersion.tls12;
    case "TLSv1.3":
        return TlsVersion.tls13;
    case "TLSv1", "TLSv1.1":
        throw new ClientException(key ~ " " ~ value ~ " is not supported: TLS 1.2 is the oldest version");
    default:
        throw new ClientException("Invalid " ~ key ~ " '" ~ value ~ "'");
    }
}

ushort parsePort(string text)
{
    import std.conv : ConvException, to;
    import std.string : strip;

    const s = text.strip;
    if (s.length == 0)
        return 0;
    try
        return s.to!ushort;
    catch (ConvException)
        throw new ClientException("Invalid port '" ~ s ~ "'");
}
