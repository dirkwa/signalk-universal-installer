import { defineConfig, devices } from '@playwright/test';

// e2e runs against its OWN demo server on a dedicated port (default 4100),
// never against the developer's instance on 4000: reusing an arbitrary
// running server means the bundled sample NMEA feed may be missing and the
// suite outcome depends on unrelated state. Override with E2E_PORT.
const PORT = process.env.E2E_PORT ?? '4100';

export default defineConfig({
  testDir: './e2e',
  timeout: 30_000,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? 'github' : 'list',
  use: {
    baseURL: `http://localhost:${PORT}`,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  // demo-fg keeps the server in the foreground (exec, no daemonizing), so
  // Playwright supervises the real server process and tears it down cleanly.
  webServer: {
    command: `PORT=${PORT} ./dev.sh demo-fg`,
    url: `http://localhost:${PORT}/signalk`,
    reuseExistingServer: false,
    timeout: 60_000,
  },
});
