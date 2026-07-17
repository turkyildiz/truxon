import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { Badge, Button, Card, Field, formatDate, LoadError, Modal, money, Select, Table } from '../components/ui'
import { createInvoice, listCustomers, listInvoices, listLoads, setInvoiceStatus, voidInvoice } from '../data'
import { downloadInvoicePdf } from '../invoicePdf'
import { errorMessage } from '../supabase'

export default function Invoices() {
  const qc = useQueryClient()
  const [creating, setCreating] = useState(false)
  const [customerId, setCustomerId] = useState('')
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [error, setError] = useState('')
  const [pageError, setPageError] = useState('')

  const invoicesQ = useQuery({ queryKey: ['invoices'], queryFn: listInvoices })
  const { data: invoices = [], isLoading } = invoicesQ
  const customersQ = useQuery({ queryKey: ['customers', ''], queryFn: () => listCustomers() })
  const customers = customersQ.data ?? []
  const { data: billableLoads = [] } = useQuery({
    queryKey: ['loads', 'completed', customerId],
    queryFn: () => listLoads({ status: 'completed', customer_id: customerId }),
    enabled: creating && !!customerId,
  })

  const create = useMutation({
    mutationFn: () => createInvoice(Number(customerId), [...selected]),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['invoices'] })
      qc.invalidateQueries({ queryKey: ['loads'] })
      close()
    },
    onError: (err) => setError(errorMessage(err)),
  })

  const statusMutation = useMutation({
    mutationFn: ({ id, status }: { id: number; status: string }) => setInvoiceStatus(id, status),
    onSuccess: () => {
      setPageError('')
      qc.invalidateQueries({ queryKey: ['invoices'] })
    },
    onError: (err) => setPageError(errorMessage(err)),
  })

  const voidMutation = useMutation({
    mutationFn: (id: number) => voidInvoice(id),
    onSuccess: () => {
      setPageError('')
      qc.invalidateQueries({ queryKey: ['invoices'] })
      qc.invalidateQueries({ queryKey: ['loads'] })
    },
    onError: (err) => setPageError(errorMessage(err)),
  })

  function pdf(id: number) {
    downloadInvoicePdf(id).catch((err) => setPageError(errorMessage(err)))
  }

  function close() {
    setCreating(false)
    setCustomerId('')
    setSelected(new Set())
    setError('')
  }

  function toggle(id: number) {
    const next = new Set(selected)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    setSelected(next)
  }

  const total = billableLoads.filter((l) => selected.has(l.id)).reduce((sum, l) => sum + Number(l.rate), 0)

  return (
    <Card title="Invoices" actions={<Button onClick={() => setCreating(true)}>+ Generate Invoice</Button>}>
      {pageError && <p className="mb-3 rounded-lg bg-red-500/10 p-3 text-sm text-red-600 dark:text-red-300">{pageError}</p>}
      {isLoading ? (
        <p className="py-8 text-center text-muted">Loading…</p>
      ) : invoicesQ.isError ? (
        <LoadError error={invoicesQ.error} onRetry={() => invoicesQ.refetch()} />
      ) : invoices.length === 0 ? (
        <p className="py-8 text-center text-muted">No invoices yet. Complete a load, then generate one.</p>
      ) : (
        <Table headers={['Invoice #', 'Customer', 'Date', 'Loads', 'Total', 'Status', '']}>
          {invoices.map((inv) => (
            <tr key={inv.id} className="hover:bg-surface-2">
              <td className="px-3 py-3 font-medium text-brand">{inv.invoice_number}</td>
              <td className="px-3 py-3">{inv.customer_name}</td>
              <td className="px-3 py-3">{formatDate(inv.invoice_date)}</td>
              <td className="px-3 py-3">{inv.load_count}</td>
              <td className="px-3 py-3 font-semibold">{money(inv.total)}</td>
              <td className="px-3 py-3">
                <Badge status={inv.status} />
              </td>
              <td className="px-3 py-3 text-right whitespace-nowrap">
                <button onClick={() => pdf(inv.id)} className="mr-3 text-sm font-medium text-brand hover:underline">
                  PDF
                </button>
                {inv.status === 'draft' && (
                  <button
                    onClick={() => statusMutation.mutate({ id: inv.id, status: 'sent' })}
                    className="mr-3 text-sm font-medium text-blue-600 hover:underline"
                  >
                    Mark Sent
                  </button>
                )}
                {inv.status === 'sent' && (
                  <button
                    onClick={() => statusMutation.mutate({ id: inv.id, status: 'paid' })}
                    className="mr-3 text-sm font-medium text-green-600 hover:underline"
                  >
                    Mark Paid
                  </button>
                )}
                {inv.status !== 'paid' && (
                  <button
                    onClick={() => window.confirm(`Void ${inv.invoice_number}? Its loads go back to "completed" for re-billing.`) && voidMutation.mutate(inv.id)}
                    className="mr-3 text-sm font-medium text-red-600 hover:underline"
                  >
                    Void
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
            {customersQ.isError && (
              <p className="mt-1 text-sm text-red-600">
                Customer list failed to load —{' '}
                <button type="button" className="font-medium underline" onClick={() => customersQ.refetch()}>
                  retry
                </button>
              </p>
            )}
          </Field>

          {customerId && (
            <div>
              <div className="mb-2 text-xs font-semibold uppercase text-muted">Completed loads ready to bill</div>
              {billableLoads.length === 0 ? (
                <p className="rounded-lg bg-surface-2 p-4 text-sm text-muted">No completed, un-billed loads for this customer.</p>
              ) : (
                <ul className="max-h-64 space-y-1 overflow-y-auto">
                  {billableLoads.map((l) => (
                    <li key={l.id}>
                      <label className="flex cursor-pointer items-center gap-3 rounded-lg border border-line p-3 text-sm hover:bg-surface-2">
                        <input type="checkbox" checked={selected.has(l.id)} onChange={() => toggle(l.id)} className="h-4 w-4" />
                        <span className="font-medium">{l.load_number}</span>
                        <span className="flex-1 truncate text-muted">
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
                  <span className="text-muted">{selected.size} load(s) — total </span>
                  <span className="text-lg font-bold text-brand">{money(total)}</span>
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
