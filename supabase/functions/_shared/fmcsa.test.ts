import { assertEquals } from 'jsr:@std/assert@1'
import { nameMatches, validateCarrierNumbers, type FmcsaCarrier } from './fmcsa.ts'

Deno.test('nameMatches tolerates DBA / word-order / suffix noise', () => {
  assertEquals(nameMatches('AM Trans Expedite, LLC', 'AM TRANS EXPEDITE LLC'), true)
  assertEquals(nameMatches('Fusion Transport LLC', 'FUSION TRANSPORT INC'), true)
  assertEquals(nameMatches('Coyote Logistics', 'COYOTE LOGISTICS LLC'), true)
})

Deno.test('nameMatches rejects unrelated carriers', () => {
  assertEquals(nameMatches('AM Trans Expedite', 'JB Hunt Transport Services'), false)
  assertEquals(nameMatches('Fusion Transport', 'Landstar System'), false)
})

Deno.test('fail-closed: no webKey drops both numbers, keeps contact fields', async () => {
  const { fields, notes } = await validateCarrierNumbers(
    { phone: '555', mc_number: '123456', usdot_number: '7654321' }, 'Acme Freight', { webKey: '' })
  assertEquals(fields.phone, '555')
  assertEquals('mc_number' in fields, false)
  assertEquals('usdot_number' in fields, false)
  assertEquals(notes.length, 2)
})

Deno.test('verified USDOT is kept + canonicalized', async () => {
  const rec: FmcsaCarrier = { dotNumber: 1234567, legalName: 'ACME FREIGHT LLC' }
  const { fields } = await validateCarrierNumbers(
    { usdot_number: '01234567' }, 'Acme Freight', { webKey: 'k', lookupDot: async () => rec })
  assertEquals(fields.usdot_number, '1234567')
})

Deno.test('transposed/misread USDOT belonging to another carrier is dropped', async () => {
  // vision misread 4186701 -> 4187601, which FMCSA resolves to a DIFFERENT company
  const other: FmcsaCarrier = { dotNumber: 4187601, legalName: 'SOME OTHER TRUCKING INC' }
  const { fields, notes } = await validateCarrierNumbers(
    { usdot_number: '4187601' }, 'AM Trans Expedite', { webKey: 'k', lookupDot: async () => other })
  assertEquals('usdot_number' in fields, false)
  assertEquals(notes.some((n) => n.includes('dropped')), true)
})

Deno.test('USDOT not found in FMCSA is dropped', async () => {
  const { fields } = await validateCarrierNumbers(
    { usdot_number: '9999999' }, 'Acme Freight', { webKey: 'k', lookupDot: async () => null })
  assertEquals('usdot_number' in fields, false)
})

Deno.test('verified MC keeps number and back-fills blank USDOT from FMCSA', async () => {
  const rec: FmcsaCarrier = { dotNumber: 555000, legalName: 'ACME FREIGHT LLC' }
  const { fields, notes } = await validateCarrierNumbers(
    { mc_number: 'MC-123456' }, 'Acme Freight', { webKey: 'k', lookupMc: async () => rec })
  assertEquals(fields.mc_number, '123456')
  assertEquals(fields.usdot_number, '555000')
  assertEquals(notes.some((n) => n.includes('back-filled')), true)
})

Deno.test('MC belonging to a different carrier is dropped (no back-fill)', async () => {
  const other: FmcsaCarrier = { dotNumber: 999, legalName: 'WRONG CARRIER LLC' }
  const { fields } = await validateCarrierNumbers(
    { mc_number: '123456' }, 'Acme Freight', { webKey: 'k', lookupMc: async () => other })
  assertEquals('mc_number' in fields, false)
  assertEquals('usdot_number' in fields, false)
})

Deno.test('no carrier numbers present -> passthrough, no lookups', async () => {
  let called = false
  const { fields, notes } = await validateCarrierNumbers(
    { phone: '555', email: 'a@b.com' }, 'Acme', { webKey: 'k', lookupDot: async () => { called = true; return null } })
  assertEquals(fields.phone, '555')
  assertEquals(notes.length, 0)
  assertEquals(called, false)
})
