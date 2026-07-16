import { createClient } from '@supabase/supabase-js';
import fs from 'fs';

const env = fs.readFileSync('/home/turkyildiz/TRUXON/frontend/.env.local', 'utf8');
const url = env.match(/VITE_SUPABASE_URL=(.*)/)[1].trim();
const anon = env.match(/VITE_SUPABASE_ANON_KEY=(.*)/)[1].trim();

const EMAIL = 'turkyildiz@gmail.com';
const PASS = 'Towtruck505.';

function newClient() {
  return createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function attempt(label, email, password) {
  const c = newClient();
  const t0 = Date.now();
  const { data, error } = await c.auth.signInWithPassword({ email, password });
  const dt = Date.now() - t0;
  const out = {
    label,
    ms: dt,
    ok: !!data?.session,
    status: error?.status ?? null,
    code: error?.code ?? null,
    msg: error?.message ?? null,
    userId: data?.user?.id ?? null,
    role: data?.user?.role ?? null,
  };
  console.log(JSON.stringify(out));
  if (data?.session) await c.auth.signOut();
  return out;
}

async function sleep(ms){ return new Promise(r=>setTimeout(r,ms)); }

(async () => {
  console.log('=== URL:', url);
  // Clean, low-concurrency, spaced attempts to avoid rate-limiting.
  const results = [];
  results.push(await attempt('correct#1', EMAIL, PASS));
  await sleep(4000);
  results.push(await attempt('wrong-pw', EMAIL, 'DefinitelyWrong999!'));
  await sleep(4000);
  results.push(await attempt('correct#2', EMAIL, PASS));
  await sleep(20000); // long cooldown to fully clear any rate-limit window
  results.push(await attempt('correct#3-after-cooldown', EMAIL, PASS));

  const anySuccess = results.some(r => r.ok);
  console.log('=== SUMMARY anySuccess=' + anySuccess);
  console.log(JSON.stringify(results, null, 2));
})();
