import { createClient } from 'file:///tmp/claude-1000/-home-turkyildiz-TRUXON/0ef16e47-863f-4746-b8c3-46a88b10f23e/scratchpad/harness/node_modules/@supabase/supabase-js/dist/index.mjs';

const url = 'https://okoeeyxxvzypjiumraxq.supabase.co';
const anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9rb2VleXh4dnp5cGppdW1yYXhxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxMzc1MDAsImV4cCI6MjA5OTcxMzUwMH0.rNGfTvCQ0ggsCSc1DbbD_Tr_h3p_hoJn2q0_ev6AO3E';
const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });

const ds = await anon.rpc('dashboard_summary', {});
console.log('=== dashboard_summary expiring_licenses ===');
console.log(JSON.stringify(ds.data?.expiring_licenses, null, 2));
console.log('=== dashboard_summary active_drivers/available_trucks ===');
console.log('active_drivers:', JSON.stringify(ds.data?.active_drivers));
console.log('available_trucks:', JSON.stringify(ds.data?.available_trucks));
console.log('week_revenue:', ds.data?.week_revenue, 'status_counts:', JSON.stringify(ds.data?.status_counts));

const gs = await anon.rpc('global_search', { q: 'a' });
console.log('\n=== global_search full ===');
console.log('drivers:', JSON.stringify(gs.data?.drivers));
console.log('customers:', JSON.stringify(gs.data?.customers));
console.log('trucks:', JSON.stringify(gs.data?.trucks));
console.log('loads count:', gs.data?.loads?.length);

const wr = await anon.rpc('weekly_report', {});
console.log('\n=== weekly_report by_driver ===');
console.log(JSON.stringify(wr.data?.by_driver, null, 2));
console.log('totals:', JSON.stringify(wr.data?.totals), 'week:', wr.data?.week_start, '->', wr.data?.week_end);
