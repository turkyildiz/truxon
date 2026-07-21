-- R12 #11 — perf pass. Prod timings today: every heavy report RPC lands in
-- 0.12–0.38s, so no code changes. These are the growth-path indexes for the
-- filters every report leans on as loads/invoices/ELD data accumulate.
create index if not exists loads_delivery_time_idx
  on public.loads (delivery_time)
  where status in ('completed', 'billed');

create index if not exists invoices_customer_status_idx
  on public.invoices (customer_id, status);

create index if not exists invoice_payments_invoice_idx
  on public.invoice_payments (invoice_id);
