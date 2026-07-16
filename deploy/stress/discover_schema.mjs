import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'fs';

const env = readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8');
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim();
const anon = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim();

const supa = createClient(url, anon);

async function main() {
  await supa.auth.signInWithPassword({ email: 'turkyildiz@gmail.com', password: 'Towtruck505' });
  for (const t of ['customers', 'loads', 'drivers', 'trucks']) {
    const { data, error } = await supa.from(t).select('*').limit(1);
    console.log('===', t, '===');
    if (error) console.log('  ERROR:', error.message);
    else if (data.length) console.log('  cols:', Object.keys(data[0]).join(', '));
    else console.log('  (empty, no rows to infer)');
  }
}
main().catch(e => console.error(e));
