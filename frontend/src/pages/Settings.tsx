import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState, type FormEvent } from 'react'
import { Button, Card, Field, Input, Textarea } from '../components/ui'
import { getCompanySettings, updateCompanySettings } from '../data'
import { errorMessage } from '../supabase'

export default function Settings() {
  const qc = useQueryClient()
  const { data } = useQuery({ queryKey: ['company-settings'], queryFn: getCompanySettings })
  const [form, setForm] = useState({ company_name: '', address: '', phone: '', email: '', mc_number: '' })
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    if (data) {
      setForm({
        company_name: data.company_name,
        address: data.address,
        phone: data.phone,
        email: data.email,
        mc_number: data.mc_number,
      })
    }
  }, [data])

  const save = useMutation({
    mutationFn: () => updateCompanySettings(form),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['company-settings'] })
      setError('')
      setSaved(true)
      setTimeout(() => setSaved(false), 2000)
    },
    onError: (err) => setError(errorMessage(err)),
  })

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    save.mutate()
  }

  return (
    <div className="mx-auto max-w-2xl">
      <Card title="Company Settings">
        <p className="mb-5 text-sm text-slate-500">
          This information appears on your invoices and reports.
        </p>
        <form onSubmit={onSubmit} className="space-y-4">
          <Field label="Company Name">
            <Input required value={form.company_name} onChange={(e) => setForm({ ...form, company_name: e.target.value })} />
          </Field>
          <Field label="Address">
            <Textarea value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} />
          </Field>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Field label="Phone">
              <Input value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
            </Field>
            <Field label="Email">
              <Input type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
            </Field>
          </div>
          <Field label="MC Number">
            <Input value={form.mc_number} onChange={(e) => setForm({ ...form, mc_number: e.target.value })} />
          </Field>
          {error && <p className="text-sm text-red-600">{error}</p>}
          <div className="flex items-center justify-end gap-3">
            {saved && <span className="text-sm font-medium text-green-600">✓ Saved</span>}
            <Button type="submit" disabled={save.isPending}>
              {save.isPending ? 'Saving…' : 'Save Settings'}
            </Button>
          </div>
        </form>
      </Card>
    </div>
  )
}
