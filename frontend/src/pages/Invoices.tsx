import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorMessage } from '../api'
import { Badge, Button, Card, Field, formatDate, Modal, money, Select, Table } from '../components/ui'
import type { Customer, Invoice, Load } from '../types'

export default function Invoices() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [customerId, setCustomerId] = useState('')
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [error, setError] = useState('')

  const { data: invoices = [], isLoading } = useQuery({
    queryKey: ['/invoices'],
    queryFn: () => api.get<Invoice[]>('/invoices').then((r) => r.data),
  })
  const { data: customers = [] } = useQuery({
    queryKey: ['/customers'],
    queryFn: () => api.get<Customer[]>('/customers').then((r) => r.data),
  })
  const { data: billableLoads = [] } = useQuery({
    queryKey: ['/loads', 'completed', customerId],
    queryFn: () => api.get<Load[]>('/loads', { params: { status: 'completed', ...(customerId ? { customer_id: customerId } : {}) } }).then((r) => r.data),
    enabled: creating && !!customerId,
  })

  const create = useMutation({
    mutationFn: () => api.post('/invoices', { customer_id: Number(customerId), load_ids: [...selected] }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['/invoices'] })
      qc.invalidateQueries({ queryKey: ['/loads'] })
      close()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const setStatus = useMutation({
    mutationFn: ({ id, status }: { id: number; status: string }) => api.post(`/invoices/${id}/status`, null, { params: { status } }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['/invoices'] }),
  })

  function close() {
    setCreating(false)
    setCustomerId('')
    setSelected(new Set())
    setError('')
  }

  async function openPdf(id: number, number: string) {
    const res = await api.get(`/invoices/${id}/pdf`, { responseType: 'blob' })
    const url = URL.createObjectURL(new Blob([res.data], { type: 'application/pdf' }))
    const a = document.createElement('a')
    a.href = url
    a.download = `${number}.pdf`
    a.click()
    URL.revokeObjectURL(url)
  }

  function toggle(id: number) {
    const next = new Set(selected)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    setSelected(next)
  }

  const total = billableLoads.filter((l) => selected.has(l.id)).reduce((sum, l) => sum + parseFloat(l.rate), 0)

  return (
    <Card title="Invoices" actions={<Button onClick={() => setCreating(true)}>+ Generate Invoice</Button>}>
      {isLoading ? (
        <p className="py-8 text-center text-slate-500">Loading…</p>
      ) : invoices.length === 0 ? (
        <p className="py-8 text-center text-slate-500">No invoices yet. Complete a load, then generate one.</p>
      ) : (
        <Table headers={['Invoice #', 'Customer', 'Date', 'Loads', 'Total', 'Status', '']}>
          {invoices.map((inv) => (
            <tr key={inv.id} className="hover:bg-slate-50">
              <td className="px-3 py-3 font-medium text-navy-700">{inv.invoice_number}</td>
              <td className="px-3 py-3">{inv.customer_name}</td>
              <td className="px-3 py-3">{formatDate(inv.invoice_date)}</td>
              <td className="px-3 py-3">{inv.load_count}</td>
              <td className="px-3 py-3 font-semibold">{money(inv.total)}</td>
              <td className="px-3 py-3">
                <Badge status={inv.status} />
              </td>
              <td className="px-3 py-3 text-right whitespace-nowrap">
                <button onClick={() => openPdf(inv.id, inv.invoice_number)} className="mr-3 text-sm font-medium text-navy-600 hover:underline">
                  PDF
                </button>
                {inv.status === 'draft' && (
                  <button onClick={() => setStatus.mutate({ id: inv.id, status: 'sent' })} className="mr-3 text-sm font-medium text-blue-600 hover:underline">
                    Mark Sent
                  </button>
                )}
                {inv.status === 'sent' && (
                  <button onClick={() => setStatus.mutate({ id: inv.id, status: 'paid' })} className="mr-3 text-sm font-medium text-green-600 hover:underline">
                    Mark Paid
                  </button>
                )}
              </td>
            </tr>
          ))}
        </Table>
      )}

      <Modal title="Generate Invoice" open={creating} onClose={close}>
        <div className="space-y-4">
          <Field label="Customer">
            <Select
              value={customerId}
              onChange={(e) => {
                setCustomerId(e.target.value)
                setSelected(new Set())
              }}
            >
              <option value="">Select customer…</option>
              {customers.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.company_name}
                </option>
              ))}
            </Select>
          </Field>

          {customerId && (
            <div>
              <div className="mb-2 text-xs font-semibold uppercase text-slate-500">Completed loads ready to bill</div>
              {billableLoads.length === 0 ? (
                <p className="rounded-lg bg-slate-50 p-4 text-sm text-slate-500">No completed, un-billed loads for this customer.</p>
              ) : (
                <ul className="max-h-64 space-y-1 overflow-y-auto">
                  {billableLoads.map((l) => (
                    <li key={l.id}>
                      <label className="flex cursor-pointer items-center gap-3 rounded-lg border border-slate-200 p-3 text-sm hover:bg-slate-50">
                        <input type="checkbox" checked={selected.has(l.id)} onChange={() => toggle(l.id)} className="h-4 w-4" />
                        <span className="font-medium">{l.load_number}</span>
                        <span className="flex-1 truncate text-slate-500">
                          {l.pickup_address?.split(',')[0]} → {l.delivery_address?.split(',')[0]}
                        </span>
                        <span className="font-semibold">{money(l.rate)}</span>
                      </label>
                    </li>
                  ))}
                </ul>
              )}
              {selected.size > 0 && (
                <div className="mt-3 text-right text-sm">
                  <span className="text-slate-500">{selected.size} load(s) — total </span>
                  <span className="text-lg font-bold text-navy-700">{money(total)}</span>
                </div>
              )}
            </div>
          )}

          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex justify-end gap-3">
            <Button variant="secondary" onClick={close}>
              Cancel
            </Button>
            <Button disabled={!customerId || selected.size === 0 || create.isPending} onClick={() => create.mutate()}>
              {create.isPending ? 'Generating…' : 'Generate Invoice'}
            </Button>
          </div>
        </div>
      </Modal>
    </Card>
  )
}
