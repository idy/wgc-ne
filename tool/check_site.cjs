// Run via: npm exec --yes --package=playwright@1.56.1 -- node tool/check_site.cjs <index.html> <output-dir> [home]
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');

function playwright() {
  try { return require('playwright'); } catch {}
  for (const directory of process.env.PATH.split(path.delimiter)) {
    const executable = path.join(directory, 'playwright');
    if (fs.existsSync(executable)) return require(path.dirname(fs.realpathSync(executable)));
  }
  throw new Error('Run this checker with the pinned Playwright npm package.');
}

(async () => {
  const input = path.resolve(process.argv[2]);
  const output = path.resolve(process.argv[3]);
  const home = process.argv[4] === 'home';
  fs.mkdirSync(output, { recursive: true });
  const browser = await playwright().chromium.launch({ headless: true, chromiumSandbox: true });
  try {
    for (const [label, width, height, colorScheme] of [
      ['desktop-light', 1360, 1000, 'light'],
      ['mobile-light', 375, 812, 'light'],
      ['mobile-dark', 375, 812, 'dark'],
    ]) {
      const context = await browser.newContext({ viewport: { width, height }, colorScheme, reducedMotion: 'reduce' });
      const page = await context.newPage();
      const failures = [];
      page.on('pageerror', error => failures.push(error.message));
      page.on('requestfailed', request => failures.push(request.url()));
      await page.goto(pathToFileURL(input).href, { waitUntil: 'load' });
      await page.evaluate(() => document.fonts.ready);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      assert.equal(overflow, false, `${label}: page overflows horizontally`);
      if (home) {
        const section = page.locator('[aria-labelledby="wgc-ne-title"]');
        assert.equal(await section.locator('h2').textContent(), 'WGC NE');
        assert.equal(await section.locator('a').count(), 3);
        await page.locator('.theme-toggle').click();
        assert.equal(await page.locator('html').getAttribute('data-theme'), colorScheme === 'dark' ? 'light' : 'dark');
        await page.locator('.theme-toggle').click();
      } else {
        assert.match(await page.title(), /WGC NE/);
        const stages = page.locator('[data-stage]');
        assert.equal(await stages.count(), 5);
        await page.locator('[data-stage="wgc"]').click();
        assert.equal(await page.locator('[data-stage="wgc"]').getAttribute('aria-pressed'), 'true');
        await page.locator('input[value="custom"]').check();
        assert.equal(await page.locator('#runtime-board').getAttribute('data-transport'), 'custom');
        const transport = JSON.parse(await page.locator('#socket-config').textContent());
        assert.equal(typeof transport.type, 'string');
        assert.notEqual(transport.type, 'udp');
        assert.equal(typeof transport.options, 'object');
        await page.locator('#flow-next').click();
        assert.equal(await page.locator('[data-stage][aria-pressed="true"]').count(), 1);
        await page.keyboard.press('Tab');
        assert.equal(await page.evaluate(() => document.activeElement !== document.body), true);
      }
      await page.locator('h1').click();
      await page.evaluate(() => scrollTo(0, 0));
      await page.screenshot({ path: path.join(output, `${home ? 'home' : 'site'}-${label}.png`), fullPage: true });
      assert.deepEqual(failures, [], `${label}: page errors or missing assets`);
      console.log(`${home ? 'home' : 'site'} ${label}: layout and interactions passed`);
      await context.close();
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
