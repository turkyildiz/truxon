import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { Button, Card, Field, Input, LoadError, Modal, PageHeader, Table } from '../components/ui'
import { createTenant, listTenants } from '../data'

/** Platform super-admin surface: create a company (tenant) and its first admin.
 * Reachable only by a super_admin (guarded in the router + server-side). */
export default function Tenants() {
  const qc = useQueryClient()
  const tenantsQ = useQuery({ queryKey: ['tenants'], queryFn: listTenants })
  const [open, setOpen] = useState(false)
  const [form, setForm] = useState({ name: '', slug: '', admin_email: '', admin_password: '', admin_full_name: '' })
  const [error, setError] = useState<string | null>(null)
  const [created, setCreated] = useState<string | null>(null)

  const set = (k: keyof typeof form) => (e: { target: { value: string } }) => setForm((f) => ({ ...f, [k]: e.target.value }))

  const createM = useMutation({
    mutationFn: () => createTenant(form),
    onSuccess: (res) => {
      setCreated(`Created “${res.tenant.name}” with admin ${form.admin_email}.`)
      setOpen(false)
      setForm({ name: '', slug: '', admin_email: '', admin_password: '', admin_full_name: '' })
      void qc.invalidateQueries({ queryKey: ['tenants'] })
    },
    onError: (e: unknown) => setError(e instanceof Error ? e.message : 'Failed to create tenant'),
  })

  function submit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    if (!form.name || !form.slug || !form.admin_email || form.admin_password.length < 8) {
      setError('Company name, slug, admin email, and a password of at least 8 characters are required.')
      return
    }
    createM.mutate()
  }

  // Auto-suggest a slug from the company name until the user edits it manually.
  function onName(e: { target: { value: string } }) {
    const name = e.target.value
    setForm((f) => ({
      ...f,
      name,
      slug: f.slug === '' || f.slug === slugify(f.name) ? slugify(name) : f.slug,
    }))
  }

  return (
    <div className="space-y-6">
      <PageHeader
        title="Tenants"
        subtitle="Companies on this Truxon platform. Each is fully isolated."
        actions={<Button onClick={() => { setError(null); setCreated(null); setOpen(true) }}>New company</Button>}
      />

      {created && (
        <div className="rounded-lg border border-emerald-300 bg-emerald-50 px-4 py-3 text-sm text-emerald-800 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300">
          {created}
        </div>
      )}

      {tenantsQ.isError ? (
        <LoadError error={tenantsQ.error} onRetry={() => tenantsQ.refetch()} />
      ) : (
        <Card>
          <Table headers={['Company', 'Slug', 'Status', 'Created']}>
            {(tenantsQ.data ?? []).map((t) => (
              <tr key={t.id}>
                <td className="px-4 py-2 font-medium">{t.name}</td>
                <td className="px-4 py-2 text-slate-500">{t.slug}</td>
                <td className="px-4 py-2">{t.is_active ? 'Active' : 'Inactive'}</td>
                <td className="px-4 py-2 text-slate-500">{t.created_at?.slice(0, 10)}</td>
              </tr>
            ))}
            {tenantsQ.data && tenantsQ.data.length === 0 && (
              <tr>
                <td colSpan={4} className="px-4 py-6 text-center text-slate-500">No tenants yet.</td>
              </tr>
            )}
          </Table>
        </Card>
      )}

      <Modal title="New company" open={open} onClose={() => setOpen(false)}>
        <form onSubmit={submit} className="space-y-4">
          <p className="text-sm text-slate-500">
            Creates an isolated company and its first admin login. The admin can then invite the rest of their team.
          </p>
          <Field label="Company name">
            <Input value={form.name} onChange={onName} placeholder="Beta Freight LLC" autoFocus />
          </Field>
          <Field label="Slug (unique, lowercase)">
            <Input value={form.slug} onChange={set('slug')} placeholder="beta-freight" />
          </Field>
          <div className="border-t border-slate-200 pt-4 dark:border-slate-700">
            <p className="mb-3 text-xs font-semibold uppercase tracking-wide text-slate-400">First admin</p>
            <Field label="Admin full name">
              <Input value={form.admin_full_name} onChange={set('admin_full_name')} placeholder="Jane Operator" />
            </Field>
            <Field label="Admin email">
              <Input type="email" value={form.admin_email} onChange={set('admin_email')} placeholder="jane@betafreight.com" />
            </Field>
            <Field label="Temporary password (min 8 chars)">
              <Input type="text" value={form.admin_password} onChange={set('admin_password')} placeholder="set a strong temporary password" />
            </Field>
          </div>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex justify-end gap-2">
            <Button type="button" variant="secondary" onClick={() => setOpen(false)}>Cancel</Button>
            <Button type="submit" disabled={createM.isPending}>{createM.isPending ? 'Creating…' : 'Create company'}</Button>
          </div>
        </form>
      </Modal>
    </div>
  )
}

function slugify(s: string): string {
  return s.toLowerCase().trim().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
}
