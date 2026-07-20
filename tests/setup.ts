// Loaded via --import in the npm test script; runs in every test process
// before any test file. Scrubs ambient environment variables that change
// provider behavior, so a developer's shell config (e.g. a real
// KIMI_MEMBERSHIP_LEVEL override) cannot break the suite. Tests that need
// one of these variables set it explicitly and restore it afterwards.
delete process.env.KIMI_MEMBERSHIP_LEVEL;
