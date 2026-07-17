-- Watchdog playbooks: transient inbox failures get scheduled for automatic
-- retry. The watchdog marks the Graph message unread and flips the log row to
-- 'retry_pending'; the poller then reclaims that row instead of skipping it.

alter table public.trux_inbox_log drop constraint if exists trux_inbox_log_status_check;
alter table public.trux_inbox_log add constraint trux_inbox_log_status_check
  check (status in ('processing', 'processed', 'rejected', 'failed', 'retry_pending'));
alter table public.trux_inbox_log add column if not exists retries int not null default 0;
