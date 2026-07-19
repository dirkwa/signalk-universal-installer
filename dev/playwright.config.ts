import { defineConfig, devices } from '@playwright/test';

const PORT = process.env.PORT ?? '4000';

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
  // Starts the dev server with sample data if it isn't already running.
  webServer: {
    command: './dev.sh demo',
    url: `http://localhost:${PORT}/signalk`,
    reuseExistingServer: true,
    timeout: 60_000,
  },
});
