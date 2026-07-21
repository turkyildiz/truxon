-- ONE-APP RADIO — push-to-talk over Supabase Realtime broadcast, replacing
-- the Mumla + Tailscale side apps on the tablets. Voice frames (Opus) ride
-- the already-authenticated Realtime socket on the private topic
-- 'radio:fleet'; dispatch joins from the web app. These policies are the
-- door: only active Truxon logins can join or speak (my_role() raises for
-- deactivated accounts, so a fired driver's radio dies with their login).
create policy radio_fleet_read on realtime.messages
  for select to authenticated
  using (
    realtime.topic() = 'radio:fleet'
    and public.my_role() in ('admin', 'dispatcher', 'accountant', 'driver', 'maintenance')
  );

create policy radio_fleet_write on realtime.messages
  for insert to authenticated
  with check (
    realtime.topic() = 'radio:fleet'
    and public.my_role() in ('admin', 'dispatcher', 'accountant', 'driver', 'maintenance')
  );
