/++
Integration test harness shared by the thread (Phobos) and fiber (vibe.d)
runners. Tests are written once here; each runner calls `runAllTests` in its
own I/O context. Tests that need a server run only when `POSTGRES_HOST` is set.
+/
module integrationtests.harness;

import core.exception : AssertError;
import std.stdio : stderr, writefln;

import integrationtests.probe;
import integrationtests.server : serverConfigured;

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
