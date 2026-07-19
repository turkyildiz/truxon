// Trux premium voice — proxies answer text to ElevenLabs TTS with a stock
// British-male voice and returns MP3, keeping ELEVENLABS_API_KEY server-side.
// Any signed-in staff member may use it; text is capped to bound cost. This is a
// legal, built-in neural voice with a JARVIS-style delivery — NOT a clone of any
// real or fictional performance. Without the key it 503s and the frontend falls
// back to the free browser voice.
import { corsResponse, getCaller, json } from '../_shared/auth.ts'

const DEFAULT_VOICE = 'onwK4e9ZLuTAKqWW03F9' // ElevenLabs stock "Daniel" — deep, authoritative British male
const DEFAULT_MODEL = 'eleven_turbo_v2_5'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  // Any authenticated user may hear answers read aloud.
  const caller = await getCaller(req)
  if (caller instanceof Response) return caller

  const key = Deno.env.get('ELEVENLABS_API_KEY')
  if (!key) return json({ error: 'Premium voice not configured' }, 503)

  let body: { text?: unknown }
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Bad request' }, 400)
  }
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
        voice_settings: { stability: 0.6, similarity_boost: 0.8, style: 0, use_speaker_boost: true },
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
