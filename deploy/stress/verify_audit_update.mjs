import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'fs';

const env = readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local','utf8');
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim();
const anon = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim();

const sb = createClient(url, anon);
const out = {};

async function main(){
  const { error: sErr } = await sb.auth.signInWithPassword({ email:'turkyildiz@gmail.com', password:'Towtruck505' });
  out.signIn = sErr ? ('FAIL '+sErr.message) : 'ok';
  if (sErr) { console.log(JSON.stringify(out,null,2)); return; }

  // pick a customer for FK
  const { data: cust } = await sb.from('customers').select('id').limit(1);
  out.customerFound = cust && cust.length ? cust[0].id : null;
  if (!out.customerFound) { console.log(JSON.stringify(out,null,2)); return; }

  // create a throwaway test load
  const ln = 'STRESSTEST-'+Date.now();
  const { data: ins, error: iErr } = await sb.from('loads')
    .insert({ load_number: ln, customer_id: cust[0].id, rate: 100, miles: 50, notes:'[STRESS TEST]' })
    .select('id').single();
  out.insert = iErr ? ('FAIL '+iErr.message) : ('ok id='+ins.id);
  if (iErr) { console.log(JSON.stringify(out,null,2)); return; }
  const id = ins.id;

  async function tryUpdate(label, patch){
    const { error } = await sb.from('loads').update(patch).eq('id', id);
    out[label] = error ? ('ERR: '+error.message) : 'ok';
  }

  // audited columns
  await tryUpdate('upd_rate',        { rate: 0 });
  await tryUpdate('upd_miles',       { miles: 0 });
  await tryUpdate('upd_pickup_addr', { pickup_address: 'X test' });
  await tryUpdate('upd_delivery_time',{ delivery_time: '2026-01-01T00:00:00Z' });
  await tryUpdate('upd_customer',    { customer_id: cust[0].id }); // same value -> not distinct, should be ok
  // un-audited columns
  await tryUpdate('upd_notes',       { notes: '[STRESS TEST] edit' });
  await tryUpdate('upd_special',     { special_terms: 'terms x' });
  await tryUpdate('upd_status',      { status: 'assigned' });

  // cleanup: delete throwaway load
  const { error: dErr } = await sb.from('loads').delete().eq('id', id);
  out.cleanupDelete = dErr ? ('FAIL '+dErr.message) : 'ok';

  // verify gone
  const { data: chk } = await sb.from('loads').select('id').eq('id', id);
  out.remainingRows = chk ? chk.length : 'unknown';

  console.log(JSON.stringify(out,null,2));
}
main().catch(e=>{ console.error('FATAL', e); });
