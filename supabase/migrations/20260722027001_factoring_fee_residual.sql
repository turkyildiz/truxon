-- Owner-reported: /invoices showed factored invoices as "past due" when the
-- only open balance is the factor's FEE sliver left on the books (Denim pays
-- net of fee; QBO keeps the fee as an open balance until written off). The
-- frontend now labels those "settled · fee $x". Here: capture that sliver as
-- factoring_fee METADATA where denim-sync couldn't (no fee obligations in the
-- payload), so factoring_overview totals the real cost of factoring. No
-- status/money changes — QuickBooks stays the book of record; the proper
-- close-out is a fee write-off in QBO (owner/accountant action).
update public.invoices i
   set factoring_fee = i.qbo_balance
 where i.factored_at is not null
   and i.source = 'qbo'
   and i.status = 'sent'
   and coalesce(i.factoring_fee, 0) = 0
   and i.qbo_balance > 0
   and i.qbo_balance <= least(0.15 * i.total, 500);
