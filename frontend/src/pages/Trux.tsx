/**
 * Trux Command — a full-page executive-analyst workspace over the SAME
 * `trux-agent` edge function the floating TruxChat uses. Trux replies are
 * Markdown (exec summaries + tables); we parse with `marked` and sanitize with
 * `DOMPurify` before rendering — never raw HTML into the DOM. Write actions the
 * agent proposes surface as confirm/reject cards, exactly as in TruxChat.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { errorMessage } from '../supabase'
import { LoadError } from '../components/ui'
import { truxAgent, ToolResult, type Proposal } from '../components/TruxChat'

type LogEntry = { role: 'user' | 'assistant'; content: string; proposals?: Proposal[]; result?: unknown }

// The conversation and session id live in a module-level store so navigating
// away from /trux and back within the same SPA session preserves the whole
// thread (a routed page unmounts on navigation, unlike the floating launcher).
const store: { sessionId: string | null; log: LogEntry[] } = { sessionId: null, log: [] }

// Suggested exec prompts shown on an empty conversation.
const SUGGESTIONS = [
  'P&L this month',
  "Fuel efficiency by driver — who's burning the most?",
  'Which customers owe us money?',
  'Least profitable trucks this month',
  'Toll violations this quarter',
  'How are we doing vs last week?',
]

/** Parse Markdown, then sanitize — the ONLY path by which agent text reaches
 * the DOM. marked runs synchronously; DOMPurify strips scripts/handlers. */
function renderMarkdown(md: string): string {
  const raw = marked.parse(md, { async: false, breaks: true, gfm: true }) as string
  return DOMPurify.sanitize(raw)
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

export default function Trux() {
  const qc = useQueryClient()
  const [sessionId, setSessionId] = useState<string | null>(store.sessionId)
  const [log, setLog] = useState<LogEntry[]>(store.log)
  const [text, setText] = useState('')
  const [error, setError] = useState('')
  const scrollRef = useRef<HTMLDivElement>(null)

  // Keep the module store in sync so the thread survives remounts.
  useEffect(() => {
    store.sessionId = sessionId
    store.log = log
  }, [sessionId, log])

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: 'smooth' })
  }, [log])

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
    },
    onError: (e) => setError(errorMessage(e)),
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

  function submit() {
    const m = text.trim()
    if (!m || send.isPending) return
    send.mutate(m)
  }

  function onKeyDown(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      submit()
    }
  }

  const empty = log.length === 0

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
      </div>

      {/* Conversation */}
      <div
        ref={scrollRef}
        className="flex-1 space-y-4 overflow-y-auto rounded-2xl border border-line bg-surface-2 p-4"
      >
        {empty && (
          <div className="mx-auto max-w-3xl py-6">
            <p className="mb-4 text-center text-sm text-muted">
              Ask Trux to analyze operations &amp; finances. Any action it proposes needs your confirmation.
            </p>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              {SUGGESTIONS.map((s) => (
                <button
                  key={s}
                  onClick={() => send.mutate(s)}
                  disabled={send.isPending}
                  className="group flex items-start gap-3 rounded-xl border border-line bg-surface p-4 text-left transition-colors hover:border-navy-600 disabled:opacity-50"
                >
                  <span className="text-lg">💡</span>
                  <span className="text-sm font-medium text-body group-hover:text-brand">{s}</span>
                </button>
              ))}
            </div>
          </div>
        )}

        {log.map((m, i) =>
          m.role === 'user' ? (
            <div key={i} className="flex justify-end">
              <div className="max-w-[85%] whitespace-pre-wrap rounded-2xl rounded-br-sm bg-navy-700 px-4 py-2.5 text-sm text-white">
                {m.content}
              </div>
            </div>
          ) : (
            <div key={i} className="flex flex-col items-start">
              <div className="w-full rounded-2xl border border-line bg-surface p-4 shadow-sm">
                <div className="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-muted">
                  <span>✨</span> Trux
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
            </div>
          ),
        )}

        {send.isPending && (
          <div className="flex items-center gap-2 px-1 text-sm text-muted">
            <span className="inline-flex gap-1">
              <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-muted [animation-delay:-0.3s]" />
              <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-muted [animation-delay:-0.15s]" />
              <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-muted" />
            </span>
            Trux is thinking…
          </div>
        )}
      </div>

      {error && <LoadError error={error} onRetry={() => setError('')} />}

      {/* Composer */}
      <div className="rounded-2xl border border-line bg-surface p-3 shadow-sm">
        <div className="flex items-end gap-2">
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={onKeyDown}
            placeholder="Ask Trux anything about your operations or finances…"
            rows={2}
            disabled={send.isPending}
            className="max-h-40 flex-1 resize-none rounded-xl border border-line bg-surface px-3 py-2.5 text-sm text-body placeholder:text-muted focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/30 disabled:opacity-50"
          />
          <button
            onClick={submit}
            disabled={send.isPending || !text.trim()}
            className="rounded-xl bg-brand px-5 py-2.5 text-sm font-semibold text-brand-fg hover:bg-brand-hover disabled:cursor-not-allowed disabled:opacity-50"
          >
            {send.isPending ? '…' : 'Send'}
          </button>
        </div>
        <p className="mt-1.5 px-1 text-xs text-muted">Enter to send · Shift+Enter for a new line</p>
      </div>
    </div>
  )
}
