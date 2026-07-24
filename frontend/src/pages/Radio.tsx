import { useMutation } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { Button, Card, Input } from '../components/ui'
import { useAuth } from '../auth'
import { searchRadioTranscripts } from '../data'
import { errorMessage, supabase } from '../supabase'

/** Dispatch side of the one-app radio: same private Realtime topic the
 * tablets use (`radio:fleet`), Opus via WebCodecs — Chrome/Edge only, which
 * is what the office runs. Wire format mirrors mobile radio_codec.dart:
 * event `ptt` {u, q, c: [b64 opus 20ms frames]}, event `state` {u, on}. */

// Chrome-only capture API not yet in TypeScript's dom lib.
declare class MediaStreamTrackProcessor {
  constructor(init: { track: MediaStreamTrack })
  readable: ReadableStream<AudioData>
}

const SAMPLE_RATE = 48000
const FRAME_SAMPLES = 960 // 20ms
const FRAMES_PER_MSG = 5

const hasWebCodecs = typeof window !== 'undefined' && 'AudioEncoder' in window && 'AudioDecoder' in window

function b64encode(data: Uint8Array): string {
  let s = ''
  data.forEach((b) => { s += String.fromCharCode(b) })
  return btoa(s)
}
function b64decode(s: string): Uint8Array {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
}

/** R9 #124 prep: transcript search over the (future) radio archive. The
 * shelf exists; the recorder does not — and this card says so plainly until
 * the owner approves transcription. Office roles only. */
function TranscriptSearchCard() {
  const [q, setQ] = useState('')
  const search = useMutation({ mutationFn: (query: string) => searchRadioTranscripts(query, 30) })
  const r = search.data
  return (
    <Card title="🔎 Transcript search">
      <form
        className="flex gap-2"
        onSubmit={(e) => { e.preventDefault(); if (q.trim()) search.mutate(q.trim()) }}
      >
        <Input placeholder='e.g. detention, "exit 40", fuel -pilot' value={q} onChange={(e) => setQ(e.target.value)} />
        <Button type="submit" disabled={search.isPending || !q.trim()}>
          {search.isPending ? 'Searching…' : 'Search'}
        </Button>
      </form>
      {search.isError && <p className="mt-2 text-xs text-red-600">{errorMessage(search.error)}</p>}
      {r && r.total_stored === 0 && (
        <p className="mt-3 text-sm text-muted">
          Nothing on the shelf — radio transmissions are not being recorded or transcribed.
          The search is ready for the day that&rsquo;s switched on (owner&rsquo;s call).
        </p>
      )}
      {r && r.total_stored > 0 && r.hits.length === 0 && (
        <p className="mt-3 text-sm text-muted">No matches in the last 30 days ({r.total_stored.toLocaleString()} transmissions stored).</p>
      )}
      {r && r.hits.length > 0 && (
        <ul className="mt-3 space-y-2">
          {r.hits.map((h) => (
            <li key={h.id} className="rounded border border-edge p-2 text-sm">
              <span className="text-xs text-muted">
                {new Date(h.spoken_at).toLocaleString()} · {h.speaker || 'unknown'}
                {h.duration_sec != null ? ` · ${h.duration_sec}s` : ''}
              </span>
              {/* ts_headline marks hits with [[ ]] — rendered as text, never HTML */}
              <p>
                {h.snippet.split(/(\[\[.*?\]\])/g).map((part, i) =>
                  part.startsWith('[[')
                    ? <mark key={i} className="rounded bg-amber-200/60 px-0.5 dark:bg-amber-500/30">{part.slice(2, -2)}</mark>
                    : <span key={i}>{part}</span>,
                )}
              </p>
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}

export default function Radio() {
  const { user } = useAuth()
  const me = user?.username || user?.full_name || 'dispatch'
  const [status, setStatus] = useState<'connecting' | 'online' | 'off'>('connecting')
  const [roster, setRoster] = useState<string[]>([])
  const [onAir, setOnAir] = useState<string | null>(null)
  const [tx, setTx] = useState(false)
  const chRef = useRef<ReturnType<typeof supabase.channel> | null>(null)
  const decoderRef = useRef<AudioDecoder | null>(null)
  const audioCtxRef = useRef<AudioContext | null>(null)
  const playheadRef = useRef(0)
  const stopCaptureRef = useRef<(() => void) | null>(null)
  const txRef = useRef(false)
  const clearTalkingRef = useRef<number | undefined>(undefined)

  useEffect(() => {
    if (!hasWebCodecs) return
    const audioCtx = new AudioContext({ sampleRate: SAMPLE_RATE })
    audioCtxRef.current = audioCtx
    const decoder = new AudioDecoder({
      output: (data: AudioData) => {
        // schedule each decoded 20ms chunk back-to-back on the audio clock
        const pcm = new Float32Array(data.numberOfFrames)
        data.copyTo(pcm, { planeIndex: 0, format: 'f32-planar' })
        data.close()
        const buf = audioCtx.createBuffer(1, pcm.length, SAMPLE_RATE)
        buf.copyToChannel(pcm, 0)
        const src = audioCtx.createBufferSource()
        src.buffer = buf
        src.connect(audioCtx.destination)
        const now = audioCtx.currentTime
        const at = Math.max(playheadRef.current, now + 0.06) // 60ms jitter cushion
        src.start(at)
        playheadRef.current = at + pcm.length / SAMPLE_RATE
      },
      error: (e) => console.warn('radio decode', e),
    })
    decoder.configure({ codec: 'opus', sampleRate: SAMPLE_RATE, numberOfChannels: 1 })
    decoderRef.current = decoder

    const ch = supabase.channel('radio:fleet', { config: { private: true } })
    ch.on('broadcast', { event: 'ptt' }, ({ payload }) => {
      const p = payload as { u: string; c: string[] }
      if (p.u === me || txRef.current) return
      setOnAir(p.u)
      window.clearTimeout(clearTalkingRef.current)
      clearTalkingRef.current = window.setTimeout(() => setOnAir(null), 600)
      for (const frame of p.c) {
        try {
          decoder.decode(new EncodedAudioChunk({
            type: 'key', timestamp: 0, data: b64decode(frame),
          }))
        } catch { /* one bad frame never kills playback */ }
      }
    })
    ch.on('broadcast', { event: 'state' }, ({ payload }) => {
      const p = payload as { u: string; on: boolean }
      if (p.u !== me) setOnAir(p.on ? p.u : null)
    })
    ch.on('presence', { event: 'sync' }, () => {
      const names = new Set<string>()
      const state = ch.presenceState<{ user: string }>()
      Object.values(state).forEach((metas) => metas.forEach((m) => m.user && names.add(m.user)))
      setRoster([...names].sort())
    })
    ch.subscribe(async (s) => {
      if (s === 'SUBSCRIBED') {
        setStatus('online')
        await ch.track({ user: me })
      } else if (s === 'CHANNEL_ERROR' || s === 'CLOSED') {
        setStatus('off')
      }
    })
    chRef.current = ch
    return () => {
      stopCaptureRef.current?.()
      supabase.removeChannel(ch)
      decoder.close()
      audioCtx.close()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [me])

  const startTalking = async () => {
    const ch = chRef.current
    if (!ch || txRef.current) return
    await audioCtxRef.current?.resume()
    txRef.current = true
    setTx(true)
    ch.send({ type: 'broadcast', event: 'state', payload: { u: me, on: true } })
    let seq = 0
    let batch: string[] = []
    const encoder = new AudioEncoder({
      output: (chunk: EncodedAudioChunk) => {
        const data = new Uint8Array(chunk.byteLength)
        chunk.copyTo(data)
        batch.push(b64encode(data))
        if (batch.length >= FRAMES_PER_MSG) {
          ch.send({ type: 'broadcast', event: 'ptt', payload: { u: me, q: seq++, c: batch } })
          batch = []
        }
      },
      error: (e) => console.warn('radio encode', e),
    })
    encoder.configure({ codec: 'opus', sampleRate: SAMPLE_RATE, numberOfChannels: 1, bitrate: 24000 })

    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, sampleRate: SAMPLE_RATE, echoCancellation: true, noiseSuppression: true },
    })
    const track = stream.getAudioTracks()[0]
    const processor = new MediaStreamTrackProcessor({ track })
    const reader = processor.readable.getReader()
    let stopped = false
    const pump = async () => {
      // Re-frame arbitrary capture chunks into exact 20ms AudioData for Opus.
      let carry = new Float32Array(0)
      let ts = 0
      while (!stopped) {
        const { value, done } = await reader.read()
        if (done || !value) break
        const pcm = new Float32Array(value.numberOfFrames)
        value.copyTo(pcm, { planeIndex: 0, format: 'f32-planar' })
        value.close()
        const merged = new Float32Array(carry.length + pcm.length)
        merged.set(carry); merged.set(pcm, carry.length)
        let off = 0
        while (merged.length - off >= FRAME_SAMPLES) {
          const frame = merged.subarray(off, off + FRAME_SAMPLES)
          const ad = new AudioData({
            format: 'f32-planar', sampleRate: SAMPLE_RATE, numberOfFrames: FRAME_SAMPLES,
            numberOfChannels: 1, timestamp: ts, data: frame.slice(),
          })
          ts += (FRAME_SAMPLES / SAMPLE_RATE) * 1e6
          encoder.encode(ad)
          ad.close()
          off += FRAME_SAMPLES
        }
        carry = merged.slice(off)
      }
    }
    void pump()
    stopCaptureRef.current = () => {
      stopped = true
      void reader.cancel().catch(() => undefined)
      track.stop()
      if (batch.length > 0) {
        ch.send({ type: 'broadcast', event: 'ptt', payload: { u: me, q: seq++, c: batch } })
        batch = []
      }
      void encoder.flush().then(() => encoder.close()).catch(() => undefined)
      ch.send({ type: 'broadcast', event: 'state', payload: { u: me, on: false } })
    }
  }

  const stopTalking = () => {
    if (!txRef.current) return
    txRef.current = false
    setTx(false)
    stopCaptureRef.current?.()
    stopCaptureRef.current = null
  }

  const office = ['admin', 'dispatcher', 'accountant'].includes(user?.role ?? '')

  if (!hasWebCodecs) {
    return (
      <div className="mx-auto max-w-lg space-y-4">
        <Card title="📻 Fleet radio">
          <p className="py-6 text-center text-sm text-muted">
            The radio needs Chrome or Edge (WebCodecs). Open truxon.com in Chrome to talk to the trucks.
          </p>
        </Card>
        {office && <TranscriptSearchCard />}
      </div>
    )
  }

  const others = roster.filter((u) => u !== me)
  return (
    <div className="mx-auto max-w-lg space-y-4">
      <Card title="📻 Fleet radio">
        <p className="mb-3 text-xs text-muted">
          Same channel as every truck tablet — hold the button, talk, release. No extra app needed.
          Status:{' '}
          <span className={status === 'online' ? 'text-emerald-600' : 'text-amber-600'}>{status}</span>
        </p>
        <div className="mb-4 flex flex-wrap gap-2">
          {others.length === 0
            ? <span className="text-sm text-muted">No one else on the radio right now.</span>
            : others.map((u) => (
                <span key={u}
                  className={`rounded-full px-3 py-1 text-sm ${onAir === u ? 'bg-emerald-500/20 font-semibold text-emerald-700 dark:text-emerald-300' : 'bg-surface-2'}`}>
                  {onAir === u ? '🎙 ' : ''}{u}
                </span>
              ))}
        </div>
        {onAir && <p className="mb-2 text-sm font-semibold text-emerald-600">{onAir} is talking…</p>}
        <button
          onMouseDown={startTalking}
          onMouseUp={stopTalking}
          onMouseLeave={stopTalking}
          onTouchStart={(e) => { e.preventDefault(); void startTalking() }}
          onTouchEnd={stopTalking}
          disabled={status !== 'online'}
          className={`mx-auto block h-44 w-44 rounded-full text-lg font-bold text-white shadow-lg transition
            ${status !== 'online' ? 'bg-gray-400' : tx ? 'bg-red-600 shadow-red-500/50' : 'bg-indigo-600 hover:bg-indigo-500'}`}
        >
          {tx ? 'ON AIR' : 'HOLD TO TALK'}
        </button>
      </Card>
      {office && <TranscriptSearchCard />}
    </div>
  )
}
