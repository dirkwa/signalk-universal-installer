import { test, expect } from '@playwright/test';

// Smoke tests against the dev instance (started automatically with sample
// NMEA data via playwright.config.ts webServer).

test('signalk API root responds', async ({ request }) => {
  const res = await request.get('/signalk');
  expect(res.ok()).toBeTruthy();
  const body = await res.json();
  expect(body.endpoints).toBeDefined();
});

test('vessel self data is populated from sample feed', async ({ request }) => {
  const res = await request.get('/signalk/v1/api/vessels/self');
  expect(res.ok()).toBeTruthy();
  const vessel = await res.json();
  expect(vessel.navigation).toBeDefined();
});

test('admin UI loads', async ({ page }) => {
  await page.goto('/admin/');
  await expect(page).toHaveTitle(/Signal K/i);
});
