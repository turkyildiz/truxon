// Truxon incident responder — runs on the workstation via systemd timer.
// When watchdog checks stay red past the playbook window, summon a headless
// Claude Code session to investigate and fix (code/functions autonomous;
// DB data/schema changes are proposed by email, never applied).
//
// Needs NO privileged credentials: it reads health from the watchdog
// function (anon) and reports back through the same function's report mode.
//
// Env (~/.config/truxon/responder.env):
//   SUPABASE_URL, SUPABASE_ANON_KEY, WATCHDOG_REPORT_KEY,
//   TRUXON_REPO (default /home/turkyildiz/TRUXON)
//
// Guarantees: at most one summon per SUMMON_COOLDOWN_MIN; a check must be
// failing for at least FAIL_AGE_MIN (playbooks get their chance first).

import { execFileSync, execSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const ENV_FILE = join(homedir(), '.config/truxon/responder.env')
const STATE_DIR = join(homedir(), '.local/state/truxon-responder')
const FAIL_AGE_MIN = 15
const SUMMON_COOLDOWN_MIN = 60
const CLAUDE_TIMEOUT_MIN = 25

const env = Object.fromEntries(
  readFileSync(ENV_FILE, 'utf8').split('\n')
    .filter((l) => l.includes('=') && !l.startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
)
const REPO = env.TRUXON_REPO ?? '/home/turkyildiz/TRUXON'
mkdirSync(STATE_DIR, { recursive: true })

const log = (m) => console.log(`[responder] ${new Date().toISOString()} ${m}`)

// --- cooldown gate ---
const lockFile = join(STATE_DIR, 'last_summon')
if (existsSync(lockFile)) {
  const last = Number(readFileSync(lockFile, 'utf8').trim() || 0)
  if (Date.now() - last < SUMMON_COOLDOWN_MIN * 60000) {
    log('cooldown active, exiting')
    process.exit(0)
  }
}

// --- run a watchdog sweep and read its stateful results ---
const res = await fetch(`${env.SUPABASE_URL}/functions/v1/watchdog`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`, 'Content-Type': 'application/json' },
  body: '{}',
})
if (!res.ok) {
  // The watchdog itself is down — that IS the incident.
  log(`watchdog endpoint unreachable: ${res.status}`)
}
const wd = res.ok ? await res.json() : { checks: [], recent_failures: [], watchdog_down: res.status }

const now = Date.now()
const stubborn = (wd.checks ?? []).filter((c) =>
  !c.ok && c.last_change && (now - new Date(c.last_change).getTime()) > FAIL_AGE_MIN * 60000,
)
if (!res.ok) stubborn.push({ name: 'watchdog_endpoint', ok: false, detail: `HTTP ${res.status}`, last_change: new Date().toISOString() })

if (!stubborn.length) {
  log(`ok (${(wd.checks ?? []).filter((c) => c.ok).length}/${(wd.checks ?? []).length} checks green, no stubborn failures)`)
  process.exit(0)
}

const summary = stubborn.map((c) => `- ${c.name}: ${c.detail} (failing since ${c.last_change})`).join('\n')

const prompt = `You are the Truxon incident responder, summoned automatically because production
watchdog checks have been failing for over ${FAIL_AGE_MIN} minutes despite automatic playbooks.

FAILING CHECKS:
${summary}

RECENT INBOX FAILURES (may be related):
${JSON.stringify(wd.recent_failures ?? [], null, 1).slice(0, 2000)}

Repo: ${REPO} (you are already in it). Read docs/TECHNICAL.md for architecture.
Supabase project ref okoeeyxxvzypjiumraxq; deploy edge functions with the
SUPABASE_ACCESS_TOKEN env prefix form used throughout git history.

YOUR MANDATE:
1. Investigate the root cause. Check edge function behavior, reproduce if possible.
2. AUTONOMOUS: code fixes, edge function redeploys, git commit+push, re-running the
   watchdog endpoint to verify recovery.
3. PROPOSE-ONLY (never execute): production data changes (INSERT/UPDATE/DELETE on
   business tables), schema migrations, secrets changes, anything irreversible.
   Write proposed SQL/steps into your final summary instead.
4. Do not touch: customer/load/invoice data, auth users, storage objects.
5. Keep the investigation under ~15 minutes of work. If the cause is external
   (provider outage, platform incident), say so and stop — do not thrash.
6. End with a short plain-language RESOLUTION section: what was wrong, what you did,
   what (if anything) needs the owner.`

log(`summoning Claude for: ${stubborn.map((c) => c.name).join(', ')}`)
writeFileSync(lockFile, String(now))

let claudeBin = ''
try {
  claudeBin = execSync(
    'ls -d ' + join(homedir(), '.config/Claude/claude-code/*/claude') + ' 2>/dev/null | sort -V | tail -1',
    { encoding: 'utf8' },
  ).trim()
} catch { /* fall through */ }

let sessionOut = ''
let resolution = 'Responder could not run a Claude session (CLI missing on this machine).'
if (claudeBin) {
  try {
    sessionOut = execFileSync(claudeBin, ['-p', prompt, '--dangerously-skip-permissions'], {
      cwd: REPO,
      encoding: 'utf8',
      timeout: CLAUDE_TIMEOUT_MIN * 60000,
      maxBuffer: 16 * 1024 * 1024,
    })
    resolution = sessionOut.slice(-6000)
  } catch (e) {
    sessionOut = String(e.stdout ?? '') + '\n' + String(e.stderr ?? '')
    resolution = `Session ended abnormally (${e.code ?? e.signal ?? 'error'}). Tail:\n${sessionOut.slice(-3000)}`
  }
  writeFileSync(join(STATE_DIR, `incident-${new Date().toISOString().replace(/[:.]/g, '-')}.log`), prompt + '\n\n=== SESSION ===\n' + sessionOut)
}

// --- report by email through the watchdog function ---
try {
  const rep = await fetch(`${env.SUPABASE_URL}/functions/v1/watchdog`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.SUPABASE_ANON_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      key: env.WATCHDOG_REPORT_KEY,
      report: {
        subject: `investigated: ${stubborn.map((c) => c.name).join(', ')}`,
        body: `Failing checks:\n${summary}\n\n${resolution}`,
      },
    }),
  })
  log(`report emailed: ${rep.status}`)
} catch (e) {
  log(`report email failed: ${e.message}`)
}
