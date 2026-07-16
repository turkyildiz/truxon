import { createClient } from '@supabase/supabase-js';

const URL = 'https://okoeeyxxvzypjiumraxq.supabase.co';
const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E';

const supa = createClient(URL, ANON);
const { data, error } = await supa.auth.signInWithPassword({ email: 'turkyildiz@gmail.com', password: 'Towtruck505' });
const out = {
  error: error ? { status: error.status, code: error.code } : null,
  hasSession: !!data?.session,
  userId: data?.user?.id || null,
  role: data?.user?.role || null,
  email: data?.user?.email || null,
  emailConfirmed: !!data?.user?.email_confirmed_at,
  appMeta: data?.user?.app_metadata || null,
};

// Read-only: try to read a table to confirm authenticated context works
if (data?.session) {
  const { data: rows, error: rerr } = await supa.from('loads').select('id').limit(1);
  out.loadsRead = rerr ? { code: rerr.code, message: rerr.message } : { rowsReturned: rows?.length ?? 0 };
}
await supa.auth.signOut();
console.log(JSON.stringify(out, null, 2));
