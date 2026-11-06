/// Thread-mode tests: connections used by several threads at once (from P4/P5).
module threadtests;

import integrationtests.harness : TestCase;

/// Tests registered by the thread runner.
immutable TestCase[] threadTests = [];
