import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

const env = fs.readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8');
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim();
const anonKey = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim();

const anon = createClient(url, anonKey);

function summarize(data) {
  if (data == null) return 'null';
  if (Array.isArray(data)) return `array len=${data.length}`;
  if (typeof data === 'object') {
    const out = {};
    for (const k of Object.keys(data)) {
      const v = data[k];
      out[k] = Array.isArray(v) ? `array len=${v.length}` : typeof v;
    }
    return JSON.stringify(out);
  }
  return typeof data;
}

async function main() {
  console.log('=== ANON global_search probe ===');

  // 1. param name 'q'
  for (const paramName of ['q', 'query', 'search_term']) {
    const { data, error } = await anon.rpc('global_search', { [paramName]: 'a' });
    console.log(`\n-- param '${paramName}' -> ${error ? 'ERROR ' + error.code + ': ' + error.message : 'OK'}`);
    if (!error) {
      console.log('   shape:', summarize(data));
    }
  }

  // 2. Detailed dump of q='a'
  console.log('\n=== Detail dump for q="a" (anon) ===');
  const { data, error } = await anon.rpc('global_search', { q: 'a' });
  if (error) {
    console.log('ERROR:', JSON.stringify(error));
  } else {
    console.log('Full keys:', Array.isArray(data) ? 'ARRAY' : Object.keys(data || {}));
    const d = data || {};
    if (d.drivers) {
      console.log(`drivers: ${d.drivers.length} -> sample:`, d.drivers.slice(0, 5).map(x => x.name || x.full_name || JSON.stringify(x)));
      console.log('   driver[0] full row keys:', Object.keys(d.drivers[0] || {}));
      console.log('   driver[0] raw:', JSON.stringify(d.drivers[0]));
    }
    if (d.customers) {
      console.log(`customers: ${d.customers.length} -> sample:`, d.customers.slice(0, 5).map(x => x.name || x.company_name || JSON.stringify(x)));
      console.log('   customer[0] raw:', JSON.stringify(d.customers[0]));
    }
    if (d.loads) {
      console.log(`loads: ${d.loads.length} -> sample:`, d.loads.slice(0, 5).map(x => x.load_number || JSON.stringify(x)));
      console.log('   load[0] raw:', JSON.stringify(d.loads[0]));
    }
    if (Array.isArray(data)) {
      console.log('Array sample:', JSON.stringify(data.slice(0, 3)));
    }
  }

  // 3. Enumeration test - can we get different results by iterating?
  console.log('\n=== Enumeration test (anon) ===');
  const seen = { drivers: new Set(), customers: new Set(), loads: new Set() };
  for (const letter of 'abcdefghijklmnopqrstuvwxyz'.split('')) {
    const { data: d2, error: e2 } = await anon.rpc('global_search', { q: letter });
    if (e2) { console.log(`  '${letter}' error`); continue; }
    if (d2?.drivers) d2.drivers.forEach(x => seen.drivers.add(x.name || x.full_name || JSON.stringify(x)));
    if (d2?.customers) d2.customers.forEach(x => seen.customers.add(x.name || x.company_name || JSON.stringify(x)));
    if (d2?.loads) d2.loads.forEach(x => seen.loads.add(x.load_number || JSON.stringify(x)));
  }
  console.log(`Distinct drivers enumerated: ${seen.drivers.size}`);
  console.log('  ', [...seen.drivers].slice(0, 20));
  console.log(`Distinct customers enumerated: ${seen.customers.size}`);
  console.log('  ', [...seen.customers].slice(0, 20));
  console.log(`Distinct loads enumerated: ${seen.loads.size}`);

  // 4. Compare: does authenticated see the same? (control)
  console.log('\n=== AUTH control ===');
  const authClient = createClient(url, anonKey);
  const { error: signErr } = await authClient.auth.signInWithPassword({ email: 'turkyildiz@gmail.com', password: 'Towtruck505.' });
  if (signErr) {
    console.log('sign-in failed:', signErr.message);
  } else {
    const { data: ad, error: ae } = await authClient.rpc('global_search', { q: 'a' });
    console.log('auth global_search q=a:', ae ? 'ERROR ' + ae.message : summarize(ad));
    await authClient.auth.signOut();
  }
}

main().then(() => process.exit(0)).catch(e => { console.error('FATAL', e); process.exit(1); });
