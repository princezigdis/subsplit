-- =====================================================================
--  SplitSub security + money tests. Runs against a database built from
--  database/*.sql plus tests/supabase_stub.sql. Every check acts as a
--  real signed-in user (role "authenticated" + their user id).
--  Output: one PASS/FAIL line per check.
-- =====================================================================
\set ON_ERROR_STOP 0
\set A '00000000-0000-0000-0000-00000000000a'
\set H '00000000-0000-0000-0000-00000000000b'
\set H2 '00000000-0000-0000-0000-00000000000c'
\set B '00000000-0000-0000-0000-00000000000d'
\set C '00000000-0000-0000-0000-00000000000e'
\set N '00000000-0000-0000-0000-0000000000a1'
\set N2 '00000000-0000-0000-0000-0000000000a2'
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
create or replace function t.code(p_name text, p_sql text, p_code text) returns void language plpgsql as $$
begin
  begin execute p_sql; insert into t.results (name, ok, detail) values (p_name, false, 'NO ERROR');
  exception when others then insert into t.results (name, ok, detail) values (p_name, sqlstate = p_code, sqlstate || ': ' || sqlerrm); end;
end $$;
create or replace function t.ok(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into t.results (name, ok, detail) values (p_name, coalesce(p_cond, false), p_detail) $$;
create or replace function t.v(k text) returns text language sql as $$ select v from t.vars where t.vars.k = $1 $$;
create or replace function t.setv(k text, v text) returns void language sql as $$
  insert into t.vars values ($1, $2) on conflict (k) do update set v = excluded.v $$;
create or replace function t.bal(p_owner uuid, p_kind text) returns bigint language sql security definer set search_path = public as $$
  select coalesce((select balance_kobo from wallet_accounts where owner_id is not distinct from p_owner and kind = p_kind), 0) $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------- setup (as the database owner, like the SQL Editor) ----------
insert into auth.users (id, email, raw_user_meta_data) values
 (:'A', 'owner@subsplit.test', '{"full_name":"Owner Admin"}'), (:'H', 'host@subsplit.test', '{"full_name":"Hannah Host"}'),
 (:'H2', 'host2@subsplit.test', '{"full_name":"Henry Host"}'), (:'B', 'buyer@subsplit.test', '{"full_name":"Bola Buyer"}'),
 (:'C', 'buyer2@subsplit.test', '{"full_name":"Chi Buyer"}'), (:'E', 'eve@subsplit.test', '{"full_name":"Eve Hacker"}')
on conflict do nothing;
select t.ok('New sign-ups are never admins', (select count(*) = 0 from public.admin_users));
insert into public.admin_users (user_id) values (:'A');   -- 005_make_admin.sql
select t.setv('netflix', (select p.id::text from service_plans p join services s on s.id = p.service_id where s.name = 'Netflix'));
select t.setv('youtube', (select p.id::text from service_plans p join services s on s.id = p.service_id where s.name = 'YouTube Premium'));
select t.setv('chatgpt', (select p.id::text from service_plans p join services s on s.id = p.service_id where s.name = 'ChatGPT'));

-- Fund wallets the real way: payment created + verified by the server (service role).
set role service_role;
select payment_create(:'B', 'REF-B1', 'TOPUP', 2000000) is not null;
select payment_complete('REF-B1', 2000000, 'NGN', 'ps_1', 'card');
select payment_create(:'C', 'REF-C1', 'TOPUP', 500000);
select payment_complete('REF-C1', 500000, 'NGN', 'ps_2', 'card');
select payment_create(:'E', 'REF-E1', 'TOPUP', 100000);
select payment_complete('REF-E1', 100000, 'NGN', 'ps_3', 'card');
-- 13. Duplicate webhook / duplicate verify
select t.ok('13 Duplicate Paystack webhook does not credit twice', (payment_complete('REF-B1', 2000000, 'NGN', 'ps_1', 'card') ->> 'result') = 'ALREADY');
select t.ok('13b Wallet credited exactly once', t.bal(:'B', 'WALLET') = 2000000, t.bal(:'B', 'WALLET')::text);
select t.ok('Unknown reference is ignored', (payment_complete('NOPE', 999, 'NGN', 'x', 'card') ->> 'result') = 'UNKNOWN');
select t.ok('Non-naira payment is rejected', (payment_create(:'C', 'REF-USD', 'TOPUP', 500000) is not null)
  and (payment_complete('REF-USD', 500000, 'USD', 'x', 'card') ->> 'result') = 'FAILED' and t.bal(:'C', 'WALLET') = 500000);
reset role;

-- ---------- HOST creates listings ----------
set role authenticated; set "request.jwt.claim.sub" = :'H';
select t.err('5 Host cannot exceed platform seat limit (Netflix max 4)',
  format('select host_create_listing(%L, 20, 5, ''email: a / pass: b'')', t.v('netflix')), '%up to 4 seats%');
select t.err('6 Host cannot set markup above 30%',  format('select host_create_listing(%L, 31, 4, ''email: a / pass: b'')', t.v('netflix')), '%between 10% and 30%%');
select t.err('6b Host cannot set markup 100%',      format('select host_create_listing(%L, 100, 4, ''email: a / pass: b'')', t.v('netflix')), '%between%');
select t.err('6c Host cannot set markup below 10%', format('select host_create_listing(%L, 5, 4, ''email: a / pass: b'')', t.v('netflix')), '%between%');
select t.err('Host cannot list a service that is switched off (ChatGPT)', format('select host_create_listing(%L, 20, 2, ''x x x x x'')', t.v('chatgpt')), '%Pick a service plan%');
select t.setv('L1', (host_create_listing(t.v('netflix')::uuid, 30, 4, 'Email: host.netflix@x.com  Password: s3cret') ->> 'listing_id'));
select t.setv('L2', (host_create_listing(t.v('youtube')::uuid, 30, 1, 'I send invites within 2 hours') ->> 'listing_id'));
select t.err('Listing needs proof before review', format('select host_submit_listing(%L, '''', '''', true)', t.v('L1')), '%Upload proof%');
select t.err('Proof must be in the host''s own folder',
  format('insert into storage.objects (bucket_id, name) values (''host-proofs'', %L)', :'B' || '/x/proof.jpg'), '%row-level security%');
insert into storage.objects (bucket_id, name) values ('host-proofs', :'H' || '/' || t.v('L1') || '/proof.jpg'), ('host-proofs', :'H' || '/' || t.v('L2') || '/proof.jpg');
select t.err('Proof path from another listing is refused',
  format('select host_submit_listing(%L, %L, '''', true)', t.v('L1'), :'H' || '/' || t.v('L2') || '/proof.jpg'), '%does not belong%');
select t.ok('Submit with proof -> PENDING_REVIEW', (host_submit_listing(t.v('L1')::uuid, :'H' || '/' || t.v('L1') || '/proof.jpg', 'Receipt Oct', true) ->> 'status') = 'PENDING_REVIEW');
select host_submit_listing(t.v('L2')::uuid, :'H' || '/' || t.v('L2') || '/proof.jpg', '', true);
select t.ok('Pending listing is not on Explore', jsonb_array_length(explore_listings()) = 0);
-- 4. Host attempts to change the normal price / plan rules
select t.err('4 Host cannot change normal price (table)', format('update service_plans set normal_price_kobo = 100 where id = %L', t.v('netflix')), '%permission denied%');
select t.err('4b Host cannot change normal price (admin API)',
  format('select admin_save_plan(jsonb_build_object(''id'', %L, ''name'', ''Premium'', ''normal_price_kobo'', 100, ''max_seats'', 20, ''min_markup_pct'', 10, ''max_markup_pct'', 30, ''access_type'', ''LOGIN''))', t.v('netflix')), '%Access denied%');
select t.err('4c Host cannot edit own listing row directly (e.g. status/markup)', format('update listings set status = ''LIVE'', markup_pct = 90 where id = %L', t.v('L1')), '%permission denied%');

-- ---------- ADMIN approves ----------
set "request.jwt.claim.sub" = :'A';
select admin_review_listing(t.v('L1')::uuid, 'APPROVE', 'Receipt checked');
select admin_review_listing(t.v('L2')::uuid, 'APPROVE', '');
select t.ok('Approved listings appear on Explore', jsonb_array_length(explore_listings()) = 2);
select t.ok('Pricing: Netflix N8,500 +30% / 4 seats = N2,763 per seat', (listing_detail(t.v('L1')::uuid) ->> 'seat_kobo')::bigint = 276300,
  listing_detail(t.v('L1')::uuid) ->> 'seat_kobo');
select t.ok('Pricing: YouTube N3,600 +30% / 5 seats = N936, saves N2,664',
  (listing_detail(t.v('L2')::uuid) ->> 'seat_kobo')::bigint = 93600 and (listing_detail(t.v('L2')::uuid) ->> 'savings_kobo')::bigint = 266400);
select t.ok('Seats shown honestly: 0 of 1 occupied, 1 available',
  (listing_detail(t.v('L2')::uuid) ->> 'seats_available')::int = 1 and (listing_detail(t.v('L2')::uuid) ->> 'seats_total')::int = 1);
select t.ok('Explore never contains login details', explore_listings()::text not ilike '%s3cret%');

-- ---------- PAYMENT price cannot be faked ----------
reset role; set role service_role;
select t.ok('12 Seat payment amount comes from the backend, not the browser',
  (payment_create(:'C', 'REF-SEAT-FAKE', 'SEAT', 100, t.v('L1')::uuid, '') ->> 'amount_kobo')::bigint = 296300);   -- N2,763 seat + N200 fee
reset role;

-- ---------- BUYERS ----------
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Invite plans need an email', format('select join_with_wallet(%L, ''not-an-email'')', t.v('L2')), '%email%');
select t.ok('Buyer joins YouTube (wallet)', join_with_wallet(t.v('L2')::uuid, 'bola@gmail.com') ? 'membership_id');
select t.ok('Buyer wallet charged N936 + N200 fee', t.bal(:'B', 'WALLET') = 2000000 - 93600 - 20000, t.bal(:'B', 'WALLET')::text);
select t.err('8 Duplicate membership is blocked', format('select join_with_wallet(%L, ''bola@gmail.com'')', t.v('L2')), '%already have a seat%');
select t.err('8b Direct insert into memberships is blocked',
  format('insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, ends_at) values (%L, %L, %L, %L, 1, 0, 1, now())',
         t.v('L2'), t.v('youtube'), :'B', :'H'), '%permission denied%');
select join_with_wallet(t.v('L1')::uuid);
select t.ok('Paid member sees Netflix login', (get_access(t.v('L1')::uuid) ->> 'details') ilike '%s3cret%');
set "request.jwt.claim.sub" = :'C';
select t.err('7 Buying an already-filled seat is blocked', format('select join_with_wallet(%L, ''chi@gmail.com'')', t.v('L2')), '%full%');

-- ---------- EVE tries everything ----------
set "request.jwt.claim.sub" = :'E';
select t.err('Not enough money is blocked (no negative balance)', format('select join_with_wallet(%L)', t.v('L1')), '%Not enough money%');
select t.ok('Failed purchase left wallet untouched', t.bal(:'E', 'WALLET') = 100000);
select t.err('1/2 Normal user calls admin dashboard API', 'select admin_dashboard()', '%Access denied%');
select t.code('1/2b Admin API error code is 42501 (HTTP 403)', 'select admin_me()', '42501');
select t.err('2c Normal user reads all users via admin API', 'select admin_users()', '%Access denied%');
select t.err('2d Normal user approves withdrawals', format('select admin_withdrawal_action(%L, ''PAID'')', gen_random_uuid()), '%Access denied%');
select t.err('2e Normal user refunds a seat', format('select admin_refund(%L, null, ''please'')', gen_random_uuid()), '%Access denied%');
select t.err('2f Normal user changes commission/settings', 'select admin_save_settings(''{"site_name":"Hacked"}'')', '%Access denied%');
select t.err('2g Normal user reads audit logs', 'select admin_audit_logs()', '%Access denied%');
select t.err('2h Normal user reads admin ledger', 'select admin_ledger()', '%Access denied%');
select t.err('3 Normal user changes a service price via table', format('update service_plans set normal_price_kobo = 1 where id = %L', t.v('netflix')), '%permission denied%');
select t.err('3b Normal user changes seat limit via table', format('update service_plans set max_seats = 20 where id = %L', t.v('netflix')), '%permission denied%');
select t.ok('9 Cannot see another user''s wallet accounts', (select count(*) from wallet_accounts where owner_id <> :'E') = 0);
select t.ok('9b Cannot see another user''s ledger', (select count(*) from wallet_transactions where user_id <> :'E') = 0);
select t.ok('9c Cannot see other profiles', (select count(*) from profiles where id <> :'E') = 0);
select t.ok('9d Cannot see other people''s payments/withdrawals', (select count(*) from payments where user_id <> :'E') + (select count(*) from withdrawals) = 0);
select t.err('10 Cannot read another plan''s login via API', format('select get_access(%L)', t.v('L1')), '%Only members%');
select t.ok('10b Cannot read login details from the table', (select count(*) from listing_access) = 0);
select t.err('11 Cannot change wallet balance (table)', format('update wallet_accounts set balance_kobo = 99999999 where owner_id = %L', :'E'), '%permission denied%');
select t.err('11b Cannot insert ledger rows', format('insert into wallet_transactions (account_id, type, amount_kobo, balance_after_kobo, reference, account_kind) select id, ''TOP_UP'', 1, 1, ''x'', ''WALLET'' from wallet_accounts limit 1'), '%permission denied%');
select t.err('11c Cannot call the internal posting function', format('select _post(%L, ''WALLET'', ''TOP_UP'', 999999, ''free'', ''x'')', :'E'), '%permission denied%');
select t.err('12b Browser cannot mark a payment as successful', 'select payment_complete(''REF-E1'', 999999, ''NGN'', ''x'', ''card'')', '%permission denied%');
select t.err('12c Browser cannot create payments', format('select payment_create(%L, ''R'', ''TOPUP'', 100000)', :'E'), '%permission denied%');
select t.err('14 Cannot make self admin (table)', format('insert into admin_users (user_id) values (%L)', :'E'), '%permission denied%');
select t.err('14b Cannot make self admin (API)', format('select admin_update_user(%L, ''ACTIVE'', true, true)', :'E'), '%Access denied%');
select t.err('14c Cannot edit own profile row directly', format('update profiles set verified_host = true where id = %L', :'E'), '%permission denied%');
select t.ok('14d Eve is still not an admin', not is_admin());
select t.ok('Cannot see other people''s memberships', (select count(*) from memberships) = 0);
set "request.jwt.claim.sub" = :'H2';
select t.err('15 Host cannot manage another host''s listing', format('select host_update_listing(%L, 30, 4, ''hijack details'', '''')', t.v('L1')), '%your own listings%');
select t.err('15b Host cannot pause another host''s listing', format('select host_set_paused(%L, true)', t.v('L1')), '%your own listings%');
select t.err('15c Host cannot touch another host''s members',
  format('select host_mark_access_sent(%L)', (select id from memberships limit 1)), '%your own members%');
select t.ok('15d Other host sees none of the first host''s listings', jsonb_array_length(my_listings()) = 0);
reset role;

-- ---------- Anonymous visitor ----------
set role anon; set "request.jwt.claim.sub" = '';
select t.ok('Visitor can browse Explore', jsonb_array_length(explore_listings()) = 2);
select t.err('Visitor cannot call member APIs', 'select my_wallet()', '%permission denied%');
select t.err('Visitor cannot call admin APIs', 'select admin_dashboard()', '%permission denied%');
reset role;

-- ---------- Escrow, disputes, refunds, withdrawals ----------
set role authenticated; set "request.jwt.claim.sub" = :'H';
select t.ok('Host pending = 90% of seats (N842.40 + N2,486.70)', t.bal(:'H', 'PENDING') = 84240 + 248670, t.bal(:'H', 'PENDING')::text);
select t.err('Withdrawal above available earnings is blocked', 'select request_withdrawal(100000, ''GTBank'', ''0123456789'', ''Hannah Host'')', '%withdraw up to%');
reset role;
select t.ok('Escrow is NOT released before the 30 days are up', release_due_escrow() = 0);
update memberships set ends_at = now() - interval '1 minute', release_at = now() - interval '1 minute' where listing_id = t.v('L2')::uuid;    -- YouTube period + 30 days over
set role anon;
select t.ok('Cycle end releases money automatically', release_due_escrow() = 1);
reset role;
select t.ok('Host earnings = N842.40 after release', t.bal(:'H', 'EARNINGS') = 84240);
select t.ok('Platform earned 10% fee N93.60 + two N200 buyer fees', t.bal(null, 'PLATFORM') = 9360 + 40000);
select t.ok('Seat freed after period ends', (listing_detail(t.v('L2')::uuid) ->> 'seats_available')::int = 1);
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.ok('Buyer opens a dispute', open_dispute((select id from memberships where buyer_id = :'B' and status = 'ACTIVE' limit 1), 'NOT_WORKING', 'Password was changed today') ? 'dispute_id');
reset role;
update memberships set ends_at = now() - interval '1 minute' where status = 'DISPUTED';
select t.ok('Disputed money is NOT released at period end', release_due_escrow() = 0);
set role authenticated; set "request.jwt.claim.sub" = :'H';
select host_respond_dispute((select id from disputes limit 1), 'I fixed the password, please try again');
set "request.jwt.claim.sub" = :'A';
select admin_dispute_action((select id from disputes limit 1), 'PARTIAL_REFUND', 138200, 'Half refund: access down for 2 weeks');
select t.ok('Partial refund: buyer gets N1,382 back', t.bal(:'B', 'WALLET') = 2000000 - 93600 - 276300 - 40000 + 138200, t.bal(:'B', 'WALLET')::text);
select t.ok('Partial refund: host gets 90% of the rest (N1,242.90)', t.bal(:'H', 'EARNINGS') = 84240 + 124290, t.bal(:'H', 'EARNINGS')::text);
select t.err('Double refund is blocked', format('select admin_refund(%L, null, ''again'')', (select membership_id from disputes limit 1)), '%already settled%');
set "request.jwt.claim.sub" = :'H';
select t.err('Withdrawal below minimum is blocked', 'select request_withdrawal(50000, ''GTBank'', ''0123456789'', ''Hannah Host'')', '%smallest withdrawal%');
select request_withdrawal(150000, 'GTBank', '0123456789', 'Hannah Host');
select t.ok('Withdrawal holds the money (earnings drop)', t.bal(:'H', 'EARNINGS') = 84240 + 124290 - 150000);
set "request.jwt.claim.sub" = :'A';
select admin_withdrawal_action((select id from withdrawals limit 1), 'PAID', 'Sent via GTBank app');
select t.err('Double payout is blocked', format('select admin_withdrawal_action(%L, ''PAID'')', (select id from withdrawals limit 1)), '%already paid%');
select t.err('Cannot reject an already paid withdrawal', format('select admin_withdrawal_action(%L, ''REJECT'', ''oops'')', (select id from withdrawals limit 1)), '%already paid%');

-- ---------- Admin controls the rules ----------
select admin_save_plan(jsonb_build_object('id', t.v('netflix'), 'name', 'Premium', 'normal_price_kobo', 900000, 'max_seats', 3, 'access_type', 'LOGIN',
  'duration_days', 30, 'min_markup_pct', 10, 'max_markup_pct', 30, 'verification_required', true, 'host_proof_required', true, 'active', true));
select t.ok('Admin price change flows to listings (N9,000 +30% / 3 = N3,900)', (listing_detail(t.v('L1')::uuid) ->> 'seat_kobo')::bigint = 390000,
  listing_detail(t.v('L1')::uuid) ->> 'seat_kobo');
select t.ok('Admin seat cut clamps existing listing to 3', (select seats_offered from listings where id = t.v('L1')::uuid) = 3);
select t.ok('Price change is in the audit log with old and new values',
  exists (select 1 from admin_audit_logs where action = 'UPDATE_PLAN' and (old_data ->> 'normal_price_kobo')::bigint = 850000 and (new_data ->> 'normal_price_kobo')::bigint = 900000));
select t.err('Admin cannot set markup cap above 30%',
  format('select admin_save_plan(jsonb_build_object(''id'', %L, ''name'', ''Premium'', ''normal_price_kobo'', 900000, ''max_seats'', 3, ''access_type'', ''LOGIN'', ''duration_days'', 30, ''min_markup_pct'', 10, ''max_markup_pct'', 40, ''verification_required'', true, ''host_proof_required'', true, ''active'', true))', t.v('netflix')), '%between 10% and 30%%');
select t.ok('Commission is fixed at 10% (not a setting)', (admin_get_settings() ->> 'fee_bps')::int = 1000 and not (admin_get_settings() ? 'fee_percent'));
select t.err('Admin cannot remove own admin access', format('select admin_update_user(%L, ''ACTIVE'', false, false)', :'A'), '%your own admin%');
select t.ok('Ledger matches every balance', jsonb_array_length(admin_ledger_check()) = 0, admin_ledger_check()::text);
select t.ok('Admin dashboard loads for admin', (admin_dashboard() ->> 'ledger_ok')::boolean);
select t.ok('Dashboard platform fees = platform ledger balance', (admin_dashboard() ->> 'fees_kobo')::bigint = t.bal(null, 'PLATFORM') and t.bal(null, 'PLATFORM') > 0);
reset role;

-- ---------- v3: fees, ledger, chat, reports, receipts, proofs ----------
reset role;
select t.ok('V1 Ledger has rows', (select count(*) from wallet_transactions) > 0);
select t.err('V2 Ledger update is blocked', 'update wallet_transactions set amount_kobo = 1 where id = (select min(id) from wallet_transactions)', '%cannot be changed%');
select t.err('V3 Ledger delete is blocked', 'delete from wallet_transactions where id = (select min(id) from wallet_transactions)', '%cannot be changed%');
select t.ok('V4 Every order has a unique transaction ID', (select count(*) = count(distinct txn_ref) and bool_and(txn_ref is not null) from memberships));
select t.ok('V5 Every order has a 30-day release date', (select bool_and(release_at is not null) from memberships));
select t.ok('V6 Buyer fee N200 recorded on orders', (select bool_and(buyer_fee_kobo = 20000) from memberships));
select t.ok('V7 Minimum deposit is at least N100', (select min_topup_kobo >= 10000 from platform_settings));
select t.ok('V8 Minimum withdrawal is at least N1,000', (select min_withdrawal_kobo >= 100000 from platform_settings));
select t.err('V9 Settings cannot lower the minimum withdrawal', 'update platform_settings set min_withdrawal_kobo = 100 where id = 1', '%min_withdrawal_floor%');
set role service_role;
select t.err('V10 Deposit below N100 refused by backend', format('select payment_create(%L, ''REF-LOW'', ''TOPUP'', 5000)', :'E'), '%between%');
reset role;

set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.ok('V11 Buyer sees an order list', jsonb_array_length(my_orders()) >= 1);
select t.ok('V12 Overview shows available + pending split', (my_overview() -> 'balances') ? 'available_kobo' and (my_overview() -> 'balances') ? 'pending_kobo');
select t.ok('V13 Receipt total = price + fee', (my_receipt((select txn_ref from memberships where buyer_id = :'B' order by created_at limit 1)) ->> 'total_kobo')::bigint
    = (select amount_kobo + buyer_fee_kobo from memberships where buyer_id = :'B' order by created_at limit 1));
select t.ok('V14 Receipt shows the N200 fee', (my_receipt((select txn_ref from memberships where buyer_id = :'B' order by created_at limit 1)) ->> 'fee_kobo')::bigint = 20000);
select t.ok('V15 Buyer can read order chat', (order_chat((select id from memberships where buyer_id = :'B' order by created_at limit 1)) ->> 'role') = 'BUYER');
select t.ok('V16 Buyer can send a chat message', (order_send((select id from memberships where buyer_id = :'B' order by created_at limit 1), 'Hello host') ->> 'ok')::boolean);
select t.err('V17 Empty chat message refused', format('select order_send(%L, ''   '')', (select id from memberships where buyer_id = :'B' order by created_at limit 1)), '%Write a message%');
reset role;
select t.ok('V18 System message created with the order', exists (select 1 from order_messages where sender_role = 'SYSTEM'));
select t.setv('M1', (select id::text from memberships order by created_at limit 1));
set role authenticated; set "request.jwt.claim.sub" = :'E';
select t.err('V19 Stranger cannot read an order chat', format('select order_chat(%L)', t.v('M1')), '%not found%');
select t.err('V20 Stranger cannot send in an order chat', format('select order_send(%L, ''hi'')', t.v('M1')), '%not found%');
select t.err('V21 Stranger cannot open someone else''s receipt', format('select my_receipt(%L)', (select txn_ref from memberships where id = t.v('M1')::uuid)), '%not found%');
select t.err('V22 Stranger cannot report someone else''s order', format('select report_order(%L, ''OTHER'', ''I am not part of this order'')', t.v('M1')), '%that is yours%');
select t.err('V23 Stranger cannot complete someone else''s order', format('select complete_order(%L)', t.v('M1')), '%not found%');
set "request.jwt.claim.sub" = :'H';
select t.err('V24 Host cannot mark the buyer''s order completed', format('select complete_order(%L)', t.v('M1')), '%not found%');
select t.ok('V25 Host can read the order chat', (order_chat((select id from memberships where host_id = :'H' order by created_at limit 1)) ->> 'role') = 'HOST');
select t.ok('V26 Host sees the member contact in chat', (order_chat((select id from memberships where host_id = :'H' order by created_at limit 1)) -> 'order') ? 'contact');
set "request.jwt.claim.sub" = :'B';
select t.ok('V27 Buyer chat view hides contact field', not ((order_chat((select id from memberships where buyer_id = :'B' order by created_at limit 1)) -> 'order') ? 'contact'));
select t.err('V28 Withdrawal below N1,000 refused', 'select request_withdrawal(90000, ''GTBank'', ''0123456789'', ''Bola B'')', '%smallest withdrawal%');
reset role;

insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, buyer_fee_kobo, contact, starts_at, ends_at, access_status, txn_ref, release_at)
select l.id, l.plan_id, :'B', l.host_id, 100000, 10000, 90000, 20000, 'bola@x.com', now(), now() + interval '30 days', 'SENT', 'SUB-TESTA', now() + interval '30 days'
from listings l where l.host_id = :'H' limit 1;
insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, buyer_fee_kobo, contact, starts_at, ends_at, access_status, txn_ref, release_at)
select l.id, l.plan_id, :'E', l.host_id, 100000, 10000, 90000, 20000, 'eve@x.com', now(), now() + interval '30 days', 'WAITING', 'SUB-TESTB', now() + interval '30 days'
from listings l where l.host_id = :'H' limit 1;
set role authenticated; set "request.jwt.claim.sub" = :'B';
set "request.jwt.claim.sub" = :'E';
select t.err('V29 Cannot complete while access is not delivered', 'select complete_order((select id from memberships where txn_ref = ''SUB-TESTB''))', '%host has sent%');
set "request.jwt.claim.sub" = :'B';
select complete_order((select id from memberships where txn_ref = 'SUB-TESTA'));
select t.ok('V30 Buyer marks order completed', (select completed_at is not null from memberships where txn_ref = 'SUB-TESTA'));
select t.err('V31 Completing twice is refused', 'select complete_order((select id from memberships where txn_ref = ''SUB-TESTA''))', '%already completed%');
set "request.jwt.claim.sub" = :'E';
select t.err('V32 Report needs details', 'select report_order((select id from memberships where txn_ref = ''SUB-TESTB''), ''OTHER'', ''short'')', '%a little more%');
select t.err('V33 Report reason must be valid', 'select report_order((select id from memberships where txn_ref = ''SUB-TESTB''), ''BOGUS'', ''long enough details'')', '%what went wrong%');
select t.ok('V34 Buyer raises distress alarm', report_order((select id from memberships where txn_ref = 'SUB-TESTB'), 'HOST_NO_RESPONSE', 'Host has not replied for two days') ? 'dispute_id');
select t.ok('V35 Order is flagged DISPUTED', (select status = 'DISPUTED' from memberships where txn_ref = 'SUB-TESTB'));
select t.err('V36 Duplicate report is refused', 'select report_order((select id from memberships where txn_ref = ''SUB-TESTB''), ''OTHER'', ''second report on same order'')', '%already has an open report%');
reset role;
select t.ok('V37 Admins were alerted', exists (select 1 from notifications n join admin_users a on a.user_id = n.user_id where n.title like 'Distress alarm%'));
set role authenticated; set "request.jwt.claim.sub" = :'H';
select t.ok('V38 Host can also raise a report', report_order((select id from memberships where txn_ref = 'SUB-TESTA'), 'OTHER', 'The buyer shared the login with others') ? 'dispute_id');
reset role;
select t.ok('V39 Dispute records who raised it', exists (select 1 from disputes where raised_by_role = 'HOST'));
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('V40 Admin can read any order chat', (admin_order_chat((select id from memberships where txn_ref = 'SUB-TESTB')) ->> 'role') = 'ADMIN');
select admin_order_send((select id from memberships where txn_ref = 'SUB-TESTB'), 'We are looking into this.');
reset role;
select t.ok('V41 Admin message appears in the chat', exists (select 1 from order_messages where sender_role = 'ADMIN'));
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('V42 Admin can open any receipt', (admin_receipt('SUB-TESTA') ->> 'kind') = 'PURCHASE');
select t.ok('V43 Proof queue loads for admin', jsonb_typeof(admin_proofs('')) = 'array');
select t.ok('V44 Chat list loads for admin', jsonb_array_length(admin_order_chats('')) >= 1);
set role authenticated; set "request.jwt.claim.sub" = :'E';
select t.err('V45 Non-admin cannot read proofs', 'select admin_proofs('''')', '%Access denied%');
select t.err('V46 Non-admin cannot read admin chats', format('select admin_order_chat(%L)', t.v('M1')), '%Access denied%');
select t.err('V47 Non-admin cannot approve proofs', format('select admin_proof_action(%L, ''APPROVE'', '''')', gen_random_uuid()), '%Access denied%');
reset role;
set role anon;
select t.err('V48 Visitor cannot read email outbox', 'select * from email_outbox', '%permission denied%');
select t.err('V49 Visitor cannot read secrets', 'select * from internal_secrets', '%permission denied%');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('V50 Members cannot call email claim', 'select email_claim(5)', '%permission denied%');
select t.err('V51 Members cannot read the proofs table', 'select * from host_proofs', '%permission denied%');
reset role;
select t.ok('V52 No live listing without approved proof',
  (select count(*) from listings l join service_plans p on p.id = l.plan_id where l.status = 'LIVE' and p.host_proof_required
     and not exists (select 1 from host_proofs h where h.listing_id = l.id and h.status = 'APPROVED')) = 0);

-- ---------- v3b: referrals, promos, requests, credits, search, desk, users ----------
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'H2';
select t.setv('L3', (host_create_listing(t.v('youtube')::uuid, 20, 5, 'Invites sent within 2 hours') ->> 'listing_id'));
reset role;
insert into host_proofs (listing_id, host_id, service_name, file_path, status) values (t.v('L3')::uuid, :'H2', 'YouTube Premium', 'x/proof.jpg', 'APPROVED');
update listings set status = 'LIVE', agreement_accepted_at = now(), proof_status = 'APPROVED' where id = t.v('L3')::uuid;
insert into listings (host_id, plan_id, markup_pct, seats_offered, status)
  select :'H2', plan_id, 20, 2, 'DRAFT' from listings where id = t.v('L3')::uuid;
select t.err('R2 Draft cannot be pushed live without agreement',
  format('update listings set status = ''LIVE'' where id = (select id from listings where status = ''DRAFT'' and host_id = %L order by created_at desc limit 1)', :'H2'), '%proof%');

-- referral signup
select t.setv('BCODE', (select referral_code from profiles where id = :'B'));
insert into auth.users (id, email, raw_user_meta_data) values (:'N', 'newbie@subsplit.test', jsonb_build_object('full_name', 'Nia New', 'referral_code', t.v('BCODE')));
insert into auth.users (id, email, raw_user_meta_data) values (:'N2', 'badcode@subsplit.test', '{"full_name":"Bad Code","referral_code":"ZZZZZZZZ"}');
select t.ok('R3 Signup with a referral code links the referrer', (select referred_by = :'B' from profiles where id = :'N'));
select t.ok('R4 A bad referral code does not block signup', exists (select 1 from profiles where id = :'N2') and (select referred_by is null from profiles where id = :'N2'));
select t.ok('R5 Everyone gets a unique referral code', (select count(*) = count(distinct referral_code) and bool_and(referral_code is not null) from profiles));
set role service_role;
select payment_create(:'N', 'REF-N1', 'TOPUP', 2000000);
select payment_complete('REF-N1', 2000000, 'NGN', 'ps_n', 'card');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('R6 Promo needs a title', 'select admin_save_promo(''{"title":""}''::jsonb)', '%title%');
select t.err('R6b Promo end must be after start', 'select admin_save_promo(jsonb_build_object(''title'', ''Bad dates'', ''starts_at'', now() + interval ''2 days'', ''ends_at'', now()))', '%end date%');
select t.setv('PROMO', admin_save_promo(jsonb_build_object('title', 'Invite & earn', 'description', 'Invite a friend', 'terms', 'First purchase only',
  'reward_referrer_kobo', 50000, 'reward_referee_kobo', 30000, 'min_purchase_kobo', 50000, 'requires_referral', true, 'active', true))::text);
select t.ok('R7 Promo appears publicly while active', jsonb_array_length(public_promos()) = 1);
set "request.jwt.claim.sub" = :'N';
select t.ok('R8 Referred buyer joins', join_with_wallet(t.v('L3')::uuid, 'nia@gmail.com') ? 'membership_id');
reset role;
select t.ok('R9 Referrer rewarded once through the ledger', (select count(*) = 1 from wallet_transactions where user_id = :'B' and type = 'REFERRAL_REWARD' and amount_kobo = 50000));
select t.ok('R10 Referred user got the welcome bonus', (select count(*) = 1 from wallet_transactions where user_id = :'N' and type = 'REFERRAL_REWARD' and amount_kobo = 30000));
select t.ok('R11 Referral marked rewarded', (select status = 'REWARDED' from referrals where referred_id = :'N'));
select t.ok('R12 Reward audited', exists (select 1 from admin_audit_logs where action = 'REFERRAL_REWARD'));
update listings set seats_offered = 5 where id = t.v('L3')::uuid;
set role authenticated; set "request.jwt.claim.sub" = :'C';
select join_with_wallet(t.v('L3')::uuid, 'chi@gmail.com');
reset role;
select t.ok('R13 No reward without a referral (requires_referral promo)', (select count(*) = 1 from wallet_transactions where type = 'REFERRAL_REWARD' and user_id = :'C') = false);
select t.ok('R14 Ledger still balances after rewards and credits', (select count(*) = 0 from wallet_accounts a
  left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) x on x.account_id = a.id where a.balance_kobo <> coalesce(x.s, 0)));
set role authenticated; set "request.jwt.claim.sub" = :'E';
select t.err('R15 Non-admin cannot create promos', 'select admin_save_promo(''{"title":"Hack promo"}''::jsonb)', '%Access denied%');
select t.ok('R16 Member sees own referral code', (my_referrals() ->> 'code') is not null);

-- subscription requests
set "request.jwt.claim.sub" = :'C';
select t.err('Q1 Request needs a name', 'select suggest_subscription('' '')', '%Type the name%');
select t.err('Q2 Existing service is not requested again', 'select suggest_subscription(''Netflix'')', '%already on SplitSub%');
select t.ok('Q3 User can request a missing subscription', suggest_subscription('Disney Plus', 'Family plan') ? 'request_id');
select t.err('Q4 Duplicate request refused', 'select suggest_subscription(''disney plus'')', '%already asked%');
select t.ok('Q5 User sees own request status', (my_requests() -> 0 ->> 'status') = 'PENDING');
set "request.jwt.claim.sub" = :'E';
select t.ok('Q7 Other users cannot see it', jsonb_array_length(my_requests()) = 0);
select t.err('Q8 Non-admin cannot list requests', 'select admin_requests('''')', '%Access denied%');
set "request.jwt.claim.sub" = :'A';
select t.ok('Q9 Admin sees the request', jsonb_array_length(admin_requests('PENDING')) = 1);
reset role;
select t.setv('REQ1', (select id::text from subscription_requests limit 1));
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('Q10 Decline needs a reason', format('select admin_request_action(%L, ''DECLINE'', '''')', t.v('REQ1')), '%reason%');
reset role;
insert into services (name, category, description) values ('Disney Plus', 'Entertainment', 'Streaming');
select t.ok('Q11 Adding the service closes the request automatically', (select status = 'ADDED' from subscription_requests where lower(service_name) = 'disney plus'));
select t.ok('Q12 The user was notified', exists (select 1 from notifications where user_id = :'C' and type = 'REQUEST_ADDED'));
select t.ok('Q13 Email queued for the user', exists (select 1 from email_outbox where to_user = :'C' and type = 'REQUEST_ADDED'));

-- admin credits
set role authenticated; set "request.jwt.claim.sub" = :'E';
select t.err('K1 Non-admin cannot credit', format('select admin_credit_user(%L, 50000, ''free money'')', :'E'), '%Access denied%');
set "request.jwt.claim.sub" = :'A';
select t.err('K2 Credit needs a reason', format('select admin_credit_user(%L, 50000, '''')', :'C'), '%reason%');
select t.err('K3 Credit below N100 refused', format('select admin_credit_user(%L, 500, ''tiny'')', :'C'), '%between%');
select t.ok('K4 Single credit works', (admin_credit_user(:'C', 100000, 'Goodwill') ->> 'users')::int = 1);
select t.ok('K5 Batch credit works', (admin_credit_batch(array[:'C'::uuid, :'N'::uuid, :'C'::uuid], 20000, 'Promo thanks') ->> 'users')::int = 2);
select t.err('K6 Credit all needs confirmation', 'select admin_credit_all(10000, ''Free'', ''yes'')', '%CREDIT ALL%');
select t.ok('K7 Credit all works', (admin_credit_all(10000, 'Launch gift', 'CREDIT ALL') ->> 'users')::int >= 5);
reset role;
select t.ok('K8 Credits sit in the ledger with the admin recorded', (select count(*) > 0 from wallet_transactions where type = 'ADMIN_CREDIT' and created_by = :'A'));
select t.ok('K9 Credits are audited', (select count(*) = 3 from admin_audit_logs where action in ('CREDIT_USER','CREDIT_BATCH','CREDIT_ALL')));
select t.ok('K10 Ledger balances after credits', (select count(*) = 0 from wallet_accounts a
  left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) x on x.account_id = a.id where a.balance_kobo <> coalesce(x.s, 0)));

-- search, desk, users
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('S1 Search by order ID finds order, payment and ledger', (admin_txn_search((select txn_ref from memberships where buyer_id = :'N' limit 1)) ->> 'found')::boolean
  and jsonb_array_length(admin_txn_search((select txn_ref from memberships where buyer_id = :'N' limit 1)) -> 'ledger') >= 4);
select t.ok('S2 Search by payment reference works', (admin_txn_search('REF-N1') ->> 'kind') = 'PAYMENT');
select t.ok('S3 Unknown ID says not found', (admin_txn_search('NOPE-123') ->> 'found')::boolean = false);
select t.err('S4 Search needs an ID', 'select admin_txn_search(''x'')', '%Type a transaction ID%');
select t.ok('S5 Search includes receipt', (admin_txn_search((select txn_ref from memberships where buyer_id = :'N' limit 1)) -> 'receipt' ->> 'kind') = 'PURCHASE');
select t.ok('D1 Approval desk loads', admin_approval_desk() ? 'totals');
select t.ok('D2 Badges load', admin_badges() ? 'proofs');
select t.ok('U1 Full user view loads', (admin_user_full(:'N') -> 'profile' ->> 'username') is not null);
select t.err('U2 Cannot delete user with history', format('select admin_delete_user(%L, %L)', :'N', (select username from profiles where id = :'N')), '%history%');
select t.err('U3 Delete needs the username typed', format('select admin_delete_user(%L, ''wrong'')', :'N2'), '%Type the username%');
select admin_edit_user(:'N2', 'Bad Coder', '08011111111', 'fix');
select t.ok('U4 Admin can edit a profile (audited)', (select full_name = 'Bad Coder' from profiles where id = :'N2') and exists (select 1 from admin_audit_logs where action = 'EDIT_USER'));
set "request.jwt.claim.sub" = :'E';
select t.err('U6 Non-admin cannot see full user', format('select admin_user_full(%L)', :'N'), '%Access denied%');
select t.err('U7 Non-admin cannot search transactions', 'select admin_txn_search(''REF-N1'')', '%Access denied%');
select t.err('U8 Non-admin cannot see the approval desk', 'select admin_approval_desk()', '%Access denied%');
set "request.jwt.claim.sub" = :'A';
select t.err('W1 Bad WhatsApp link refused', 'select admin_save_settings(''{"support_whatsapp_link":"http://evil.example/x"}''::jsonb)', '%WhatsApp link%');
select admin_save_settings('{"support_whatsapp_link":"https://wa.me/2348012345678"}'::jsonb);
select t.ok('W2 WhatsApp link is public for the frontend', (public_catalog() -> 'settings' ->> 'support_whatsapp_link') = 'https://wa.me/2348012345678');
select t.ok('W3 Catalog exposes fees and escrow days', (public_catalog() -> 'settings' ->> 'buyer_fee_kobo')::bigint = 20000 and (public_catalog() -> 'settings' ->> 'escrow_days')::int = 30);
reset role;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a3', 'ghost@subsplit.test');
set role authenticated; set "request.jwt.claim.sub" = :'A';
select admin_delete_user('00000000-0000-0000-0000-0000000000a3', (select username from profiles where id = '00000000-0000-0000-0000-0000000000a3'));
select t.ok('U9 Account with no history can be deleted', not exists (select 1 from profiles where id = '00000000-0000-0000-0000-0000000000a3'));
reset role;

-- reminders: once to buyer and once to host
update memberships set ends_at = now() + interval '2 days' where buyer_id = :'N';
set role service_role;
select t.ok('M1 Reminders go to buyer and host', send_expiry_reminders() >= 2);
select t.ok('M2 Second run sends no duplicates', send_expiry_reminders() = 0);
reset role;
select t.ok('M3 Host got an expiry notice', exists (select 1 from notifications where user_id = :'H2' and type = 'EXPIRING_HOST'));

\echo
select case when ok then 'PASS' else 'FAIL' end as result, name, case when ok then '' else detail end as detail from t.results order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.results;
