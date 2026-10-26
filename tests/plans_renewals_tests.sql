-- Tests for migration 017: card switch, plan lengths + start date, renewals + auto-renew,
-- host "will you renew", moving members, creators & payouts, bulk messages.
\set ON_ERROR_STOP 0
\set A '00000000-0000-0000-0000-00000000000a'
\set H '00000000-0000-0000-0000-00000000000b'
\set G '00000000-0000-0000-0000-00000000000c'
\set B '00000000-0000-0000-0000-00000000000d'
\set C '00000000-0000-0000-0000-00000000000e'
\set K '00000000-0000-0000-0000-00000000000f'
\set R '00000000-0000-0000-0000-000000000010'
\set R2 '00000000-0000-0000-0000-000000000011'
\set D '00000000-0000-0000-0000-000000000012'
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
create or replace function t.v(k text) returns text language sql as $$ select v from t.vars where t.vars.k = $1 $$;
create or replace function t.setv(k text, v text) returns void language sql as $$
  insert into t.vars values ($1, $2) on conflict (k) do update set v = excluded.v $$;
grant execute on all functions in schema t to anon, authenticated, service_role;
-- a live listing, created directly (proof approved, agreement accepted)
create or replace function t.mk_listing(p_host uuid, p_service text, p_markup int, p_seats int) returns uuid language plpgsql as $$
declare v_id uuid; v_plan uuid;
begin
  select p.id into v_plan from service_plans p join services s on s.id = p.service_id where s.name = p_service limit 1;
  insert into listings (host_id, plan_id, markup_pct, seats_offered, status, agreement_accepted_at, agreement_text, proof_status)
  values (p_host, v_plan, p_markup, p_seats, 'DRAFT', now(), _agreement_text(), 'APPROVED') returning id into v_id;
  insert into listing_access (listing_id, details) values (v_id, 'Email: fam@test.ng Password: x');
  insert into host_proofs (listing_id, host_id, service_name, file_path, status) values (v_id, p_host, p_service, 'x', 'APPROVED');
  update listings set status = 'LIVE' where id = v_id;
  return v_id;
end $$;
create or replace function t.fund(p_user uuid, p_kobo bigint) returns void language sql as $$
  select _post(p_user, 'WALLET', 'TOP_UP', p_kobo, 'test money', _ref('TST')) $$;
create or replace function t.ledger_ok() returns boolean language sql as $$
  select not exists (select 1 from wallet_accounts a left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) x
                     on x.account_id = a.id where a.balance_kobo <> coalesce(x.s, 0)) $$;
create or replace function t.notes(p_user uuid, p_type text) returns int language sql as $$
  select count(*)::int from notifications where user_id = p_user and type = p_type $$;

insert into auth.users (id, email, raw_user_meta_data) values
 (:'A', 'owner@subsplit.test', '{"full_name":"Owner Admin","phone":"08030000001"}'), (:'H', 'host@subsplit.test', '{"full_name":"Hannah Host"}'),
 (:'G', 'host2@subsplit.test', '{"full_name":"Gbenga Host"}'),
 (:'B', 'buyer@subsplit.test', '{"full_name":"Bola Buyer","phone":"08031234567"}'), (:'C', 'chidi@subsplit.test', '{"full_name":"Chidi Buyer"}'),
 (:'K', 'creator@subsplit.test', '{"full_name":"Kemi Creator"}'), (:'D', 'dayo@subsplit.test', '{"full_name":"Dayo Mover"}') on conflict do nothing;
update services set active = true where name = 'Canva';
update service_plans set active = true where service_id = (select id from services where name = 'Canva');
insert into public.admin_users (user_id) values (:'A') on conflict do nothing;
update profiles set username = 'kemi' where id = :'K';
update profiles set username = 'bola' where id = :'B';

select t.setv('L1', t.mk_listing(:'H', 'Netflix', 20, 4)::text);      -- seat ₦2,550
select t.setv('L2', t.mk_listing(:'G', 'Netflix', 10, 4)::text);      -- seat ₦2,338 (cheaper)
select t.setv('L3', t.mk_listing(:'G', 'Canva', 20, 1)::text);        -- seat ₦4,500 (dearer), 1 seat
select t.setv('L4', t.mk_listing(:'G', 'Spotify', 20, 1)::text);      -- 1 seat
select t.setv('P2', (select _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct)::text from listings l join service_plans p on p.id = l.plan_id where l.id = t.v('L2')::uuid));
select t.setv('P3', (select _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct)::text from listings l join service_plans p on p.id = l.plan_id where l.id = t.v('L3')::uuid));
select t.ok('New live listings get a "confirmed until" date about 30 days ahead',
  (select bool_and(host_paid_until between now() + interval '29 days' and now() + interval '31 days') from listings));

-- =====================================================================
-- 1. CARD PAYMENTS SWITCH
-- =====================================================================
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('A normal user cannot switch card payments', 'select admin_set_card_payments(false)', '%admins only%');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('Admin switches card payments OFF', (admin_set_card_payments(false) ->> 'card_payments') = 'false');
reset role;
select t.ok('The website sees card payments OFF', (public_catalog() -> 'settings' ->> 'card_payments') = 'false');
set role service_role;
select t.err('Card top-up is refused while OFF', format($$select payment_create(%L, 'SS-OFF1', 'TOPUP', 500000)$$, :'B'), '%switched off%');
select t.err('Card seat payment is refused while OFF', format($$select payment_create(%L, 'SS-OFF2', 'SEAT', null, %L, '')$$, :'B', t.v('L1')), '%switched off%');
reset role;
select t.ok('No payment rows were created while OFF', (select count(*) = 0 from payments));
set role authenticated; set "request.jwt.claim.sub" = :'A';
select admin_set_card_payments(true);
reset role;
set role service_role;
select t.ok('Card top-up works again when ON', (payment_create(:'B', 'SS-ON1', 'TOPUP', 500000) ->> 'amount_kobo')::bigint = 500000);
reset role;
select t.ok('The switch is in the audit log', (select count(*) = 2 from admin_audit_logs where action in ('CARD_PAYMENTS_ON','CARD_PAYMENTS_OFF')));

-- =====================================================================
-- 2. PLAN LENGTHS + START DATE
-- =====================================================================
select t.fund(:'B', 5000000);                                -- ₦50,000
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('2 months is not a length', format($$select join_with_wallet(%L, '', 2)$$, t.v('L1')), '%can be bought for%');
select t.err('A start date in the past is refused', format($$select join_with_wallet(%L, '', 3, (now() at time zone 'Africa/Lagos')::date - 1)$$, t.v('L1')), '%today or a later%');
select t.err('A start date more than 30 days away is refused', format($$select join_with_wallet(%L, '', 3, (now() at time zone 'Africa/Lagos')::date + 31)$$, t.v('L1')), '%30 days%');
select t.ok('Buyer joins Netflix for 3 months starting today', (join_with_wallet(t.v('L1')::uuid, '', 3, (now() at time zone 'Africa/Lagos')::date) ->> 'membership_id') is not null);
select t.err('The same buyer cannot join the same plan twice', format($$select join_with_wallet(%L, '', 1)$$, t.v('L1')), '%already have a seat%');
reset role;
select t.setv('ORD', (select order_ref from memberships where buyer_id = :'B' and period_no = 1));
select t.ok('3 rows, one per month, all in one order', (select count(*) = 3 and count(distinct order_ref) = 1 from memberships where buyer_id = :'B'));
select t.ok('Months follow each other with no gap (30 days each)',
  (select bool_and(m2.starts_at = m1.ends_at and m2.renewed_from = m1.id) from memberships m1 join memberships m2 on m2.order_ref = m1.order_ref and m2.period_no = m1.period_no + 1 where m1.buyer_id = :'B')
  and (select max(ends_at) - min(starts_at) = interval '90 days' from memberships where buyer_id = :'B'));
select t.ok('Each month is ₦2,550, and the ₦200 fee is charged once',
  (select bool_and(amount_kobo = 255000) and sum(buyer_fee_kobo) = 20000 from memberships where buyer_id = :'B'));
select t.ok('Wallet paid 3 × ₦2,550 + ₦200 = ₦7,850', _balance(:'B', 'WALLET') = 5000000 - 785000);
select t.ok('Host sees 3 months pending (3 × ₦2,295)', _balance(:'H', 'PENDING') = 3 * 229500);
select t.ok('Each month releases on its own date (end of that month)',
  (select bool_and(release_at = greatest(ends_at, created_at + interval '30 days')) from memberships where buyer_id = :'B'));
select t.ok('Only one seat is taken', _occupied(t.v('L1')::uuid) = 1);
select t.ok('The receipt shows the whole order (3 months, ₦7,850)',
  (select (_receipt(txn_ref, null) ->> 'total_kobo')::bigint = 785000 and _receipt(txn_ref, null) ->> 'item' like '%3 months%' from memberships where buyer_id = :'B' and period_no = 1));
-- month 1 ends: only month 1 is released to the host
update memberships set starts_at = starts_at - interval '30 days', ends_at = ends_at - interval '30 days', release_at = now() - interval '1 minute'
 where buyer_id = :'B' and period_no = 1;
update memberships set starts_at = starts_at - interval '30 days', ends_at = ends_at - interval '30 days' where buyer_id = :'B' and period_no > 1;
select release_due_escrow();
select t.ok('After month 1, only month 1 is paid to the host', _balance(:'H', 'EARNINGS') = 229500 and _balance(:'H', 'PENDING') = 2 * 229500);
select t.ok('Platform got its 10% for month 1 only (+ the ₦200 fee)', _balance(null, 'PLATFORM') = 25500 + 20000);

-- start date in the future
select t.fund(:'C', 2000000);
set role authenticated; set "request.jwt.claim.sub" = :'C';
select t.ok('Chidi books 1 month starting in 10 days', (join_with_wallet(t.v('L1')::uuid, '', 1, (now() at time zone 'Africa/Lagos')::date + 10) ->> 'membership_id') is not null);
reset role;
select t.ok('It starts at midnight Lagos time on that day and ends 30 days later',
  (select starts_at = (((now() at time zone 'Africa/Lagos')::date + 10)::timestamp at time zone 'Africa/Lagos') and ends_at = starts_at + interval '30 days'
   from memberships where buyer_id = :'C'));
select t.ok('The seat is held from today', _occupied(t.v('L1')::uuid) = 2);
select t.ok('Host money for it is released only after it ends', (select release_at = ends_at from memberships where buyer_id = :'C'));

-- plan lengths can be limited by the admin
set role authenticated; set "request.jwt.claim.sub" = :'A';
select admin_save_plan(jsonb_build_object('id', p.id, 'service_id', p.service_id, 'name', p.name, 'normal_price_kobo', p.normal_price_kobo, 'max_seats', p.max_seats,
  'access_type', p.access_type, 'duration_days', p.duration_days, 'min_markup_pct', p.min_markup_pct, 'max_markup_pct', p.max_markup_pct,
  'verification_required', true, 'host_proof_required', true, 'active', true, 'allowed_months', jsonb_build_array(1, 12)))
from service_plans p join services s on s.id = p.service_id where s.name = 'Spotify';
select t.err('Admin must tick at least one valid length', format($$select admin_save_plan(jsonb_build_object('id', %L, 'service_id', %L, 'name', 'Premium Family',
  'normal_price_kobo', 250000, 'max_seats', 5, 'access_type', 'FAMILY', 'duration_days', 30, 'min_markup_pct', 10, 'max_markup_pct', 30,
  'verification_required', true, 'host_proof_required', true, 'active', true, 'allowed_months', jsonb_build_array(2)))$$,
  (select p.id from service_plans p join services s on s.id = p.service_id where s.name = 'Spotify'), (select s.id from services s where s.name = 'Spotify')), '%at least one length%');
reset role;
select t.ok('Spotify now sells only 1 or 12 months', (select allowed_months = '{1,12}' from service_plans p join services s on s.id = p.service_id where s.name = 'Spotify'));
set role authenticated; set "request.jwt.claim.sub" = :'C';
select t.err('3 months of Spotify is refused after the change', format($$select join_with_wallet(%L, 'chidi@subsplit.test', 3)$$, t.v('L4')), '%1, 12%');
reset role;

-- card payment for 6 months
select t.fund(:'G', 0);
set role service_role;
select t.ok('Card payment for 6 months asks 6 × seat + ₦200',
  (payment_create(:'A', 'SS-SIX', 'SEAT', null, t.v('L2')::uuid, '', 6, null) ->> 'amount_kobo')::bigint = 6 * t.v('P2')::bigint + 20000);
select t.ok('Paying it creates 6 months', (payment_complete('SS-SIX', 6 * t.v('P2')::bigint + 20000, 'NGN', 'flw-1', 'card') ->> 'joined') = 'true');
reset role;
select t.ok('6 rows for the admin in Gbenga''s plan', (select count(*) = 6 from memberships where buyer_id = :'A' and listing_id = t.v('L2')::uuid));
select t.ok('Wallet is back to ₦0 (paid exactly)', _balance(:'A', 'WALLET') = 0);
set role service_role;
select payment_create(:'C', 'SS-OLD', 'SEAT', null, t.v('L3')::uuid, 'chidi@subsplit.test', 1, (now() at time zone 'Africa/Lagos')::date + 2);
reset role;
update payments set start_date = (now() at time zone 'Africa/Lagos')::date - 3 where reference = 'SS-OLD';
set role service_role;
select t.ok('A slow payment whose start date passed still joins, starting today', (payment_complete('SS-OLD', t.v('P3')::bigint + 20000, 'NGN', 'flw-2', 'card') ->> 'joined') = 'true');
reset role;
select t.ok('…and it starts now, not in the past', (select starts_at > now() - interval '1 minute' from memberships where buyer_id = :'C' and listing_id = t.v('L3')::uuid));
select t.ok('Ledger balanced after the purchases', t.ledger_ok());

-- =====================================================================
-- 3. RENEWALS AND AUTO-RENEW
-- =====================================================================
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Renewing early is refused (3rd month ends in about 60 days)',
  format($$select renew_membership(%L, 1)$$, (select id from memberships where buyer_id = :'B' and period_no = 3)), '%last%days%');
reset role;
-- bring the end close: month 3 ends in 2 days
update memberships set ends_at = now() + interval '2 days', starts_at = now() - interval '28 days', release_at = now() + interval '2 days' where buyer_id = :'B' and period_no = 3;
update memberships set ends_at = now() - interval '28 days' + interval '0 second', starts_at = now() - interval '58 days', release_at = now() - interval '28 days' where buyer_id = :'B' and period_no = 2;
select release_due_escrow();
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.ok('My Subs: the current month shows "ask to renew"',
  (select bool_or((x ->> 'ask_renew')::boolean and (x ->> 'can_renew')::boolean) from jsonb_array_elements(my_subscriptions()) x where x ->> 'listing_id' = t.v('L1')));
select t.ok('Buyer turns ON auto-renew', (set_auto_renew((select id from memberships where buyer_id = :'B' and period_no = 3), true) ->> 'auto_renew') = 'true');
reset role;
select t.ok('Auto-renew is saved on the seat', (select auto_renew from memberships where buyer_id = :'B' and period_no = 3));
select t.ok('Reminder job runs', send_expiry_reminders() >= 1);
select t.ok('Reminder (3 days before) tells the buyer auto-renew is on', (select body like '%Auto-renew is on%' from notifications where user_id = :'B' and type = 'EXPIRING' order by created_at desc limit 1));
select t.setv('Bwallet', _balance(:'B', 'WALLET')::text);
select process_renewals();
select t.ok('process_renewals renewed it from the wallet (original order was 3 months, so 3 more)',
  (select count(*) = 3 from memberships where buyer_id = :'B' and listing_id = t.v('L1')::uuid and order_ref <> t.v('ORD')));
select t.ok('Charged 3 × ₦2,550 + ₦200', _balance(:'B', 'WALLET') = t.v('Bwallet')::bigint - 785000);
select t.ok('New months start exactly when the old one ends', (select m2.starts_at = m1.ends_at from memberships m1 join memberships m2 on m2.renewed_from = m1.id
   where m1.buyer_id = :'B' and m1.period_no = 3 and m1.order_ref = t.v('ORD')));
select t.ok('Auto-renew stays on for the next time', (select bool_and(auto_renew) from memberships where buyer_id = :'B' and order_ref <> t.v('ORD')));
select t.ok('Running the job again does not charge twice', (process_renewals() ->> 'auto_renewed')::int = 0
  and (select count(*) = 6 from memberships where buyer_id = :'B' and listing_id = t.v('L1')::uuid));

-- auto-renew without enough money: a clear "top up" message, once a day, and the seat is held during the grace time
select t.fund(:'C', 0);
set role authenticated; set "request.jwt.claim.sub" = :'C';
select set_auto_renew((select id from memberships where buyer_id = :'C' and listing_id = t.v('L3')::uuid), true);
reset role;
select _post(:'C', 'WALLET', 'ADJUSTMENT', -_balance(:'C', 'WALLET'), 'empty for test', 'TST-EMPTY');
update memberships set starts_at = now() - interval '30 days' - interval '2 hours', ends_at = now() - interval '2 hours', release_at = now() + interval '28 days'
 where buyer_id = :'C' and listing_id = t.v('L3')::uuid;
select process_renewals();
select t.ok('Empty wallet: auto-renew sends a "top up" message', t.notes(:'C', 'AUTO_RENEW_FAILED') = 1
  and (select body like 'Add ₦%' from notifications where user_id = :'C' and type = 'AUTO_RENEW_FAILED' limit 1));
select process_renewals();
select t.ok('…only once per day, not every hour', t.notes(:'C', 'AUTO_RENEW_FAILED') = 1);
select t.ok('The 1-seat Canva plan stays full during the 24-hour grace time', _occupied(t.v('L3')::uuid) = 1);
select t.fund(:'B', 1000000);
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Nobody else can take the held seat', format($$select join_with_wallet(%L, 'bola@test.ng', 1)$$, t.v('L3')), '%full%');
reset role;
select t.fund(:'C', t.v('P3')::bigint + 20000);
select process_renewals();
select t.ok('After topping up, the next run renews it (even 2 hours after the end)',
  (select count(*) = 2 from memberships where buyer_id = :'C' and listing_id = t.v('L3')::uuid) and _balance(:'C', 'WALLET') = 0);
select t.ok('The renewed month starts now (no backdating)', (select starts_at > now() - interval '1 minute' from memberships where buyer_id = :'C' and listing_id = t.v('L3')::uuid and not renewed));
update memberships set ends_at = now() - interval '30 hours' where buyer_id = :'C' and listing_id = t.v('L3')::uuid and not renewed;
update memberships set renewed = false, auto_renew = true where id = (select id from memberships where buyer_id = :'C' and listing_id = t.v('L3')::uuid and not renewed);
select t.ok('After the grace time the seat is free again', _occupied(t.v('L3')::uuid) = 0);
update memberships set ends_at = now() + interval '28 days' where buyer_id = :'C' and listing_id = t.v('L3')::uuid and not renewed;

-- the member says "I won't renew"
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.ok('Buyer taps "I won''t renew"', (member_renew_choice((select id from memberships where buyer_id = :'B' and listing_id = t.v('L1')::uuid and not renewed), 'NO') ->> 'choice') = 'NO');
reset role;
select t.ok('That switches auto-renew off for the whole seat', (select not bool_or(auto_renew) from memberships where buyer_id = :'B' and listing_id = t.v('L1')::uuid and ends_at > now()));
select t.ok('The host is told the seat will open', (select count(*) >= 1 from notifications where user_id = :'H' and type = 'EXPIRING_HOST' and title like '%will not renew%'));
set role authenticated; set "request.jwt.claim.sub" = :'C';
select t.err('Someone else cannot answer for the buyer', format($$select member_renew_choice(%L, 'NO')$$, (select id from memberships where buyer_id = :'B' limit 1)), '%not found%');
select t.err('Someone else cannot switch the buyer''s auto-renew', format($$select set_auto_renew(%L, true)$$, (select id from memberships where buyer_id = :'B' limit 1)), '%not found%');
reset role;

-- =====================================================================
-- 4. HOSTS: "Will you renew your plan?"
-- =====================================================================
update listings set host_paid_until = now() + interval '4 days' where id = t.v('L1')::uuid;
select process_renewals();
select t.ok('5 days before, the host is asked (in-app + email)', t.notes(:'H', 'HOST_RENEW_ASK') = 1
  and (select count(*) = 1 from email_outbox where to_user = :'H' and type = 'HOST_RENEW_ASK'));
select process_renewals();
select t.ok('…only once', t.notes(:'H', 'HOST_RENEW_ASK') = 1);
set role authenticated; set "request.jwt.claim.sub" = :'H';
select t.ok('Host''s listing shows the renew buttons', (select bool_or((x ->> 'ask_renew')::boolean) from jsonb_array_elements(my_listings()) x where x ->> 'id' = t.v('L1')));
select t.ok('Host taps "I will renew": confirmed for 30 more days', (host_renew_answer(t.v('L1')::uuid, true) ->> 'renewed') = 'true');
reset role;
select t.ok('New date = old date + 30 days, and the question is reset',
  (select host_paid_until between now() + interval '33 days 23 hours' and now() + interval '34 days 1 hour' and host_renew_asked_at is null from listings where id = t.v('L1')::uuid));
set role authenticated; set "request.jwt.claim.sub" = :'G';
select t.err('Another host cannot answer for this listing', format($$select host_renew_answer(%L, false)$$, t.v('L1')), '%your own listings%');
reset role;
-- no answer: the listing pauses for new members
update listings set host_paid_until = now() - interval '1 hour', host_renew_asked_at = now() - interval '5 days' where id = t.v('L2')::uuid;
select process_renewals();
select t.ok('No answer by the date: listing is paused for new members', (select status = 'PAUSED' and renew_paused from listings where id = t.v('L2')::uuid));
set role authenticated; set "request.jwt.claim.sub" = :'G';
select t.err('Host cannot simply un-pause; they must confirm first', format($$select host_set_paused(%L, false)$$, t.v('L2')), '%I will renew%');
select t.ok('"I will renew" opens it again', (host_renew_answer(t.v('L2')::uuid, true) ->> 'renewed') = 'true');
reset role;
select t.ok('Live again with a new date', (select status = 'LIVE' and not renew_paused and host_paid_until > now() + interval '29 days' from listings where id = t.v('L2')::uuid));
-- "I won't renew": no new members, future months refunded
select t.setv('Bbefore', _balance(:'B', 'WALLET')::text);
update listings set host_paid_until = now() + interval '3 days' where id = t.v('L1')::uuid;
set role authenticated; set "request.jwt.claim.sub" = :'H';
select t.ok('Host taps "I won''t renew"', (host_renew_answer(t.v('L1')::uuid, false) ->> 'renewed') = 'false');
reset role;
select t.ok('Listing stops taking members', (select status = 'PAUSED' and host_stopping from listings where id = t.v('L1')::uuid));
select t.ok('Months that start after the host''s plan ends were refunded to the buyer',
  _balance(:'B', 'WALLET') = t.v('Bbefore')::bigint + 2 * 255000
  and (select count(*) = 2 from memberships where buyer_id = :'B' and listing_id = t.v('L1')::uuid and status = 'REFUNDED'));
select t.ok('Chidi''s future month (starts in 10 days) was refunded too', (select status = 'REFUNDED' from memberships where buyer_id = :'C' and listing_id = t.v('L1')::uuid));
select t.ok('Members were told', t.notes(:'B', 'HOST_NOT_RENEWING') = 1 and t.notes(:'C', 'HOST_NOT_RENEWING') = 1);
select t.ok('Admins were alerted', (select count(*) >= 1 from notifications where user_id = :'A' and title like 'Host not renewing%'));
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Renewing is refused when the host is stopping',
  format($$select renew_membership(%L, 1)$$, (select id from memberships where buyer_id = :'B' and listing_id = t.v('L1')::uuid and status = 'ACTIVE' and not renewed)), '%paused%');
reset role;
select t.ok('Ledger balanced after renewals and host answers', t.ledger_ok());

-- =====================================================================
-- 5. MOVING A MEMBER
-- =====================================================================
update listings set status = 'PAUSED' where id = t.v('L1')::uuid;
update listings set status = 'LIVE' where id = t.v('L1')::uuid;        -- reopen Hannah's Netflix (₦2,550)
select t.fund(:'D', 1000000);
set role authenticated; set "request.jwt.claim.sub" = :'D';
select join_with_wallet(t.v('L1')::uuid, '', 1);
reset role;
select t.setv('Dm', (select id::text from memberships where buyer_id = :'D'));
update memberships set starts_at = now() - interval '15 days', ends_at = now() + interval '15 days', release_at = now() + interval '15 days' where id = t.v('Dm')::uuid;
set role authenticated; set "request.jwt.claim.sub" = :'D';
select t.err('A member cannot move themselves', format($$select admin_move_member(%L, %L)$$, t.v('Dm'), t.v('L2')), '%admins only%');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('Cannot move into the same plan', format($$select admin_move_member(%L, %L)$$, t.v('Dm'), t.v('L1')), '%already in this plan%');
select t.ok('Move targets list other live plans with free seats', (select count(*) >= 2 from jsonb_array_elements(admin_move_targets(t.v('Dm')::uuid))));
select t.setv('Q', admin_move_quote(t.v('Dm')::uuid, t.v('L2')::uuid, true)::text);
reset role;
select t.ok('Quote: half a month left → credit about half of ₦2,550', (t.v('Q')::jsonb ->> 'credit_kobo')::bigint between 120000 and 130000);
select t.ok('Quote: new plan is cheaper, so the difference is negative', (t.v('Q')::jsonb ->> 'difference_kobo')::bigint < 0);
select t.setv('Dw', _balance(:'D', 'WALLET')::text);
select t.setv('He', _balance(:'H', 'EARNINGS')::text);
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('Admin moves Dayo to the cheaper plan: done at once', (admin_move_member(t.v('Dm')::uuid, t.v('L2')::uuid, true, false, '', 'Host had problems') ->> 'done') = 'true');
reset role;
select t.ok('Old month: part refunded, ended now, linked to the new seat',
  (select status = 'PARTIALLY_REFUNDED' and escrow = 'SETTLED' and ends_at <= now() and moved_to is not null from memberships where id = t.v('Dm')::uuid));
select t.ok('Old host was paid for the 15 days used (minus 10%)', _balance(:'H', 'EARNINGS') - t.v('He')::bigint between 110000 and 120000);
select t.ok('New seat in Gbenga''s plan with the same end date',
  (select count(*) = 1 from memberships m where m.buyer_id = :'D' and m.listing_id = t.v('L2')::uuid and m.status = 'ACTIVE'
     and abs(extract(epoch from (m.ends_at - (now() + interval '15 days')))) < 120));
select t.ok('The cheaper price left change in Dayo''s wallet (never a minus)',
  _balance(:'D', 'WALLET') = t.v('Dw')::bigint - (t.v('Q')::jsonb ->> 'difference_kobo')::bigint and _balance(:'D', 'WALLET') >= 0);
select t.ok('Dayo, the old host and the new host were told', t.notes(:'D', 'SEAT_MOVED') = 1
  and (select count(*) >= 1 from notifications where user_id = :'H' and title like '%moved out%')
  and (select count(*) >= 1 from notifications where user_id = :'G' and body like '%moved to your plan%'));
select t.ok('The move is in the audit log', (select count(*) = 1 from admin_audit_logs where action = 'MOVE_MEMBER'));
-- now move him to Canva (dearer): he must pay the difference
update memberships set status = 'COMPLETED' where buyer_id = :'C' and listing_id = t.v('L3')::uuid;   -- free the 1 Canva seat
select t.setv('Dm2', (select id::text from memberships where buyer_id = :'D' and listing_id = t.v('L2')::uuid and status = 'ACTIVE' limit 1));
select _post(:'D', 'WALLET', 'ADJUSTMENT', -_balance(:'D', 'WALLET'), 'empty for test', 'TST-EMPTY2');
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.setv('MV', (admin_move_member(t.v('Dm2')::uuid, t.v('L3')::uuid, true, false, 'dayo@subsplit.test', '') ->> 'move_id'));
select t.err('Only one waiting move per seat', format($$select admin_move_member(%L, %L)$$, t.v('Dm2'), t.v('L3')), '%already has a move waiting%');
reset role;
select t.ok('Dearer plan: the move waits for Dayo to pay the difference', t.v('MV') is not null
  and (select status = 'AWAITING_PAYMENT' and quoted_difference_kobo > 0 from seat_moves where id = t.v('MV')::uuid));
select t.ok('His current seat keeps working meanwhile', (select status = 'ACTIVE' from memberships where id = t.v('Dm2')::uuid));
select t.ok('He was asked to pay (in-app + email)', t.notes(:'D', 'MOVE_PAYMENT') = 1 and (select count(*) = 1 from email_outbox where to_user = :'D' and type = 'MOVE_PAYMENT'));
set role authenticated; set "request.jwt.claim.sub" = :'D';
select t.ok('My Subs shows the move with the amount', (select bool_or(x -> 'move' is not null and (x -> 'move' ->> 'difference_kobo')::bigint > 0)
   from jsonb_array_elements(my_subscriptions()) x));
select t.ok('He can see the current amount to pay', (seat_move_quote(t.v('MV')::uuid) ->> 'difference_kobo')::bigint > 0);
select t.err('With ₦0 in the wallet he is asked to add money (no minus balance)', format($$select complete_seat_move(%L)$$, t.v('MV')), 'Add ₦%');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Another user cannot pay someone else''s move', format($$select complete_seat_move(%L)$$, t.v('MV')), '%not waiting%');
reset role;
select t.ok('Nothing changed after the refused attempts', (select status = 'ACTIVE' from memberships where id = t.v('Dm2')::uuid) and _balance(:'D', 'WALLET') = 0);
select t.fund(:'D', (select quoted_difference_kobo from seat_moves where id = t.v('MV')::uuid) + 10000);
set role authenticated; set "request.jwt.claim.sub" = :'D';
select t.ok('After adding money he taps "Pay and move": done', (complete_seat_move(t.v('MV')::uuid) ->> 'membership_id') is not null);
reset role;
select t.ok('He is now in Canva and the move is marked done', (select status = 'DONE' from seat_moves where id = t.v('MV')::uuid)
  and (select count(*) = 1 from memberships where buyer_id = :'D' and listing_id = t.v('L3')::uuid and status = 'ACTIVE'));
select t.ok('His wallet never went below zero', (select min(balance_after_kobo) >= 0 from wallet_transactions where user_id = :'D' and account_kind = 'WALLET'));
select t.ok('Canva needs an invite email: the one the admin typed was used', (select contact = 'dayo@subsplit.test' from memberships where buyer_id = :'D' and listing_id = t.v('L3')::uuid and status = 'ACTIVE'));
-- SplitSub covers the difference, old host gets nothing (full refund chosen); all 6 months move
update memberships set status = 'COMPLETED' where buyer_id = :'D' and listing_id = t.v('L3')::uuid;
select t.setv('Am', (select id::text from memberships where buyer_id = :'A' and listing_id = t.v('L2')::uuid and status = 'ACTIVE' order by starts_at limit 1));
select t.setv('Pbefore', _balance(null, 'PLATFORM')::text);
select t.setv('Ge', _balance(:'G', 'EARNINGS')::text);
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.setv('MV2', admin_move_member(t.v('Am')::uuid, t.v('L3')::uuid, false, true, 'owner@subsplit.test', 'Our fault')::text);
reset role;
select t.ok('"SplitSub covers the difference": done at once', (t.v('MV2')::jsonb ->> 'done') = 'true');
select t.ok('All 6 months moved and the old host got nothing',
  (select count(*) = 6 from memberships where buyer_id = :'A' and listing_id = t.v('L2')::uuid and status = 'REFUNDED')
  and (select count(*) = 6 from memberships where buyer_id = :'A' and listing_id = t.v('L3')::uuid) and _balance(:'G', 'EARNINGS') = t.v('Ge')::bigint);
select t.ok('The difference came from the platform account', _balance(null, 'PLATFORM') < t.v('Pbefore')::bigint);
select t.ok('The new seat is one chain of 6 months with one newest month', (select count(*) = 1 from memberships where buyer_id = :'A' and listing_id = t.v('L3')::uuid and not renewed));
-- reports block moves
select t.setv('Am2', (select id::text from memberships where buyer_id = :'A' and listing_id = t.v('L3')::uuid order by starts_at limit 1));
update memberships set status = 'DISPUTED' where id = t.v('Am2')::uuid;
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('A seat with an open report cannot be moved', format($$select admin_move_member(%L, %L)$$, t.v('Am2'), t.v('L2')), '%open report%');
reset role;
update memberships set status = 'ACTIVE' where id = t.v('Am2')::uuid;
-- a full refund of the current month also refunds the later months
set role authenticated; set "request.jwt.claim.sub" = :'A';
select admin_refund(t.v('Am2')::uuid, null, 'Host stopped working');
reset role;
select t.ok('Full refund of month 1 also refunded months 2 to 6', (select count(*) = 6 from memberships where buyer_id = :'A' and listing_id = t.v('L3')::uuid and status = 'REFUNDED'));
select t.ok('Ledger balanced after all the moves', t.ledger_ok());

-- =====================================================================
-- 6. CREATORS & PARTNERS
-- =====================================================================
set role authenticated; set "request.jwt.claim.sub" = :'K';
select t.err('A user cannot make themselves a creator', $$select admin_save_creator('{"username":"kemi","code":"KEMI","commission_type":"PERCENT","commission_bps":500}')$$, '%admins only%');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('Unknown username is refused', $$select admin_save_creator('{"username":"nobody99","code":"NOBODY","commission_type":"PERCENT","commission_bps":500}')$$, '%No user%');
select t.err('Reserved codes are refused', $$select admin_save_creator('{"username":"kemi","code":"ADMIN","commission_type":"PERCENT","commission_bps":500}')$$, '%reserved%');
select t.err('Bad account numbers are refused', $$select admin_save_creator('{"username":"kemi","code":"KEMI","commission_type":"PERCENT","commission_bps":500,"account_number":"123"}')$$, '%10 digits%');
select t.ok('Admin adds Kemi: code KEMI, 5% commission, Moniepoint account',
  (admin_save_creator('{"username":"kemi","code":"kemi","commission_type":"PERCENT","commission_bps":500,"bank_name":"Moniepoint","account_number":"8012345678","account_name":"Kemi A"}') ->> 'code') = 'KEMI');
select t.err('The same code cannot be given to someone else', $$select admin_save_creator('{"username":"bola","code":"KEMI","commission_type":"FLAT","commission_flat_kobo":50000}')$$, '%already used%');
reset role;
select t.ok('KEMI is now Kemi''s invite code too (so the link works at sign-up)', (select referral_code = 'KEMI' from profiles where id = :'K'));
select t.ok('Kemi was told', (select count(*) = 1 from notifications where user_id = :'K' and title like '%creator%'));
insert into auth.users (id, email, raw_user_meta_data) values (:'R', 'fan1@subsplit.test', '{"full_name":"Fan One","referral_code":"KEMI"}'),
  (:'R2', 'fan2@subsplit.test', '{"full_name":"Fan Two","referral_code":"kemi"}');
select t.ok('Two fans signed up with the code: both counted for Kemi', (select count(*) = 2 from referrals where referrer_id = :'K'));
select t.fund(:'R', 2000000);
update listings set status = 'LIVE' where id = t.v('L2')::uuid;
set role authenticated; set "request.jwt.claim.sub" = :'R';
select join_with_wallet(t.v('L2')::uuid, '', 3);
reset role;
select t.setv('CM', floor(t.v('P2')::bigint * 0.05)::bigint::text);
select t.ok('Fan bought 3 months: 3 commission lines of 5% of the seat price each',
  (select count(*) = 3 and bool_and(amount_kobo = t.v('CM')::bigint and status = 'PENDING') from creator_earnings where referred_id = :'R'));
set role authenticated; set "request.jwt.claim.sub" = :'K';
select t.ok('Kemi sees 2 sign-ups, 1 buyer and 3 commissions pending', (select (x ->> 'signups')::int = 2 and (x ->> 'buyers')::int = 1 and (x ->> 'pending_kobo')::bigint = 3 * t.v('CM')::bigint from (select my_creator() x) y));
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.ok('A normal user has no creator dashboard', my_creator() is null);
reset role;
-- month 1 released, month 3 refunded
update memberships set release_at = now() - interval '1 minute' where buyer_id = :'R' and period_no = 1;
select release_due_escrow();
select _refund((select id from memberships where buyer_id = :'R' and period_no = 3), null, 'test refund');
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('Admin list: 1 payable (released), 1 pending, refunded month cancelled',
  (select (x ->> 'payable_kobo')::bigint = t.v('CM')::bigint and (x ->> 'pending_kobo')::bigint = t.v('CM')::bigint from jsonb_array_elements(admin_creators()) x where x ->> 'code' = 'KEMI'));
select t.ok('Month-end: 1 payout prepared', (admin_prepare_creator_payouts('Oct 2026') ->> 'payouts')::int = 1);
select t.ok('Preparing again adds nothing new', (admin_prepare_creator_payouts('Oct 2026') ->> 'payouts')::int = 0);
select t.ok('The payout carries her bank details', (select bool_and(x ->> 'bank_name' = 'Moniepoint' and x ->> 'account_number' = '8012345678') from jsonb_array_elements(admin_creator_payouts('DUE')) x));
reset role;
select t.setv('PO', (select id::text from creator_payouts limit 1));
select t.setv('Pb', _balance(null, 'PLATFORM')::text);
set role authenticated; set "request.jwt.claim.sub" = :'A';
select admin_creator_payout_action(t.v('PO')::uuid, 'WALLET', '');
reset role;
select t.ok('"Pay to wallet": Kemi''s wallet up, platform down by the same amount', _balance(:'K', 'WALLET') = t.v('CM')::bigint and _balance(null, 'PLATFORM') = t.v('Pb')::bigint - t.v('CM')::bigint);
select t.ok('Earnings and payout marked paid; she was told', (select status = 'PAID' from creator_payouts where id = t.v('PO')::uuid)
  and (select count(*) = 1 from creator_earnings where status = 'PAID') and t.notes(:'K', 'CREATOR_PAYOUT') = 1);
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('A paid payout cannot be paid twice', format($$select admin_creator_payout_action(%L, 'PAID')$$, t.v('PO')), '%already paid%');
reset role;
select t.setv('KID', (select id::text from creators where code = 'KEMI'));
set role authenticated; set "request.jwt.claim.sub" = :'A';
-- flat ₦, first order only
select admin_save_creator(jsonb_build_object('id', t.v('KID'), 'code', 'KEMI', 'commission_type', 'FLAT',
  'commission_flat_kobo', 50000, 'first_purchase_only', true, 'bank_name', 'Kuda', 'account_number', '2012345678', 'account_name', 'Kemi A'));
reset role;
select t.fund(:'R2', 2000000);
set role authenticated; set "request.jwt.claim.sub" = :'R2';
select join_with_wallet(t.v('L2')::uuid, '', 6);
reset role;
select t.ok('Flat ₦500 is paid once per order (not per month)', (select count(*) = 1 and sum(amount_kobo) = 50000 from creator_earnings where referred_id = :'R2'));
update memberships set ends_at = now() + interval '1 day' where buyer_id = :'R2' and not renewed;
set role authenticated; set "request.jwt.claim.sub" = :'R2';
select renew_membership((select id from memberships where buyer_id = :'R2' and not renewed), 1);
reset role;
select t.ok('"First order only": the renewal earns nothing more', (select count(*) = 1 from creator_earnings where referred_id = :'R2'));
select t.ok('Ledger balanced after creator payouts', t.ledger_ok());

-- =====================================================================
-- 7. BULK MESSAGES
-- =====================================================================
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('A normal user cannot send bulk messages', $$select admin_bulk_create('EMAIL', 'Hi', 'Hello', 'a@b.ng')$$, '%admins only%');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.setv('J1', admin_bulk_create('EMAIL', 'SplitSub is live', 'Hello from SplitSub', E'ada@gmail.com\nADA@gmail.com, bad-email\n tobi@yahoo.com tolu@outlook.com;')::text);
select t.ok('Emails: 3 valid (duplicate removed), 1 invalid reported', (t.v('J1')::jsonb ->> 'valid')::int = 3 and jsonb_array_length(t.v('J1')::jsonb -> 'invalid') = 1);
select t.setv('J2', admin_bulk_create('SMS', '', 'Hello', E'0803 123 4567\n+2348031234567\n8091234567\n12345\n+447911123456, 08051234567 08061234567')::text);
reset role;
select t.ok('Phones: Nigerian numbers normalised to 234…, duplicates removed, bad one reported',
  (t.v('J2')::jsonb ->> 'valid')::int = 5 and jsonb_array_length(t.v('J2')::jsonb -> 'invalid') = 1
  and (select array_agg(recipient order by recipient) = '{2348031234567,2348051234567,2348061234567,2348091234567,447911123456}'
       from broadcast_items where job_id = (t.v('J2')::jsonb ->> 'job_id')::uuid));
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('Email needs a subject', $$select admin_bulk_create('EMAIL', '', 'Hello', 'a@b.ng')$$, '%subject%');
select t.err('SMS is limited to 640 characters', format($$select admin_bulk_create('SMS', '', %L, '08031234567')$$, repeat('x', 641)), '%640%');
select t.err('Nothing valid is refused', $$select admin_bulk_create('WHATSAPP', '', 'Hi', 'hello, 123')$$, '%No valid%');
select t.ok('"Fill with all users" gives every user''s email', length(admin_bulk_audience('EMAIL')) > 0 and admin_bulk_audience('EMAIL') like '%buyer@subsplit.test%');
select t.ok('…or every user''s phone, normalised', admin_bulk_audience('SMS') like '%2348031234567%');
select t.setv('C1', admin_bulk_claim((t.v('J1')::jsonb ->> 'job_id')::uuid, 2)::text);
select t.ok('Sending takes a batch of 2', jsonb_array_length(t.v('C1')::jsonb -> 'items') = 2 and t.v('C1')::jsonb -> 'job' ->> 'channel' = 'EMAIL');
select t.ok('Results recorded: 1 sent, 1 failed for good',
  (admin_bulk_mark((t.v('J1')::jsonb ->> 'job_id')::uuid, jsonb_build_array(
     jsonb_build_object('id', (t.v('C1')::jsonb -> 'items' -> 0 ->> 'id')::bigint, 'ok', true),
     jsonb_build_object('id', (t.v('C1')::jsonb -> 'items' -> 1 ->> 'id')::bigint, 'ok', false, 'error', 'Mailbox not found', 'final', true))) ->> 'pending')::int = 1);
select t.setv('C2', admin_bulk_claim((t.v('J1')::jsonb ->> 'job_id')::uuid, 10)::text);
select t.ok('The last one finishes the job', (admin_bulk_mark((t.v('J1')::jsonb ->> 'job_id')::uuid, jsonb_build_array(
     jsonb_build_object('id', (t.v('C2')::jsonb -> 'items' -> 0 ->> 'id')::bigint, 'ok', true))) ->> 'status') = 'DONE');
select t.ok('History shows 2 sent, 1 failed with the reason', (select (x ->> 'sent')::int = 2 and (x ->> 'failed')::int = 1 and x -> 'errors' -> 0 ->> 'error' = 'Mailbox not found'
   from jsonb_array_elements(admin_bulk_jobs()) x where x ->> 'id' = t.v('J1')::jsonb ->> 'job_id'));
select admin_bulk_cancel((t.v('J2')::jsonb ->> 'job_id')::uuid);
select t.ok('Cancelling stops the rest', jsonb_array_length(admin_bulk_claim((t.v('J2')::jsonb ->> 'job_id')::uuid, 10) -> 'items') = 0);
reset role;
select t.ok('…and the job is marked cancelled', (select status = 'CANCELLED' from broadcast_jobs where id = (t.v('J2')::jsonb ->> 'job_id')::uuid));
set role anon;
select t.err('Visitors cannot call any of the new admin tools', $$select admin_bulk_jobs()$$, '%permission denied%');
select t.err('Visitors cannot run the renewal job', $$select process_renewals()$$, '%permission denied%');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Signed-in users cannot run the renewal job', $$select process_renewals()$$, '%permission denied%');
select t.err('Signed-in users cannot call the internal buying engine', format($$select _buy_periods(%L, %L, 1, now(), '', null, null, 0)$$, :'B', t.v('L2')), '%permission denied%');
select t.err('Signed-in users cannot call the old join function', format($$select join_with_wallet_pre017(%L, '')$$, t.v('L2')), '%permission denied%');
reset role;
select t.ok('Final ledger check: every balance matches its ledger', t.ledger_ok());
select t.ok('No wallet anywhere went below zero', (select min(balance_kobo) >= 0 from wallet_accounts where kind <> 'PLATFORM'));
