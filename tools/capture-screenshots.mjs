// Auto-capture the user-guide screenshots from a RUNNING IPTV Gateway instance.
//
// Why this exists: the screenshots in docs/USER-GUIDE.md must show the live app
// with YOUR providers/catalog — which only runs on your machine (the service
// can't be launched from the build tooling). So you run this once and it shoots
// all of them with the right filenames into docs/screenshots/.
//
// Prereqs (one-time, from the repo root):
//     npm i -D playwright
//     npx playwright install chromium
//
// Run (with the service + UI reachable):
//     # default base http://localhost:7777 (the service serves the built UI there)
//     node tools/capture-screenshots.mjs
//
//     # or against the Vite dev server, and with an admin password set:
//     BASE_URL=http://localhost:5173 ADMIN_PW=yourpass node tools/capture-screenshots.mjs
//
// Env:
//     BASE_URL   where the UI is served      (default http://localhost:7777)
//     ADMIN_PW   admin password, if you set one in config.json (default none)
//     OUT_DIR    output folder               (default docs/screenshots)

import { chromium } from 'playwright'
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'
import { mkdirSync } from 'node:fs'

const BASE = process.env.BASE_URL || 'http://localhost:7777'
const ADMIN_PW = process.env.ADMIN_PW || ''
const here = dirname(fileURLToPath(import.meta.url))
const OUT = resolve(process.env.OUT_DIR || join(here, '..', 'docs', 'screenshots'))
mkdirSync(OUT, { recursive: true })

const shot = (page, name) => page.screenshot({ path: join(OUT, name), animations: 'disabled' })
const shotOf = async (page, selector, name) => {
  const el = page.locator(selector).first()
  if (await el.count()) await el.screenshot({ path: join(OUT, name), animations: 'disabled' })
  else { console.warn(`  ! "${selector}" not found — full-page fallback for ${name}`); await shot(page, name) }
}
const clickTab = async (page, label) => {
  await page.getByRole('button', { name: label, exact: true }).first().click()
  await page.waitForTimeout(400)
}

const browser = await chromium.launch()
// wide viewport so the 3-panel workbench shows all columns (narrow widths collapse it)
const context = await browser.newContext({ viewport: { width: 1680, height: 1020 }, deviceScaleFactor: 2 })
// pre-seed the admin password so the initial /api probe passes and no login gate shows
if (ADMIN_PW) await context.addInitScript((pw) => localStorage.setItem('iptv.admin.pw', pw), ADMIN_PW)

const page = await context.newPage()
console.log(`Capturing ${BASE} -> ${OUT}`)
await page.goto(BASE, { waitUntil: 'networkidle' })

// fallback: if a login gate is shown anyway, fill it
const pwInput = page.locator('.login-gate input[type=password]')
if (await pwInput.count()) {
  if (!ADMIN_PW) console.warn('  ! login gate shown but ADMIN_PW not set — set it and re-run')
  else { await pwInput.fill(ADMIN_PW); await page.getByRole('button', { name: 'Log in' }).click() }
}
await page.locator('.app').first().waitFor({ timeout: 15000 })
await page.waitForTimeout(800) // let initial data settle

// 1. app overview — full Workbench with the three header tabs
await clickTab(page, 'Workbench')
await shot(page, 'app-overview.png')

// 2. the three-panel workbench
await shotOf(page, '.columns', 'workbench.png')

// 3. source editor modal (Add/Edit opens it)
const editBtn = page.getByRole('button', { name: 'Edit', exact: true }).first()
if (await editBtn.count()) await editBtn.click()
else await page.getByRole('button', { name: 'Add source', exact: true }).first().click()
await page.locator('.modal').first().waitFor({ timeout: 5000 })
await page.waitForTimeout(300)
await shotOf(page, '.modal', 'source-edit.png')
await page.keyboard.press('Escape')
await page.waitForTimeout(300)

// 4. catalog pane
await shotOf(page, '.wb-catalog', 'catalog-search.png')

// 5. bouquet pane
await shotOf(page, '.wb-list', 'bouquet.png')

// 6. EPG grid
await clickTab(page, 'EPG')
await shotOf(page, '.epg-view-wrap', 'epg.png')

// 7. settings
await clickTab(page, 'Settings')
await shotOf(page, '.settings-wrap', 'settings.png')

await browser.close()
console.log('Done. Screenshots written to', OUT)
