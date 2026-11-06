/++
The test server: `POSTGRES_HOST` (`host` or `host:port`, port 5432 by
default), `POSTGRES_DB` (default `testdb`), `POSTGRES_USER` (default
`testuser`), `POSTGRES_PASSWORD`.

These names are deliberately not libpq's `PG*` variables, which the library
itself will read as defaults.
+/
module integrationtests.server;

import std.process : environment;

import postgresql;

/// Whether a server is configured.
bool serverConfigured()
{
    return environment.get("POSTGRES_HOST", "").length > 0;
}

/// Host name of the test server.
string serverHost()
{
    import std.string : lastIndexOf;

    const value = environment.get("POSTGRES_HOST", "");
    const colon = value.lastIndexOf(':');
    return colon < 0 ? value : value[0 .. colon];
}

/// Port of the test server.
ushort serverPort()
{
    import std.conv : to;
    import std.string : lastIndexOf;

    const value = environment.get("POSTGRES_HOST", "");
    const colon = value.lastIndexOf(':');
    return colon < 0 ? 5432 : value[colon + 1 .. $].to!ushort;
}

/// The test database.
string databaseName()
{
    return environment.get("POSTGRES_DB", "testdb");
}

/// The test user and password.
string userName()
{
    return environment.get("POSTGRES_USER", "testuser");
}

/// ditto
string password()
{
    return environment.get("POSTGRES_PASSWORD", "");
}

/++
Whether `integration-tests/setup-server.sh` prepared the server (`POSTGRES_SETUP=1`):
TLS with the test certificates and a user per authentication method.
+/
bool serverSetUp()
{
    return environment.get("POSTGRES_SETUP", "") == "1";
}

/// The directory of the test certificates (`POSTGRES_TLS_DIR`, default `integration-tests/tls`).
string tlsDir()
{
    import std.path : absolutePath;

    return environment.get("POSTGRES_TLS_DIR", "integration-tests/tls").absolutePath;
}

/// A file in `tlsDir`.
string tlsFile(string name)
{
    import std.path : buildPath;

    return buildPath(tlsDir(), name);
}

/// Options for the test server and user, without TLS unless `sslMode` says otherwise.
ConnectionOptions serverOptions(SslMode sslMode = SslMode.prefer)
{
    ConnectionOptions o;
    o.host = serverHost();
    o.port = serverPort();
    o.database = databaseName();
    o.user = userName();
    o.password = password();
    o.sslMode = sslMode;
    return o;
}

/// Options for one of the users made by the setup script (password `<user>_pw` unless given).
ConnectionOptions userOptions(string user, SslMode sslMode = SslMode.disable, string pw = null)
{
    auto o = serverOptions(sslMode);
    o.user = user;
    o.password = pw is null ? user ~ "_pw" : pw;
    return o;
}

/// Connects to the test server.
Connection connectToServer(SslMode sslMode = SslMode.prefer)
{
    return new Connection(serverOptions(sslMode));
}

/// The first value of the first row of `sql` as text (the result is closed).
string scalar(Connection conn, string sql)
{
    auto r = conn.query(sql);
    scope (exit)
        r.close();
    if (r.empty)
        return null;
    return r.front.getString(0);
}
