// Shared admin-credential input for the ITS migration scripts.
// Prefers ADMIN_EMAIL / ADMIN_PASSWORD env vars (for automation/CI); if either
// is missing, prompts on the terminal instead. The password is read WITHOUT
// echoing — so it never lands in your shell history, your scrollback, or `ps`.
// Nothing here is stored or logged; the value goes straight into the sign-in.
import readline from 'node:readline'

export async function getCreds() {
  let email = process.env.ADMIN_EMAIL
  let password = process.env.ADMIN_PASSWORD
  if (email && password) return { email, password } // fully non-interactive

  // One readline interface for BOTH prompts — a second interface on the same
  // stdin can't read the remaining input (esp. when piped).
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true })
  const orig = rl._writeToOutput.bind(rl)
  let hide = false
  rl._writeToOutput = (s) => { if (!hide || s.includes('\n')) orig(s) } // keep the prompt/newlines, drop typed chars
  const ask = (query, hidden = false) => new Promise((resolve) => {
    hide = false
    rl.question(query, (ans) => { if (hidden) rl.output.write('\n'); resolve(ans.trim()) })
    if (hidden) hide = true // question printed synchronously above; now mute echoes
  })

  if (!email) email = await ask('Truxon admin email: ')
  if (!password) password = await ask('Truxon admin password (hidden): ', true)
  rl.close()
  if (!email || !password) { console.error('Email and password are both required.'); process.exit(2) }
  return { email, password }
}
