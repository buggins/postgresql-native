/// Fiber-mode tests that need vibe-core: waiting for the server doesn't block the event loop (from P5).
module vibetests;

import integrationtests.harness : TestCase;

/// Tests registered by the vibe.d runner.
immutable TestCase[] vibeTests = [];
