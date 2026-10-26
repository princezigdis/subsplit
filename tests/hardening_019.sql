-- Tests for migration 019 (security hardening).
\set ON_ERROR_STOP 0
\set A '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000d'
\set E '00000000-0000-0000-0000-00000000000f'
reset role;
create schema if not exists t;
drop table if exists t.results; create table t.results (n serial, name text, ok boolean, detail text);
create table if not exists t.vars (k text primary key, v text);
grant usage on schema t to anon, authenticated, service_role;
grant all on t.results, t.vars to anon, authenticated, service_role;
grant usage on sequence t.results_n_seq to anon, authenticated, service_role;
create or replace function t.err(p_name text, p_sql text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; insert into t.results (name, ok, detail) values (p_name, false, 'NO ERROR (should have been blocked)');
  exception when others then insert into t.results (name, ok, detail) values (p_name, sqlerrm ilike p_like, sqlstate || ': ' || sqlerrm); end;
end $$;
create or replace function t.ok(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into t.results (name, ok, detail) values (p_name, coalesce(p_cond, false), p_detail) $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
 (:'A', 'owner@subsplit.test', '{"full_name":"Owner Admin"}'), (:'B', 'buyer@subsplit.test', '{"full_name":"Bola Buyer"}'),
 (:'E', 'eve@subsplit.test', '{"full_name":"Eve Hacker"}') on conflict do nothing;
insert into public.admin_users (user_id) values (:'A') on conflict do nothing;

-- 1. No direct table reads for anyone outside the server
select t.ok('No public table is readable by visitors (anon)',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','v','m','p') and has_table_privilege('anon', c.oid, 'select')));
select t.ok('No public table is readable by signed-in users directly',
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r','v','m','p') and has_table_privilege('authenticated', c.oid, 'select')));
set role anon;
select t.err('Visitor cannot read settings (admin email hidden)', 'select admin_notify_email from platform_settings', '%permission denied%');
select t.err('Visitor cannot read plan notes for hosts', 'select host_instructions from service_plans', '%permission denied%');
select t.ok('Visitor still gets the public catalog through the safe function', jsonb_typeof(public_catalog()) = 'object');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'E';
select t.err('Signed-in user cannot read wallets table', 'select * from wallet_transactions', '%permission denied%');
select t.err('Signed-in user cannot read listing access table', 'select * from listing_access', '%permission denied%');
select t.err('Signed-in user cannot read profiles table', 'select * from profiles', '%permission denied%');
select t.ok('Signed-in user still sees own wallet through the safe function', jsonb_typeof(my_wallet()) = 'object');
reset role;

-- 2. Things made later are locked by default
create function public.zz_new_fn() returns int language sql as 'select 1';
create table public.zz_new_tbl (id int);
select t.ok('A function added later is NOT callable by visitors', not has_function_privilege('anon', 'public.zz_new_fn()', 'execute'));
select t.ok('A function added later is NOT callable by users', not has_function_privilege('authenticated', 'public.zz_new_fn()', 'execute'));
select t.ok('A table added later is NOT readable by users', not has_table_privilege('authenticated', 'public.zz_new_tbl', 'select'));

-- 3. New bank account warning (a hacker sending money to their own bank stands out)
set role authenticated; set "request.jwt.claim.sub" = :'A';
select admin_credit_user(:'B', 2000000, 'test money for withdrawals');
set "request.jwt.claim.sub" = :'B';
select request_withdrawal(300000, 'GTBank', '0123456789', 'Bola Buyer');
set "request.jwt.claim.sub" = :'A';
select t.ok('First withdrawal to an account is flagged as new bank', (admin_withdrawals('PENDING') -> 0 ->> 'new_bank')::boolean);
select admin_withdrawal_action((admin_withdrawals('PENDING') -> 0 ->> 'id')::uuid, 'PAID', 'sent');
set "request.jwt.claim.sub" = :'B';
select request_withdrawal(300000, 'GTBank', '0123456789', 'Bola Buyer');
set "request.jwt.claim.sub" = :'A';
select t.ok('Second withdrawal to the same paid account is not flagged', not (admin_withdrawals('PENDING') -> 0 ->> 'new_bank')::boolean);
select admin_withdrawal_action((admin_withdrawals('PENDING') -> 0 ->> 'id')::uuid, 'PAID', 'sent');
set "request.jwt.claim.sub" = :'B';
select request_withdrawal(300000, 'Kuda', '9999999999', 'Someone Else');
set "request.jwt.claim.sub" = :'A';
select t.ok('Withdrawal to a different account is flagged again', (admin_withdrawals('PENDING') -> 0 ->> 'new_bank')::boolean);
set "request.jwt.claim.sub" = :'E';
select t.err('Non-admin cannot list withdrawals', 'select admin_withdrawals(null)', '%denied%');
reset role;

-- 4. Search logging cannot be flooded
set role anon; reset "request.jwt.claim.sub";
select log_search('term ' || g, 1) from generate_series(1, 300) g;
reset role;
select t.ok('Visitors can log at most 120 searches a minute', (select count(*) from search_log where user_id is null) = 120,
  (select count(*) from search_log where user_id is null)::text);
set role authenticated; set "request.jwt.claim.sub" = :'E';
select log_search('eve ' || g, 1) from generate_series(1, 100) g;
reset role;
select t.ok('A signed-in user can log at most 30 a minute', (select count(*) from search_log where user_id = :'E') = 30);
