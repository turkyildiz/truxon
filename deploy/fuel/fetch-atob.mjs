#!/usr/bin/env node
// Truxon fuel fetcher — pulls the AtoB transactions CSV and pushes it into
// Truxon's fuel-import edge function. Runs on the NAS via cron at 03:00 and
// 16:00 local (see README.md). One-time manual login required first (AtoB uses
// Auth0); the persistent browser profile then keeps the session alive across
// runs and silently renews it. When the session finally expires, the run exits
// non-zero and emails an alert so the owner logs in once more.
//
// Env (deploy/fuel/fuel.env, chmod 600):
//   TRUXON_FUEL_IMPORT_URL   https://<ref>.supabase.co/functions/v1/fuel-import
//   FUEL_IMPORT_KEY          same value set as the fuel-import secret
//   ATOB_PROFILE_DIR         persistent browser profile dir (default ./.atob-profile)
//   FUEL_LOOKBACK_DAYS       export window, default 35 (month-to-date + settle lag)
//   ALERT_WEBHOOK            optional: watchdog heartbeat/report URL for failure email
//   WATCHDOG_REPORT_KEY      optional: to post the failure alert through the watchdog
//
// Usage:
//   node fetch-atob.mjs            # scheduled run
//   node fetch-atob.mjs --login    # first-time / re-auth: opens a window to log in
//
// NOTE: this drives the AtoB web UI (Playwright) rather than its private API,
// so it needs no reverse-engineered endpoints and mirrors exactly what a human
// does. Selectors are text-based; if AtoB changes its UI they may need updates.

import { chromium } from 'playwright'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const HERE = dirname(fileURLToPath(import.meta.url))
const env = loadEnv(join(HERE, 'fuel.env'))
const PROFILE = env.ATOB_PROFILE_DIR || join(HERE, '.atob-profile')
const LOOKBACK = Number(env.FUEL_LOOKBACK_DAYS || 35)
const LOGIN_MODE = process.argv.includes('--login')

function loadEnv(path) {
  try {
    return Object.fromEntries(readFileSync(path, 'utf8').split('\n')
      .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]))
  } catch { return {} }
}

const log = (m) => console.log(`[fuel] ${new Date().toISOString()} ${m}`)

async function alert(subject, body) {
  if (!env.ALERT_WEBHOOK || !env.WATCHDOG_REPORT_KEY) return
  try {
    await fetch(env.ALERT_WEBHOOK, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ report: { subject, body }, key: env.WATCHDOG_REPORT_KEY }),
    })
  } catch { /* best effort */ }
}

function fmt(d) {
  return `${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getDate()).padStart(2, '0')}/${d.getFullYear()}`
}

async function main() {
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    headless: !LOGIN_MODE,
    acceptDownloads: true,
  })
  const page = ctx.pages()[0] || await ctx.newPage()

  if (LOGIN_MODE) {
    log('login mode — a window is open; sign in to AtoB, then press Enter here.')
    await page.goto('https://app.atob.com/')
    await new Promise((r) => process.stdin.once('data', r))
    await ctx.close()
    log('session saved to the profile. Scheduled runs will reuse it.')
    return
  }

  await page.goto('https://app.atob.com/transactions', { waitUntil: 'domcontentloaded' })
  await page.waitForTimeout(4000)

  // Session check: if AtoB bounced us to Auth0 login, the session is dead.
  if (/auth0|login|signin/i.test(page.url()) || !(await page.getByText('Export Transactions').count())) {
    await ctx.close()
    await alert('Fuel fetch: AtoB session expired', `Could not reach the transactions page (${page.url()}). Run \`node fetch-atob.mjs --login\` on the NAS to re-authenticate.`)
    throw new Error('AtoB session expired — re-login needed')
  }

  const end = new Date()
  const start = new Date(end.getTime() - LOOKBACK * 86400_000)

  await page.getByText('Export Transactions').click()
  await page.waitForTimeout(800)
  // Fill the Start / End date inputs (labelled Start and End in the modal).
  const inputs = page.locator('input')
  await page.getByText('All Transaction Data').click().catch(() => {})
  // The two date fields are the modal's only date-like inputs.
  const dateInputs = await page.locator('input[value*="/20"]').all()
  if (dateInputs.length >= 2) {
    await dateInputs[0].fill(fmt(start))
    await dateInputs[1].fill(fmt(end))
  }

  const [download] = await Promise.all([
    page.waitForEvent('download', { timeout: 120_000 }),
    page.getByRole('button', { name: /download/i }).click(),
  ])
  const csv = readFileSync(await download.path(), 'utf8')
  log(`downloaded CSV: ${csv.split(/\r?\n/).length - 1} rows, ${csv.length} bytes`)
  await ctx.close()

  if (!/UUID/.test(csv.split(/\r?\n/)[0] || '')) throw new Error('Downloaded file is not the expected AtoB export')

  const res = await fetch(env.TRUXON_FUEL_IMPORT_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'text/csv', 'X-Fuel-Key': env.FUEL_IMPORT_KEY },
    body: csv,
  })
  const out = await res.json().catch(() => ({}))
  if (!res.ok) {
    await alert('Fuel import failed', `HTTP ${res.status}: ${JSON.stringify(out)}`)
    throw new Error(`fuel-import returned ${res.status}`)
  }
  log(`imported: ${JSON.stringify(out)}`)
}

main().catch((e) => { console.error(`[fuel] ERROR: ${e.message}`); process.exit(1) })
