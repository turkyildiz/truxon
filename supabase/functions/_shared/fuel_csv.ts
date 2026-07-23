// CSV primitives for fuel-import, extracted for fuzz/property tests.
/** RFC-4180-ish CSV split: handles quoted fields, embedded commas, "" escapes. */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = [], field = '', inQuotes = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (inQuotes) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++ } else inQuotes = false }
      else field += c
    } else if (c === '"') inQuotes = true
    else if (c === ',') { row.push(field); field = '' }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = '' }
    else if (c === '\r') { /* skip */ }
    else field += c
  }
  if (field.length || row.length) { row.push(field); rows.push(row) }
  return rows.filter((r) => r.length > 1 || (r.length === 1 && r[0] !== ''))
}

export function money(v: string): number | null {
  const s = v.replace(/[$,\s]/g, '')
  if (!s) return null
  const n = Number(s)
  return Number.isFinite(n) ? n : null
}

/** "07/19/2026 12:19:25" (GMT) → ISO 8601 UTC. Empty/invalid → null.
 * Range-checked: the fuzz suite caught the shape-only regex happily minting
 * "2026-19-07T99:99:99Z" from a swapped day/month with garbage time. */
export function gmtToIso(v: string): string | null {
  const m = v.trim().match(/^(\d{2})\/(\d{2})\/(\d{4})[ T](\d{2}):(\d{2}):(\d{2})$/)
  if (!m) return null
  const [, mo, d, y, h, mi, s] = m
  if (+mo < 1 || +mo > 12 || +d < 1 || +d > 31 || +h > 23 || +mi > 59 || +s > 59) return null
  return `${y}-${mo}-${d}T${h}:${mi}:${s}Z`
}

