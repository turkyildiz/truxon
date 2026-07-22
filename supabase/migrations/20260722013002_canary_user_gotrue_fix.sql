-- INCIDENT FIX. The honeytoken canary user (20260722002003) was inserted into
-- auth.users via raw SQL, leaving GoTrue's token string columns NULL. GoTrue's
-- Go scanner cannot read NULL into string, so GET /auth/v1/admin/users started
-- returning 500 "Database error finding users" — which silently killed every
-- consumer of the admin user list, most visibly trux-sentinel's acting-admin
-- mint ("No active admin to run the sentinel as", every scan since 03:06Z).
-- pg_cron kept logging "succeeded" because it only records that the HTTP call
-- was queued. Findings froze at last_seen 03:06Z for ~20h.
--
-- The canary stays (its purpose is sound) — its row just becomes shaped like a
-- GoTrue-born user: empty strings, not NULLs, in the scanner-fragile columns.
update auth.users set
  confirmation_token         = coalesce(confirmation_token, ''),
  recovery_token             = coalesce(recovery_token, ''),
  email_change_token_new     = coalesce(email_change_token_new, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  email_change               = coalesce(email_change, ''),
  phone_change               = coalesce(phone_change, ''),
  phone_change_token         = coalesce(phone_change_token, ''),
  reauthentication_token     = coalesce(reauthentication_token, '')
where email = 'ap-archive@aidalogistics.com';
