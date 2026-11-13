import { chromium } from 'playwright-core'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'

// Usage: node tools/demo-screenshots/mock-api.mjs frontend/dist   (serves :7790)
//        node tools/demo-screenshots/capture.mjs docs/screenshots    (needs: npm i playwright-core; uses installed Edge)
const OUT = process.argv[2]
const ONLY = process.argv[3] || ''
mkdirSync(OUT, { recursive: true })
const browser = await chromium.launch({ executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' })
const ctx = await browser.newContext({ viewport: { width: 1600, height: 940 }, deviceScaleFactor: 1.5, locale: 'en-US', colorScheme: 'light' })
await ctx.addInitScript(() => { try { if (!sessionStorage.getItem('seeded')) { localStorage.clear(); localStorage.setItem('iptvplay_leftW', '300'); localStorage.setItem('iptvplay_rightW', '780'); sessionStorage.setItem('seeded', '1') } } catch {} })
const page = await ctx.newPage()
page.on('pageerror', (e) => console.log('PAGEERROR', e.message))
const shot = async (name, sel) => {
  if (ONLY && !name.includes(ONLY)) return
  if (!sel) { await page.screenshot({ path: join(OUT, name), animations: 'disabled' }) }
  else {
    const box = await page.evaluate((q) => { const r = [...document.querySelectorAll(q)].map((e) => e.getBoundingClientRect()).find((r) => r.width > 0); return r ? { x: r.x, y: r.y, width: r.width, height: r.height } : null }, sel)
    if (!box) { console.log('NOBOX', sel); return }
    await page.screenshot({ path: join(OUT, name), animations: 'disabled', clip: box })
  }
  console.log('shot', name)
}
await page.goto('http://127.0.0.1:7790/', { waitUntil: 'networkidle' })
await page.locator('.app').first().waitFor({ timeout: 15000 })
await page.waitForTimeout(1200)


// browse one source in the catalog
await page.locator('.wb-catalog select').nth(1).selectOption({ label: 'Provider A' })
await page.waitForTimeout(800)
// drill into a catalog group so channels show
const grp = page.getByText('NL | SPORT', { exact: true }).first()
if (await grp.count()) { await grp.click(); await page.waitForTimeout(800) }
const noBtn = page.locator('.wb-list').getByRole('button', { name: 'No.', exact: true })
if (await noBtn.count()) { await noBtn.first().click(); await page.waitForTimeout(600) }
await shot('workbench.png')
await shot('catalog.png', '.wb-catalog')
await shot('bouquet.png', '.wb-list')

// quality probe from the first 📊 in the catalog
const probe = page.locator('.wb-catalog .probe-btn').first()
if (await probe.count()) {
  await probe.click()
  await page.locator('.modal').first().waitFor({ timeout: 5000 })
  await page.waitForTimeout(2500)
  await shot('quality-probe.png', '.modal')
  await page.keyboard.press('Escape'); await page.waitForTimeout(300)
}

// EPG + settings tabs
for (const [label, file, sel] of [['EPG', 'epg.png', null], ['Media Servers', 'media-servers.png', null]]) {
  const b = page.getByRole('button', { name: label, exact: true }).first()
  if (await b.count()) { await b.click(); await page.waitForTimeout(1200); await shot(file, sel) }
}
await browser.close()
