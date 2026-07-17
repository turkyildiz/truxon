/** Ordered pickup/delivery stop editor used by Dispatch (new load) and
 * LoadDetail (edit). The first pickup and final delivery become the load's
 * primary route fields; everything is stored in load_stops. */
import { Button, Field, Input, Textarea } from './ui'

export interface StopForm {
  stop_type: 'pickup' | 'delivery'
  facility: string
  address: string
  time: string // datetime-local value or ''
  reference: string
}

export const emptyStop = (stop_type: 'pickup' | 'delivery'): StopForm => ({ stop_type, facility: '', address: '', time: '', reference: '' })

interface Props {
  stops: StopForm[]
  onChange: (stops: StopForm[]) => void
  /** Called after add/remove/address edits so miles can recalculate. */
  onRouteBlur?: () => void
}

export default function StopsEditor({ stops, onChange, onRouteBlur }: Props) {
  const groups: Array<{ type: 'pickup' | 'delivery'; label: string; addLabel: string }> = [
    { type: 'pickup', label: 'Pickup', addLabel: '+ Add pickup location' },
    { type: 'delivery', label: 'Delivery', addLabel: '+ Add delivery location' },
  ]

  function update(index: number, patch: Partial<StopForm>) {
    onChange(stops.map((s, i) => (i === index ? { ...s, ...patch } : s)))
  }
  function add(type: 'pickup' | 'delivery') {
    // Pickups stay grouped before deliveries so the route reads top-to-bottom.
    const lastOfType = stops.map((s) => s.stop_type).lastIndexOf(type)
    const at = type === 'pickup' && lastOfType === -1 ? 0 : lastOfType === -1 ? stops.length : lastOfType + 1
    const next = [...stops]
    next.splice(at, 0, emptyStop(type))
    onChange(next)
  }
  function remove(index: number) {
    onChange(stops.filter((_, i) => i !== index))
    onRouteBlur?.()
  }

  return (
    <div className="space-y-4 sm:col-span-2">
      {groups.map((g) => {
        const ofType = stops.map((s, i) => ({ s, i })).filter((x) => x.s.stop_type === g.type)
        return (
          <div key={g.type}>
            <div className="mb-2 flex items-center justify-between">
              <span className="text-xs font-semibold uppercase tracking-wide text-muted">
                {g.label} {ofType.length > 1 ? `(${ofType.length} stops)` : ''}
              </span>
              <Button type="button" variant="secondary" className="!py-1 text-xs" onClick={() => add(g.type)}>
                {g.addLabel}
              </Button>
            </div>
            <div className="space-y-3">
              {ofType.map(({ s, i }, n) => (
                <div key={i} className="rounded-xl border border-line p-3">
                  <div className="mb-2 flex items-center justify-between">
                    <span className="text-xs font-semibold text-brand">
                      {g.label} {ofType.length > 1 ? `#${n + 1}` : ''}
                    </span>
                    {ofType.length > 1 && (
                      <button type="button" onClick={() => remove(i)} className="text-xs font-medium text-red-600 hover:underline">
                        Remove
                      </button>
                    )}
                  </div>
                  <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                    <Field label="Facility / Shipper">
                      <Input value={s.facility} onChange={(e) => update(i, { facility: e.target.value })} />
                    </Field>
                    <Field label={g.type === 'pickup' ? 'Pickup # / PO' : 'Delivery # / PO'}>
                      <Input value={s.reference} onChange={(e) => update(i, { reference: e.target.value })} />
                    </Field>
                    <Field label="Address" className="sm:col-span-2">
                      <Textarea rows={2} value={s.address} onChange={(e) => update(i, { address: e.target.value })} onBlur={onRouteBlur} />
                    </Field>
                    <Field label={g.type === 'pickup' ? 'Pickup Time' : 'Delivery Time'}>
                      <Input type="datetime-local" value={s.time} onChange={(e) => update(i, { time: e.target.value })} />
                    </Field>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )
      })}
    </div>
  )
}
