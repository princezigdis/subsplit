-- =====================================================================
--  SPLITSUB · 018_renewals_cron.sql  (run after 017; needs pg_cron)
--  Every hour: ask hosts "Will you renew?", pause plans nobody confirmed,
--  and auto-renew seats from members' wallets.
-- =====================================================================
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname = 'subsplit-renewals';
select cron.schedule('subsplit-renewals', '7 * * * *', $$select public.process_renewals()$$);
