-- Speed test: 4,000 users, ~3,000 payments, 600 withdrawals, then time the busiest database calls.
-- Usage: psql -d <db built from database/*.sql> -f tests/perf.sql
\set ON_ERROR_STOP 1
\timing off
set role postgres;
insert into auth.users (id, email, raw_user_meta_data)
select gen_random_uuid(), 'perf' || g || '@x.test', jsonb_build_object('full_name', 'Perf User ' || g) from generate_series(1, 4000) g;
do $$ declare r record; n int := 0; begin
  set local role service_role;
  for r in select id from profiles where email like 'perf%' order by email limit 3000 loop
    n := n + 1;
    perform payment_create(r.id, 'PERF-' || n, 'TOPUP', 2000000);
    perform payment_complete('PERF-' || n, 2000000, 'NGN', 'ps_' || n, 'card');
  end loop;
end $$;
do $$ declare r record; begin
  for r in select id from profiles where email like 'perf%' order by email limit 600 loop
    perform set_config('request.jwt.claim.sub', r.id::text, true);
    set local role authenticated;
    perform request_withdrawal(500000 + (random() * 1000000)::bigint, 'GTBank', '0123456789', 'Perf User');
    reset role;
  end loop;
end $$;
analyze;
create temp table perf_out (what text, ms numeric);
grant all on perf_out to public;
do $$ declare t timestamptz; i int; uid uuid; adm uuid;
begin
  select id into adm from profiles order by created_at limit 1; insert into admin_users (user_id) values (adm) on conflict do nothing;
  select id into uid from profiles where email = 'perf10@x.test';
  perform set_config('request.jwt.claim.sub', adm::text, true);
  t := clock_timestamp(); for i in 1..50 loop perform public_catalog(); end loop;
  insert into perf_out values ('public_catalog (x50 avg)', extract(milliseconds from clock_timestamp() - t) / 50);
  t := clock_timestamp(); perform admin_users(''); insert into perf_out values ('admin_users (4,000 users)', extract(milliseconds from clock_timestamp() - t));
  t := clock_timestamp(); perform admin_users('perf10'); insert into perf_out values ('admin_users search', extract(milliseconds from clock_timestamp() - t));
  t := clock_timestamp(); perform admin_dashboard(); insert into perf_out values ('admin_dashboard', extract(milliseconds from clock_timestamp() - t));
  t := clock_timestamp(); perform admin_ledger_check(); insert into perf_out values ('admin_ledger_check', extract(milliseconds from clock_timestamp() - t));
  t := clock_timestamp(); perform admin_withdrawals(null); insert into perf_out values ('admin_withdrawals (600)', extract(milliseconds from clock_timestamp() - t));
  t := clock_timestamp(); perform admin_user_full(uid); insert into perf_out values ('admin_user_full', extract(milliseconds from clock_timestamp() - t));
  t := clock_timestamp(); perform admin_txn_search('PERF-77'); insert into perf_out values ('admin_txn_search', extract(milliseconds from clock_timestamp() - t));
  t := clock_timestamp(); perform admin_ledger(null); insert into perf_out values ('admin_ledger', extract(milliseconds from clock_timestamp() - t));
  perform set_config('request.jwt.claim.sub', uid::text, true);
  t := clock_timestamp(); for i in 1..50 loop perform my_wallet(); end loop; insert into perf_out values ('my_wallet (x50 avg)', extract(milliseconds from clock_timestamp() - t) / 50);
  t := clock_timestamp(); for i in 1..50 loop perform my_overview(); end loop; insert into perf_out values ('my_overview (x50 avg)', extract(milliseconds from clock_timestamp() - t) / 50);
  t := clock_timestamp(); for i in 1..50 loop perform explore_listings(); end loop; insert into perf_out values ('explore_listings (x50 avg)', extract(milliseconds from clock_timestamp() - t) / 50);
  t := clock_timestamp(); perform sum(_withdrawal_fee_for(a)) from generate_series(1, 200000) a; insert into perf_out values ('fee function x200,000', extract(milliseconds from clock_timestamp() - t));
end $$;
select what, round(ms, 2) as ms from perf_out;
