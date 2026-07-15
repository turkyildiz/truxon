// Admin-only user management. Creating auth users requires the service
// role key, which must never reach the browser — so it lives here.
//
//   GET    → list users (profiles + email)
//   POST   {email, password, username?, full_name?, role}   → create user
//   PATCH  {id, full_name?, password?, role?, is_active?}   → update user

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsResponse, getCaller, json } from '../_shared/auth.ts'

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
    const { email, password, username, full_name, role } = await req.json()
    if (!email || !password || !role) return json({ error: 'email, password and role are required' }, 422)
    if (String(password).length < 8) return json({ error: 'Password must be at least 8 characters' }, 422)

    const { data, error } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { username: username || email.split('@')[0], full_name: full_name ?? '', role },
    })
    if (error) return json({ error: error.message }, 400)
    return json({ id: data.user.id }, 201)
  }

  if (req.method === 'PATCH') {
    const { id, full_name, password, role, is_active } = await req.json()
    if (!id) return json({ error: 'id is required' }, 422)

    if (password) {
      if (String(password).length < 8) return json({ error: 'Password must be at least 8 characters' }, 422)
      const { error } = await admin.auth.admin.updateUserById(id, { password })
      if (error) return json({ error: error.message }, 400)
    }
    if (is_active !== undefined) {
      // Disable sign-in for deactivated accounts (100-year ban) and revoke sessions.
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
