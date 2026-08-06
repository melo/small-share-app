// Playwright config for the share end-to-end suite.
//
// No webServer block: run.sh brings the app up (locally or on a remote box
// through a tunnel) before invoking playwright, because the app is a docker
// image that has to be built, and a throwaway one at that.
const { defineConfig, devices } = require('/usr/local/lib/node_modules/playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  // Serial. The suite asserts on "recent uploads", which is per-browser state,
  // and on counts from a store it is also writing to.
  workers: 1,
  fullyParallel: false,
  reporter: [['list']],
  timeout: 30_000,
  expect: { timeout: 10_000 },
  use: {
    baseURL: process.env.BASE_URL || 'http://127.0.0.1:8099',
    // The Copy button uses navigator.clipboard, which needs permission and a
    // secure context. http://127.0.0.1 counts as secure.
    permissions: ['clipboard-read', 'clipboard-write'],
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    ...devices['Desktop Chrome'],
  },
});
