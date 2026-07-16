import { createClient } from '@supabase/supabase-js';

const url = 'https://okoeeyxxvzypjiumraxq.supabase.co';
const anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E';

// UNauthenticated anon client — do NOT sign in.
const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });

// Deliberately non-existent ids so no production data can be touched.
const BOGUS_LOAD_ID = 2000000001;
const BOGUS_INVOICE_ID = 2000000002;

function classify(error) {
  if (!error) return 'NO_ERROR (call returned data)';
  const msg = (error.message || '') + ' ' + (error.details || '') + ' ' + (error.hint || '');
  const low = msg.toLowerCase();
  const authBlock = low.includes('not enough permission') ||
                    low.includes('permission denied') ||
                    low.includes('not authorized') ||
                    low.includes('unauthor') ||
                    error.code === '42501' ||
                    error.code === '401';
  return (authBlock ? 'AUTH_BLOCKED' : 'PASSED_AUTH_GATE (business validation)') +
         ' :: code=' + error.code + ' msg=' + JSON.stringify(error.message);
}

async function probe(name, args) {
  try {
    const { data, error } = await anon.rpc(name, args);
    console.log(`\n--- ${name} ---`);
    console.log('  verdict :', classify(error));
    if (!error) console.log('  DATA    :', JSON.stringify(data));
  } catch (e) {
    console.log(`\n--- ${name} --- THREW: ${e.message}`);
  }
}

console.log('=== Anon (unauthenticated) write-RPC authorization probe ===');
console.log('Using non-existent ids:', BOGUS_LOAD_ID, BOGUS_INVOICE_ID);

await probe('change_load_status', { p_load_id: BOGUS_LOAD_ID, p_status: 'billed' });
await probe('create_invoice',     { p_customer_id: 2000000003, p_load_ids: [] });
await probe('void_invoice',       { p_invoice_id: BOGUS_INVOICE_ID });
await probe('set_invoice_status', { p_invoice_id: BOGUS_INVOICE_ID, p_status: 'paid' });

console.log('\n=== done ===');
