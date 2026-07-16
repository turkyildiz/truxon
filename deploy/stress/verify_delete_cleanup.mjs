import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'fs';

const env = readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8');
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim();
const anon = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim();
const supa = createClient(url, anon);

const targets = {
  loads: [994],
  customers: [206],
  drivers: [29],
  trucks: [14],
};

async function main() {
  await supa.auth.signInWithPassword({ email: 'turkyildiz@gmail.com', password: 'Towtruck505' });
  const out = {};
  // delete loads first (FK), then others
  for (const t of ['loads', 'customers', 'drivers', 'trucks']) {
    out[t] = [];
    for (const id of targets[t]) {
      const { data, error } = await supa.from(t).delete().eq('id', id).select();
      const { data: after } = await supa.from(t).select('id').eq('id', id);
      out[t].push({ id, deletedRows: data ? data.length : null, error: error ? error.message : null, stillPresent: after && after.length > 0 });
    }
  }
  console.log(JSON.stringify(out, null, 2));
}
main().catch(e => console.error('FATAL', e));
