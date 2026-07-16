import ResourcePage from '../components/ResourcePage'
import { Badge, formatDate, money } from '../components/ui'
import { trailersApi, trucksApi } from '../data'
import type { Equipment } from '../types'

const STATUS_OPTIONS = [
  { value: 'available', label: 'Available' },
  { value: 'in_use', label: 'In Use' },
  { value: 'maintenance', label: 'Maintenance' },
  { value: 'retired', label: 'Retired' },
]

function EquipmentPage({ title, api, queryKey, entityType }: { title: string; api: typeof trucksApi; queryKey: string; entityType: 'truck' | 'trailer' }) {
  return (
    <ResourcePage<Equipment>
      title={title}
      queryKey={queryKey}
      list={api.list}
      create={api.create}
      update={api.update}
      docs={{ entityType, docTypes: ['Registration', 'Insurance', 'Inspection', 'Other'], label: (t) => `Unit ${t.unit_number}` }}
      columns={[
        { header: 'Unit #', render: (t) => <span className="font-medium">{t.unit_number}</span> },
        { header: 'Make / Model / Year', render: (t) => [t.make, t.model, t.year].filter(Boolean).join(' ') || '—' },
        { header: 'VIN', render: (t) => t.vin || '—' },
        { header: 'Plate', render: (t) => (t.plate_number ? `${t.plate_number}${t.plate_expiry ? ` (exp ${formatDate(t.plate_expiry)})` : ''}` : '—') },
        { header: 'In Service', render: (t) => formatDate(t.in_service_date) },
        { header: 'Monthly Cost', render: (t) => money(t.monthly_cost) },
        { header: 'Status', render: (t) => <Badge status={t.status} /> },
      ]}
      fields={[
        { name: 'unit_number', label: 'Unit #', required: true },
        { name: 'make', label: 'Make' },
        { name: 'model', label: 'Model' },
        { name: 'year', label: 'Year', type: 'number' },
        { name: 'vin', label: 'VIN' },
        { name: 'plate_number', label: 'Plate Number' },
        { name: 'plate_expiry', label: 'Plate Expiry', type: 'date' },
        { name: 'monthly_cost', label: 'Monthly Cost ($)', type: 'number', step: '0.01' },
        { name: 'in_service_date', label: 'In-Service Date', type: 'date' },
        { name: 'out_of_service_date', label: 'Out-of-Service Date', type: 'date' },
        { name: 'status', label: 'Status', type: 'select', required: true, options: STATUS_OPTIONS },
        { name: 'notes', label: 'Notes', type: 'textarea', full: true },
      ]}
      defaults={{ unit_number: '', make: '', model: '', year: '', vin: '', plate_number: '', plate_expiry: '', monthly_cost: '0', in_service_date: '', out_of_service_date: '', status: 'available', notes: '' }}
      toForm={(t) => ({
        unit_number: t.unit_number,
        make: t.make,
        model: t.model,
        year: t.year ?? '',
        vin: t.vin,
        plate_number: t.plate_number,
        plate_expiry: t.plate_expiry ?? '',
        monthly_cost: t.monthly_cost,
        in_service_date: t.in_service_date ?? '',
        out_of_service_date: t.out_of_service_date ?? '',
        status: t.status,
        notes: t.notes,
      })}
    />
  )
}

export const Trucks = () => <EquipmentPage title="Trucks" api={trucksApi} queryKey="trucks" entityType="truck" />
export const Trailers = () => <EquipmentPage title="Trailers" api={trailersApi} queryKey="trailers" entityType="trailer" />
