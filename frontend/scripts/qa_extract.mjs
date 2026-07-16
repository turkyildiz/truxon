// Batch-test AI dispatch extraction against production, as a real dispatcher:
// every PDF in a folder goes through the deployed extract-pdf edge function.
// Usage: node scripts/qa_extract.mjs <email> <password> <pdf_dir> <out_dir>
import { createClient } from '@supabase/supabase-js'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const env = Object.fromEntries(
  readFileSync(new URL('../.env.local', import.meta.url), 'utf8')
    .split('\n').filter((l) => l.includes('=')).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
)
const supabase = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY)

const [email, password, pdfDir, outDir] = process.argv.slice(2)
const { error: loginErr } = await supabase.auth.signInWithPassword({ email, password })
if (loginErr) { console.error('login failed:', loginErr.message); process.exit(1) }
mkdirSync(outDir, { recursive: true })

/** Stand-in for the browser's pdfjs rendering: pdftoppm → JPEG pages. */
function renderPages(pdfPath) {
  const dir = mkdtempSync(join(tmpdir(), 'qa-pages-'))
  try {
    execFileSync('pdftoppm', ['-jpeg', '-r', '150', '-f', '1', '-l', '3', pdfPath, join(dir, 'p')])
    return readdirSync(dir).sort().map((f) => readFileSync(join(dir, f)))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

async function invoke(pdfPath, name, pageImages = []) {
  const form = new FormData()
  form.append('file', new File([readFileSync(pdfPath)], name, { type: 'application/pdf' }))
  pageImages.forEach((buf, i) => form.append(`page${i}`, new File([buf], `page${i}.jpg`, { type: 'image/jpeg' })))
  const { data, error } = await supabase.functions.invoke('extract-pdf', { body: form })
  if (error) {
    const body = error.context ? await error.context.json().catch(() => null) : null
    return { fields: null, error: body?.error ?? error.message }
  }
  return data
}

const files = readdirSync(pdfDir).filter((f) => f.toLowerCase().endsWith('.pdf')).sort()
for (const name of files) {
  const started = Date.now()
  let result = await invoke(join(pdfDir, name), name)
  let via = 'text'
  if (result?.needs_images) {
    result = await invoke(join(pdfDir, name), name, renderPages(join(pdfDir, name)))
    via = 'vision'
  }
  const ms = Date.now() - started
  const slug = name.replace(/[^A-Za-z0-9]+/g, '_').slice(0, 60)
  writeFileSync(join(outDir, slug + '.json'), JSON.stringify(result, null, 2))
  const f = result?.fields
  console.log(
    `${result?.error ? 'ERR ' : f ? 'OK  ' : '??  '}[${via}] ${name} (${ms}ms)` +
      (f
        ? ` | cust=${JSON.stringify(f.customer_name)} rate=${f.rate} pu=${JSON.stringify(f.pickup_time)} del=${JSON.stringify(f.delivery_time)}`
        : ` | ${result?.error ?? 'no fields'}`),
  )
  // Stay under Groq's per-minute token budget between documents.
  await new Promise((r) => setTimeout(r, 4000))
}
