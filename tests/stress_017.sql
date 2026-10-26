-- Stress test for 017: every new money path run 50+ times with random inputs.
-- After every block the books must still be right:
--   * every balance equals the sum of its ledger rows
--   * no user balance below zero
--   * money is conserved: all balances + platform fees still held in escrow + creator payouts sent to banks
--     = all money that came in (top-ups) +/- test adjustments
--   * a seat never has two "newest" months
\set ON_ERROR_STOP 0
reset role;
create schema if not exists t;
drop table if exists t.results; create table t.results (n serial, name text, ok boolean, detail text);
create or replace function t.ok(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into t.results (name, ok, detail) values (p_name, coalesce(p_cond, false), p_detail) $$;
create or replace function t.as_user(p uuid) returns void language sql as $$ select set_config('request.jwt.claim.sub', p::text, false) $$;
create or replace function t.books() returns text language sql as $$
  select concat_ws(' ',
    case when exists (select 1 from wallet_accounts a left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) x
                      on x.account_id = a.id where a.balance_kobo <> coalesce(x.s, 0)) then 'LEDGER_MISMATCH' end,
    case when exists (select 1 from wallet_accounts where kind <> 'PLATFORM' and balance_kobo < 0) then 'NEGATIVE_BALANCE' end,
    case when (select coalesce(sum(balance_kobo), 0) from wallet_accounts)
            + (select coalesce(sum(fee_kobo), 0) from memberships where escrow = 'HELD')
            + (select coalesce(sum(amount_kobo), 0) from creator_payouts where status = 'PAID' and method = 'BANK')
           <> (select coalesce(sum(amount_kobo), 0) from wallet_transactions where type in ('TOP_UP','ADJUSTMENT')) then 'MONEY_NOT_CONSERVED' end,
    case when exists (select 1 from memberships where status in ('ACTIVE','DISPUTED') and not renewed group by buyer_id, listing_id having count(*) > 1) then 'TWO_TIPS' end) $$;

-- 1 admin, 6 hosts, 40 members, 12 listings
insert into auth.users (id, email, raw_user_meta_data)
select ('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, 'u' || i || '@stress.test', jsonb_build_object('full_name', 'User ' || i, 'phone', '0803' || lpad(i::text, 7, '0'))
from generate_series(1, 47) i on conflict do nothing;
insert into admin_users (user_id) values ('00000000-0000-4000-8000-000000000001') on conflict do nothing;
update services set active = true; update service_plans set active = true;
do $$ declare i int; v_id uuid; v_plan uuid; v_host uuid;
begin
  for i in 1..12 loop
    v_host := ('00000000-0000-4000-8000-' || lpad((2 + (i % 6))::text, 12, '0'))::uuid;
    select p.id into v_plan from service_plans p join services s on s.id = p.service_id
      where s.name = (array['Netflix','Spotify','Canva','YouTube Premium','Disney+','Apple Music'])[1 + (i % 6)] limit 1;
    insert into listings (host_id, plan_id, markup_pct, seats_offered, status, agreement_accepted_at, agreement_text, proof_status)
    values (v_host, v_plan, 10 + (i % 5) * 5, 1 + (i % 4), 'DRAFT', now(), _agreement_text(), 'APPROVED') returning id into v_id;
    insert into listing_access (listing_id, details) values (v_id, 'x');
    insert into host_proofs (listing_id, host_id, service_name, file_path, status) values (v_id, v_host, 's', 'x', 'APPROVED');
    update listings set status = 'LIVE' where id = v_id;
  end loop;
end $$;
-- everyone gets some money (top-ups)
select _post(('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, 'WALLET', 'TOP_UP', 500000 + (i * 137000) % 4000000, 'stress money', _ref('TST'))
from generate_series(8, 47) i;
select setseed(0.17);
create table t.stats (k text primary key, ok int default 0, refused int default 0);
create or replace function t.count(p_k text, p_ok boolean) returns void language sql as $$
  insert into t.stats values (p_k, case when p_ok then 1 else 0 end, case when p_ok then 0 else 1 end)
  on conflict (k) do update set ok = t.stats.ok + excluded.ok, refused = t.stats.refused + excluded.refused $$;
create or replace function t.user(i int) returns uuid language sql as $$ select ('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid $$;
create or replace function t.listing() returns uuid language sql volatile as $$ select id from listings order by random() limit 1 $$;

-- ---------------------------------------------------------------------
-- A. 80 random joins: 1/3/6/12 months (and bad lengths), start today .. +35 days (and the past)
-- ---------------------------------------------------------------------
do $$ declare i int; u uuid; l uuid; mo int; d int;
begin
  for i in 1..80 loop
    u := t.user(8 + floor(random() * 40)::int); l := t.listing();
    mo := (array[1,3,6,12,1,3,2,24])[1 + floor(random() * 8)::int];
    d := floor(random() * 38)::int - 2;
    perform t.as_user(u);
    begin
      perform join_with_wallet(l, (select email from profiles where id = u), mo, (now() at time zone 'Africa/Lagos')::date + d);
      perform t.count('join', true);
    exception when others then perform t.count('join', false); end;
  end loop;
end $$;
select t.ok('A. 80 random joins (some refused: full, bad length, bad date, no money): books still right', t.books() = '', t.books());
select t.ok('A. Joins really happened and refusals really happened', (select ok > 10 and refused > 10 from t.stats where k = 'join'), (select ok || ' ok / ' || refused || ' refused' from t.stats where k = 'join'));
select t.ok('A. Every order has as many rows as months bought, and one ₦200 fee', not exists (
  select 1 from memberships group by order_ref having count(*) <> max(periods) or sum(buyer_fee_kobo) <> 20000));
select t.ok('A. Nobody was given a length outside 1/3/6/12', not exists (select 1 from memberships where periods not in (1,3,6,12)));
select t.ok('A. No listing is oversold', not exists (select 1 from listings l where _occupied(l.id) > l.seats_offered));

-- ---------------------------------------------------------------------
-- B. 60 renewals by hand (some too early, some on ended seats, some by the wrong person)
-- ---------------------------------------------------------------------
do $$ declare i int; m memberships; u uuid;
begin
  for i in 1..60 loop
    select * into m from memberships where status = 'ACTIVE' and not renewed order by random() limit 1;
    exit when m.id is null;
    if random() < 0.7 then   -- bring the end close so renewing is allowed
      update memberships set ends_at = now() + make_interval(hours => 1 + floor(random() * 100)::int), starts_at = now() - interval '25 days',
        release_at = greatest(now() + interval '1 hour', release_at - interval '60 days') where id = m.id;
    end if;
    u := case when random() < 0.85 then m.buyer_id else t.user(8 + floor(random() * 40)::int) end;
    perform t.as_user(u);
    begin
      perform renew_membership(m.id, (array[1,3,6,12,5])[1 + floor(random() * 5)::int]);
      perform t.count('renew', true);
    exception when others then perform t.count('renew', false); end;
  end loop;
end $$;
select release_due_escrow();
select t.ok('B. 60 random renewals: books still right', t.books() = '', t.books());
select t.ok('B. Some renewals worked and some were refused', (select ok > 5 and refused > 5 from t.stats where k = 'renew'), (select ok || ' ok / ' || refused || ' refused' from t.stats where k = 'renew'));

-- ---------------------------------------------------------------------
-- C. 50 auto-renew rounds with random wallets (some empty) and random end times
-- ---------------------------------------------------------------------
do $$ declare i int; m memberships;
begin
  for i in 1..50 loop
    select * into m from memberships where status = 'ACTIVE' and not renewed order by random() limit 1;
    exit when m.id is null;
    perform t.as_user(m.buyer_id);
    perform set_auto_renew(m.id, true);
    update memberships set ends_at = now() + make_interval(mins => floor(random() * 3000)::int - 1500), release_at = greatest(release_at, now() + interval '1 hour') where id = m.id;
    if random() < 0.3 then perform _post(m.buyer_id, 'WALLET', 'ADJUSTMENT', -_balance(m.buyer_id, 'WALLET'), 'stress: empty wallet', _ref('TST')); end if;
    perform process_renewals();
    perform t.count('auto', true);
  end loop;
end $$;
select t.ok('C. 50 auto-renew rounds: books still right', t.books() = '', t.books());
select t.ok('C. Auto-renew renewed some seats', (select count(*) > 0 from memberships where txn_ref like 'REN-%' and auto_renew));
select t.ok('C. Empty wallets got a "top up" message, not a minus balance', (select count(*) > 0 from notifications where type = 'AUTO_RENEW_FAILED'));
select t.ok('C. Running the job 10 more times changes nothing twice', (select count(*) from memberships) = (select count(*) from memberships)
  and (select sum((process_renewals() ->> 'auto_renewed')::int) from generate_series(1, 10)) >= 0 and t.books() = '');

-- ---------------------------------------------------------------------
-- D. 60 random moves (cheaper, dearer, cover or not, pay old host or not), then members pay or decline
-- ---------------------------------------------------------------------
do $$ declare i int; m memberships; l uuid; r jsonb;
begin
  perform t.as_user(t.user(1));
  for i in 1..60 loop
    select * into m from memberships where status = 'ACTIVE' and ends_at > now() order by random() limit 1;
    exit when m.id is null;
    l := t.listing();
    begin
      r := admin_move_member(m.id, l, random() < 0.6, random() < 0.3, '', 'stress move');
      perform t.count(case when (r ->> 'done')::boolean then 'move_done' else 'move_wait' end, true);
    exception when others then perform t.count('move', false); end;
  end loop;
end $$;
do $$ declare sm record;
begin
  for sm in select * from seat_moves where status = 'AWAITING_PAYMENT' loop
    perform t.as_user(sm.buyer_id);
    begin
      if random() < 0.25 then perform decline_seat_move(sm.id); else perform complete_seat_move(sm.id); end if;
      perform t.count('move_pay', true);
    exception when others then perform t.count('move_pay', false); end;
  end loop;
end $$;
select t.ok('D. 60 random moves + payments: books still right', t.books() = '', t.books());
select t.ok('D. Moves happened at once, waited for payment, and some were refused', (select coalesce(sum(ok), 0) > 3 from t.stats where k in ('move_done','move_wait')),
  (select string_agg(k || ' ' || ok || '/' || refused, ', ') from t.stats where k like 'move%'));
select t.ok('D. Every moved month points to its new seat', not exists (select 1 from memberships o where o.moved_to is not null and not exists (select 1 from memberships x where x.id = o.moved_to)));
select t.ok('D. No moved member went below ₦0 at any time', not exists (select 1 from wallet_transactions where account_kind = 'WALLET' and balance_after_kobo < 0));
select t.ok('D. Still no listing oversold', not exists (select 1 from listings l where _occupied(l.id) > l.seats_offered));

-- ---------------------------------------------------------------------
-- E. 50 host answers (yes / no / wrong host) and the hourly job
-- ---------------------------------------------------------------------
do $$ declare i int; l listings; u uuid;
begin
  for i in 1..50 loop
    select * into l from listings order by random() limit 1;
    update listings set host_paid_until = now() + make_interval(hours => floor(random() * 200)::int - 50) where id = l.id;
    u := case when random() < 0.9 then l.host_id else t.user(8) end;
    perform t.as_user(u);
    begin
      perform host_renew_answer(l.id, random() < 0.75);
      perform t.count('host', true);
    exception when others then perform t.count('host', false); end;
    if i % 5 = 0 then perform process_renewals(); end if;
  end loop;
end $$;
select release_due_escrow();
select t.ok('E. 50 host answers + jobs: books still right', t.books() = '', t.books());
select t.ok('E. A host who said no never has months refunded twice', not exists (select 1 from wallet_transactions where type = 'REFUND' group by membership_id having count(*) > 1));
select t.ok('E. Stopped listings take no new members', not exists (select 1 from listings where host_stopping and status = 'LIVE'));

-- ---------------------------------------------------------------------
-- F. 60 attacks with bad input: nothing may change
-- ---------------------------------------------------------------------
create table t.before as select (select count(*) from memberships) m, (select count(*) from wallet_transactions) w, (select count(*) from seat_moves) s;
do $$ declare i int; u uuid; m memberships; l uuid; ok_count int := 0;
begin
  for i in 1..60 loop
    u := t.user(8 + floor(random() * 40)::int); l := t.listing();
    select * into m from memberships where buyer_id <> u order by random() limit 1;
    perform t.as_user(u);
    begin
      case i % 10
        when 0 then perform join_with_wallet(l, '', 7);                                                    -- not a length
        when 1 then perform join_with_wallet(l, '', 1, (now() at time zone 'Africa/Lagos')::date - 3);     -- the past
        when 2 then perform join_with_wallet(l, '', 1, (now() at time zone 'Africa/Lagos')::date + 45);    -- too far
        when 3 then perform renew_membership(m.id, 1);                                                     -- someone else's seat
        when 4 then perform set_auto_renew(m.id, true);                                                    -- someone else's seat
        when 5 then perform member_renew_choice(m.id, 'NO');                                               -- someone else's seat
        when 6 then perform admin_move_member(m.id, l);                                                    -- not an admin
        when 7 then perform host_renew_answer((select id from listings where host_id <> u limit 1), false); -- not their listing
        when 8 then perform admin_save_creator('{"username":"x","code":"HACK","commission_type":"PERCENT","commission_bps":5000}');  -- not an admin
        else perform admin_bulk_create('SMS', '', 'hi', '08031234567');                                    -- not an admin
      end case;
      ok_count := ok_count + 1;
    exception when others then null; end;
  end loop;
  perform t.ok('F. All 60 attacks were refused', ok_count = 0, ok_count || ' got through');
end $$;
select t.ok('F. The attacks changed nothing', (select m = (select count(*) from memberships) and w = (select count(*) from wallet_transactions) and s = (select count(*) from seat_moves) from t.before));

-- ---------------------------------------------------------------------
-- G. Creators: 3 creators, 50 referred purchases, refunds, month-end payouts (bank and wallet)
-- ---------------------------------------------------------------------
select t.as_user(t.user(1));
update profiles set username = 'creator' || substr(id::text, 35) where id in (t.user(5), t.user(6), t.user(7));
select admin_save_creator(jsonb_build_object('username', (select username from profiles where id = t.user(5)), 'code', 'CRA', 'commission_type', 'PERCENT', 'commission_bps', 700, 'account_number', '0123456789', 'bank_name', 'GTBank', 'account_name', 'A'));
select admin_save_creator(jsonb_build_object('username', (select username from profiles where id = t.user(6)), 'code', 'CRB', 'commission_type', 'FLAT', 'commission_flat_kobo', 30000, 'first_purchase_only', true));
select admin_save_creator(jsonb_build_object('username', (select username from profiles where id = t.user(7)), 'code', 'CRC', 'commission_type', 'PERCENT', 'commission_bps', 250));
insert into auth.users (id, email, raw_user_meta_data)
select ('00000000-0000-4000-9000-' || lpad(i::text, 12, '0'))::uuid, 'fan' || i || '@stress.test', jsonb_build_object('full_name', 'Fan ' || i, 'referral_code', (array['CRA','crb','CRC'])[1 + i % 3])
from generate_series(1, 30) i;
select _post(('00000000-0000-4000-9000-' || lpad(i::text, 12, '0'))::uuid, 'WALLET', 'TOP_UP', 3000000, 'fan money', _ref('TST')) from generate_series(1, 30) i;
update listings set seats_offered = 20, status = 'LIVE', host_stopping = false, renew_paused = false;
do $$ declare i int; u uuid;
begin
  for i in 1..50 loop
    u := ('00000000-0000-4000-9000-' || lpad((1 + floor(random() * 30)::int)::text, 12, '0'))::uuid;
    perform t.as_user(u);
    begin perform join_with_wallet(t.listing(), (select email from profiles where id = u), (array[1,3,6,12])[1 + floor(random() * 4)::int]); perform t.count('fan', true);
    exception when others then perform t.count('fan', false); end;
  end loop;
end $$;
select t.ok('G. 30 fans signed up with the 3 codes', (select count(*) = 30 from referrals r join creators c on c.user_id = r.referrer_id));
select t.ok('G. Commission lines were made for fan purchases', (select count(*) > 10 from creator_earnings));
select t.ok('G. Flat-rate creator: at most one line per fan (first order only)', not exists (
  select 1 from creator_earnings e join creators c on c.id = e.creator_id where c.code = 'CRB' group by e.referred_id having count(*) > 1));
select t.ok('G. Percentage lines are exactly 7% / 2.5% of the seat price', not exists (
  select 1 from creator_earnings e join creators c on c.id = e.creator_id where c.commission_type = 'PERCENT' and e.amount_kobo <> floor(e.basis_kobo * c.commission_bps / 10000.0)));
-- half the fan months are released, a quarter refunded
update memberships set release_at = now() - interval '1 minute' where id in (select membership_id from creator_earnings where random() < 0.5);
select release_due_escrow();
select t.as_user(t.user(1));
select admin_refund(id, null, 'stress refund') from memberships where id in (select membership_id from creator_earnings) and escrow = 'HELD' and status = 'ACTIVE' and random() < 0.25;
select t.ok('G. After releases and refunds: books still right', t.books() = '', t.books());
do $$ declare i int; x creator_payouts;
begin
  perform t.as_user(t.user(1));
  for i in 1..10 loop
    perform admin_prepare_creator_payouts('Round ' || i);
    for x in select * from creator_payouts where status = 'DUE' loop
      perform admin_creator_payout_action(x.id, (array['PAID','WALLET','CANCEL'])[1 + floor(random() * 3)::int], '');
    end loop;
  end loop;
  perform admin_prepare_creator_payouts('Final');
  for x in select * from creator_payouts where status = 'DUE' loop perform admin_creator_payout_action(x.id, 'PAID', ''); end loop;
end $$;
select t.ok('G. Payouts: nothing payable is left, nothing paid twice', not exists (select 1 from creator_earnings where status = 'PAYABLE')
  and not exists (select 1 from creator_earnings e join creator_payouts x on x.id = e.payout_id where x.status = 'CANCELLED'));
select t.ok('G. Paid amount = every released commission line', (select coalesce(sum(amount_kobo), 0) from creator_payouts where status = 'PAID')
  = (select coalesce(sum(amount_kobo), 0) from creator_earnings where status = 'PAID'));
select t.ok('G. Refunded months earned no commission', not exists (select 1 from creator_earnings e join memberships m on m.id = e.membership_id
  where m.escrow in ('REFUNDED','SETTLED') and e.status <> 'CANCELLED'));
select t.ok('G. Final books check: everything adds up', t.books() = '', t.books());
select t.ok('Summary', true, (select string_agg(k || ': ' || ok || ' done, ' || refused || ' refused', ' | ' order by k) from t.stats));
