-- Purge transient-negative geocode cache rows. The cache must only ever hold a
-- real result (coordinates) or a genuine ZERO_RESULTS; a row with null lat and
-- any other location_type came from a transient error (REQUEST_DENIED, quota)
-- and must be dropped so the address re-geocodes once the key/quota recovers.
delete from public.geocode_cache
 where lat is null and location_type <> 'ZERO_RESULTS';
