import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'fs';

const env = readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8');
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim();
const anon = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim();

const supa = createClient(url, anon);
const out = { tables: {} };

async function testTable(t, payload) {
  const r = { table: t };
  const { data: created, error: cErr } = await supa.from(t).insert(payload).select();
  if (cErr) { r.create_error = cErr.message; return r; }
  const id = created[0].id;
  r.createdId = id;
  const { data: delData, error: delErr } = await supa.from(t).delete().eq('id', id).select();
  r.delete_error = delErr ? delErr.message : null;
  r.delete_returnedRows = delData ? delData.length : null;
  const { data: after } = await supa.from(t).select('id').eq('id', id);
  r.stillPresentAfterDelete = after && after.length > 0;
  return r;
}

async function main() {
  const { error: authErr } = await supa.auth.signInWithPassword({
    email: 'turkyildiz@gmail.com', password: 'Towtruck505'
  });
  if (authErr) { out.signIn = authErr.message; console.log(JSON.stringify(out, null, 2)); return; }

  out.tables.trucks = await testTable('trucks',
    { unit_number: 'ST-' + Date.now(), status: 'available', notes: '[STRESS TEST]' });

  // loads needs a customer_id; reuse the stuck test customer 206 if present, else any customer
  const { data: cust } = await supa.from('customers').select('id').limit(1);
  const cid = cust && cust.length ? cust[0].id : null;
  out.tables.loads = await testTable('loads', {
    load_number: 'STRESS-' + Date.now(),
    customer_id: cid,
    status: 'completed',
    notes: '[STRESS TEST]'
  });

  console.log(JSON.stringify(out, null, 2));
}
main().catch(e => console.error('FATAL', e));
