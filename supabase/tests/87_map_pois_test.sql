-- Tablet day: POI cache — service-only writes, idempotent upsert, bbox reads.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

-- service path (auth.uid() null) writes
select is(public.upsert_map_pois('truck_stop',
  '[{"id": 101, "name": "Pilot Travel Center", "lat": 41.5, "lon": -87.6},
    {"id": 102, "name": "", "lat": 40.0, "lon": -83.0}]'::jsonb),
  2, 'service upsert loads both POIs');
select is(public.upsert_map_pois('truck_stop',
  '[{"id": 101, "name": "Pilot Travel Center #423", "lat": 41.5, "lon": -87.6}]'::jsonb),
  1, 'same osm id updates in place (monthly refresh is idempotent)');
select is((select name from public.map_pois where osm_id = 101),
  'Pilot Travel Center #423', 'refresh took the new name');

-- bbox read finds only what's inside the box
select is((select count(*)::int from public.pois_in_bbox(41.0, -88.0, 42.0, -87.0)),
  1, 'bbox query returns only POIs inside the box');

select * from finish();
rollback;
