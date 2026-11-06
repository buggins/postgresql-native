/// Integration test runner for thread mode (blocking Phobos sockets).
module app;

import integrationtests.harness;
import threadtests : threadTests;

int main()
{
    return runAllTests(RunnerContext("phobos"), threadTests) == 0 ? 0 : 1;
}
