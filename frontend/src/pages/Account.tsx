/** My Account — self-service security for EVERY office user (dispatchers and
 * accountants don't see the admin Security console, but MFA only protects the
 * company if everyone with money/data access enrolls). MFA phase 2 groundwork:
 * enrollment surface for all; enforcement (AAL2) comes later as a flag. */
import MfaCard from '../components/MfaCard'
import { Card, PageHeader } from '../components/ui'
import { useAuth } from '../auth'

export default function Account() {
  const { user } = useAuth()
  return (
    <div className="mx-auto max-w-3xl space-y-6 p-4 lg:p-6">
      <PageHeader title="My Account" subtitle="Your sign-in security." />
      <Card title="Who you are">
        <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
          <div><div className="text-xs uppercase tracking-wide text-muted">Name</div><div className="mt-1 font-medium">{user?.full_name || user?.username || '—'}</div></div>
          <div><div className="text-xs uppercase tracking-wide text-muted">Username</div><div className="mt-1 font-medium">{user?.username ?? '—'}</div></div>
          <div><div className="text-xs uppercase tracking-wide text-muted">Role</div><div className="mt-1 font-medium capitalize">{user?.role ?? '—'}</div></div>
        </div>
      </Card>
      <MfaCard />
    </div>
  )
}
