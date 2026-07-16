import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'fs';

const env = readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8');
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim();
const anonKey = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim();

// Fresh ANON client — never sign in.
const anon = createClient(url, anonKey);

const out = {};

// Confirm we truly are anon (no session)
const { data: sess } = await anon.auth.getSession();
out.session = sess.session; // expect null

// Decode JWT role from the anon key to confirm role=anon
try {
  const payload = JSON.parse(Buffer.from(anonKey.split('.')[1], 'base64').toString());
  out.jwt_role = payload.role;
} catch (e) { out.jwt_role = 'decode_err'; }

// 1) global_search
try {
  const { data, error } = await anon.rpc('global_search', { q: 'a' });
  out.global_search = error ? { error: error.message, code: error.code } : {
    ok: true,
    count: Array.isArray(data) ? data.length : (data ? 'obj' : 0),
    sample: data,
  };
} catch (e) { out.global_search = { throw: String(e) }; }

// 2) dashboard_summary
try {
  const { data, error } = await anon.rpc('dashboard_summary');
  out.dashboard_summary = error ? { error: error.message, code: error.code } : {
    ok: true, sample: data,
  };
} catch (e) { out.dashboard_summary = { throw: String(e) }; }

// 3) weekly_report
try {
  const { data, error } = await anon.rpc('weekly_report');
  out.weekly_report = error ? { error: error.message, code: error.code } : {
    ok: true,
    count: Array.isArray(data) ? data.length : 'obj',
    sample: data,
  };
} catch (e) { out.weekly_report = { throw: String(e) }; }

// 4) Direct table reads (should be 0 rows under RLS)
for (const t of ['customers', 'loads', 'drivers', 'profiles', 'invoices']) {
  try {
    const { data, error } = await anon.from(t).select('*').limit(5);
    out['table_' + t] = error ? { error: error.message, code: error.code } : { rows: data.length };
  } catch (e) { out['table_' + t] = { throw: String(e) }; }
}

console.log(JSON.stringify(out, null, 2));
