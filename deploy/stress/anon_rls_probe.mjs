import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

const url = 'https://okoeeyxxvzypjiumraxq.supabase.co';
const anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E';

// Explicitly ANON: create client, DO NOT sign in.
const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });

const tables = [
  'profiles', 'customers', 'drivers', 'trucks', 'trailers', 'loads',
  'load_stops', 'invoices', 'documents', 'drive_files', 'activity_log',
  'company_settings', 'maintenance_records', 'rate_limit_events'
];

const rpcs = [
  ['dashboard_summary', {}],
  ['global_search', { q: 'a' }],
  ['global_search', { query: 'a' }],
  ['global_search', { search_term: 'a' }],
  ['weekly_report', {}],
];

const results = { tables: {}, rpcs: {}, leaks: [] };

for (const t of tables) {
  try {
    // request exact count + up to 5 rows to see if data leaks
    const { data, error, count, status } = await anon
      .from(t)
      .select('*', { count: 'exact' })
      .limit(5);
    if (error) {
      results.tables[t] = { ok: false, status, code: error.code, message: error.message };
    } else {
      const rows = data ? data.length : 0;
      results.tables[t] = { ok: true, status, rowsReturned: rows, exactCount: count, sampleKeys: rows > 0 ? Object.keys(data[0]) : [] };
      if (rows > 0 || (count && count > 0)) {
        results.leaks.push({ table: t, rowsReturned: rows, exactCount: count });
      }
    }
  } catch (e) {
    results.tables[t] = { ok: false, thrown: String(e) };
  }
}

for (const [name, args] of rpcs) {
  const key = `${name}(${Object.keys(args).join(',') || 'no-args'})`;
  try {
    const { data, error, status } = await anon.rpc(name, args);
    if (error) {
      results.rpcs[key] = { ok: false, status, code: error.code, message: error.message };
    } else {
      let shape;
      if (Array.isArray(data)) shape = `array[${data.length}]`;
      else if (data && typeof data === 'object') shape = `object{${Object.keys(data).join(',')}}`;
      else shape = String(data);
      results.rpcs[key] = { ok: true, status, shape, sample: JSON.stringify(data).slice(0, 500) };
      // Determine if real data leaked
      const hasData = (Array.isArray(data) && data.length > 0) || (data && typeof data === 'object' && Object.keys(data).length > 0);
      if (hasData) results.leaks.push({ rpc: key, shape });
    }
  } catch (e) {
    results.rpcs[key] = { ok: false, thrown: String(e) };
  }
}

console.log(JSON.stringify(results, null, 2));
fs.writeFileSync('/home/turkyildiz/TRUXON/deploy/stress/anon_rls_report.json', JSON.stringify(results, null, 2));
