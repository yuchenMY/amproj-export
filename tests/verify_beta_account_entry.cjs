// Browser integration check against the existing account page with fixture data.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const source = fs.readFileSync(path.join(__dirname, '../AMProjExport/AMProjBetaDiagnostics.m'), 'utf8');
const block = source.split('NSString *AMProjBetaDiagnosticsAccountScript(void) {')[1]
  .split('\nvoid AMProjBetaDiagnosticsPresent')[0];
const script = [...block.matchAll(/@?"((?:\\.|[^"\\])*)"/g)].map(match => JSON.parse('"' + match[1] + '"')).join('');

(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
    await page.route('**/api/**', route => route.fulfill({ json: { code: 0, data: {} } }));
    await page.addInitScript(() => {
      window.diagnosticMessages = [];
      window.webkit = { messageHandlers: { amAccount: {
        postMessage: value => window.diagnosticMessages.push(value)
      } } };
    });
    await page.goto('https://am.meowcr.cn/me.html?embed=1&platform=ios', { waitUntil: 'networkidle' });
    await page.evaluate(() => window.dispatchEvent(new CustomEvent('af:user', { detail: {
      id: 'design-fixture', username: 'beta_preview', nickname: '测试账号', level: 3, points: 120,
      iosAccess: { membershipEnabled: true, membershipPermanent: true, deviceCount: 1, deviceLimit: 2,
        importEnabled: true, exportEnabled: true, cloudPluginsEnabled: true }
    } })));
    await page.evaluate(script);
    await page.evaluate(script);
    assert.equal(await page.locator('#am-beta-diagnostics').count(), 1, 'Entry must be idempotent');
    assert.equal(await page.evaluate(() => document.getElementById('am-beta-diagnostics').nextElementSibling
      .contains(document.getElementById('btnLogout'))), true, 'Entry must precede logout');
    await page.locator('#am-beta-diagnostics').click();
    assert.equal(await page.evaluate(() => window.diagnosticMessages.filter(message => message.type === 'diagnostics').length), 1);
    assert.equal((await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--af-brand'))).trim(), '#39C5BB');
    if (process.env.AMPROJ_UI_SCREENSHOT) await page.screenshot({ path: process.env.AMPROJ_UI_SCREENSHOT });
    for (const url of ['http://am.meowcr.cn/me.html', 'https://untrusted.invalid/me.html', 'https://am.meowcr.cn/backup.html']) {
      const other = await browser.newPage();
      await other.route('**/*', route => route.fulfill({ contentType: 'text/html',
        body: '<div id="meContent"><div><button id="btnLogout">Logout</button></div></div>' }));
      await other.goto(url);
      await other.evaluate(script);
      assert.equal(await other.locator('#am-beta-diagnostics').count(), 0, 'Untrusted page must not get an entry');
      await other.close();
    }
    console.log('PASS: account entry, exact placement, idempotence, bridge click, brand color, and origin/path exclusions');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
