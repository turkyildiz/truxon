// Nightly off-site backup: dump the business-critical tables to the private
// db-backups storage bucket as gzipped JSON, keep 30 days. This is the
// independent layer next to the NAS backup pipeline (which needs the NAS up);
// storage lives in a different failure domain than the Postgres instance.
// Door: CRON_SECRET only (an admin session may also trigger a manual run).
import { createClient } from 'jsr:@supabase/supabase-js@2'
import { getCaller, json, requireCron } from '../_shared/auth.ts'

const TABLES = [
  'customers', 'drivers', 'trucks', 'trailers', 'loads', 'load_stops',
  'invoices', 'invoice_payments', 'load_accessorials', 'maintenance_records',
  'maintenance_vendors', 'pm_programs', 'budgets', 'gl_monthly', 'bs_snapshot',
  'safety_events', 'safety_csa', 'fuel_transactions', 'toll_transactions',
  'documents', 'profiles', 'company_settings', 'eld_daily_miles',
  'playbook_metrics', 'metric_snapshots', 'trux_insights',
]
const KEEP_DAYS = 30
const BUCKET = 'db-backups'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  if (!requireCron(req)) {
    const caller = await getCaller(req)
    if (caller instanceof Response) return caller
    if (caller.role !== 'admin') return json({ error: 'Admin only' }, 403)
  }

  const svc = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const stamp = new Date().toISOString().slice(0, 10)
  const counts: Record<string, number> = {}
  const errors: string[] = []

  for (const table of TABLES) {
    const rows: unknown[] = []
    for (let page = 0; page < 200; page++) {
      const { data, error } = await svc.from(table).select('*')
        .range(page * 1000, page * 1000 + 999)
      if (error) { errors.push(`${table}: ${error.message}`); break }
      rows.push(...(data ?? []))
      if (!data || data.length < 1000) break
    }
    counts[table] = rows.length
    const body = new Blob([JSON.stringify(rows)]).stream()
      .pipeThrough(new CompressionStream('gzip'))
    const bytes = new Uint8Array(await new Response(body).arrayBuffer())
    const { error: upErr } = await svc.storage.from(BUCKET)
      .upload(`${stamp}/${table}.json.gz`, bytes, {
        contentType: 'application/gzip', upsert: true,
      })
    if (upErr) errors.push(`upload ${table}: ${upErr.message}`)
  }

  // prune folders older than the retention window
  let pruned = 0
  const cutoff = new Date(Date.now() - KEEP_DAYS * 86400_000).toISOString().slice(0, 10)
  const { data: folders } = await svc.storage.from(BUCKET).list('', { limit: 100 })
  for (const f of folders ?? []) {
    if (f.name < cutoff && /^\d{4}-\d{2}-\d{2}$/.test(f.name)) {
      const { data: objs } = await svc.storage.from(BUCKET).list(f.name, { limit: 200 })
      const paths = (objs ?? []).map((o) => `${f.name}/${o.name}`)
      if (paths.length) {
        await svc.storage.from(BUCKET).remove(paths)
        pruned += paths.length
      }
    }
  }

  return json({ ok: errors.length === 0, stamp, tables: counts, pruned, errors })
})
