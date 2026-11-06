/// Integration test runner for fiber mode: every test runs inside a vibe.d task.
module app;

import vibe.core.core : exitEventLoop, runEventLoop, runTask;

import postgresql : postgresqlHasVibe;
import integrationtests.harness;
import vibetests;

static assert(postgresqlHasVibe, "postgresql-native must be built with vibe-core support for this runner");

int main()
{
    int failures;

    void runTests() nothrow
    {
        scope (exit)
            exitEventLoop();
        try
            failures = runAllTests(RunnerContext("vibe"), vibeTests);
        catch (Exception e)
            failures = 1;
    }

    runTask(&runTests);
    runEventLoop();
    return failures == 0 ? 0 : 1;
}
