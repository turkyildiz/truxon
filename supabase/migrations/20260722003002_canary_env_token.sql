-- Canary env credential (counters JadePuffer stage 2: environment secret sweep).
-- A realistic-looking but useless secret is planted in the edge-function env as
-- `LEGACY_WORKER_KEY` (set via `supabase secrets set`, never in git). Nothing
-- reads it. An agentic attacker that harvests env vars will grab it alongside
-- the real secrets; the moment it's replayed to any Truxon cron door,
-- requireCron's honeytoken check (shared auth) recognizes it → critical alarm.
-- Only the sha256 is stored here; the plaintext lives solely in the edge env.
insert into app_private.honeytokens (token_hash, label) values
  ('62b0996b5f13e29adbc48f33b116b6f00e72a2ad63ca4d8ccf897251da9d2d54', 'canary edge env LEGACY_WORKER_KEY')
on conflict (token_hash) do nothing;
