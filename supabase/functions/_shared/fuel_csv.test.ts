// Fuzz/property tests for the fuel-import CSV primitives — the door that
// swallows raw AtoB exports. deno test supabase/functions/_shared/
import { assertEquals } from 'jsr:@std/assert@1'
import { gmtToIso, money, parseCsv } from './fuel_csv.ts'

Deno.test('quoted fields: embedded commas, "" escapes, newlines-in-quotes', () => {
  const rows = parseCsv('a,"b,1","say ""hi""","line1\nline2"\nx,y,z,w')
  assertEquals(rows, [['a', 'b,1', 'say "hi"', 'line1\nline2'], ['x', 'y', 'z', 'w']])
})

Deno.test('CRLF, trailing newline, blank lines are absorbed', () => {
  assertEquals(parseCsv('a,b\r\nc,d\r\n\r\n'), [['a', 'b'], ['c', 'd']])
})

Deno.test('unterminated quote cannot hang or throw — best-effort last field', () => {
  const rows = parseCsv('a,"never closed')
  assertEquals(rows, [['a', 'never closed']])
})

Deno.test('roundtrip property: 200 random nasty fields survive encode->parse', () => {
  // deterministic PRNG so a failure reproduces
  let seed = 42
  const rand = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff
  const alphabet = ['a', 'Z', '9', ',', '"', '\n', ' ', '$', 'é', '—']
  const enc = (f: string) => '"' + f.replaceAll('"', '""') + '"'
  for (let t = 0; t < 200; t++) {
    const row = Array.from({ length: 1 + Math.floor(rand() * 5) }, () =>
      Array.from({ length: Math.floor(rand() * 12) }, () => alphabet[Math.floor(rand() * alphabet.length)]).join(''))
    // fully-empty single-field rows are dropped by design — skip those
    if (row.length === 1 && row[0] === '') continue
    const parsed = parseCsv(row.map(enc).join(','))
    assertEquals(parsed, [row], `seed row ${t}: ${JSON.stringify(row)}`)
  }
})

Deno.test('money: currency junk, negatives, garbage', () => {
  assertEquals(money('$1,234.56'), 1234.56)
  assertEquals(money(' -87.20 '), -87.2)
  assertEquals(money(''), null)
  assertEquals(money('N/A'), null)
  assertEquals(money('12.3.4'), null)
})

Deno.test('gmtToIso: strict format, everything else null', () => {
  assertEquals(gmtToIso('07/19/2026 12:19:25'), '2026-07-19T12:19:25Z')
  assertEquals(gmtToIso('2026-07-19 12:19:25'), null)
  assertEquals(gmtToIso('07/19/26 12:19:25'), null)
  assertEquals(gmtToIso(''), null)
  assertEquals(gmtToIso('19/07/2026 99:99:99'), null)
})
