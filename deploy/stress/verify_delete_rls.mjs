import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'fs';

const env = readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8');
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim();
const anon = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim();

const supa = createClient(url, anon);
const out = { tables: {} };

// insert payloads per table, all marked [STRESS TEST]
const payloads = {
  customers: { company_name: '[STRESS TEST] del-rls', notes: '[STRESS TEST]', is_active: true },
  drivers:   { full_name: '[STRESS TEST] del-rls', status: 'inactive', notes: '[STRESS TEST]' },
  trucks:    { unit_number: 'ST-' + Date.now(), status: 'inactive', notes: '[STRESS TEST]' },
};

async function testTable(t, payload) {
  const r = { table: t };
  const { data: created, error: cErr } = await supa.from(t).insert(payload).select();
  if (cErr) { r.create_error = cErr.message; return r; }
  const id = created[0].id;
  r.createdId = id;

  // DELETE attempt with select() to see affected rows
  const { data: delData, error: delErr } = await supa.from(t).delete().eq('id', id).select();
  r.delete_error = delErr ? delErr.message : null;
  r.delete_returnedRows = delData ? delData.length : null;

  // re-select
  const { data: after } = await supa.from(t).select('id').eq('id', id);
  r.stillPresentAfterDelete = after && after.length > 0;

  // If it's still present (delete blocked), try to neutralize by leaving marked;
  // record whether cleanup possible
  return r;
}

async function main() {
  const { data: auth, error: authErr } = await supa.auth.signInWithPassword({
    email: 'turkyildiz@gmail.com', password: 'Towtruck505'
  });
  out.signIn = authErr ? { error: authErr.message } : { user: auth.user.id, role: auth.user.role };
  if (authErr) { console.log(JSON.stringify(out, null, 2)); return; }

  for (const [t, p] of Object.entries(payloads)) {
    out.tables[t] = await testTable(t, p);
  }
  console.log(JSON.stringify(out, null, 2));
}
main().catch(e => console.error('FATAL', e));
