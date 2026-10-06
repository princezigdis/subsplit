-- =====================================================================
--  SUBSPLIT · 004_cron.sql  (run after the other files)
--  Background jobs:
--   * every 15 minutes: move finished seats' money from Pending to Available
--   * every morning 08:00 Lagos (07:00 UTC): "your seat ends soon" reminders
--  If "pg_cron" is missing: Supabase -> Integrations -> Cron (or Database ->
--  Extensions -> pg_cron) -> enable, then run this file again.
-- =====================================================================
create extension if not exists pg_cron;

select cron.schedule('subsplit-release-escrow', '*/15 * * * *', $$select public.release_due_escrow()$$);
select cron.schedule('subsplit-expiry-reminders', '0 7 * * *', $$select public.send_expiry_reminders()$$);
