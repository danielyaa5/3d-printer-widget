const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');

(async () => {
  const browser = await chromium.launch({ headless: true, channel: process.env.PRINT_TEST_BROWSER || 'chrome' });
  const base = process.env.PRINT_SITE_URL || 'http://127.0.0.1:8765/3d-printer-widget/';
  const output = 'build/SiteQA.noindex';
  await fs.mkdir(output, { recursive: true });
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => { if (response.url().startsWith(base) && response.status() >= 400) errors.push(`${response.status()}: ${response.url()}`); });
    await page.goto(base, { waitUntil: 'networkidle' });
    await page.locator('header .brand img').evaluate(image => image.decode());
    for (const [width, height] of [[1440, 1000], [768, 1024], [390, 844], [320, 720]]) {
      await page.setViewportSize({ width, height });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth), false, `Overflow at ${width}px`);
      await page.locator('footer').scrollIntoViewIfNeeded();
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.screenshot({ path: `${output}/website-${width}.png`, fullPage: true });
    }
    assert.deepEqual(await page.locator('img').evaluateAll(images => images.filter(image => !image.complete || !image.naturalWidth).map(image => image.src)), []);
    for (const [value, label] of [['circlePercent', '64'], ['percent', '64%'], ['time', '42m'], ['circle', '']]) {
      await page.locator(`input[value="${value}"]`).check();
      assert.equal(await page.locator('#menu-demo .menu-value').textContent(), label);
    }
    await page.locator('#compatibility details').nth(3).locator('summary').click();
    assert.equal(await page.locator('#compatibility details').nth(3).getAttribute('open'), '');
    assert.deepEqual(await page.locator('a[href^="#"]').evaluateAll(links => links.map(link => link.getAttribute('href')).filter(href => !document.getElementById(href.slice(1)))), []);
    for (const link of await page.locator('[data-download]').all()) assert.equal(await link.getAttribute('href'), 'https://github.com/danielyaa5/3d-printer-widget/releases/latest/download/Print-Progress.dmg');
    await page.locator('video').evaluate(async video => {
      video.load();
      await new Promise((resolve, reject) => { video.onloadedmetadata = resolve; video.onerror = () => reject(new Error('Demo video could not load')); });
      if (!Number.isFinite(video.duration) || video.duration <= 0) throw new Error('Demo video has no duration');
    });
    await page.emulateMedia({ reducedMotion: 'reduce' });
    assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).scrollBehavior), 'auto');
    assert.deepEqual(errors, []);
    console.log('PASS: four responsive sizes, loaded images/video, menu previews, compatibility disclosure, anchors, download targets, reduced motion and browser errors.');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
