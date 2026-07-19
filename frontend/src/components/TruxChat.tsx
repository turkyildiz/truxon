/**
 * Trux — Truxon's operating agent. Floating app-wide chat with
 * confirm-before-write cards. Tools are role-scoped server-side.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useAuth } from '../auth'
import { supabase, errorMessage } from '../supabase'
import { Button, Input } from './ui'

type Proposal = { token: string; tool: string; args: unknown; summary: string }

type LogEntry = { role: 'user' | 'assistant'; content: string; proposals?: Proposal[]; result?: unknown }

/** One-line human summary of a tool result, shown as the details toggle. */
function resultSummary(result: unknown): string {
  if (Array.isArray(result)) return `${result.length} item${result.length === 1 ? '' : 's'} — details`
  if (result && typeof result === 'object') {
    const obj = result as Record<string, unknown>
    const id = obj.load_number ?? obj.number ?? obj.id
    if (id != null) return `Result: ${String(id)} — details`
    const keys = Object.keys(obj)
    return `${keys.length} field${keys.length === 1 ? '' : 's'} — details`
  }
  if (result == null) return 'details'
  return `${String(result)}`
}

/** Renders a tool result as a compact, collapsible pane instead of dumping raw
 * JSON into the message flow. */
function ToolResult({ result }: { result: unknown }) {
  if (result == null || (typeof result === 'object' && Object.keys(result as object).length === 0)) return null
  return (
    <details className="mt-2 inline-block max-w-[95%] rounded-lg border border-line bg-surface px-3 py-2 text-left text-xs">
      <summary className="cursor-pointer font-medium text-muted">{resultSummary(result)}</summary>
      <pre className="mt-2 max-h-52 overflow-auto whitespace-pre-wrap break-all text-muted">{JSON.stringify(result, null, 2)}</pre>
    </details>
  )
}

async function truxAgent(body: Record<string, unknown>) {
  const { data, error } = await supabase.functions.invoke('trux-agent', { body })
  if (error) {
    const ctx = (error as { context?: Response }).context
    if (ctx) {
      const j = await ctx.json().catch(() => null)
      if (j?.error) throw new Error(j.error)
    }
    throw new Error(error.message)
  }
  return data as {
    session_id: string
    reply?: string
    proposals?: Proposal[]
    executed?: boolean
    result?: unknown
    error?: string
  }
}

const SUGGESTIONS: Record<string, string[]> = {
  admin: ['Give me a recap — how are we doing vs last week?', 'List available trucks and drivers'],
  dispatcher: ['List available trucks and drivers', 'Find loads for customer TQL'],
  accountant: ['Weekly report for this week', 'Give me a recap of this week'],
  driver: ['What are my loads?', 'Show my next pickup'],
  maintenance: ['List equipment status', 'Recent maintenance records'],
}

export default function TruxChat({ onClose }: { onClose?: () => void }) {
  const qc = useQueryClient()
  const { user } = useAuth()
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [text, setText] = useState('')
  const [log, setLog] = useState<LogEntry[]>([])
  const [error, setError] = useState('')
  const scrollRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight })
  }, [log])

  const send = useMutation({
    mutationFn: async (message: string) => {
      const res = await truxAgent({ session_id: sessionId ?? undefined, message })
      return res
    },
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
          // Structured result is shown via a collapsible pane, not dumped raw.
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
    onSuccess: () => {
      setLog((prev) => [...prev, { role: 'assistant', content: 'Cancelled that action.' }])
    },
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    const m = text.trim()
    if (!m || send.isPending) return
    send.mutate(m)
  }

  const suggestions = SUGGESTIONS[user?.role ?? ''] ?? []

  return (
    <div className="flex h-full flex-col rounded-xl bg-surface shadow-2xl ring-1 ring-slate-200">
      <div className="flex items-center justify-between rounded-t-xl bg-navy-900 px-4 py-3 text-white">
        <div className="flex items-center gap-2">
          <span className="text-lg">🤖</span>
          <span className="font-bold tracking-wide">Trux</span>
          <span className="text-xs text-navy-100">Truxon assistant</span>
        </div>
        {onClose && (
          <button onClick={onClose} className="rounded-md px-2 py-0.5 text-navy-100 hover:bg-navy-700" aria-label="Close Trux">
            ✕
          </button>
        )}
      </div>
      <div ref={scrollRef} className="flex-1 space-y-2 overflow-y-auto bg-surface-2 p-3 text-sm">
        {log.length === 0 && (
          <div className="space-y-2">
            <p className="text-muted">Ask Trux about your work. Any action it proposes needs your confirmation.</p>
            {suggestions.map((s) => (
              <button
                key={s}
                onClick={() => send.mutate(s)}
                disabled={send.isPending}
                className="block w-full rounded-lg border border-line bg-surface px-3 py-2 text-left text-body hover:border-navy-600 hover:text-brand"
              >
                {s}
              </button>
            ))}
          </div>
        )}
        {log.map((m, i) => (
          <div key={i} className={m.role === 'user' ? 'text-right' : ''}>
            <div
              className={`inline-block max-w-[95%] rounded-lg px-3 py-2 text-left whitespace-pre-wrap ${
                m.role === 'user' ? 'bg-navy-700 text-white' : 'border border-line bg-surface text-body'
              }`}
            >
              {m.content}
            </div>
            {m.result != null && (
              <div>
                <ToolResult result={m.result} />
              </div>
            )}
            {m.proposals?.map((p) => (
              <div key={p.token} className="mt-2 rounded-lg border border-amber-500/30 bg-amber-500/10 p-2 text-left">
                <div className="font-medium break-all text-amber-900">{p.summary}</div>
                <div className="mt-2 flex gap-2">
                  <Button type="button" onClick={() => confirm.mutate(p.token)} disabled={confirm.isPending}>
                    Confirm
                  </Button>
                  <Button type="button" variant="secondary" onClick={() => reject.mutate(p.token)}>
                    Reject
                  </Button>
                </div>
              </div>
            ))}
          </div>
        ))}
        {send.isPending && <p className="text-muted">Trux is thinking…</p>}
      </div>
      {error && <p className="px-3 pt-2 text-sm text-red-600">{error}</p>}
      <form onSubmit={onSubmit} className="flex gap-2 p-3">
        <Input
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Message Trux…"
          className="flex-1"
          disabled={send.isPending}
        />
        <Button type="submit" disabled={send.isPending || !text.trim()}>
          {send.isPending ? '…' : 'Send'}
        </Button>
      </form>
    </div>
  )
}

/** Floating launcher + panel, mounted once in Layout. */
export function TruxLauncher() {
  const [open, setOpen] = useState(false)
  return (
    <>
      {/* Kept mounted and hidden with CSS (not unmounted) so toggling the panel
          closed and back open preserves the whole conversation. */}
      <div
        className={`fixed right-4 bottom-20 z-40 flex h-[min(34rem,calc(100vh-7rem))] w-[min(24rem,calc(100vw-2rem))] flex-col ${open ? '' : 'hidden'}`}
      >
        <TruxChat onClose={() => setOpen(false)} />
      </div>
      <button
        onClick={() => setOpen((v) => !v)}
        aria-label={open ? 'Close Trux' : 'Open Trux'}
        className="fixed right-4 bottom-4 z-40 flex h-13 items-center gap-2 rounded-full bg-navy-900 px-4 text-white shadow-lg transition-transform hover:scale-105"
      >
        <span className="text-xl">🤖</span>
        <span className="text-sm font-bold tracking-wide">{open ? 'Close' : 'Trux'}</span>
      </button>
    </>
  )
}
