/++
The test server: `POSTGRES_HOST` (`host` or `host:port`, port 5432 by
default), `POSTGRES_DB` (default `testdb`), `POSTGRES_USER` (default
`testuser`), `POSTGRES_PASSWORD`.

These names are deliberately not libpq's `PG*` variables, which the library
itself will read as defaults.
+/
module integrationtests.server;

import std.process : environment;

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
