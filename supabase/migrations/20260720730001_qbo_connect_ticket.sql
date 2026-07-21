-- GT-05 — the QBO connect flow put the admin's session JWT in a URL query
-- param (browser history, Referer, proxy logs). Replace with a one-time
-- connect ticket: minted over a proper Authorization header, stored hashed,
-- 2-minute expiry, cleared on first use. qbo_connection is service-only (RLS
-- with no policies), so the hash never reaches a client.
alter table public.qbo_connection
  add column if not exists connect_ticket_hash text,
  add column if not exists connect_ticket_expires timestamptz;
