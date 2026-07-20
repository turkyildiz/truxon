// Trux premium voice — proxies answer text to ElevenLabs TTS with a stock
// warm friendly Southern-male voice and returns MP3, keeping ELEVENLABS_API_KEY server-side.
// Any signed-in staff member may use it; text is capped to bound cost. This is a
// legal, built-in neural voice with a JARVIS-style delivery — NOT a clone of any
// real or fictional performance. Without the key it 503s and the frontend falls
// back to the free browser voice.
import { corsResponse, getCaller, json } from '../_shared/auth.ts'

function isCronBearer(req: Request): boolean {
  try {
    const p = JSON.parse(atob((req.headers.get('Authorization')?.replace('Bearer ', '').split('.')[1] ?? '').replace(/-/g, '+').replace(/_/g, '/')))
    const ref = new URL(Deno.env.get('SUPABASE_URL')!).hostname.split('.')[0]
    return p?.role === 'anon' && p?.ref === ref
  } catch { return false }
}

const DEFAULT_VOICE = 'dtVZnErhiiosqofxDzSH' // ElevenLabs "Havoc" — gritty deep Southern narrator (Forest). Louder/faster tuning stays on the client.
const DEFAULT_MODEL = 'eleven_turbo_v2_5'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const key = Deno.env.get('ELEVENLABS_API_KEY')
  if (!key) return json({ error: 'Premium voice not configured' }, 503)

  const cron = isCronBearer(req)
  let body: { text?: unknown }
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Bad request' }, 400)
  }
  // ── voice catalog browsing (admin or cron): find/add a stock/library voice ──
  const b = body as Record<string, unknown>
  if (b.mode === 'voices' || b.mode === 'voice_search' || b.mode === 'voice_add') {
    if (!cron) { const c = await getCaller(req); if (c instanceof Response) return c; if (c.role !== 'admin') return json({ error: 'Admin only' }, 403) }
    if (b.mode === 'voices') {
      const r = await fetch('https://api.elevenlabs.io/v1/voices', { headers: { 'xi-api-key': key } })
      const j = await r.json()
      // deno-lint-ignore no-explicit-any
      return json({ voices: (j.voices ?? []).map((v: any) => ({ id: v.voice_id, name: v.name, category: v.category, labels: v.labels, description: v.description })) })
    }
    if (b.mode === 'voice_search') {
      const q = new URLSearchParams({ search: String(b.q ?? 'southern'), gender: String(b.gender ?? 'male'), language: 'en', page_size: '20' })
      const r = await fetch(`https://api.elevenlabs.io/v1/shared-voices?${q}`, { headers: { 'xi-api-key': key } })
      const j = await r.json()
      // deno-lint-ignore no-explicit-any
      return json({ results: (j.voices ?? []).map((v: any) => ({ id: v.voice_id, owner: v.public_owner_id, name: v.name, accent: v.accent, age: v.age, gender: v.gender, description: v.description, use_case: v.use_case, preview: v.preview_url, cloned_by_count: v.cloned_by_count })) })
    }
    // voice_add: pull a shared-library voice into this workspace so TTS can use it
    const r = await fetch(`https://api.elevenlabs.io/v1/voices/add/${String(b.owner)}/${String(b.voice_id)}`, {
      method: 'POST', headers: { 'xi-api-key': key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ new_name: String(b.name ?? 'Forest') }),
    })
    const j = await r.json().catch(() => ({}))
    return json({ status: r.status, result: j })
  }

  // Any authenticated user may hear answers read aloud.
  const caller = await getCaller(req)
  if (caller instanceof Response) return caller

  const text = String(body.text ?? '').trim().slice(0, 5000)
  if (!text) return json({ error: 'No text' }, 422)

  const voiceId = Deno.env.get('ELEVENLABS_VOICE_ID') ?? DEFAULT_VOICE
  const modelId = Deno.env.get('ELEVENLABS_MODEL_ID') ?? DEFAULT_MODEL

  let el: Response
  try {
    el = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}?output_format=mp3_44100_128`, {
      method: 'POST',
      headers: { 'xi-api-key': key, 'Content-Type': 'application/json', accept: 'audio/mpeg' },
      body: JSON.stringify({
        text,
        model_id: modelId,
        voice_settings: { stability: 0.5, similarity_boost: 0.85, style: 0.15, use_speaker_boost: true },
      }),
      signal: AbortSignal.timeout(30_000),
    })
  } catch (e) {
    return json({ error: `Voice service unreachable: ${e}` }, 502)
  }
  if (!el.ok) {
    const detail = (await el.text()).slice(0, 300)
    return json({ error: `Voice service ${el.status}`, detail }, 502)
  }

  const audio = await el.arrayBuffer()
  return new Response(audio, {
    status: 200,
    headers: { 'Content-Type': 'audio/mpeg', 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*' },
  })
})
