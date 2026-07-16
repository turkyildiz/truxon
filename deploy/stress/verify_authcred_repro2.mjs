import { createClient } from '@supabase/supabase-js';

const URL = 'https://okoeeyxxvzypjiumraxq.supabase.co';
const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E';

const EMAIL = 'turkyildiz@gmail.com';
const PASS = 'Towtruck505.';

const out = {};

// 1. supabase-js signInWithPassword
try {
  const supa = createClient(URL, ANON);
  const t0 = Date.now();
  const { data, error } = await supa.auth.signInWithPassword({ email: EMAIL, password: PASS });
  out.js_signin = {
    ms: Date.now() - t0,
    error: error ? { status: error.status, code: error.code, message: error.message } : null,
    hasSession: !!data?.session,
    userId: data?.user?.id || null,
  };
} catch (e) {
  out.js_signin = { thrown: String(e) };
}

// 2. raw auth endpoint - correct password
async function rawLogin(pw, label) {
  const t0 = Date.now();
  const r = await fetch(`${URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: ANON, Authorization: `Bearer ${ANON}` },
    body: JSON.stringify({ email: EMAIL, password: pw }),
  });
  const ms = Date.now() - t0;
  const text = await r.text();
  const headers = {};
  for (const [k, v] of r.headers.entries()) {
    if (/rate|retry|limit|x-/i.test(k)) headers[k] = v;
  }
  return { label, ms, status: r.status, body: text.slice(0, 400), interestingHeaders: headers, hasAccessToken: text.includes('access_token') };
}

out.raw_correct = await rawLogin(PASS, 'correct-password');
out.raw_wrong = await rawLogin('WrongPassword999!', 'wrong-password');
out.raw_bytesIdentical = out.raw_correct.body === out.raw_wrong.body;

// 3. Try a couple password variants in case of transcription/trailing issues
const variants = ['Towtruck505', 'towtruck505.', 'Towtruck505. ', ' Towtruck505.', 'Towtruck505!'];
out.variants = [];
for (const v of variants) {
  const r = await rawLogin(v, JSON.stringify(v));
  out.variants.push({ pw: JSON.stringify(v), status: r.status, hasToken: r.hasAccessToken });
}

// 4. Check whether the user exists at all via OTP/magic behavior? Instead, check signup disabled or error shape.
// Probe: does the auth server respond to the health/settings endpoint (confirms email auth enabled)?
try {
  const r = await fetch(`${URL}/auth/v1/settings`, { headers: { apikey: ANON } });
  out.auth_settings = { status: r.status, body: (await r.text()).slice(0, 500) };
} catch (e) {
  out.auth_settings = { thrown: String(e) };
}

console.log(JSON.stringify(out, null, 2));
