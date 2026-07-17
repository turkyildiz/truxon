/**
 * Trux dispatcher agent — text chat with confirm-before-write cards.
 */
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { supabase, errorMessage } from '../supabase'
import { Button, Card, Input } from './ui'

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

export default function TruxChat() {
  const qc = useQueryClient()
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [text, setText] = useState('')
  const [log, setLog] = useState<{ role: 'user' | 'assistant'; content: string; proposals?: Proposal[] }[]>([])
  const [error, setError] = useState('')

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

  return (
    <Card title="Trux assistant">
      <p className="mb-3 text-sm text-slate-600">
        Ask Trux to create a load, assign truck/driver, or advance status. Write actions require your confirmation.
      </p>
      <div className="mb-3 max-h-80 space-y-2 overflow-y-auto rounded-lg border border-slate-200 bg-slate-50 p-3 text-sm">
        {log.length === 0 && (
          <p className="text-slate-500">
            Try: “List available trucks and drivers” or “Create a load for customer Acme from Dallas to Houston at $1800”.
          </p>
        )}
        {log.map((m, i) => (
          <div key={i} className={m.role === 'user' ? 'text-right' : ''}>
            <div
              className={`inline-block max-w-[95%] rounded-lg px-3 py-2 whitespace-pre-wrap ${
                m.role === 'user' ? 'bg-navy-700 text-white' : 'bg-white border border-slate-200 text-slate-800'
              }`}
            >
              {m.content}
            </div>
            {m.proposals?.map((p) => (
              <div key={p.token} className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-2 text-left">
                <div className="font-medium text-amber-900">{p.summary}</div>
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
      </div>
      {error && <p className="mb-2 text-sm text-red-600">{error}</p>}
      <form onSubmit={onSubmit} className="flex gap-2">
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
    </Card>
  )
}
