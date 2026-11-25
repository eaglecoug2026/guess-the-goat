import { defineConfig } from '@playwright/test';
const sizes = { phone: { width: 390, height: 844 }, desktop: { width: 1280, height: 900 } };
export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 30000,
  fullyParallel: true,
  workers: 4,
  reporter: [['list']],
  use: { baseURL: 'http://127.0.0.1:4173', timezoneId: 'America/Los_Angeles', locale: 'en-US' },
  webServer: { command: 'node tests/e2e/serve.mjs 4173', url: 'http://127.0.0.1:4173/index.html', reuseExistingServer: true },
  projects: ['chromium', 'webkit'].flatMap(browserName => Object.entries(sizes).map(([n, viewport]) => ({
    name: `${browserName}-${n}`, use: { browserName, viewport }
  })))
});
