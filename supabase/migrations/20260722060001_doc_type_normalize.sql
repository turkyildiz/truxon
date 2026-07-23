-- R9 #101 (part 1): normalize legacy lowercase doc types from the early
-- import era to the canonical labels every checker uses. Idempotent one-shot;
-- 41 docs on prod (pod 33, ratecon 4, bol 2, invoice 1, registration 1).
update public.documents set doc_type = 'POD' where doc_type = 'pod';
update public.documents set doc_type = 'Rate Confirmation' where doc_type = 'ratecon';
update public.documents set doc_type = 'BOL' where doc_type = 'bol';
update public.documents set doc_type = 'Invoice' where doc_type = 'invoice';
update public.documents set doc_type = 'Registration' where doc_type = 'registration';
