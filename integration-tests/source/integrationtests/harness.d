/++
Integration test harness shared by the thread (Phobos) and fiber (vibe.d)
runners. Tests are written once here; each runner calls `runAllTests` in its
own I/O context. Tests that need a server run only when `POSTGRES_HOST` is set.
+/
module integrationtests.harness;

import core.exception : AssertError;
import std.stdio : stderr, writefln;

import integrationtests.basic;
import integrationtests.connect;
import integrationtests.copynotify;
import integrationtests.highlevel;
import integrationtests.moretypes;
import integrationtests.params;
import integrationtests.probe;
import integrationtests.server : serverConfigured;
import integrationtests.statements;
import integrationtests.types;

/// Integration test entry point. Throws on failure.
alias TestFunction = void function();

/// A named integration test.
struct TestCase
{
    /// Test name used in reports.
    string name;
    /// Test body.
    TestFunction run;
    /// Whether the test needs a server.
    bool needsServer;
}

/// All integration tests, in execution order.
immutable TestCase[] allTests = [
    TestCase("library version", &testVersion, false),
    TestCase("server answers an SSLRequest", &testSslRequestProbe, true),
    TestCase("connect, session information, ping", &testConnect, true),
    TestCase("URI and key=value strings, startup parameters", &testConnectionStrings, true),
    TestCase("failed logins", &testLoginErrors, true),
    TestCase("authentication methods, require_auth, SASLprep", &testAuthMethods, true),
    TestCase("TLS: sslmode, verification, client certificates, direct TLS", &testTls, true),
    TestCase("protocol version 3.2", &testProtocolVersion, true),
    TestCase("failover to the next host", &testFailover, true),
    TestCase("simple queries: text rows, tags, streaming", &testSimpleQuery, true),
    TestCase("exec: affected rows, several statements", &testExec, true),
    TestCase("errors keep the connection usable", &testErrors, true),
    TestCase("notices", &testNotices, true),
    TestCase("busy connections, FATAL errors", &testBusyAndFatal, true),
    TestCase("integers, booleans, text, bytea, uuid, json", &testScalarTypes, true),
    TestCase("float4 and float8", &testFloats, true),
    TestCase("numeric", &testNumeric, true),
    TestCase("dates, times, timestamps, intervals", &testDateTimes, true),
    TestCase("text fallback, variants, simple-protocol values", &testTextFallbackAndVariants, true),
    TestCase("parameters of every D type", &testParameterTypes, true),
    TestCase("placeholders, client and server errors, RETURNING", &testPlaceholdersAndErrors, true),
    TestCase("statement cache: reuse, eviction, invalidation", &testStatementCache, true),
    TestCase("prepared statements", &testPreparedStatements, true),
    TestCase("Variant[] parameters (run-time values)", &testVariantParameters, true),
    TestCase("several result sets", &testMultipleResults, true),
    TestCase("transactions and savepoints", &testTransactions, true),
    TestCase("statement_timeout, idle cancel", &testStatementTimeout, true),
    TestCase("pipelines", &testPipelines, true),
    TestCase("struct mapping: query!T, queryRow!T, queryValue!T, insert", &testStructMapping, true),
    TestCase("bulk insert: several statements, atomic", &testBulkInsert, true),
    TestCase("pool: reuse, session reset, limits", &testPool, true),
    TestCase("target_session_attrs, load_balance_hosts", &testTargetSessionAttrs, true),
    TestCase("PG* environment, password file, ~/.postgresql files", &testEnvironmentAndUserFiles, true),
    TestCase("hostaddr and connection services", &testHostaddrAndServices, true),
    TestCase("arrays", &testArrays, true),
    TestCase("ranges and multiranges", &testRanges, true),
    TestCase("composite types, enums, domains", &testCompositesEnumsDomains, true),
    TestCase("inet, cidr, macaddr, bit strings, pg_lsn", &testNetworkAndBits, true),
    TestCase("geometric types", &testGeometric, true),
    TestCase("hstore, citext, types read as text", &testExtensionAndTextTypes, true),
    TestCase("PostGIS geometry and geography (when installed)", &testPostgis, true),
    TestCase("COPY FROM STDIN: text, CSV, binary, structs, errors", &testCopyIn, true),
    TestCase("COPY TO STDOUT: text, CSV, binary", &testCopyOut, true),
    TestCase("LISTEN/NOTIFY", &testListenNotify, true),
];

/// Runner identity, for reports.
struct RunnerContext
{
    /// Runner name used in reports, e.g. "phobos" or "vibe".
    string name;
}

/++
Runs all integration tests, plus `extraTests` from the runner, and prints a report.

Returns: the number of failed tests.
+/
int runAllTests(RunnerContext runner, const TestCase[] extraTests = null)
{
    const withServer = serverConfigured();
    if (!withServer)
        writefln("[%s] POSTGRES_HOST is not set: skipping tests that need a server", runner.name);
    int failures, skipped;
    foreach (test; allTests ~ extraTests)
    {
        if (test.needsServer && !withServer)
        {
            skipped++;
            writefln("[%s] SKIP  %s", runner.name, test.name);
            continue;
        }
        try
        {
            test.run();
            writefln("[%s] PASS  %s", runner.name, test.name);
        }
        catch (AssertError e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s (%s:%s)", runner.name, test.name, e.msg, e.file, e.line);
        }
        catch (Exception e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s", runner.name, test.name, e.msg);
        }
    }
    writefln("[%s] %d test(s), %d failed, %d skipped", runner.name, allTests.length + extraTests.length, failures,
            skipped);
    return failures;
}
