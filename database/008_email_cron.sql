-- =====================================================================
--  SUBSPLIT · 008_email_cron.sql  (run after 007; needs pg_cron + pg_net)
--  Every 5 minutes the database asks the send-emails Edge Function to
--  send whatever is waiting in the email queue. The private token lives
--  in the internal_secrets table (no browser can read it).
--  If your project ref is different, change the URL below.
-- =====================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.unschedule(jobid) from cron.job where jobname = 'subsplit-send-emails';
select cron.schedule('subsplit-send-emails', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://merpfrmpxsvtxbkazgdy.supabase.co/functions/v1/send-emails',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (select value from public.internal_secrets where name = 'email_cron')),
    body := '{}'::jsonb)
$$);
