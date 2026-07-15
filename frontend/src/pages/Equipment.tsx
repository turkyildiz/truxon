import ResourcePage from '../components/ResourcePage'
import { Badge, formatDate, money } from '../components/ui'
import type { Equipment } from '../types'

const STATUS_OPTIONS = [
  { value: 'available', label: 'Available' },
  { value: 'in_use', label: 'In Use' },
  { value: 'maintenance', label: 'Maintenance' },
  { value: 'retired', label: 'Retired' },
]

function EquipmentPage({ title, endpoint }: { title: string; endpoint: string }) {
  return (
    <ResourcePage<Equipment>
      title={title}
      endpoint={endpoint}
      columns={[
        { header: 'Unit #', render: (t) => <span className="font-medium">{t.unit_number}</span> },
        { header: 'Make / Model / Year', render: (t) => [t.make, t.model, t.year].filter(Boolean).join(' ') || '—' },
        { header: 'VIN', render: (t) => t.vin || '—' },
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
        { name: 'monthly_cost', label: 'Monthly Cost ($)', type: 'number', step: '0.01' },
        { name: 'in_service_date', label: 'In-Service Date', type: 'date' },
        { name: 'out_of_service_date', label: 'Out-of-Service Date', type: 'date' },
        { name: 'status', label: 'Status', type: 'select', required: true, options: STATUS_OPTIONS },
      ]}
      defaults={{ unit_number: '', make: '', model: '', year: '', vin: '', monthly_cost: '0', in_service_date: '', out_of_service_date: '', status: 'available' }}
      toForm={(t) => ({
        unit_number: t.unit_number,
        make: t.make,
        model: t.model,
        year: t.year ?? '',
        vin: t.vin,
        monthly_cost: t.monthly_cost,
        in_service_date: t.in_service_date ?? '',
        out_of_service_date: t.out_of_service_date ?? '',
        status: t.status,
      })}
    />
  )
}

export const Trucks = () => <EquipmentPage title="Trucks" endpoint="/trucks" />
export const Trailers = () => <EquipmentPage title="Trailers" endpoint="/trailers" />
