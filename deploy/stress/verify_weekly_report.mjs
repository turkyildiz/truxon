import { createClient } from '@supabase/supabase-js';

const url = 'https://okoeeyxxvzypjiumraxq.supabase.co';
const anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E';

// UNAUTHENTICATED anon client
const anon = createClient(url, anonKey);

console.log('=== Test 1: anon rpc weekly_report (no args) ===');
let r = await anon.rpc('weekly_report');
console.log('error:', JSON.stringify(r.error));
console.log('data:', JSON.stringify(r.data, null, 2));

console.log('\n=== Test 2: anon rpc weekly_report with week_start arg ===');
r = await anon.rpc('weekly_report', { week_start: '2026-07-13' });
console.log('error:', JSON.stringify(r.error));
console.log('data:', JSON.stringify(r.data)?.slice(0, 2000));

console.log('\n=== Test 3: raw HTTP POST to /rest/v1/rpc/weekly_report as anon ===');
const resp = await fetch(`${url}/rest/v1/rpc/weekly_report`, {
  method: 'POST',
  headers: {
    'apikey': anonKey,
    'Authorization': `Bearer ${anonKey}`,
    'Content-Type': 'application/json',
  },
  body: JSON.stringify({}),
});
console.log('HTTP status:', resp.status);
const text = await resp.text();
console.log('body (first 3000 chars):', text.slice(0, 3000));
