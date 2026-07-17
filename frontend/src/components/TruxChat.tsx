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
  const [log, setLog] = useState<{ role: 'user' | 'assistant'; content: string; proposals?: Proposal[] }[]>([])
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
          content: res.executed
            ? `✓ Confirmed. ${JSON.stringify(res.result ?? {}).slice(0, 300)}`
            : res.reply ?? 'Done.',
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
    <div className="flex h-full flex-col rounded-xl bg-white shadow-2xl ring-1 ring-slate-200">
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
      <div ref={scrollRef} className="flex-1 space-y-2 overflow-y-auto bg-slate-50 p-3 text-sm">
        {log.length === 0 && (
          <div className="space-y-2">
            <p className="text-slate-500">Ask Trux about your work. Any action it proposes needs your confirmation.</p>
            {suggestions.map((s) => (
              <button
                key={s}
                onClick={() => send.mutate(s)}
                disabled={send.isPending}
                className="block w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-left text-slate-700 hover:border-navy-600 hover:text-navy-700"
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
                m.role === 'user' ? 'bg-navy-700 text-white' : 'border border-slate-200 bg-white text-slate-800'
              }`}
            >
              {m.content}
            </div>
            {m.proposals?.map((p) => (
              <div key={p.token} className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-2 text-left">
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
        {send.isPending && <p className="text-slate-400">Trux is thinking…</p>}
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
      {open && (
        <div className="fixed right-4 bottom-20 z-40 flex h-[min(34rem,calc(100vh-7rem))] w-[min(24rem,calc(100vw-2rem))] flex-col">
          <TruxChat onClose={() => setOpen(false)} />
        </div>
      )}
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
