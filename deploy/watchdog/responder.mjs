// Truxon incident responder — runs on the workstation via systemd timer.
// When watchdog checks stay red past the playbook window, summon a headless
// Claude Code session to INVESTIGATE (read-only) and email a diagnosis with
// a proposed fix. It never edits, commits, or deploys on its own: the
// watchdog endpoint is reachable with the public anon key, so a sustained
// induced failure must not be able to summon an agent with write powers.
//
// RESPONDER_AUTOFIX=1 in responder.env opts back into autonomous fixing
// (edits/redeploys/commits, still propose-only for DB data/schema). Only set
// it understanding the above: autofix hands code execution to whatever
// condition keeps the checks red.
//
// Needs NO privileged credentials: it reads health from the watchdog
// function (anon) and reports back through the same function's report mode.
//
// Env (~/.config/truxon/responder.env):
//   SUPABASE_URL, SUPABASE_ANON_KEY, WATCHDOG_REPORT_KEY,
//   TRUXON_REPO (default /home/turkyildiz/TRUXON), RESPONDER_AUTOFIX (0/1)
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
// HARD GATE (2026-07-21 review H-2): autofix grants commit+push to prod, and
// the trigger + prompt inputs include attacker-influenceable text (inbox
// failure messages). Arming it now requires BOTH flags — the second one is a
// deliberate speed bump so "=1" alone can never re-enable autonomous pushes.
const AUTOFIX = env.RESPONDER_AUTOFIX === '1'
  && env.RESPONDER_AUTOFIX_CONFIRM === 'I_ACCEPT_AUTONOMOUS_PROD_PUSH'
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
${AUTOFIX
    ? `1. Investigate the root cause. Check edge function behavior, reproduce if possible.
2. AUTONOMOUS: code fixes, edge function redeploys, git commit (NO push — the
   owner pushes), re-running the watchdog endpoint to verify recovery.
3. PROPOSE-ONLY (never execute): production data changes (INSERT/UPDATE/DELETE on
   business tables), schema migrations, secrets changes, anything irreversible.
   Write proposed SQL/steps into your final summary instead.
4. Do not touch: customer/load/invoice data, auth users, storage objects.`
    : `1. Investigate the root cause by READING the repo (code, docs, git history).
2. You are read-only: do not edit files, run commands with side effects, deploy,
   or commit. Diagnose and write the exact proposed fix (diff or steps) into
   your final summary for the owner to apply.`}
${AUTOFIX ? '5' : '3'}. Keep the investigation under ~15 minutes of work. If the cause is external
   (provider outage, platform incident), say so and stop — do not thrash.
${AUTOFIX ? '6' : '4'}. End with a short plain-language RESOLUTION section: what was wrong, what
   ${AUTOFIX ? 'you did' : 'you propose'}, what (if anything) needs the owner.`

log(`summoning Claude (${AUTOFIX ? 'AUTOFIX' : 'read-only investigate'}) for: ${stubborn.map((c) => c.name).join(', ')}`)
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
    // Read-only mode grants only inspection tools; nothing that mutates state.
    // AUTOFIX (explicit owner opt-in) restores full-permission autonomy.
    // Even armed, autofix no longer gets skip-permissions: an explicit tool
    // allowlist that can edit/deploy but has NO git push (review H-2 — the
    // prompt embeds inbox text an outsider can influence; a push to main
    // deploys prod, so that one action stays human-only).
    const claudeArgs = AUTOFIX
      ? ['-p', prompt, '--allowedTools',
         'Read Glob Grep Edit Write Bash(git log:*) Bash(git show:*) Bash(git diff:*) Bash(git status:*) Bash(git add:*) Bash(git commit:*) Bash(supabase functions deploy:*) Bash(curl:*)']
      : ['-p', prompt, '--allowedTools', 'Read Glob Grep Bash(git log:*) Bash(git show:*) Bash(git diff:*)']
    sessionOut = execFileSync(claudeBin, claudeArgs, {
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
