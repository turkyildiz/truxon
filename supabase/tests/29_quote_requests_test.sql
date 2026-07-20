-- Quote requests: the City+State-or-Zip rule lives in the table itself.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

-- zip alone is enough (both ends)
insert into public.quote_requests (contact_name, email, origin_zip, dest_zip)
  values ('Zip Only', 'z@t.co', '60601', '64101');
select is((select count(*)::int from public.quote_requests where contact_name = 'Zip Only'), 1, 'zip-only accepted');

-- city+state alone is enough
insert into public.quote_requests (contact_name, phone, origin_city, origin_state, dest_city, dest_state)
  values ('City State', '555', 'Chicago', 'IL', 'Kansas City', 'MO');
select is((select count(*)::int from public.quote_requests where contact_name = 'City State'), 1, 'city+state accepted');

-- neither → rejected
select throws_like($$
  insert into public.quote_requests (contact_name, email, origin_city, dest_zip)
    values ('Bad Origin', 'b@t.co', 'Chicago', '64101')
$$, '%quote_origin_locatable%', 'city without state (no zip) rejected');

select throws_like($$
  insert into public.quote_requests (contact_name, email, origin_zip, dest_state)
    values ('Bad Dest', 'b@t.co', '60601', 'MO')
$$, '%quote_dest_locatable%', 'state without city (no zip) rejected');

-- unreachable requester → rejected
select throws_like($$
  insert into public.quote_requests (contact_name, origin_zip, dest_zip)
    values ('No Contact', '60601', '64101')
$$, '%quote_reachable%', 'no email and no phone rejected');

select * from finish();
rollback;
