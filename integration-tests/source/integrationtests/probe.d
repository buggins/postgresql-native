/++
Scaffold tests: the runners work in both I/O modes and reach the server.
They are replaced by real connection tests in P1.
+/
module integrationtests.probe;

import core.time : seconds;
import std.exception : enforce;

import dbwire.io.backend : backendFor, IoMode;

import postgresql : postgresqlVersion;
import integrationtests.server : serverHost, serverPort;

/// The library is linked.
void testVersion()
{
    enforce(postgresqlVersion.length >= 5, "version string");
}

/++
Opens a TCP connection through dbwire's I/O backend for the current mode and
sends an SSLRequest (length 8, code 80877103); the server answers one byte,
`S` (TLS available) or `N` (not available), before any authentication.
+/
void testSslRequestProbe()
{
    auto transport = backendFor(IoMode.auto_).connect(serverHost(), serverPort(), 10.seconds);
    scope (exit)
        transport.close();
    static immutable ubyte[8] sslRequest = [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F];
    transport.write(sslRequest[]);
    ubyte[1] answer;
    enforce(transport.read(answer[]) == 1, "no answer to the SSLRequest");
    enforce(answer[0] == 'S' || answer[0] == 'N', "unexpected answer to the SSLRequest");
}
