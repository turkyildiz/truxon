/**
 * Trux — a search-bar-centric executive analyst over the SAME `trux-agent`
 * edge function the floating TruxChat uses. The big "Ask Trux anything…" bar is
 * the primary interface; answers stream below it newest-first. Trux replies are
 * Markdown (exec summaries + tables) parsed with `marked` and sanitized with
 * `DOMPurify` — never raw HTML into the DOM. Write actions the agent proposes
 * surface as confirm/reject cards, exactly as in TruxChat.
 *
 * Hands-free voice is layered on top with the Web Speech API: speech-to-text
 * (SpeechRecognition) drives the bar, text-to-speech (speechSynthesis) reads
 * answers aloud, and a hands-free loop chains listen → send → speak → listen.
 * All of it degrades to a plain text search when the API is absent.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { errorMessage } from '../supabase'
import { synthesizeSpeech } from '../data'
import { LoadError } from '../components/ui'
import { truxAgent, ToolResult, type Proposal } from '../components/TruxChat'
import TruxShadow from '../components/TruxShadow'
import SentinelFeed from '../components/SentinelFeed'

type LogEntry = { role: 'user' | 'assistant'; content: string; proposals?: Proposal[]; result?: unknown }
type Phase = 'idle' | 'listening' | 'thinking' | 'speaking'

// The conversation and session id live in a module-level store so navigating
// away from /trux and back within the same SPA session preserves the whole
// thread (a routed page unmounts on navigation, unlike the floating launcher).
const store: { sessionId: string | null; log: LogEntry[] } = { sessionId: null, log: [] }

/** Parse Markdown, then sanitize — the ONLY path by which agent text reaches
 * the DOM. marked runs synchronously; DOMPurify strips scripts/handlers. */
function renderMarkdown(md: string): string {
  const raw = marked.parse(md, { async: false, breaks: true, gfm: true }) as string
  return DOMPurify.sanitize(raw)
}

/** Reduce Markdown to plain prose the synthesizer can read: drop tables, code
 * blocks and formatting marks, keep the narrative, and cap to a few sentences
 * (~800 chars) so answers stay listenable, not a wall of speech. */
function toSpeech(md: string): string {
  const prose = md
    .split('\n')
    .filter((line) => !line.trim().startsWith('|')) // drop Markdown table rows
    .join('\n')
    .replace(/```[\s\S]*?```/g, ' ') // fenced code blocks
    .replace(/`([^`]*)`/g, '$1') // inline code
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ') // images
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1') // links → their text
    .replace(/[#*_>`|~]/g, ' ') // stray formatting marks
    .replace(/\s+/g, ' ')
    .trim()
  if (prose.length <= 800) return prose
  const head = prose.slice(0, 800)
  const stop = Math.max(head.lastIndexOf('. '), head.lastIndexOf('! '), head.lastIndexOf('? '))
  return stop > 200 ? head.slice(0, stop + 1) : head
}

/** Hand-rolled prose styling (no plugin) via Tailwind child selectors so the
 * agent's headings/tables/lists/code match the app in light and dark. */
const PROSE =
  'text-sm leading-relaxed text-body ' +
  '[&_h1]:mt-3 [&_h1]:mb-2 [&_h1]:text-lg [&_h1]:font-bold [&_h1]:text-body ' +
  '[&_h2]:mt-3 [&_h2]:mb-2 [&_h2]:text-base [&_h2]:font-semibold [&_h2]:text-body ' +
  '[&_h3]:mt-2 [&_h3]:mb-1 [&_h3]:text-sm [&_h3]:font-semibold [&_h3]:text-body ' +
  '[&_p]:my-2 [&_p:first-child]:mt-0 [&_p:last-child]:mb-0 ' +
  '[&_a]:font-medium [&_a]:text-brand [&_a]:underline ' +
  '[&_ul]:my-2 [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:my-2 [&_ol]:list-decimal [&_ol]:pl-5 [&_li]:my-0.5 ' +
  '[&_strong]:font-semibold [&_strong]:text-body ' +
  '[&_blockquote]:my-2 [&_blockquote]:border-l-2 [&_blockquote]:border-line [&_blockquote]:pl-3 [&_blockquote]:text-muted ' +
  '[&_hr]:my-3 [&_hr]:border-line ' +
  '[&_code]:rounded [&_code]:bg-surface-2 [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:font-mono [&_code]:text-xs [&_code]:text-body ' +
  '[&_pre]:my-2 [&_pre]:overflow-x-auto [&_pre]:rounded-lg [&_pre]:border [&_pre]:border-line [&_pre]:bg-surface-2 [&_pre]:p-3 ' +
  '[&_pre_code]:bg-transparent [&_pre_code]:p-0 ' +
  '[&_table]:my-2 [&_table]:block [&_table]:w-full [&_table]:overflow-x-auto [&_table]:border-collapse [&_table]:text-sm ' +
  '[&_thead]:border-b [&_thead]:border-line ' +
  '[&_th]:whitespace-nowrap [&_th]:px-3 [&_th]:py-2 [&_th]:text-left [&_th]:text-xs [&_th]:font-semibold [&_th]:uppercase [&_th]:tracking-wide [&_th]:text-muted ' +
  '[&_td]:border-t [&_td]:border-line [&_td]:px-3 [&_td]:py-2 [&_td]:align-top ' +
  '[&_tbody_tr:hover]:bg-surface-2'

function Markdown({ content }: { content: string }) {
  const html = useMemo(() => renderMarkdown(content), [content])
  return <div className={PROSE} dangerouslySetInnerHTML={{ __html: html }} />
}

// Runtime feature detection — decided once, drives graceful degradation.
const RECOGNITION_CTOR: SpeechRecognitionCtor | undefined =
  typeof window !== 'undefined' ? window.SpeechRecognition ?? window.webkitSpeechRecognition : undefined
const SYNTH_OK = typeof window !== 'undefined' && 'speechSynthesis' in window
const STT_OK = RECOGNITION_CTOR != null

// A calm, refined British male voice — the closest a legal, built-in system
// voice gets to a JARVIS-style assistant (no cloning of any real/fictional
// performance). Picks the best available voice; browsers expose different sets,
// so we score by name then fall back to any en-GB, then any English male.
const PREFERRED_VOICES = [
  'google uk english male', 'daniel', 'arthur', 'oliver', 'microsoft george',
  'microsoft ryan', 'microsoft george online', 'rishi', 'ryan',
]
const MALE_HINTS = ['male', 'daniel', 'george', 'ryan', 'james', 'arthur', 'oliver', 'thomas', 'guy', 'david', 'mark', 'fred', 'albert', 'rishi']
const FEMALE_HINTS = ['female', 'samantha', 'victoria', 'karen', 'moira', 'tessa', 'fiona', 'serena', 'kate', 'hazel', 'susan', 'zira', 'sonia', 'libby', 'catherine', 'emily', 'amelie']

let cachedVoice: SpeechSynthesisVoice | null = null
function chooseVoice(): SpeechSynthesisVoice | null {
  if (!SYNTH_OK) return null
  const voices = window.speechSynthesis.getVoices()
  if (!voices.length) return null
  const named = (n: string) => voices.find((v) => v.name.toLowerCase().includes(n))
  for (const p of PREFERRED_VOICES) {
    const v = named(p)
    if (v) return v
  }
  const gb = voices.filter((v) => v.lang.toLowerCase().startsWith('en-gb'))
  const has = (v: SpeechSynthesisVoice, hints: string[]) => hints.some((h) => v.name.toLowerCase().includes(h))
  return (
    gb.find((v) => has(v, MALE_HINTS)) ??
    gb.find((v) => !has(v, FEMALE_HINTS)) ??
    voices.find((v) => v.lang.toLowerCase().startsWith('en') && has(v, MALE_HINTS)) ??
    gb[0] ??
    voices.find((v) => v.lang.toLowerCase().startsWith('en')) ??
    null
  )
}
function jarvisVoice(): SpeechSynthesisVoice | null {
  if (!cachedVoice) cachedVoice = chooseVoice()
  return cachedVoice
}
if (SYNTH_OK) {
  window.speechSynthesis.getVoices() // kick off async voice loading
  window.speechSynthesis.addEventListener?.('voiceschanged', () => {
    cachedVoice = chooseVoice()
  })
}

// Premium-voice delivery tuning: louder (gain above 100%) and a touch faster,
// pitch-preserved so the speed-up doesn't undo the voice's depth.
const VOICE_GAIN = 1.6
const VOICE_RATE = 1.08
let audioCtx: AudioContext | null = null
function boostGain(audio: HTMLAudioElement): void {
  try {
    const Ctx = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!Ctx) return
    if (!audioCtx) audioCtx = new Ctx()
    if (audioCtx.state === 'suspended') void audioCtx.resume()
    const src = audioCtx.createMediaElementSource(audio)
    const gain = audioCtx.createGain()
    gain.gain.value = VOICE_GAIN
    src.connect(gain).connect(audioCtx.destination)
  } catch {
    /* fall back to the element's own volume */
  }
}

export default function Trux() {
  const [view, setView] = useState<'chat' | 'shadow'>('chat')
  const qc = useQueryClient()
  const [sessionId, setSessionId] = useState<string | null>(store.sessionId)
  const [log, setLog] = useState<LogEntry[]>(store.log)
  const [text, setText] = useState('')
  const [error, setError] = useState('')

  // Voice UI state.
  const [listening, setListening] = useState(false)
  const [handsFree, setHandsFree] = useState(false)
  const [phase, setPhaseState] = useState<Phase>('idle')
  const [interim, setInterim] = useState('')
  const [micDenied, setMicDenied] = useState(false)
  const [premium, setPremium] = useState<boolean>(() => {
    try {
      return localStorage.getItem('trux_premium_voice') === '1'
    } catch {
      return false
    }
  })

  // Refs let the async Web Speech callbacks (which capture an old render) read
  // the *current* intent instead of a stale snapshot.
  const recognitionRef = useRef<SpeechRecognition | null>(null)
  const handsFreeRef = useRef(false)
  const phaseRef = useRef<Phase>('idle')
  const startListeningRef = useRef<() => void>(() => {})
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const speakSeqRef = useRef(0)
  const premiumRef = useRef(premium)
  premiumRef.current = premium

  function togglePremium() {
    setPremium((p) => {
      const n = !p
      try {
        localStorage.setItem('trux_premium_voice', n ? '1' : '0')
      } catch {
        /* ignore */
      }
      return n
    })
  }

  function setPhase(p: Phase) {
    phaseRef.current = p
    setPhaseState(p)
  }

  // Keep the module store in sync so the thread survives remounts.
  useEffect(() => {
    store.sessionId = sessionId
    store.log = log
  }, [sessionId, log])

  const send = useMutation({
    mutationFn: async (message: string) => truxAgent({ session_id: sessionId ?? undefined, message }),
    onSuccess: (res, message) => {
      setSessionId(res.session_id)
      setLog((prev) => [
        ...prev,
        { role: 'user', content: message },
        { role: 'assistant', content: res.reply ?? '', proposals: res.proposals },
      ])
      setText('')
      setError('')
      // Hands-free: read the answer, then the utterance's onend resumes the loop.
      // A proposal needs a human decision, so we don't auto-listen past it.
      if (handsFreeRef.current) speak(res.reply ?? '', !res.proposals?.length)
    },
    onError: (e) => {
      setError(errorMessage(e))
      if (handsFreeRef.current) startListeningRef.current() // keep the loop alive
    },
  })

  const confirm = useMutation({
    mutationFn: async (token: string) => truxAgent({ session_id: sessionId ?? undefined, confirm_token: token }),
    onSuccess: (res) => {
      setLog((prev) => [
        ...prev,
        {
          role: 'assistant',
          content: res.executed ? '✓ Confirmed.' : res.reply ?? 'Done.',
          result: res.executed ? res.result : undefined,
        },
      ])
      void qc.invalidateQueries({ queryKey: ['loads'] })
      void qc.invalidateQueries({ queryKey: ['fleet-positions'] })
      void qc.invalidateQueries({ queryKey: ['dashboard'] })
    },
    onError: (e) => setError(errorMessage(e)),
  })

  const reject = useMutation({
    mutationFn: async (token: string) => truxAgent({ session_id: sessionId ?? undefined, reject_token: token }),
    onSuccess: () => setLog((prev) => [...prev, { role: 'assistant', content: 'Cancelled that action.' }]),
    onError: (e) => setError(errorMessage(e)),
  })

  function cancelSpeech() {
    // Bump the sequence so any in-flight fetch/utterance is ignored on return.
    speakSeqRef.current++
    if (SYNTH_OK) window.speechSynthesis.cancel()
    if (audioRef.current) {
      audioRef.current.pause()
      audioRef.current = null
    }
  }

  function stopRecognition() {
    const r = recognitionRef.current
    if (!r) return
    r.onresult = null
    r.onerror = null
    r.onend = null
    try {
      r.stop()
    } catch {
      /* stop() throws if not started — safe to ignore */
    }
    recognitionRef.current = null
  }

  /** Speak an answer aloud; `resume` chains back into the hands-free loop when
   * playback finishes. Barge-in-safe: cancelSpeech bumps a sequence so an
   * in-flight fetch or utterance is ignored. Premium mode streams a British
   * male neural voice from the trux-tts function; browser speechSynthesis is the
   * free fallback (also used if premium fails). */
  async function speak(md: string, resume: boolean) {
    cancelSpeech()
    const seq = speakSeqRef.current
    const spoken = toSpeech(md)
    const resumeOrIdle = () => {
      if (seq !== speakSeqRef.current) return
      if (resume && handsFreeRef.current) startListeningRef.current()
      else if (phaseRef.current === 'speaking') setPhase('idle')
    }
    if (!spoken) {
      if (resume && handsFreeRef.current) startListeningRef.current()
      else setPhase('idle')
      return
    }
    setPhase('speaking')
    if (premiumRef.current) {
      try {
        const blob = await synthesizeSpeech(spoken)
        if (seq !== speakSeqRef.current) return // barged in during the fetch
        const url = URL.createObjectURL(blob)
        const audio = new Audio(url)
        ;(audio as HTMLAudioElement & { preservesPitch?: boolean }).preservesPitch = true
        audio.playbackRate = VOICE_RATE
        audioRef.current = audio
        boostGain(audio)
        const end = () => {
          URL.revokeObjectURL(url)
          resumeOrIdle()
        }
        audio.onended = end
        audio.onerror = end
        await audio.play()
        return
      } catch {
        if (seq !== speakSeqRef.current) return
        // fall through to the free browser voice
      }
    }
    browserSpeak(spoken, resumeOrIdle)
  }

  function browserSpeak(spoken: string, resumeOrIdle: () => void) {
    if (!SYNTH_OK) {
      resumeOrIdle()
      return
    }
    const u = new SpeechSynthesisUtterance(spoken)
    // JARVIS-ish delivery: a British male voice, measured pace, lower pitch.
    const v = jarvisVoice()
    if (v) {
      u.voice = v
      u.lang = v.lang
    }
    u.rate = 1.05
    u.pitch = 0.82
    u.onend = resumeOrIdle
    u.onerror = resumeOrIdle
    window.speechSynthesis.speak(u)
  }

  /** Submit a query from any source (typing, mic, hands-free). Cancels ongoing
   * speech (barge-in) so a new question always interrupts Trux mid-sentence. */
  function runQuery(message: string) {
    const m = message.trim()
    if (!m || send.isPending) return
    cancelSpeech()
    setInterim('')
    if (handsFreeRef.current) setPhase('thinking')
    send.mutate(m)
  }

  function startListening() {
    if (!STT_OK || !RECOGNITION_CTOR) return
    cancelSpeech()
    stopRecognition()
    const rec = new RECOGNITION_CTOR()
    rec.lang = 'en-US'
    rec.interimResults = true
    rec.continuous = false
    rec.maxAlternatives = 1
    recognitionRef.current = rec
    setInterim('')
    setListening(true)
    setPhase('listening')
    rec.onresult = (e) => {
      let interimStr = ''
      let finalStr = ''
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const r = e.results[i]
        if (r.isFinal) finalStr += r[0].transcript
        else interimStr += r[0].transcript
      }
      if (finalStr) {
        setText(finalStr)
        runQuery(finalStr) // recognition auto-stops (continuous=false); onend follows
      } else {
        setInterim(interimStr)
      }
    }
    rec.onerror = (e) => {
      if (e.error === 'not-allowed' || e.error === 'service-not-allowed') {
        setMicDenied(true)
        setHandsFree(false)
        handsFreeRef.current = false
      }
    }
    rec.onend = () => {
      setListening(false)
      recognitionRef.current = null
      // Silence with no final result: if still hands-free and idle-listening
      // (a query would have moved us to 'thinking'), resume the loop.
      if (handsFreeRef.current && phaseRef.current === 'listening') startListeningRef.current()
    }
    try {
      rec.start()
    } catch {
      setListening(false)
    }
  }
  // Always call the freshest closure from async callbacks.
  startListeningRef.current = startListening

  function toggleMic() {
    if (!STT_OK) return
    if (listening) {
      stopRecognition()
      setListening(false)
      setPhase('idle')
    } else {
      setMicDenied(false)
      startListening()
    }
  }

  function stopHandsFree() {
    setHandsFree(false)
    handsFreeRef.current = false
    stopRecognition()
    cancelSpeech()
    setListening(false)
    setInterim('')
    setPhase('idle')
  }

  function toggleHandsFree() {
    if (!STT_OK || !SYNTH_OK) return
    if (handsFreeRef.current) {
      stopHandsFree()
    } else {
      setMicDenied(false)
      setHandsFree(true)
      handsFreeRef.current = true
      startListening()
    }
  }

  // Tear down any recognition/speech when leaving the page.
  useEffect(() => {
    return () => {
      handsFreeRef.current = false
      stopRecognition()
      cancelSpeech()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  function submit() {
    runQuery(text)
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter') {
      e.preventDefault()
      submit()
    }
  }

  // Group the flat log into turns (a question + its answer parts) and show the
  // newest turn on top — a running transcript, not a chat-bubble app.
  const turns = useMemo(() => {
    const out: { key: number; question?: string; answers: LogEntry[] }[] = []
    log.forEach((e, i) => {
      if (e.role === 'user') out.push({ key: i, question: e.content, answers: [] })
      else {
        if (!out.length) out.push({ key: i, answers: [] })
        out[out.length - 1].answers.push(e)
      }
    })
    return out.reverse()
  }, [log])

  const empty = log.length === 0
  const inputValue = listening && interim ? interim : text
  const busy = send.isPending

  const PILL: Record<Phase, { label: string; cls: string }> = {
    idle: { label: 'Idle', cls: 'bg-surface-2 text-muted' },
    listening: { label: '● Listening', cls: 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-300' },
    thinking: { label: '… Thinking', cls: 'bg-amber-500/15 text-amber-700 dark:text-amber-300' },
    speaking: { label: '🔊 Speaking', cls: 'bg-navy-500/15 text-navy-700 dark:text-navy-200' },
  }

  return (
    <div className="flex h-[calc(100vh-6.5rem)] flex-col gap-4">
      {/* Header */}
      <div className="flex items-center gap-3">
        <span className="flex h-11 w-11 items-center justify-center rounded-2xl bg-gradient-to-br from-navy-600 to-navy-900 text-2xl shadow-md">
          ✨
        </span>
        <div>
          <h1 className="text-xl font-bold text-body">Trux</h1>
          <p className="text-sm text-muted">Your AI operations &amp; finance analyst</p>
        </div>
        <div className="ml-auto flex overflow-hidden rounded-xl border border-line">
          <button
            onClick={() => setView('chat')}
            className={`px-4 py-2 text-sm font-medium ${view === 'chat' ? 'bg-surface-2 text-body' : 'text-muted hover:text-body'}`}
          >
            💬 Chat
          </button>
          <button
            onClick={() => setView('shadow')}
            className={`px-4 py-2 text-sm font-medium ${view === 'shadow' ? 'bg-surface-2 text-body' : 'text-muted hover:text-body'}`}
            title="What Trux would do with the dispatch inbox (observe-only)"
          >
            👁️ Shadow
          </button>
        </div>
      </div>

      {view === 'shadow' ? <TruxShadow /> : <>

      {/* Search bar — the centerpiece */}
      <div className={empty ? 'flex flex-1 flex-col justify-center' : ''}>
        <div className="mx-auto w-full max-w-3xl">
          <div className="flex items-center gap-2 rounded-2xl border border-line bg-surface px-4 py-2.5 shadow-sm focus-within:border-brand focus-within:ring-2 focus-within:ring-brand/30">
            <svg className="h-5 w-5 shrink-0 text-muted" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
              <circle cx="11" cy="11" r="7" />
              <path d="m21 21-4.3-4.3" strokeLinecap="round" />
            </svg>
            <input
              value={inputValue}
              onChange={(e) => setText(e.target.value)}
              onKeyDown={onKeyDown}
              placeholder="Ask Trux anything…"
              disabled={busy}
              className="flex-1 bg-transparent py-1 text-base text-body placeholder:text-muted focus:outline-none disabled:opacity-50"
            />
            {STT_OK && (
              <button
                onClick={toggleMic}
                disabled={busy || handsFree}
                title={listening ? 'Stop listening' : 'Speak your question'}
                aria-pressed={listening}
                className={
                  'flex h-9 w-9 shrink-0 items-center justify-center rounded-xl transition-colors disabled:opacity-40 ' +
                  (listening ? 'bg-emerald-500/20 text-emerald-600 dark:text-emerald-300' : 'text-muted hover:bg-surface-2 hover:text-body')
                }
              >
                <span className={listening ? 'animate-pulse text-lg' : 'text-lg'}>🎤</span>
              </button>
            )}
            <button
              onClick={submit}
              disabled={busy || !text.trim()}
              className="shrink-0 rounded-xl bg-brand px-4 py-2 text-sm font-semibold text-brand-fg hover:bg-brand-hover disabled:cursor-not-allowed disabled:opacity-50"
            >
              {busy ? '…' : 'Ask'}
            </button>
          </div>

          {/* Controls row: hint / hands-free toggle / status */}
          <div className="mt-2 flex flex-wrap items-center justify-between gap-2 px-1">
            <p className="text-xs text-muted">
              {empty
                ? 'Ask about fuel, P&L, who owes us money, a driver, a load — or tap the mic and talk'
                : 'Enter to ask · Any action Trux proposes needs your confirmation'}
            </p>
            <div className="flex items-center gap-2">
              <button
                onClick={togglePremium}
                title={premium ? 'Premium British-male (JARVIS) voice is on — tap for the free browser voice' : 'Use the premium British-male (JARVIS) voice'}
                aria-pressed={premium}
                className={
                  'rounded-full border px-3 py-1 text-xs font-semibold ' +
                  (premium ? 'border-navy-600 bg-navy-500/15 text-navy-700 dark:text-navy-200' : 'border-line bg-surface text-muted hover:bg-surface-2')
                }
              >
                🎩 JARVIS voice{premium ? ' · on' : ''}
              </button>
              {handsFree && (
                <span className={'rounded-full px-2.5 py-1 text-xs font-semibold ' + PILL[phase].cls}>{PILL[phase].label}</span>
              )}
              {STT_OK && SYNTH_OK &&
                (handsFree ? (
                  <button
                    onClick={stopHandsFree}
                    className="rounded-full border border-line bg-surface px-3 py-1 text-xs font-semibold text-body hover:bg-surface-2"
                  >
                    ■ Stop
                  </button>
                ) : (
                  <button
                    onClick={toggleHandsFree}
                    disabled={busy || listening}
                    className="rounded-full border border-line bg-surface px-3 py-1 text-xs font-semibold text-body hover:border-navy-600 disabled:opacity-50"
                  >
                    🎙 Hands-free
                  </button>
                ))}
            </div>
          </div>

          {micDenied && (
            <p className="mt-1 px-1 text-xs text-amber-600 dark:text-amber-400">
              Microphone access was blocked. Enable it in your browser to use voice, or just type your question.
            </p>
          )}
        </div>
      </div>

      {/* Sentinel: what Trux noticed on its own */}
      <SentinelFeed />

      {/* Answer stream (newest first) */}
      {!empty && (
        <div className="flex-1 space-y-4 overflow-y-auto rounded-2xl border border-line bg-surface-2 p-4">
          {busy && (
            <div className="flex items-center gap-2 px-1 text-sm text-muted">
              <span className="inline-flex gap-1">
                <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-muted [animation-delay:-0.3s]" />
                <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-muted [animation-delay:-0.15s]" />
                <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-muted" />
              </span>
              Trux is thinking…
            </div>
          )}

          {turns.map((t) => (
            <div key={t.key} className="space-y-2">
              {t.question && (
                <div className="flex items-start gap-2">
                  <span className="mt-0.5 text-muted">You</span>
                  <p className="flex-1 text-sm font-medium text-body">{t.question}</p>
                </div>
              )}
              {t.answers.map((m, j) => (
                <div key={j} className="w-full rounded-2xl border border-line bg-surface p-4 shadow-sm">
                  <div className="mb-2 flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-muted">
                      <span>✨</span> Trux
                    </div>
                    {SYNTH_OK && m.content && (
                      <button
                        onClick={() => speak(m.content, false)}
                        title="Read this answer aloud"
                        className="rounded-lg px-1.5 py-0.5 text-sm text-muted hover:bg-surface-2 hover:text-body"
                      >
                        🔊
                      </button>
                    )}
                  </div>
                  {m.content && <Markdown content={m.content} />}
                  {m.result != null && <ToolResult result={m.result} />}
                  {m.proposals?.map((p) => (
                    <div key={p.token} className="mt-3 rounded-xl border border-amber-500/30 bg-amber-500/10 p-3">
                      <div className="font-medium break-words text-amber-900 dark:text-amber-200">{p.summary}</div>
                      <div className="mt-3 flex gap-2">
                        <button
                          onClick={() => confirm.mutate(p.token)}
                          disabled={confirm.isPending}
                          className="rounded-xl bg-brand px-4 py-2 text-sm font-semibold text-brand-fg hover:bg-brand-hover disabled:opacity-50"
                        >
                          Confirm
                        </button>
                        <button
                          onClick={() => reject.mutate(p.token)}
                          disabled={reject.isPending}
                          className="rounded-xl border border-line bg-surface px-4 py-2 text-sm font-semibold text-body hover:bg-surface-2 disabled:opacity-50"
                        >
                          Reject
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              ))}
            </div>
          ))}
        </div>
      )}

      {error && <LoadError error={error} onRetry={() => setError('')} />}
      </>}
    </div>
  )
}
