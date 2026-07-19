// Admin-only user management. Creating auth users requires the service
// role key, which must never reach the browser — so it lives here.
//
//   GET    → list users (profiles + email)
//   POST   {email, password, username?, full_name?, role, link_driver_id?}
//   PATCH  {id, full_name?, password?, role?, is_active?}

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json } from '../_shared/auth.ts'

const VALID_ROLES = new Set(['admin', 'dispatcher', 'driver', 'accountant', 'maintenance'])

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsResponse()

  const caller = await getCaller(req)
  if (caller instanceof Response) return caller
  if (caller.role !== 'admin') return json({ error: 'Admin only' }, 403)

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  if (req.method === 'GET') {
    const { data: profiles, error } = await admin
      .from('profiles')
      .select('id, username, full_name, role, is_active, created_at')
      .order('username')
    if (error) return json({ error: error.message }, 500)

    const { data: usersData } = await admin.auth.admin.listUsers({ perPage: 1000 })
    const emails = new Map(usersData.users.map((u) => [u.id, u.email]))
    return json(profiles.map((p) => ({ ...p, email: emails.get(p.id) ?? '' })))
  }

  if (req.method === 'POST') {
    const body = await req.json()
    const { email, password, username, full_name, role, link_driver_id } = body
    if (!email || !password || !role) return json({ error: 'email, password and role are required' }, 422)
    if (!VALID_ROLES.has(String(role))) return json({ error: 'Invalid role' }, 422)
    if (String(password).length < 8) return json({ error: 'Password must be at least 8 characters' }, 422)
    if (link_driver_id != null && role !== 'driver') {
      return json({ error: 'link_driver_id requires role=driver' }, 422)
    }

    if (link_driver_id != null) {
      const { data: drv, error: dErr } = await admin
        .from('drivers')
        .select('id, user_id')
        .eq('id', link_driver_id)
        .maybeSingle()
      if (dErr) return json({ error: dErr.message }, 400)
      if (!drv) return json({ error: 'Driver not found' }, 404)
      if (drv.user_id) return json({ error: 'Driver already linked to a login' }, 409)
    }

    // The profile trigger never grants 'admin' from metadata (defense against
    // signup ever being enabled) — admins are created as dispatcher and
    // promoted explicitly below with the service role.
    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { username: username || email.split('@')[0], full_name: full_name ?? '', role },
    })
    if (error) return json({ error: error.message }, 400)

    if (role === 'admin' && data.user) {
      const { error: promoteErr } = await admin
        .from('profiles')
        .update({ role: 'admin' })
        .eq('id', data.user.id)
      if (promoteErr) {
        await admin.auth.admin.deleteUser(data.user.id).catch(() => {})
        return json({ error: `User created but admin promotion failed: ${promoteErr.message}` }, 400)
      }
    }

    if (link_driver_id != null && data.user) {
      const { error: linkErr } = await admin
        .from('drivers')
        .update({ user_id: data.user.id })
        .eq('id', link_driver_id)
      if (linkErr) {
        await admin.auth.admin.deleteUser(data.user.id).catch(() => {})
        return json({ error: `User created but driver link failed: ${linkErr.message}` }, 400)
      }
    }

    return json({ id: data.user.id }, 201)
  }

  if (req.method === 'PATCH') {
    const { id, full_name, password, role, is_active } = await req.json()
    if (!id) return json({ error: 'id is required' }, 422)

    if (role !== undefined && !VALID_ROLES.has(String(role))) {
      return json({ error: 'Invalid role' }, 422)
    }

    if (role !== undefined || is_active === false) {
      const { data: target } = await admin.from('profiles').select('role, is_active').eq('id', id).maybeSingle()
      if (target?.role === 'admin' && target.is_active) {
        const demoting = role !== undefined && role !== 'admin'
        const deactivating = is_active === false
        if (demoting || deactivating) {
          const { count } = await admin
            .from('profiles')
            .select('id', { count: 'exact', head: true })
            .eq('role', 'admin')
            .eq('is_active', true)
          if ((count ?? 0) <= 1) {
            return json({ error: 'Cannot demote or deactivate the last remaining admin' }, 400)
          }
        }
      }
    }

    if (id === caller.userId && is_active === false) {
      return json({ error: 'Cannot deactivate your own account' }, 400)
    }

    if (password) {
      if (String(password).length < 8) return json({ error: 'Password must be at least 8 characters' }, 422)
      const { error } = await admin.auth.admin.updateUserById(id, { password })
      if (error) return json({ error: error.message }, 400)
    }
    if (is_active !== undefined) {
      const { error } = await admin.auth.admin.updateUserById(id, {
        ban_duration: is_active ? 'none' : '876000h',
      })
      if (error) return json({ error: error.message }, 400)
      if (!is_active) await admin.auth.admin.signOut(id, 'global').catch(() => {})
    }

    const updates: Record<string, unknown> = {}
    if (full_name !== undefined) updates.full_name = full_name
    if (role !== undefined) updates.role = role
    if (is_active !== undefined) updates.is_active = is_active
    if (Object.keys(updates).length > 0) {
      const { error } = await admin.from('profiles').update(updates).eq('id', id)
      if (error) return json({ error: error.message }, 400)
    }
    return json({ ok: true })
  }

  return json({ error: 'Method not allowed' }, 405)
})
