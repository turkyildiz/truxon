// Platform onboarding: create a new tenant (company) and its first admin user.
// Super-admin only. The service role key stays server-side.
//
//   POST {name, slug, admin_email, admin_password, admin_full_name?}
//     → { tenant: {id, name, slug}, admin_user_id }

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json } from '../_shared/auth.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (!caller.superAdmin) return json({ error: 'Super admin only' }, 403)

  const { name, slug, admin_email, admin_password, admin_full_name } = await req.json()
  if (!name || !slug || !admin_email || !admin_password) {
    return json({ error: 'name, slug, admin_email and admin_password are required' }, 422)
  }
  if (String(admin_password).length < 8) {
    return json({ error: 'admin_password must be at least 8 characters' }, 422)
  }

  // Create the tenant via the SECURITY DEFINER RPC using the CALLER's JWT — the
  // function re-checks super_admin in the DB, so authority is enforced there too.
  const { data: tenant, error: tErr } = await caller.client
    .rpc('create_tenant', { p_name: name, p_slug: slug })
    .single()
  if (tErr) return json({ error: `Create tenant failed: ${tErr.message}` }, 400)
  const t = tenant as { id: number; name: string; slug: string }

  // Create the tenant's first admin with the service role.
  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )
  const { data: userData, error: uErr } = await admin.auth.admin.createUser({
    email: admin_email,
    password: admin_password,
    email_confirm: true,
    user_metadata: {
      username: String(admin_email).split('@')[0],
      full_name: admin_full_name ?? '',
      role: 'admin',
      tenant_id: String(t.id),
    },
  })
  if (uErr) {
    // Roll back the tenant so a failed admin create doesn't leave an orphan.
    await admin.from('tenants').delete().eq('id', t.id).catch(() => {})
    return json({ error: `Tenant created but admin failed: ${uErr.message}` }, 400)
  }

  return json({ tenant: { id: t.id, name: t.name, slug: t.slug }, admin_user_id: userData.user?.id }, 201)
})
