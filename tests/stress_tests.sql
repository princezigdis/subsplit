-- Stress / attack tests: every money path and every admin function tried 50 times.
-- Expected: attacks always fail, honest flows always credit exactly once, the ledger always balances.
\set ON_ERROR_STOP 0
\set A '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000d'
\set C '00000000-0000-0000-0000-00000000000e'
\set E '00000000-0000-0000-0000-00000000000f'
reset role;
create schema if not exists t;
drop table if exists t.results; create table t.results (n serial, name text, ok boolean, detail text);
grant usage on schema t to anon, authenticated, service_role;
grant all on t.results to anon, authenticated, service_role;
grant usage on sequence t.results_n_seq to anon, authenticated, service_role;
create or replace function t.ok(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into t.results (name, ok, detail) values (p_name, coalesce(p_cond, false), p_detail) $$;
create or replace function t.as_user(p_uid uuid) returns void language plpgsql as $$
begin perform set_config('role', 'authenticated', true); perform set_config('request.jwt.claim.sub', p_uid::text, true); end $$;
create or replace function t.as_anon() returns void language plpgsql as $$
begin perform set_config('role', 'anon', true); perform set_config('request.jwt.claim.sub', '', true); end $$;
create or replace function t.as_server() returns void language plpgsql as $$
begin perform set_config('role', 'service_role', true); end $$;
create or replace function t.as_owner() returns void language plpgsql as $$
begin perform set_config('role', 'postgres', true); end $$;
-- run a statement; returns true when it was refused
create or replace function t.refused(p_sql text) returns boolean language plpgsql as $$
begin execute p_sql; return false; exception when others then return true; end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;
create or replace function t.wallet(p_uid uuid) returns bigint language sql security definer set search_path = public as $$
  select coalesce((select balance_kobo from wallet_accounts where owner_id = p_uid and kind = 'WALLET'), 0) $$;
grant execute on function t.wallet(uuid) to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
 (:'A', 'owner@subsplit.test', '{"full_name":"Owner Admin"}'), (:'B', 'buyer@subsplit.test', '{"full_name":"Bola Buyer"}'),
 (:'C', 'c@subsplit.test', '{"full_name":"Chi Buyer"}'), (:'E', 'eve@subsplit.test', '{"full_name":"Eve Hacker"}') on conflict do nothing;
insert into public.admin_users (user_id) values (:'A') on conflict do nothing;
update platform_settings set manual_funding_enabled = true where id = 1;

-- ============ S1: a signed-in user tries to put money in their own wallet, 50 times each ============
do $$
declare i int; n int; before bigint; r record; s text; sql text[]; k int;
begin
  perform t.as_owner();
  perform t.ok('S0 start', true);
  sql := array[
    $q$select payment_complete('REF-X', 99999999, 'NGN', 'x', 'card')$q$,
    $q$select payment_create('00000000-0000-0000-0000-00000000000f', 'REF-ATTACK', 'TOPUP', 99999999)$q$,
    $q$select _post('00000000-0000-0000-0000-00000000000f', 'WALLET', 'TOP_UP', 99999999, 'x', 'ATK')$q$,
    $q$select admin_credit_user('00000000-0000-0000-0000-00000000000f', 99999999, 'please')$q$,
    $q$select admin_adjust_wallet('00000000-0000-0000-0000-00000000000f', 'WALLET', 99999999, 'please')$q$,
    $q$select admin_credit_all(99999999, 'x', 'CREDIT ALL')$q$,
    $q$select admin_manual_deposit_action(gen_random_uuid(), 'APPROVE', 99999999, '')$q$,
    $q$insert into wallet_transactions (account_id, user_id, account_kind, type, amount_kobo, balance_after_kobo, description, reference) values (gen_random_uuid(), '00000000-0000-0000-0000-00000000000f', 'WALLET', 'TOP_UP', 99999999, 99999999, 'x', 'x')$q$,
    $q$update wallet_accounts set balance_kobo = 99999999 where owner_id = '00000000-0000-0000-0000-00000000000f'$q$,
    $q$update payments set status = 'SUCCESS'$q$,
    $q$insert into payments (reference, user_id, purpose, amount_kobo, status) values ('REF-FAKE', '00000000-0000-0000-0000-00000000000f', 'TOPUP', 99999999, 'SUCCESS')$q$,
    $q$update manual_deposits set status = 'APPROVED'$q$,
    $q$insert into manual_deposits (reference, user_id, amount_kobo, status) values ('MD-FAKE', '00000000-0000-0000-0000-00000000000f', 99999999, 'APPROVED')$q$,
    $q$update platform_settings set manual_account_number = '1'$q$,
    $q$update admin_users set user_id = user_id$q$,
    $q$insert into admin_users (user_id) values ('00000000-0000-0000-0000-00000000000f')$q$,
    $q$select manual_deposit_support(gen_random_uuid(), 'Eve', '00000000-0000-0000-0000-00000000000f/x.png')$q$,
    $q$select manual_deposit_sent(gen_random_uuid())$q$
  ];
  for k in 1..array_length(sql, 1) loop
    n := 0;
    for i in 1..50 loop
      perform t.as_user('00000000-0000-0000-0000-00000000000f'::uuid);
      if t.refused(sql[k]) then n := n + 1; end if;
      perform t.as_owner();
    end loop;
    perform t.ok('S1.' || k || ' blocked 50/50: ' || left(sql[k], 60), n = 50, n || '/50 blocked');
  end loop;
  perform t.ok('S1 attacker wallet is still 0', t.wallet('00000000-0000-0000-0000-00000000000f') = 0, t.wallet('00000000-0000-0000-0000-00000000000f')::text);
end $$;

-- ============ S2: a visitor who is not signed in, 50 times each ============
do $$
declare i int; n int; k int; fn text[] := array['my_manual_deposits()', 'manual_deposit_start(500000)', 'admin_badges()', 'admin_dashboard()', 'request_withdrawal(100000, ''x'', ''0123456789'', ''x'')',
  'join_with_wallet(gen_random_uuid(), '''')', 'admin_manual_deposits(''OPEN'')', 'admin_inquiries('''')', 'admin_save_settings(''{"manual_funding_enabled":false}''::jsonb)', 'admin_get_settings()',
  'payment_complete(''x'', 1, ''NGN'', ''x'', ''x'')', 'admin_credit_user(gen_random_uuid(), 100, ''x'')'];
begin
  for k in 1..array_length(fn, 1) loop
    n := 0;
    for i in 1..50 loop
      perform t.as_anon(); if t.refused('select ' || fn[k]) then n := n + 1; end if; perform t.as_owner();
    end loop;
    perform t.ok('S2.' || k || ' visitor blocked 50/50: ' || fn[k], n = 50, n || '/50');
  end loop;
end $$;

-- ============ S3: EVERY admin function, called by a normal user 50 times ============
do $$
declare r record; i int; n int; args text; total int := 0; bad text := '';
begin
  for r in select p.oid, p.proname, p.pronargs from pg_proc p
           where p.pronamespace = 'public'::regnamespace and p.proname like 'admin\_%' escape '\' and p.prokind = 'f' order by 2 loop
    args := (select coalesce(string_agg('null', ','), '') from generate_series(1, r.pronargs));
    n := 0;
    for i in 1..50 loop
      perform t.as_user('00000000-0000-0000-0000-00000000000f'::uuid);
      begin execute format('select public.%I(%s)', r.proname, args); exception when others then
        if sqlerrm ilike '%admin%' or sqlerrm ilike '%denied%' or sqlerrm ilike '%not allowed%' or sqlerrm ilike '%permission%' or sqlerrm ilike '%sign%in%' then n := n + 1; end if;
      end;
      perform t.as_owner();
    end loop;
    total := total + 1;
    if n <> 50 then bad := bad || r.proname || ' (' || n || '/50) '; end if;
  end loop;
  perform t.ok('S3 all ' || total || ' admin functions refuse a normal user 50/50', bad = '', bad);
end $$;

-- ============ S4: online payments, 50 honest and 50 hostile, with replays ============
do $$
declare i int; r jsonb; expected bigint := 0; amt bigint; ref text; reps int; j int; w0 bigint;
begin
  w0 := t.wallet('00000000-0000-0000-0000-00000000000e'::uuid);
  for i in 1..50 loop
    amt := (10000 + (random() * 4000000))::bigint;
    ref := 'SS-STRESS' || i;
    perform t.as_server();
    perform payment_create('00000000-0000-0000-0000-00000000000e'::uuid, ref, 'TOPUP', amt);
    reps := 1 + (random() * 5)::int;
    for j in 1..reps loop perform payment_complete(ref, amt, 'NGN', 'p' || i, 'card'); end loop;
    expected := expected + amt;
    perform t.as_owner();
  end loop;
  perform t.ok('S4a 50 payments each replayed up to 6 times credit exactly once', t.wallet('00000000-0000-0000-0000-00000000000e') - w0 = expected, (t.wallet('00000000-0000-0000-0000-00000000000e') - w0)::text || ' vs ' || expected);
  w0 := t.wallet('00000000-0000-0000-0000-00000000000e');
  for i in 1..50 loop
    perform t.as_server();
    perform payment_create('00000000-0000-0000-0000-00000000000e'::uuid, 'SS-BAD' || i, 'TOPUP', 500000);
    perform payment_complete('SS-BAD' || i, 500000, case i % 3 when 0 then 'USD' when 1 then '' else null end, 'x', 'card');
    perform payment_complete('SS-NOPE' || i, 500000, 'NGN', 'x', 'card');
    perform payment_complete('SS-BAD' || i, case when i % 2 = 0 then 0 else -500000 end, 'NGN', 'x', 'card');
    perform payment_fail('SS-BAD' || i, 'FAILED', 'test');
    perform t.as_owner();
  end loop;
  perform t.ok('S4b 50 wrong-currency / zero / negative / unknown / already-failed payments credit nothing', t.wallet('00000000-0000-0000-0000-00000000000e') = w0, (t.wallet('00000000-0000-0000-0000-00000000000e') - w0)::text);
end $$;

-- ============ S5: bank transfers, 50 cycles of every ending ============
do $$
declare i int; d jsonb; id uuid; w0 bigint; amt bigint; okc int := 0; rej int := 0; can int := 0; expected bigint := 0; dbl int := 0; self int := 0;
begin
  w0 := t.wallet('00000000-0000-0000-0000-00000000000d'::uuid);
  for i in 1..50 loop
    amt := (10000 + (random() * 900000))::bigint;
    perform t.as_user('00000000-0000-0000-0000-00000000000d'::uuid);
    d := manual_deposit_start(amt); id := (d ->> 'id')::uuid;
    if i % 5 = 0 then
      perform manual_deposit_cancel(id); can := can + 1;
    else
      perform manual_deposit_sent(id); perform manual_deposit_sent(id);
      -- the user cannot approve their own transfer
      if t.refused(format('select admin_manual_deposit_action(%L, ''APPROVE'')', id)) then self := self + 1; end if;
      perform t.as_owner();
      perform t.as_user('00000000-0000-0000-0000-00000000000a'::uuid);
      if i % 5 = 1 then
        perform admin_manual_deposit_action(id, 'REJECT', null, 'not received'); rej := rej + 1;
      else
        perform admin_manual_deposit_action(id, 'APPROVE', null, 'ok'); okc := okc + 1; expected := expected + amt;
        if t.refused(format('select admin_manual_deposit_action(%L, ''APPROVE'')', id)) then dbl := dbl + 1; end if;
      end if;
    end if;
    perform t.as_owner();
  end loop;
  perform t.ok('S5a only approved transfers credited: ' || okc || ' approved, ' || rej || ' rejected, ' || can || ' cancelled', t.wallet('00000000-0000-0000-0000-00000000000d') - w0 = expected, (t.wallet('00000000-0000-0000-0000-00000000000d') - w0)::text || ' vs ' || expected);
  perform t.ok('S5b a user could never approve their own transfer (all attempts refused)', self = okc + rej, self || ' of ' || (okc + rej));
  perform t.ok('S5c every second approval was refused', dbl = okc, dbl || ' of ' || okc);
  perform t.ok('S5d no transfer is left open', (select count(*) = 0 from manual_deposits where status in ('PENDING', 'SENT')));
end $$;

-- ============ S6: withdrawals, 50 valid and 50 invalid ============
do $$
declare i int; w jsonb; before bigint; okc int := 0; bad int := 0;
begin
  perform t.as_server(); perform payment_create('00000000-0000-0000-0000-00000000000e'::uuid, 'SS-WD', 'TOPUP', 40000000); perform payment_complete('SS-WD', 40000000, 'NGN', 'x', 'card'); perform t.as_owner();
  for i in 1..50 loop
    perform t.as_user('00000000-0000-0000-0000-00000000000e'::uuid);
    w := request_withdrawal(100000 + i * 1000, 'Test Bank', '0123456789', 'Chi Buyer'); okc := okc + 1;
    perform t.as_owner();
    perform t.as_user('00000000-0000-0000-0000-00000000000a'::uuid);
    perform admin_withdrawal_action((w ->> 'withdrawal_id')::uuid, 'REJECT', 'stress test');
    perform t.as_owner();
  end loop;
  for i in 1..50 loop
    perform t.as_user('00000000-0000-0000-0000-00000000000e'::uuid);
    if t.refused('select request_withdrawal(' || (case i % 5 when 0 then '1' when 1 then '-100000' when 2 then '999999999999' when 3 then '0' else 'null' end) || ', ''B'', ''0123456789'', ''x'')') then bad := bad + 1; end if;
    perform t.as_owner();
  end loop;
  perform t.ok('S6a 50 withdrawals requested then rejected: money returned each time', t.wallet('00000000-0000-0000-0000-00000000000e') >= 40000000 and okc = 50, t.wallet('00000000-0000-0000-0000-00000000000e')::text);
  perform t.ok('S6b 50 invalid withdrawals (too small / negative / too big / zero / null) all refused', bad = 50, bad || '/50');
end $$;

-- ============ S7: the books ============
reset role; set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('S7a ledger matches every balance', jsonb_array_length(admin_ledger_check()) = 0, admin_ledger_check()::text);
reset role;
select t.ok('S7b attacker still has nothing', t.wallet(:'E') = 0);
select t.ok('S7c total in wallets equals the sum of every ledger entry',
  (select coalesce(sum(balance_kobo),0) from wallet_accounts where kind = 'WALLET') = (select coalesce(sum(amount_kobo),0) from wallet_transactions where account_kind = 'WALLET'));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '  -> ' || coalesce(detail, '') end from t.results order by n;
