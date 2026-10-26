-- =====================================================================
--  SPLITSUB · 017_plans_renewals_creators.sql   (run after 016; safe to re-run)
--  Adds (nothing is removed):
--   1. Card payments (Flutterwave) on/off switch for admins
--   2. Plan lengths: 1, 3, 6 or 12 months, with a start date (today or up to 30 days ahead).
--      Each month is its own escrow period, so the host is paid one month at a time and
--      unused months can always be refunded.
--   3. Renewals: hosts confirm their plan 5 days before it ends ("I will renew" / "I won't renew"),
--      members answer 3 days before their seat ends, and members can switch on
--      "Auto-renew my seat from my wallet balance".
--   4. Admin can move a member to another plan or host. The unused part of the old seat is
--      credited; if the new plan costs more the member pays only the difference (never a minus balance).
--   5. Creators & partners: promo codes, links (splitsub.app/name), commission (% or flat ₦),
--      bank details, monthly payout list, and a dashboard for the creator.
--   6. Bulk messages from the admin page: email, SMS and WhatsApp.
--  Money is still integer kobo in the same immutable ledger.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. NEW SETTINGS AND COLUMNS
-- ---------------------------------------------------------------------
alter table public.platform_settings add column if not exists card_payments_enabled boolean not null default true;
alter table public.platform_settings add column if not exists host_reminder_days int not null default 5;
alter table public.platform_settings add column if not exists auto_renew_grace_hours int not null default 24;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'host_reminder_days_range') then
    alter table public.platform_settings add constraint host_reminder_days_range check (host_reminder_days between 1 and 14); end if;
  if not exists (select 1 from pg_constraint where conname = 'auto_renew_grace_range') then
    alter table public.platform_settings add constraint auto_renew_grace_range check (auto_renew_grace_hours between 0 and 168); end if;
end $$;

-- which lengths a plan can be bought for (months = periods of the plan's duration, normally 30 days)
alter table public.service_plans add column if not exists allowed_months int[] not null default '{1,3,6,12}';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'plan_allowed_months') then
    alter table public.service_plans add constraint plan_allowed_months
      check (allowed_months <@ array[1,3,6,12] and cardinality(allowed_months) between 1 and 4); end if;
end $$;

alter table public.memberships add column if not exists order_ref text;          -- shared by every month bought together
alter table public.memberships add column if not exists period_no int not null default 1;
alter table public.memberships add column if not exists periods int not null default 1;
alter table public.memberships add column if not exists auto_renew boolean not null default false;
alter table public.memberships add column if not exists renew_choice text;       -- the member's answer: YES / NO
alter table public.memberships add column if not exists auto_renew_note_at timestamptz;
alter table public.memberships add column if not exists moved_to uuid;
alter table public.memberships add column if not exists moved_from uuid;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'memberships_renew_choice_check') then
    alter table public.memberships add constraint memberships_renew_choice_check check (renew_choice is null or renew_choice in ('YES','NO')); end if;
end $$;
update public.memberships set order_ref = txn_ref where order_ref is null;
create index if not exists memberships_order_ref_idx on public.memberships (order_ref);
create index if not exists memberships_buyer_listing_idx on public.memberships (buyer_id, listing_id, ends_at);
create index if not exists memberships_tip_idx on public.memberships (status, renewed, ends_at);

-- the host's own plan cycle ("confirmed until")
alter table public.listings add column if not exists host_paid_until timestamptz;
alter table public.listings add column if not exists host_renew_asked_at timestamptz;
alter table public.listings add column if not exists host_stopping boolean not null default false;
alter table public.listings add column if not exists renew_paused boolean not null default false;
update public.listings l set host_paid_until = now() + make_interval(days => p.duration_days)
  from public.service_plans p where p.id = l.plan_id and l.host_paid_until is null and l.status in ('LIVE','PAUSED');

alter table public.payments add column if not exists months int not null default 1;
alter table public.payments add column if not exists start_date date;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'payments_months_check') then
    alter table public.payments add constraint payments_months_check check (months in (1,3,6,12)); end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. NOTIFICATIONS: new types that also go out by email
-- ---------------------------------------------------------------------
create or replace function public._notify(p_user uuid, p_type text, p_title text, p_body text default '', p_ref text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  insert into notifications (user_id, type, title, body, ref) values (p_user, p_type, p_title, coalesce(p_body, ''), p_ref);
  if p_type = any (array['PAYMENT_SUCCESS','PAYMENT_FAILED','SUBSCRIPTION_JOINED','SUBSCRIPTION_RENEWED','NEW_MEMBER','ACCESS_AVAILABLE',
      'EXPIRING','EXPIRING_HOST','EARNING_AVAILABLE','REFUND','WITHDRAWAL_REQUESTED','WITHDRAWAL_APPROVED','WITHDRAWAL_PAID',
      'WITHDRAWAL_REJECTED','DISPUTE_OPENED','DISPUTE_RESOLVED','DISPUTE_PROOF','LISTING_APPROVED','LISTING_REJECTED','LISTING_SUSPENDED',
      'REFERRAL_REWARD','REQUEST_ADDED','REQUEST_DECLINED','ADMIN_CREDIT','ADJUSTMENT','SUPPORT_REPLY','ADMIN_ALERT',
      'HOST_RENEW_ASK','HOST_NOT_RENEWING','AUTO_RENEW_FAILED','SEAT_MOVED','MOVE_PAYMENT','CREATOR_PAYOUT']) then
    select email into v_email from profiles where id = p_user;
    if coalesce(v_email, '') <> '' then
      insert into email_outbox (to_user, to_email, type, subject, body) values (p_user, v_email, p_type, left(p_title, 200), coalesce(p_body, ''));
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. HELPERS
-- ---------------------------------------------------------------------
create or replace function public._lagos_day(p timestamptz) returns text
language sql stable set search_path = public as $$ select to_char(p at time zone 'Africa/Lagos', 'DD Mon YYYY') $$;

-- The chosen calendar day -> start time. Today = now; a later day = midnight Lagos time.
create or replace function public._start_on(p_date date) returns timestamptz
language plpgsql stable set search_path = public as $$
declare v_today date := (now() at time zone 'Africa/Lagos')::date;
begin
  if p_date is null or p_date = v_today then return now(); end if;
  if p_date < v_today then raise exception 'Pick today or a later date to start.'; end if;
  if p_date > v_today + 30 then raise exception 'You can start at most 30 days from today.'; end if;
  return p_date::timestamp at time zone 'Africa/Lagos';
end $$;

create or replace function public._plan_months(p service_plans, p_months int) returns int
language plpgsql stable set search_path = public as $$
declare v int := coalesce(p_months, 1);
begin
  if not (v = any (p.allowed_months)) then
    raise exception 'This plan can be bought for % month(s).', array_to_string(array(select x from unnest(p.allowed_months) x order by x), ', ');
  end if;
  return v;
end $$;

create or replace function public._period_word(p_months int) returns text
language sql immutable as $$
  select case p_months when 1 then '1 month' when 3 then '3 months' when 6 then '6 months' when 12 then '12 months' else p_months || ' months' end $$;

-- A seat that will auto-renew keeps its place for a short grace time after it ends.
create or replace function public._occupied(p_listing uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(distinct buyer_id)::int from memberships
  where listing_id = p_listing and (status = 'DISPUTED' or (status = 'ACTIVE' and (ends_at > now()
     or (auto_renew and not renewed and coalesce(renew_choice, '') <> 'NO'
         and ends_at > now() - make_interval(hours => (select auto_renew_grace_hours from platform_settings where id = 1))))));
$$;

-- the newest period of a member's seat in a listing (the one that gets renewed)
create or replace function public._seat_tip(p_buyer uuid, p_listing uuid) returns memberships
language sql stable security definer set search_path = public as $$
  select * from memberships where buyer_id = p_buyer and listing_id = p_listing and status in ('ACTIVE','DISPUTED') and not renewed
  order by ends_at desc limit 1;
$$;

-- After later months are refunded, the newest month that is still active becomes the "newest" again,
-- so reminders, renewals and auto-renew keep working for it.
create or replace function public._fix_tip(p_buyer uuid, p_listing uuid) returns void
language sql security definer set search_path = public as $$
  update memberships set renewed = false
  where id = (select id from memberships where buyer_id = p_buyer and listing_id = p_listing and status in ('ACTIVE','DISPUTED')
              order by ends_at desc limit 1)
    and renewed
    and not exists (select 1 from memberships x where x.buyer_id = p_buyer and x.listing_id = p_listing
                    and x.status in ('ACTIVE','DISPUTED') and not x.renewed);
$$;

-- same refund as before, plus the tip fix above
create or replace function public._refund(p_id uuid, p_amount bigint, p_why text) returns void
language plpgsql security definer set search_path = public as $$
declare m memberships; v_service text; v_ref text; v_rest bigint; v_fee bigint;
begin
  select * into m from memberships where id = p_id for update;
  if not found or m.escrow <> 'HELD' then raise exception 'This payment is already settled.'; end if;
  if p_amount is null then p_amount := m.amount_kobo; end if;
  if p_amount <= 0 or p_amount > m.amount_kobo then
    raise exception 'Refund must be between ₦0.01 and %.', _naira(m.amount_kobo);
  end if;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  v_ref := _ref('RFD');
  perform _post(m.buyer_id, 'WALLET', 'REFUND', p_amount, v_service || ' refund · ' || p_why, v_ref, m.id, m.listing_id);
  perform _post(m.host_id, 'PENDING', 'EARNING_REVERSED', -m.host_kobo, v_service || ' seat refunded', v_ref, m.id, m.listing_id);
  v_rest := m.amount_kobo - p_amount;
  if v_rest > 0 then
    v_fee := _fee(v_rest);
    perform _post(m.host_id, 'EARNINGS', 'HOST_EARNING', v_rest - v_fee, v_service || ' seat · part paid after refund', v_ref, m.id, m.listing_id);
    perform _post(null, 'PLATFORM', 'PLATFORM_FEE', v_fee, v_service || ' seat fee (partial)', v_ref, m.id, m.listing_id);
    update memberships set escrow = 'SETTLED', status = 'PARTIALLY_REFUNDED', refund_kobo = p_amount where id = m.id;
  else
    update memberships set escrow = 'REFUNDED', status = 'REFUNDED', refund_kobo = p_amount where id = m.id;
  end if;
  perform _fix_tip(m.buyer_id, m.listing_id);
  perform _notify(m.buyer_id, 'REFUND', _naira(p_amount) || ' refunded to your wallet', v_service || ': ' || p_why);
  perform _notify(m.host_id, 'REFUND', 'A ' || v_service || ' seat was refunded',
    case when v_rest > 0 then 'Part of the payment was refunded to the member.' else 'The full payment was returned to the member.' end);
end $$;

-- ---------------------------------------------------------------------
-- 4. CREATOR COMMISSION (tables first, the engine uses them)
-- ---------------------------------------------------------------------
create table if not exists public.creators (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(id) on delete restrict,
  code text not null unique check (code ~ '^[A-Z0-9]{3,12}$'),
  commission_type text not null default 'PERCENT' check (commission_type in ('PERCENT','FLAT')),
  commission_bps int not null default 0 check (commission_bps between 0 and 5000),            -- 500 = 5% of the seat price
  commission_flat_kobo bigint not null default 0 check (commission_flat_kobo between 0 and 10000000),
  first_purchase_only boolean not null default false,
  bank_name text not null default '',
  account_number text not null default '',
  account_name text not null default '',
  notes text not null default '',
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.creator_payouts (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.creators(id) on delete restrict,
  period_label text not null,
  amount_kobo bigint not null check (amount_kobo > 0),
  items int not null default 0,
  bank_name text not null default '',
  account_number text not null default '',
  account_name text not null default '',
  status text not null default 'DUE' check (status in ('DUE','PAID','CANCELLED')),
  method text check (method in ('BANK','WALLET')),
  reference text not null,
  note text not null default '',
  created_by uuid,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  paid_by uuid
);
create table if not exists public.creator_earnings (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.creators(id) on delete restrict,
  referred_id uuid not null references public.profiles(id) on delete restrict,
  membership_id uuid not null unique references public.memberships(id) on delete restrict,
  basis_kobo bigint not null default 0,
  amount_kobo bigint not null check (amount_kobo > 0),
  status text not null default 'PENDING' check (status in ('PENDING','PAYABLE','PAID','CANCELLED')),
  payout_id uuid references public.creator_payouts(id) on delete set null,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index if not exists creator_earnings_creator_idx on public.creator_earnings (creator_id, status);
create index if not exists creator_payouts_creator_idx on public.creator_payouts (creator_id, created_at desc);
alter table public.creators enable row level security;
alter table public.creator_payouts enable row level security;
alter table public.creator_earnings enable row level security;
revoke all on public.creators, public.creator_payouts, public.creator_earnings from anon, authenticated;

-- Called for every paid seat month. Commission is only paid out after the host's escrow for that
-- month is released; refunded months are cancelled (see _creator_refresh).
create or replace function public._creator_commission(p_buyer uuid, p_membership uuid, p_amount bigint) returns void
language plpgsql security definer set search_path = public as $$
declare cr creators; m memberships; v_amt bigint;
begin
  select c.* into cr from referrals r join creators c on c.user_id = r.referrer_id where r.referred_id = p_buyer and c.active;
  if not found or cr.user_id = p_buyer then return; end if;
  select * into m from memberships where id = p_membership;
  if cr.first_purchase_only and exists (select 1 from creator_earnings e join memberships x on x.id = e.membership_id
       where e.creator_id = cr.id and e.referred_id = p_buyer and x.order_ref is distinct from m.order_ref) then return; end if;
  if cr.commission_type = 'PERCENT' then v_amt := floor(p_amount::numeric * cr.commission_bps / 10000);
  else v_amt := case when m.period_no = 1 then cr.commission_flat_kobo else 0 end; end if;
  if v_amt > 0 then
    insert into creator_earnings (creator_id, referred_id, membership_id, basis_kobo, amount_kobo) values (cr.id, p_buyer, p_membership, p_amount, v_amt)
    on conflict (membership_id) do nothing;
  end if;
end $$;

create or replace function public._creator_refresh() returns void
language sql security definer set search_path = public as $$
  update creator_earnings e set status = 'PAYABLE', decided_at = now() from memberships m
   where m.id = e.membership_id and e.status = 'PENDING' and m.escrow = 'RELEASED';
  update creator_earnings e set status = 'CANCELLED', decided_at = now() from memberships m
   where m.id = e.membership_id and e.status = 'PENDING' and m.escrow in ('REFUNDED','SETTLED');
$$;

-- ---------------------------------------------------------------------
-- 5. THE BUYING ENGINE: one row per month, each month is its own escrow period
-- ---------------------------------------------------------------------
create or replace function public._buy_periods(p_user uuid, p_listing uuid, p_months int, p_start timestamptz, p_contact text,
  p_payment text, p_prev uuid, p_buyer_fee bigint) returns uuid
language plpgsql security definer set search_path = public as $$
declare l listings; p service_plans; s services; v_buyer text; v_price bigint; v_fee bigint; v_ref text; v_first uuid; v_id uuid;
        v_prev uuid := p_prev; v_start timestamptz := p_start; v_end timestamptz; v_access text; v_contact text; v_auto boolean := false; i int;
begin
  select * into l from listings where id = p_listing;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  select username into v_buyer from profiles where id = p_user;
  v_price := _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct);
  v_fee := _fee(v_price);
  v_ref := _ref(case when p_prev is null then 'SUB' else 'REN' end);
  if p_prev is not null then
    select access_status, contact, auto_renew into v_access, v_contact, v_auto from memberships where id = p_prev;
  else
    v_access := case when p.access_type = 'LOGIN' then 'READY' else 'WAITING' end;
    v_contact := trim(coalesce(p_contact, ''));
  end if;
  for i in 1..p_months loop
    v_end := v_start + make_interval(days => p.duration_days);
    -- only one "newest" period may exist per seat (unique index), so close the previous one first
    if v_prev is not null then update memberships set renewed = true where id = v_prev; end if;
    insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, buyer_fee_kobo, contact, starts_at, ends_at,
                             access_status, payment_reference, txn_ref, release_at, renewed_from, order_ref, period_no, periods, auto_renew)
    values (l.id, p.id, p_user, l.host_id, v_price, v_fee, v_price - v_fee, case when i = 1 then p_buyer_fee else 0 end, v_contact, v_start, v_end,
            v_access, p_payment, case when i = 1 then v_ref else v_ref || '-' || i end,
            greatest(v_end, now() + make_interval(days => escrow_days())), v_prev, v_ref, i, p_months, v_auto)
    returning id into v_id;
    if i = 1 then v_first := v_id; end if;
    perform _post(p_user, 'WALLET', 'SUBSCRIPTION', -v_price,
      case when p_prev is null then 'Seat: ' else 'Renewal: ' end || s.name || ' · ' || p.name || case when p_months > 1 then ' · month ' || i || ' of ' || p_months else '' end,
      v_ref, v_id, l.id, p_payment);
    perform _post(l.host_id, 'PENDING', 'HOST_EARNING_PENDING', v_price - v_fee,
      s.name || ' seat · @' || v_buyer || case when p_months > 1 then ' · month ' || i || ' of ' || p_months else '' end, v_ref, v_id, l.id, p_payment);
    perform _creator_commission(p_user, v_id, v_price);
    v_prev := v_id;
    v_start := v_end;
  end loop;
  if p_buyer_fee > 0 then
    perform _post(p_user, 'WALLET', 'PURCHASE_FEE', -p_buyer_fee, 'Transaction fee · ' || s.name || case when p_prev is null then '' else ' renewal' end, v_ref, v_first, l.id, p_payment);
    perform _post(null, 'PLATFORM', 'PLATFORM_FEE', p_buyer_fee, 'Transaction fee · ' || s.name || case when p_prev is null then '' else ' renewal' end, v_ref, v_first, l.id);
  end if;
  return v_first;
end $$;

-- Join a plan: months (1/3/6/12) and a start date (today or up to 30 days ahead).
create or replace function public._join2(p_user uuid, p_listing uuid, p_contact text, p_payment text, p_months int, p_start date) returns uuid
language plpgsql security definer set search_path = public as $$
declare l listings; p service_plans; s services; v_buyer text; v_months int; v_start timestamptz; v_id uuid; v_ref text; v_ready boolean; v_end timestamptz;
begin
  perform release_due_escrow();
  perform _join_check(p_user, p_listing, p_contact);   -- also locks the listing row (no overselling)
  select * into l from listings where id = p_listing;
  if l.host_stopping then raise exception 'This plan is not open right now.'; end if;
  if exists (select 1 from memberships where listing_id = p_listing and buyer_id = p_user and status in ('ACTIVE','DISPUTED') and not renewed) then
    raise exception 'You already have a seat in this plan. Renew it from My Subs.';
  end if;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  select username into v_buyer from profiles where id = p_user;
  v_months := _plan_months(p, p_months);
  v_start := _start_on(p_start);
  v_id := _buy_periods(p_user, p_listing, v_months, v_start, p_contact, p_payment, null, buyer_fee_kobo());
  select txn_ref into v_ref from memberships where id = v_id;
  select max(ends_at) into v_end from memberships where order_ref = v_ref;
  v_ready := p.access_type = 'LOGIN';
  perform _notify(p_user, 'SUBSCRIPTION_JOINED', 'You joined ' || s.name,
    'Order ' || v_ref || ' · ' || _period_word(v_months) || ', ' || _lagos_day(v_start) || ' to ' || _lagos_day(v_end) || '. '
    || case when v_ready then 'Your access details are ready in My Subs.'
       else 'The host will send your access to ' || trim(p_contact) || '. We will let you know when it is sent.' end, v_id::text);
  perform _notify(l.host_id, 'NEW_MEMBER', 'New order for your ' || s.name || ' plan',
    '@' || v_buyer || ' paid for ' || _period_word(v_months) || ' (order ' || v_ref || ', starts ' || _lagos_day(v_start) || ').'
    || case when v_ready then '' else ' Please send access to ' || trim(p_contact) || ' and mark it as sent.' end, v_id::text);
  perform _chat_system(v_id, 'Order ' || v_ref || ' created for ' || s.name || ' · ' || p.name || ' · ' || _period_word(v_months)
    || ' (' || _lagos_day(v_start) || ' to ' || _lagos_day(v_end) || '). Use this chat for anything about this order.'
    || case when v_months > 1 then ' The host is paid one month at a time.' else '' end
    || case when v_ready then '' else ' Host: please send access to the member and tap "Mark sent".' end);
  perform _referral_check(p_user, v_id, _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct) * v_months);
  return v_id;
end $$;

-- the old entry point keeps working (1 month, starting now)
create or replace function public._join(p_user uuid, p_listing uuid, p_contact text, p_payment text) returns uuid
language sql security definer set search_path = public as $$ select public._join2(p_user, p_listing, p_contact, p_payment, 1, null) $$;

-- ---------------------------------------------------------------------
-- 6. PAYING: wallet, card (Flutterwave on/off), payment completion
-- ---------------------------------------------------------------------
do $$ begin
  if to_regprocedure('public.join_with_wallet(uuid,text)') is not null then
    execute 'alter function public.join_with_wallet(uuid,text) rename to join_with_wallet_pre017'; end if;
  if to_regprocedure('public.payment_create(uuid,text,text,bigint,uuid,text)') is not null then
    execute 'alter function public.payment_create(uuid,text,text,bigint,uuid,text) rename to payment_create_pre017'; end if;
  if to_regprocedure('public.renew_membership(uuid)') is not null then
    execute 'alter function public.renew_membership(uuid) rename to renew_membership_pre017'; end if;
end $$;
do $$ begin
  if to_regprocedure('public.join_with_wallet_pre017(uuid,text)') is not null then
    execute 'revoke all on function public.join_with_wallet_pre017(uuid,text) from public, anon, authenticated'; end if;
  if to_regprocedure('public.payment_create_pre017(uuid,text,text,bigint,uuid,text)') is not null then
    execute 'revoke all on function public.payment_create_pre017(uuid,text,text,bigint,uuid,text) from public, anon, authenticated, service_role'; end if;
  if to_regprocedure('public.renew_membership_pre017(uuid)') is not null then
    execute 'revoke all on function public.renew_membership_pre017(uuid) from public, anon, authenticated'; end if;
end $$;

create or replace function public.join_with_wallet(p_listing uuid, p_contact text default '', p_months int default 1, p_start date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_id uuid; m text;
begin
  me := _me();
  m := maintenance_on();
  if m is not null then raise exception 'Purchases are paused for maintenance. %', m; end if;
  v_id := _join2(me.id, p_listing, p_contact, null, p_months, p_start);
  return jsonb_build_object('membership_id', v_id);
end $$;

create or replace function public.payment_create(p_user uuid, p_reference text, p_purpose text, p_amount_kobo bigint,
  p_listing uuid default null, p_contact text default '', p_months int default 1, p_start date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_status text; v_email text; v_amount bigint; s platform_settings; l listings; p service_plans; v_months int := 1;
begin
  select status, email into v_status, v_email from profiles where id = p_user;
  if v_status is null then raise exception 'Account not found.'; end if;
  if v_status <> 'ACTIVE' then raise exception 'Your account is suspended. Please contact support.'; end if;
  select * into s from platform_settings where id = 1;
  if not s.card_payments_enabled then
    raise exception 'Card payments are switched off right now.%',
      case when s.manual_funding_enabled then ' Please add money by bank transfer instead.' else ' Please contact support.' end;
  end if;
  if p_purpose = 'TOPUP' then
    if p_amount_kobo is null or p_amount_kobo < s.min_topup_kobo or p_amount_kobo > s.max_topup_kobo then
      raise exception 'Enter an amount between % and %.', _naira(s.min_topup_kobo), _naira(s.max_topup_kobo);
    end if;
    v_amount := p_amount_kobo;
  elsif p_purpose = 'SEAT' then
    v_amount := _join_check(p_user, p_listing, p_contact);     -- backend seat price; the browser's amount is ignored
    select * into l from listings where id = p_listing;
    if l.host_stopping then raise exception 'This plan is not open right now.'; end if;
    select * into p from service_plans where id = l.plan_id;
    v_months := _plan_months(p, p_months);
    perform _start_on(p_start);
    v_amount := v_amount * v_months + buyer_fee_kobo();
  else
    raise exception 'Unknown payment type.';
  end if;
  insert into payments (reference, user_id, purpose, listing_id, contact, amount_kobo, months, start_date)
  values (p_reference, p_user, p_purpose, case when p_purpose = 'SEAT' then p_listing end, trim(coalesce(p_contact, '')), v_amount,
          v_months, case when p_purpose = 'SEAT' then p_start end);
  return jsonb_build_object('reference', p_reference, 'amount_kobo', v_amount, 'email', v_email);
end $$;

create or replace function public.payment_complete(p_reference text, p_paid_kobo bigint, p_currency text, p_provider_id text, p_channel text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x payments; v_ref text; v_joined boolean := false; v_mid uuid; v_msg text := ''; v_start date;
begin
  select * into x from payments where reference = p_reference for update;
  if not found then return jsonb_build_object('result', 'UNKNOWN'); end if;
  if x.status = 'SUCCESS' then
    return jsonb_build_object('result', 'ALREADY', 'purpose', x.purpose, 'amount_kobo', x.paid_kobo, 'membership_id', x.membership_id,
                              'joined', x.membership_id is not null);
  end if;
  if coalesce(p_currency, '') <> 'NGN' or p_paid_kobo is null or p_paid_kobo <= 0 then
    update payments set status = 'FAILED', note = 'Invalid currency or amount from the payment provider', verified_at = now() where reference = x.reference;
    return jsonb_build_object('result', 'FAILED');
  end if;
  v_ref := _ref('PAY');
  update payments set status = 'SUCCESS', paid_kobo = p_paid_kobo, provider_id = p_provider_id, channel = p_channel, verified_at = now(),
    note = case when p_paid_kobo <> x.amount_kobo then 'Paid amount differs from expected' else '' end
  where reference = x.reference;
  perform _post(x.user_id, 'WALLET', 'TOP_UP', p_paid_kobo, 'Added money · Online payment', v_ref, null, x.listing_id, x.reference);
  perform _notify(x.user_id, 'PAYMENT_SUCCESS', 'Payment successful', _naira(p_paid_kobo) || ' was added to your wallet.');
  if x.purpose = 'SEAT' then
    -- if the bank took a few days, a start date in the past simply becomes "today"
    v_start := case when x.start_date is null or x.start_date < (now() at time zone 'Africa/Lagos')::date then null else x.start_date end;
    begin
      v_mid := _join2(x.user_id, x.listing_id, x.contact, x.reference, coalesce(x.months, 1), v_start);
      v_joined := true;
      update payments set membership_id = v_mid where reference = x.reference;
    exception when others then
      v_msg := sqlerrm;
      perform _notify(x.user_id, 'PAYMENT_SUCCESS', 'We could not reserve your seat',
        v_msg || ' Your ' || _naira(p_paid_kobo) || ' is safe in your wallet.');
    end;
  end if;
  return jsonb_build_object('result', 'CREDITED', 'purpose', x.purpose, 'amount_kobo', p_paid_kobo, 'joined', v_joined,
                            'membership_id', v_mid, 'message', v_msg);
end $$;

-- ---------------------------------------------------------------------
-- 7. RENEWING: by hand, or automatically from the wallet
-- ---------------------------------------------------------------------
create or replace function public._renew(p_id uuid, p_months int, p_auto boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare m memberships; l listings; p service_plans; s services; st platform_settings; v_first uuid; v_start timestamptz; v_months int;
        v_buyer text; v_host_status text; v_ref text; v_end timestamptz;
begin
  select * into st from platform_settings where id = 1;
  select * into m from memberships where id = p_id for update;
  if not found then raise exception 'Subscription not found.'; end if;
  if m.renewed then raise exception 'You already renewed this subscription.'; end if;
  if m.status <> 'ACTIVE' then raise exception 'Only active subscriptions can be renewed.'; end if;
  if m.ends_at <= now() and not (m.auto_renew and m.ends_at > now() - make_interval(hours => st.auto_renew_grace_hours)) then
    raise exception 'This subscription has ended. Join the plan again from Explore.';
  end if;
  select * into l from listings where id = m.listing_id for update;
  if l.status <> 'LIVE' or l.host_stopping then raise exception 'The host has paused this plan, so it cannot be renewed right now.'; end if;
  if not p_auto and m.ends_at > now() + make_interval(days => st.renewal_window_days) then
    raise exception 'You can renew in the last % days of your subscription.', st.renewal_window_days;
  end if;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  select status into v_host_status from profiles where id = l.host_id;
  if not p.active or not s.active or v_host_status <> 'ACTIVE' then raise exception 'This service is not available right now.'; end if;
  if p_auto then
    v_months := case when m.periods = any (p.allowed_months) then m.periods else (select min(x) from unnest(p.allowed_months) x) end;
  else
    v_months := _plan_months(p, p_months);
  end if;
  v_start := greatest(m.ends_at, now());
  v_first := _buy_periods(m.buyer_id, l.id, v_months, v_start, m.contact, null, m.id, buyer_fee_kobo());
  select txn_ref into v_ref from memberships where id = v_first;
  select max(ends_at) into v_end from memberships where order_ref = v_ref;
  update memberships set renew_choice = null, auto_renew_note_at = null where id = m.id;
  select username into v_buyer from profiles where id = m.buyer_id;
  perform _notify(m.buyer_id, 'SUBSCRIPTION_RENEWED', s.name || case when p_auto then ' renewed automatically' else ' renewed' end,
    'Order ' || v_ref || ' · ' || _period_word(v_months) || ', ' || _lagos_day(v_start) || ' to ' || _lagos_day(v_end) || '.'
    || case when p_auto then ' Paid from your wallet.' else '' end, v_first::text);
  perform _notify(l.host_id, 'NEW_MEMBER', '@' || v_buyer || ' renewed their ' || s.name || ' seat',
    'Order ' || v_ref || ' · ' || _period_word(v_months) || ' until ' || _lagos_day(v_end) || '.', v_first::text);
  perform _chat_system(v_first, 'Renewal order ' || v_ref || ' created' || case when p_auto then ' automatically from the wallet' else '' end
    || ' · ' || _period_word(v_months) || ' (' || _lagos_day(v_start) || ' to ' || _lagos_day(v_end) || ').');
  return v_first;
end $$;

create or replace function public.renew_membership(p_id uuid, p_months int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_id uuid; mm text;
begin
  me := _me();
  mm := maintenance_on();
  if mm is not null then raise exception 'Purchases are paused for maintenance. %', mm; end if;
  if not exists (select 1 from memberships where id = p_id and buyer_id = me.id) then raise exception 'Only active subscriptions can be renewed.'; end if;
  v_id := _renew(p_id, p_months, false);
  return jsonb_build_object('membership_id', v_id);
end $$;

-- "Auto-renew my seat from my wallet balance when it expires"
create or replace function public.set_auto_renew(p_membership uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; n int;
begin
  me := _me();
  select * into m from memberships where id = p_membership and buyer_id = me.id;
  if not found then raise exception 'Subscription not found.'; end if;
  update memberships set auto_renew = coalesce(p_on, false), auto_renew_note_at = null,
    renew_choice = case when coalesce(p_on, false) then null else renew_choice end
  where buyer_id = me.id and listing_id = m.listing_id and status in ('ACTIVE','DISPUTED') and ends_at > now() - interval '7 days';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'This subscription has ended.'; end if;
  return jsonb_build_object('auto_renew', coalesce(p_on, false));
end $$;

-- the member's answer to "Will you renew?"
create or replace function public.member_renew_choice(p_membership uuid, p_choice text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; t memberships; v_service text;
begin
  me := _me();
  if p_choice not in ('YES','NO') then raise exception 'Pick yes or no.'; end if;
  select * into m from memberships where id = p_membership and buyer_id = me.id;
  if not found then raise exception 'Subscription not found.'; end if;
  t := _seat_tip(me.id, m.listing_id);
  if t.id is null or t.ends_at <= now() then raise exception 'This subscription has ended.'; end if;
  update memberships set renew_choice = p_choice, auto_renew = case when p_choice = 'NO' then false else auto_renew end
  where id = t.id;
  if p_choice = 'NO' then
    update memberships set auto_renew = false where buyer_id = me.id and listing_id = m.listing_id and status = 'ACTIVE' and ends_at > now();
    select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = t.plan_id;
    perform _notify(t.host_id, 'EXPIRING_HOST', '@' || me.username || ' will not renew their ' || v_service || ' seat',
      'Their seat ends on ' || _lagos_day(t.ends_at) || ' and then opens for someone new.', t.id::text);
  end if;
  return jsonb_build_object('choice', p_choice);
end $$;

-- ---------------------------------------------------------------------
-- 8. HOSTS: "Will you renew your plan?" (asked a few days before it ends)
-- ---------------------------------------------------------------------
create or replace function public._listing_cycle() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_days int;
begin
  if new.status = 'LIVE' and (tg_op = 'INSERT' or old.status is distinct from 'LIVE') then
    if new.host_paid_until is null or new.host_paid_until < now() then
      select duration_days into v_days from service_plans where id = new.plan_id;
      new.host_paid_until := now() + make_interval(days => coalesce(v_days, 30));
      new.host_renew_asked_at := null;
    end if;
    new.renew_paused := false;
    new.host_stopping := false;
  end if;
  return new;
end $$;
create or replace trigger listing_cycle before insert or update of status on public.listings
  for each row execute function public._listing_cycle();

create or replace function public.host_set_paused(p_listing uuid, p_paused boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; l listings;
begin
  me := _me();
  select * into l from listings where id = p_listing and host_id = me.id for update;
  if not found then raise exception using errcode = '42501', message = 'You can only manage your own listings.'; end if;
  if not p_paused and (l.renew_paused or l.host_stopping) then
    raise exception 'Tap "I will renew" on this listing first, so members know your plan continues.';
  end if;
  if p_paused and l.status = 'LIVE' then update listings set status = 'PAUSED', updated_at = now() where id = l.id;
  elsif not p_paused and l.status = 'PAUSED' then update listings set status = 'LIVE', updated_at = now() where id = l.id;
  else raise exception 'Only live or paused listings can be paused or resumed.';
  end if;
end $$;

create or replace function public.host_renew_answer(p_listing uuid, p_yes boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; l listings; p service_plans; s services; r record; v_refunded bigint := 0; v_n int := 0; v_until timestamptz;
        v_buyers uuid[]; v_b uuid; v_last timestamptz;
begin
  me := _me();
  select * into l from listings where id = p_listing and host_id = me.id for update;
  if not found then raise exception using errcode = '42501', message = 'You can only manage your own listings.'; end if;
  if l.status not in ('LIVE','PAUSED') then raise exception 'Only live or paused listings can be renewed.'; end if;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  if coalesce(p_yes, false) then
    v_until := greatest(coalesce(l.host_paid_until, now()), now()) + make_interval(days => p.duration_days);
    update listings set host_paid_until = v_until, host_renew_asked_at = null, host_stopping = false,
      renew_paused = false, status = case when l.renew_paused or l.host_stopping then 'LIVE' else status end, updated_at = now()
    where id = l.id;
    return jsonb_build_object('renewed', true, 'until', v_until);
  end if;
  -- "I won't renew": no new members or renewals; months that start after the plan ends are refunded now.
  v_until := greatest(coalesce(l.host_paid_until, now()), now());
  update listings set host_stopping = true, renew_paused = true, host_renew_asked_at = coalesce(host_renew_asked_at, now()),
    status = case when status = 'LIVE' then 'PAUSED' else status end, updated_at = now()
  where id = l.id;
  update memberships set auto_renew = false where listing_id = l.id and status = 'ACTIVE' and ends_at > now();
  v_buyers := array(select distinct buyer_id from memberships where listing_id = l.id and status in ('ACTIVE','DISPUTED') and ends_at > now());
  for r in select * from memberships where listing_id = l.id and status = 'ACTIVE' and escrow = 'HELD' and starts_at >= v_until order by starts_at desc loop
    perform _refund(r.id, null, 'the host is not renewing this plan');
    v_refunded := v_refunded + r.amount_kobo; v_n := v_n + 1;
  end loop;
  foreach v_b in array v_buyers loop
    select max(ends_at) into v_last from memberships where listing_id = l.id and buyer_id = v_b and status in ('ACTIVE','DISPUTED') and ends_at > now();
    perform _notify(v_b, 'HOST_NOT_RENEWING', 'Your ' || s.name || ' host is not renewing',
      case when v_last is not null then 'Your seat stays active until ' || _lagos_day(v_last) || '. ' else '' end
      || 'Any months that had not started were refunded to your wallet. You can find a new seat on Explore.', l.id::text);
  end loop;
  perform _notify_admins('ADMIN_ALERT', 'Host not renewing: ' || s.name, '@' || me.username || ' will not renew ' || s.name || ' · ' || p.name
    || '. ' || v_n || ' future month(s) refunded (' || _naira(v_refunded) || ').', l.id::text);
  return jsonb_build_object('renewed', false, 'refunded_kobo', v_refunded, 'refunded_months', v_n);
end $$;

-- ---------------------------------------------------------------------
-- 9. BACKGROUND JOB (every hour): ask hosts, pause unanswered plans, auto-renew seats
-- ---------------------------------------------------------------------
create or replace function public.process_renewals() returns jsonb
language plpgsql security definer set search_path = public as $$
declare st platform_settings; r record; n_ask int := 0; n_pause int := 0; n_auto int := 0; n_fail int := 0; v_need bigint; v_msg text;
begin
  select * into st from platform_settings where id = 1;
  for r in select l.id, l.host_id, l.host_paid_until, s.name svc, p.name plan from listings l
           join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id
           where l.status in ('LIVE','PAUSED') and not l.host_stopping and l.host_paid_until is not null and l.host_renew_asked_at is null
             and l.host_paid_until <= now() + make_interval(days => st.host_reminder_days)
           for update of l skip locked
  loop
    update listings set host_renew_asked_at = now() where id = r.id;
    perform _notify(r.host_id, 'HOST_RENEW_ASK', 'Will you renew your ' || r.svc || ' plan?',
      'Your ' || r.svc || ' · ' || r.plan || ' listing is confirmed until ' || _lagos_day(r.host_paid_until)
      || '. Open My Subs, then Shared by me, and tap "I will renew" or "I won''t renew".', r.id::text);
    n_ask := n_ask + 1;
  end loop;
  for r in select l.id, l.host_id, s.name svc from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id
           where l.status = 'LIVE' and not l.host_stopping and l.host_paid_until < now() for update of l skip locked
  loop
    update listings set status = 'PAUSED', renew_paused = true, updated_at = now() where id = r.id;
    perform _notify(r.host_id, 'HOST_RENEW_ASK', 'Your ' || r.svc || ' listing is paused',
      'You did not confirm that your plan continues, so new members cannot join. Tap "I will renew" in My Subs to open it again.', r.id::text);
    n_pause := n_pause + 1;
  end loop;
  for r in select m.id, m.buyer_id, m.listing_id, m.auto_renew_note_at, m.ends_at, s.name svc,
                  _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct)
                    * (case when m.periods = any (p.allowed_months) then m.periods else (select min(x) from unnest(p.allowed_months) x) end) price
           from memberships m join listings l on l.id = m.listing_id join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id
           where m.status = 'ACTIVE' and not m.renewed and m.auto_renew and coalesce(m.renew_choice, '') <> 'NO'
             and m.ends_at <= now() + interval '2 days' and m.ends_at > now() - make_interval(hours => st.auto_renew_grace_hours)
           order by m.ends_at
  loop
    begin
      perform _renew(r.id, null, true);
      n_auto := n_auto + 1;
    exception when others then
      v_msg := sqlerrm;
      if v_msg like 'You already renewed%' then continue; end if;   -- another run renewed it a moment ago
      n_fail := n_fail + 1;
      if r.auto_renew_note_at is null or r.auto_renew_note_at < now() - interval '20 hours' then
        update memberships set auto_renew_note_at = now() where id = r.id;
        v_need := r.price + buyer_fee_kobo() - _balance(r.buyer_id, 'WALLET');
        perform _notify(r.buyer_id, 'AUTO_RENEW_FAILED', 'We could not renew your ' || r.svc || ' seat yet',
          case when v_msg like 'Not enough money%' and v_need > 0
               then 'Add ' || _naira(v_need) || ' to your wallet before ' || _lagos_day(r.ends_at + make_interval(hours => st.auto_renew_grace_hours))
                    || ' and we will renew it automatically. After that the seat opens for someone else.'
               else v_msg || ' Your seat ends on ' || _lagos_day(r.ends_at) || '.' end, r.id::text);
      end if;
    end;
  end loop;
  return jsonb_build_object('asked_hosts', n_ask, 'paused', n_pause, 'auto_renewed', n_auto, 'auto_failed', n_fail);
end $$;

-- member reminder (3 days before by default): now with the yes/no buttons and auto-renew text
create or replace function public.send_expiry_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_days int;
begin
  select reminder_days into v_days from platform_settings where id = 1;
  for r in select m.id, m.buyer_id, m.host_id, m.ends_at, m.reminder_sent, m.host_reminder_sent, m.auto_renew, m.renew_choice, s.name, b.username buyer,
                  _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct)
                    * (case when m.periods = any (p.allowed_months) then m.periods else (select min(x) from unnest(p.allowed_months) x) end) price
           from memberships m join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id join profiles b on b.id = m.buyer_id
           join listings l on l.id = m.listing_id
           where m.status = 'ACTIVE' and not m.renewed and (not m.reminder_sent or not m.host_reminder_sent)
             and m.ends_at > now() and m.ends_at <= now() + make_interval(days => v_days)
           for update of m skip locked
  loop
    if not r.reminder_sent then
      if coalesce(r.renew_choice, '') <> 'NO' then
        perform _notify(r.buyer_id, 'EXPIRING', 'Your ' || r.name || ' seat ends soon',
          'It ends on ' || _lagos_day(r.ends_at) || '. ' || case when r.auto_renew
            then 'Auto-renew is on: keep at least ' || _naira(r.price + buyer_fee_kobo()) || ' in your wallet and we renew it for you.'
            else 'Open My Subs and tap "I will renew" or "I won''t renew".' end, r.id::text);
        n := n + 1;
      end if;
      update memberships set reminder_sent = true where id = r.id;
    end if;
    if not r.host_reminder_sent then
      perform _notify(r.host_id, 'EXPIRING_HOST', '@' || r.buyer || '''s ' || r.name || ' seat ends soon',
        'It ends on ' || _lagos_day(r.ends_at) || '. If they renew, you get paid again; if not, the seat opens up.', r.id::text);
      update memberships set host_reminder_sent = true where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 10. WHAT THE APPS SEE
-- ---------------------------------------------------------------------
create or replace function public._listing_obj(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', l.id, 'status', l.status, 'service_id', s.id, 'service', s.name, 'category', s.category,
    'logo_color', s.logo_color, 'logo_url', s.logo_url, 'sharing_rules', s.sharing_rules,
    'plan_id', p.id, 'plan', p.name, 'access_type', p.access_type, 'duration_days', p.duration_days,
    'allowed_months', to_jsonb(p.allowed_months),
    'customer_instructions', p.customer_instructions,
    'normal_kobo', p.normal_price_kobo, 'compare_kobo', coalesce(p.compare_price_kobo, p.normal_price_kobo), 'markup_pct', l.markup_pct,
    'seat_kobo', _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct),
    'buyer_fee_kobo', buyer_fee_kobo(),
    'total_kobo', _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct) + buyer_fee_kobo(),
    'savings_kobo', greatest(coalesce(p.compare_price_kobo, p.normal_price_kobo) - _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct), 0),
    'seats_total', l.seats_offered, 'seats_occupied', least(_occupied(l.id), l.seats_offered),
    'seats_available', greatest(l.seats_offered - _occupied(l.id), 0),
    'host_id', l.host_id, 'host_username', h.username, 'host_name', split_part(h.full_name, ' ', 1),
    'host_verified', h.verified_host, 'note', l.note,
    'members_total', (select count(*) from memberships m where m.listing_id = l.id),
    'created_at', l.created_at)
  from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id join profiles h on h.id = l.host_id
  where l.id = p_id;
$$;

create or replace function public.public_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'settings', (select jsonb_build_object('site_name', site_name, 'hero_title', hero_title, 'hero_text', hero_text, 'notice', notice,
                   'support_whatsapp', support_whatsapp, 'support_whatsapp_link', support_whatsapp_link, 'support_email', support_email,
                   'categories', to_jsonb(categories), 'min_withdrawal_kobo', min_withdrawal_kobo, 'min_topup_kobo', min_topup_kobo,
                   'max_topup_kobo', max_topup_kobo, 'renewal_window_days', renewal_window_days, 'reminder_days', reminder_days,
                   'host_reminder_days', host_reminder_days, 'auto_renew_grace_hours', auto_renew_grace_hours,
                   'buyer_fee_kobo', buyer_fee_kobo(), 'withdrawal_fee_kobo', withdrawal_fee_kobo(), 'withdrawal_fee_tiers', withdrawal_fee_tiers, 'escrow_days', escrow_days(),
                   'agreement_text', _agreement_text(),
                   'maintenance', case when maintenance_mode then maintenance_message end,
                   'manual_funding', manual_funding_enabled, 'card_payments', card_payments_enabled) from platform_settings where id = 1),
    'fee_bps', platform_fee_bps(),
    'promos', public_promos(),
    'services', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'category', s.category, 'logo_color', s.logo_color, 'logo_url', s.logo_url,
        'description', s.description, 'sharing_rules', s.sharing_rules,
        'plans', (select jsonb_agg(jsonb_build_object(
            'id', p.id, 'name', p.name, 'normal_kobo', p.normal_price_kobo, 'compare_kobo', coalesce(p.compare_price_kobo, p.normal_price_kobo), 'max_seats', p.max_seats, 'access_type', p.access_type,
            'duration_days', p.duration_days, 'allowed_months', to_jsonb(p.allowed_months), 'min_markup_pct', p.min_markup_pct, 'max_markup_pct', p.max_markup_pct,
            'host_proof_required', p.host_proof_required, 'verification_required', p.verification_required,
            'host_instructions', p.host_instructions, 'customer_instructions', p.customer_instructions) order by p.sort, p.name)
          from service_plans p where p.service_id = s.id and p.active)) order by s.sort, s.name)
      from services s where s.active and exists (select 1 from service_plans p where p.service_id = s.id and p.active)), '[]'::jsonb));
$$;

-- pending seat move for a member's seat (used below)
create table if not exists public.seat_moves (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.memberships(id) on delete restrict,
  buyer_id uuid not null references public.profiles(id) on delete restrict,
  from_listing uuid not null references public.listings(id) on delete restrict,
  to_listing uuid not null references public.listings(id) on delete restrict,
  pay_old_host boolean not null default true,
  contact text not null default '',
  note text not null default '',
  status text not null default 'AWAITING_PAYMENT' check (status in ('AWAITING_PAYMENT','DONE','CANCELLED','DECLINED')),
  quoted_difference_kobo bigint not null default 0,
  new_membership_id uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create unique index if not exists seat_moves_one_open on public.seat_moves (buyer_id, from_listing) where status = 'AWAITING_PAYMENT';
alter table public.seat_moves enable row level security;
revoke all on public.seat_moves from anon, authenticated;

create or replace function public.my_subscriptions() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; st platform_settings;
begin
  me := _me();
  select * into st from platform_settings where id = 1;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', m.id, 'listing_id', m.listing_id, 'service', s.name, 'plan', p.name, 'logo_color', s.logo_color, 'logo_url', s.logo_url,
    'access_type', p.access_type, 'host_username', h.username, 'amount_kobo', m.amount_kobo, 'refund_kobo', m.refund_kobo,
    'buyer_fee_kobo', m.buyer_fee_kobo, 'total_kobo', m.amount_kobo + m.buyer_fee_kobo, 'txn_ref', m.txn_ref, 'order_ref', m.order_ref,
    'period_no', m.period_no, 'periods', m.periods,
    'order_total_kobo', (select sum(x.amount_kobo + x.buyer_fee_kobo) from memberships x where x.order_ref = m.order_ref),
    'first_txn_ref', (select x.txn_ref from memberships x where x.order_ref = m.order_ref and x.period_no = 1 limit 1),
    'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'order_status', _order_status(m), 'completed_at', m.completed_at,
    'access_status', m.access_status, 'renewed', m.renewed, 'contact', m.contact,
    'paid_until', t.ends_at, 'tip_id', t.id, 'auto_renew', coalesce(t.auto_renew, false), 'renew_choice', t.renew_choice,
    'months_ahead', (select count(*) from memberships x where x.buyer_id = me.id and x.listing_id = m.listing_id and x.status = 'ACTIVE' and x.starts_at > now()),
    'allowed_months', to_jsonb(p.allowed_months), 'duration_days', p.duration_days,
    'renew_price_kobo', case when l.status = 'LIVE' and not l.host_stopping then _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct) end,
    'host_stopping', l.host_stopping,
    'can_renew', (t.id is not null and t.status = 'ACTIVE' and t.ends_at > now() and t.ends_at <= now() + make_interval(days => st.renewal_window_days)
                  and l.status = 'LIVE' and not l.host_stopping and p.active and s.active),
    'ask_renew', (t.id is not null and t.status = 'ACTIVE' and t.ends_at > now() and t.ends_at <= now() + make_interval(days => st.reminder_days)
                  and t.renew_choice is null and not coalesce(t.auto_renew, false)),
    'can_complete', (m.status = 'ACTIVE' and m.completed_at is null and m.access_status in ('READY','SENT')),
    'moved_to', m.moved_to,
    'move', (select jsonb_build_object('id', sm.id, 'service', ts.name, 'plan', tp.name, 'host', th.username,
               'difference_kobo', sm.quoted_difference_kobo, 'note', sm.note, 'created_at', sm.created_at)
             from seat_moves sm join listings tl on tl.id = sm.to_listing join service_plans tp on tp.id = tl.plan_id
             join services ts on ts.id = tp.service_id join profiles th on th.id = tl.host_id
             where sm.buyer_id = me.id and sm.from_listing = m.listing_id and sm.status = 'AWAITING_PAYMENT' limit 1),
    'unread', (select count(*) from order_messages x where x.membership_id = m.id and x.sender_role <> 'SYSTEM'
               and x.sender_id is distinct from me.id and x.id > coalesce((select r.last_read_id from order_reads r where r.membership_id = m.id and r.user_id = me.id), 0)),
    'dispute', (select jsonb_build_object('id', d.id, 'status', d.status, 'reason', d.reason, 'resolution', d.resolution, 'raised_by_role', d.raised_by_role)
                from disputes d where d.membership_id = m.id order by d.created_at desc limit 1))
    order by m.starts_at desc)
  from memberships m join listings l on l.id = m.listing_id join service_plans p on p.id = m.plan_id
  join services s on s.id = p.service_id join profiles h on h.id = m.host_id
  left join lateral (select * from _seat_tip(m.buyer_id, m.listing_id)) t on true
  where m.buyer_id = me.id), '[]'::jsonb);
end $$;

create or replace function public.my_listings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; st platform_settings;
begin
  me := _me();
  select * into st from platform_settings where id = 1;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', l.id, 'status', l.status, 'service', s.name, 'plan', p.name, 'plan_id', p.id, 'logo_color', s.logo_color, 'logo_url', s.logo_url,
      'access_type', p.access_type, 'duration_days', p.duration_days, 'normal_kobo', p.normal_price_kobo, 'max_seats', p.max_seats,
      'min_markup_pct', p.min_markup_pct, 'max_markup_pct', p.max_markup_pct, 'markup_pct', l.markup_pct, 'seats_offered', l.seats_offered,
      'seats_occupied', _occupied(l.id),
      'seat_kobo', _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct),
      'fee_kobo', _fee(_seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct)),
      'host_kobo', _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct) - _fee(_seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct)),
      'host_proof_required', p.host_proof_required, 'host_instructions', p.host_instructions,
      'note', l.note, 'access_details', coalesce(a.details, ''), 'proof_uploaded', l.proof_path <> '', 'proof_note', l.proof_note,
      'proof_status', l.proof_status,
      'proof_reason', coalesce((select h.reason from host_proofs h where h.listing_id = l.id order by h.submitted_at desc limit 1), ''),
      'agreement_accepted_at', l.agreement_accepted_at,
      'review_note', l.review_note, 'created_at', l.created_at,
      'host_paid_until', l.host_paid_until, 'host_stopping', l.host_stopping, 'renew_paused', l.renew_paused,
      'ask_renew', (l.status in ('LIVE','PAUSED') and l.host_paid_until is not null
                    and (l.renew_paused or l.host_paid_until <= now() + make_interval(days => st.host_reminder_days))),
      'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'buyer_username', b.username, 'buyer_name', split_part(b.full_name, ' ', 1),
            'contact', m.contact, 'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'access_status', m.access_status,
            'host_kobo', m.host_kobo, 'escrow', m.escrow, 'txn_ref', m.txn_ref, 'release_at', m.release_at,
            'order_status', _order_status(m), 'completed_at', m.completed_at, 'period_no', m.period_no, 'periods', m.periods,
            'auto_renew', m.auto_renew, 'renew_choice', m.renew_choice, 'renewed', m.renewed,
            'unread', (select count(*) from order_messages x where x.membership_id = m.id and x.sender_role <> 'SYSTEM'
                       and x.sender_id is distinct from me.id and x.id > coalesce((select r.last_read_id from order_reads r where r.membership_id = m.id and r.user_id = me.id), 0)))
            order by m.starts_at desc)
          from memberships m join profiles b on b.id = m.buyer_id where m.listing_id = l.id), '[]'::jsonb),
      'disputes', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'membership_id', d.membership_id, 'status', d.status,
            'reason', d.reason, 'details', d.details, 'host_response', d.host_response, 'resolution', d.resolution,
            'raised_by_role', d.raised_by_role, 'created_at', d.created_at)
            order by d.created_at desc) from disputes d where d.listing_id = l.id), '[]'::jsonb))
    order by l.created_at desc)
  from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id
  left join listing_access a on a.listing_id = l.id
  where l.host_id = me.id), '[]'::jsonb);
end $$;

-- the host marks access as sent once for the whole order (every month of it)
create or replace function public.host_mark_access_sent(p_membership uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; v_service text;
begin
  me := _me();
  select * into m from memberships where id = p_membership and host_id = me.id for update;
  if not found then raise exception using errcode = '42501', message = 'You can only update your own members.'; end if;
  if m.status not in ('ACTIVE','DISPUTED') then raise exception 'This seat is no longer active.'; end if;
  update memberships set access_status = 'SENT'
   where buyer_id = m.buyer_id and listing_id = m.listing_id and status in ('ACTIVE','DISPUTED') and ends_at > now() and access_status <> 'SENT';
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  perform _notify(m.buyer_id, 'ACCESS_AVAILABLE', 'Your ' || v_service || ' access was sent',
    'The host sent your access to ' || m.contact || '. Check your inbox or phone.');
end $$;

-- receipts: an order of several months shows the whole order
create or replace function public._receipt(p_ref text, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m memberships; w withdrawals; u profiles; v_item text; v_method text; v_host text; v_chan text; v_sum bigint; v_fees bigint; v_end timestamptz;
        v_n int; v_refund bigint;
begin
  p_ref := trim(coalesce(p_ref, ''));
  if p_ref = '' then return null; end if;
  select * into m from memberships where txn_ref = p_ref and (p_user is null or buyer_id = p_user);
  if found then
    select * into u from profiles where id = m.buyer_id;
    select s.name || ' · ' || p.name into v_item from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
    select username into v_host from profiles where id = m.host_id;
    if m.payment_reference is not null then
      select channel into v_chan from payments where reference = m.payment_reference;
      v_method := 'Flutterwave' || case when coalesce(v_chan, '') <> '' then ' (' || v_chan || ')' else '' end;
    else v_method := 'SplitSub wallet'; end if;
    if m.period_no = 1 and m.periods > 1 and m.order_ref is not null then
      select sum(amount_kobo), sum(buyer_fee_kobo), max(ends_at), count(*), sum(refund_kobo) into v_sum, v_fees, v_end, v_n, v_refund
      from memberships where order_ref = m.order_ref;
      v_item := v_item || ' · ' || _period_word(v_n);
    else
      v_sum := m.amount_kobo; v_fees := m.buyer_fee_kobo; v_end := m.ends_at; v_refund := m.refund_kobo;
      if m.periods > 1 then v_item := v_item || ' · month ' || m.period_no || ' of ' || m.periods; end if;
    end if;
    return jsonb_build_object('kind', 'PURCHASE', 'txn_id', m.txn_ref, 'created_at', m.created_at,
      'user', jsonb_build_object('name', u.full_name, 'username', u.username, 'email', u.email),
      'item', v_item, 'host', v_host, 'period_start', m.starts_at, 'period_end', v_end,
      'price_kobo', v_sum, 'fee_kobo', v_fees, 'total_kobo', v_sum + v_fees,
      'refund_kobo', v_refund, 'method', v_method,
      'status', case m.status when 'REFUNDED' then 'Refunded' when 'PARTIALLY_REFUNDED' then 'Partly refunded' when 'DISPUTED' then 'Successful (under review)' else 'Successful' end);
  end if;
  select * into w from withdrawals where (ledger_reference = p_ref or id::text = p_ref) and (p_user is null or user_id = p_user);
  if found then
    select * into u from profiles where id = w.user_id;
    return jsonb_build_object('kind', 'WITHDRAWAL', 'txn_id', w.ledger_reference, 'created_at', w.created_at,
      'user', jsonb_build_object('name', u.full_name, 'username', u.username, 'email', u.email),
      'item', 'Withdrawal to ' || w.bank_name, 'account_name', w.account_name, 'account', '******' || right(w.account_number, 4),
      'price_kobo', w.amount_kobo, 'fee_kobo', w.fee_kobo, 'total_kobo', coalesce(w.payout_kobo, w.amount_kobo),
      'method', 'Bank transfer', 'paid_at', w.paid_at,
      'status', case w.status when 'PENDING' then 'Requested' when 'APPROVED' then 'Approved' when 'PAID' then 'Paid' else 'Returned to balance' end);
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- 11. ADMIN: settings, plan lengths, refunds that also cover future months
-- ---------------------------------------------------------------------
create or replace function public.admin_save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare old platform_settings; v_link text; v_mail text; v_acc text;
begin
  perform _need_admin();
  select * into old from platform_settings where id = 1 for update;
  v_link := case when p ? 'support_whatsapp_link' then trim(coalesce(p ->> 'support_whatsapp_link', '')) end;
  if v_link is not null and v_link <> '' and v_link !~* '^https://(wa\.me|wa\.link|api\.whatsapp\.com|chat\.whatsapp\.com)/\S+$' then
    raise exception 'Use a WhatsApp link, for example https://wa.me/2348012345678 or a chat.whatsapp.com invite link.';
  end if;
  v_mail := case when p ? 'admin_notify_email' then lower(trim(coalesce(p ->> 'admin_notify_email', ''))) end;
  if v_mail is not null and v_mail <> '' and v_mail !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    raise exception 'Enter a valid email address for admin alerts, for example support@splitsub.app.';
  end if;
  v_acc := case when p ? 'manual_account_number' then regexp_replace(coalesce(p ->> 'manual_account_number', ''), '\s', '', 'g') end;
  if v_acc is not null and v_acc !~ '^[0-9]{6,20}$' then
    raise exception 'The account number must be digits only (6 to 20 digits).';
  end if;
  if p ? 'manual_bank_name' and length(trim(coalesce(p ->> 'manual_bank_name', ''))) not between 2 and 60 then
    raise exception 'Enter the bank name.';
  end if;
  if p ? 'manual_account_name' and length(trim(coalesce(p ->> 'manual_account_name', ''))) not between 2 and 100 then
    raise exception 'Enter the account name.';
  end if;
  if p ? 'host_reminder_days' and coalesce((p ->> 'host_reminder_days')::int, 0) not between 1 and 14 then
    raise exception 'Ask hosts between 1 and 14 days before their plan ends.';
  end if;
  if p ? 'auto_renew_grace_hours' and coalesce((p ->> 'auto_renew_grace_hours')::int, -1) not between 0 and 168 then
    raise exception 'Keep an auto-renew seat for 0 to 168 hours after it ends.';
  end if;
  update platform_settings set
    site_name = coalesce(nullif(trim(p ->> 'site_name'), ''), site_name),
    hero_title = coalesce(nullif(trim(p ->> 'hero_title'), ''), hero_title),
    hero_text = coalesce(p ->> 'hero_text', hero_text),
    notice = coalesce(p ->> 'notice', notice),
    support_whatsapp = coalesce(regexp_replace(p ->> 'support_whatsapp', '\D', '', 'g'), support_whatsapp),
    support_whatsapp_link = coalesce(v_link, support_whatsapp_link),
    support_email = coalesce(p ->> 'support_email', support_email),
    categories = coalesce((select array_agg(trim(x)) from jsonb_array_elements_text(p -> 'categories') x where trim(x) <> ''), categories),
    min_withdrawal_kobo = coalesce((p ->> 'min_withdrawal_kobo')::bigint, min_withdrawal_kobo),
    min_topup_kobo = coalesce((p ->> 'min_topup_kobo')::bigint, min_topup_kobo),
    max_topup_kobo = coalesce((p ->> 'max_topup_kobo')::bigint, max_topup_kobo),
    auto_approve_listings = coalesce((p ->> 'auto_approve_listings')::boolean, auto_approve_listings),
    renewal_window_days = coalesce((p ->> 'renewal_window_days')::int, renewal_window_days),
    reminder_days = coalesce((p ->> 'reminder_days')::int, reminder_days),
    host_reminder_days = coalesce((p ->> 'host_reminder_days')::int, host_reminder_days),
    auto_renew_grace_hours = coalesce((p ->> 'auto_renew_grace_hours')::int, auto_renew_grace_hours),
    card_payments_enabled = coalesce((p ->> 'card_payments_enabled')::boolean, card_payments_enabled),
    maintenance_mode = coalesce((p ->> 'maintenance_mode')::boolean, maintenance_mode),
    maintenance_message = coalesce(nullif(left(trim(p ->> 'maintenance_message'), 300), ''), maintenance_message),
    manual_funding_enabled = coalesce((p ->> 'manual_funding_enabled')::boolean, manual_funding_enabled),
    manual_bank_name = coalesce(nullif(trim(p ->> 'manual_bank_name'), ''), manual_bank_name),
    manual_account_number = coalesce(nullif(v_acc, ''), manual_account_number),
    manual_account_name = coalesce(nullif(trim(p ->> 'manual_account_name'), ''), manual_account_name),
    admin_notify_email = coalesce(v_mail, admin_notify_email),
    updated_at = now()
  where id = 1;
  perform _audit('UPDATE_SETTINGS', 'platform_settings', '1', to_jsonb(old), (select to_jsonb(s) from platform_settings s where id = 1));
end $$;

-- quick switch for card payments (Flutterwave), used by the button on the admin dashboard
create or replace function public.admin_set_card_payments(p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_old boolean;
begin
  perform _need_admin();
  select card_payments_enabled into v_old from platform_settings where id = 1 for update;
  update platform_settings set card_payments_enabled = coalesce(p_on, false), updated_at = now() where id = 1;
  perform _audit(case when coalesce(p_on, false) then 'CARD_PAYMENTS_ON' else 'CARD_PAYMENTS_OFF' end, 'platform_settings', '1',
    jsonb_build_object('card_payments_enabled', v_old), jsonb_build_object('card_payments_enabled', coalesce(p_on, false)));
  return jsonb_build_object('card_payments', coalesce(p_on, false),
    'manual_funding', (select manual_funding_enabled from platform_settings where id = 1));
end $$;

create or replace function public.admin_save_plan(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare old service_plans; v_id uuid; v_new service_plans; v_months int[];
begin
  perform _need_admin();
  if length(trim(coalesce(p ->> 'name', ''))) < 2 then raise exception 'Enter the plan name.'; end if;
  if coalesce((p ->> 'normal_price_kobo')::bigint, 0) <= 0 then raise exception 'Enter the normal price.'; end if;
  if coalesce((p ->> 'max_seats')::int, 0) not between 1 and 20 then raise exception 'Maximum seats must be between 1 and 20.'; end if;
  if coalesce((p ->> 'min_markup_pct')::int, 0) < 10 or coalesce((p ->> 'max_markup_pct')::int, 99) > 30
     or (p ->> 'min_markup_pct')::int > (p ->> 'max_markup_pct')::int then
    raise exception using message = 'Markup must stay between 10% and 30%, and the minimum cannot be above the maximum.';
  end if;
  if jsonb_typeof(p -> 'allowed_months') = 'array' then
    select array_agg(distinct x::int order by x::int) into v_months from jsonb_array_elements_text(p -> 'allowed_months') x;
    if v_months is null or not (v_months <@ array[1,3,6,12]) then raise exception 'Tick at least one length: 1, 3, 6 or 12 months.'; end if;
  end if;
  if nullif(p ->> 'id', '') is not null then
    select * into old from service_plans where id = (p ->> 'id')::uuid for update;
    if not found then raise exception 'Plan not found.'; end if;
    update service_plans set name = trim(p ->> 'name'), normal_price_kobo = (p ->> 'normal_price_kobo')::bigint,
      compare_price_kobo = nullif((p ->> 'compare_price_kobo')::bigint, 0),
      max_seats = (p ->> 'max_seats')::int, access_type = p ->> 'access_type', duration_days = (p ->> 'duration_days')::int,
      min_markup_pct = (p ->> 'min_markup_pct')::int, max_markup_pct = (p ->> 'max_markup_pct')::int,
      verification_required = (p ->> 'verification_required')::boolean, host_proof_required = (p ->> 'host_proof_required')::boolean,
      active = (p ->> 'active')::boolean, customer_instructions = coalesce(p ->> 'customer_instructions', ''),
      host_instructions = coalesce(p ->> 'host_instructions', ''), notes = coalesce(p ->> 'notes', ''),
      allowed_months = coalesce(v_months, allowed_months),
      sort = coalesce((p ->> 'sort')::int, 0), updated_at = now()
    where id = old.id returning * into v_new;
    v_id := v_new.id;
    update listings l set seats_offered = greatest(_occupied(l.id), v_new.max_seats), updated_at = now()
      where l.plan_id = v_id and l.seats_offered > v_new.max_seats;
    update listings l set markup_pct = least(greatest(l.markup_pct, v_new.min_markup_pct), v_new.max_markup_pct), updated_at = now()
      where l.plan_id = v_id and (l.markup_pct < v_new.min_markup_pct or l.markup_pct > v_new.max_markup_pct);
    perform _audit('UPDATE_PLAN', 'service_plan', v_id::text, to_jsonb(old), to_jsonb(v_new));
  else
    insert into service_plans (service_id, name, normal_price_kobo, compare_price_kobo, max_seats, access_type, duration_days, min_markup_pct, max_markup_pct,
      verification_required, host_proof_required, active, customer_instructions, host_instructions, notes, sort, allowed_months)
    values ((p ->> 'service_id')::uuid, trim(p ->> 'name'), (p ->> 'normal_price_kobo')::bigint, nullif((p ->> 'compare_price_kobo')::bigint, 0), (p ->> 'max_seats')::int, p ->> 'access_type',
      coalesce((p ->> 'duration_days')::int, 30), (p ->> 'min_markup_pct')::int, (p ->> 'max_markup_pct')::int,
      coalesce((p ->> 'verification_required')::boolean, true), coalesce((p ->> 'host_proof_required')::boolean, true),
      coalesce((p ->> 'active')::boolean, true), coalesce(p ->> 'customer_instructions', ''), coalesce(p ->> 'host_instructions', ''),
      coalesce(p ->> 'notes', ''), coalesce((p ->> 'sort')::int, 0), coalesce(v_months, '{1,3,6,12}'))
    returning * into v_new;
    v_id := v_new.id;
    perform _audit('CREATE_PLAN', 'service_plan', v_id::text, null, to_jsonb(v_new));
  end if;
  return jsonb_build_object('id', v_id);
exception
  when unique_violation then raise exception 'This service already has a plan with that name.';
  when check_violation then raise exception 'Some values are outside the allowed limits. Check price, seats, days and access type.';
end $$;

-- A full refund of the current month also refunds the months that have not started yet.
create or replace function public.admin_refund(p_id uuid, p_amount_kobo bigint default null, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare v_full bigint; m memberships; r record;
begin
  perform _need_admin();
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write the reason for the refund.'; end if;
  select * into m from memberships where id = p_id;
  v_full := m.amount_kobo;
  perform _refund(p_id, p_amount_kobo, trim(p_note));
  update disputes set status = 'RESOLVED', resolution = case when coalesce(p_amount_kobo, v_full) < v_full then 'PARTIAL_REFUND' else 'REFUND' end,
    refund_kobo = coalesce(p_amount_kobo, v_full), admin_note = trim(p_note), resolved_by = auth.uid(), resolved_at = now(), updated_at = now()
  where membership_id = p_id and status in ('OPEN','IN_REVIEW');
  if p_amount_kobo is null or p_amount_kobo >= v_full then
    for r in select id from memberships where buyer_id = m.buyer_id and listing_id = m.listing_id and status = 'ACTIVE' and escrow = 'HELD'
             and starts_at > now() and id <> p_id order by starts_at desc loop
      perform _refund(r.id, null, 'later month of a refunded seat');
    end loop;
  end if;
  perform _audit(case when coalesce(p_amount_kobo, v_full) < v_full then 'PARTIAL_REFUND' else 'REFUND' end, 'membership', p_id::text, null,
    jsonb_build_object('refund_kobo', coalesce(p_amount_kobo, v_full)), p_note);
end $$;

create or replace function public.admin_memberships(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'service', s.name, 'plan', p.name, 'buyer', b.username, 'host', h.username,
      'buyer_id', m.buyer_id, 'listing_id', m.listing_id,
      'amount_kobo', m.amount_kobo, 'fee_kobo', m.fee_kobo, 'host_kobo', m.host_kobo, 'refund_kobo', m.refund_kobo, 'contact', m.contact,
      'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'escrow', m.escrow, 'access_status', m.access_status,
      'txn_ref', m.txn_ref, 'buyer_fee_kobo', m.buyer_fee_kobo, 'release_at', m.release_at, 'completed_at', m.completed_at,
      'order_ref', m.order_ref, 'period_no', m.period_no, 'periods', m.periods, 'auto_renew', m.auto_renew, 'renew_choice', m.renew_choice,
      'renewed', m.renewed, 'moved_to', m.moved_to, 'moved_from', m.moved_from,
      'pending_move', exists (select 1 from seat_moves sm where sm.buyer_id = m.buyer_id and sm.from_listing = m.listing_id and sm.status = 'AWAITING_PAYMENT'))
      order by m.created_at desc)
    from (select * from memberships where p_status is null or p_status = '' or status = p_status order by created_at desc limit 300) m
    join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id
    join profiles b on b.id = m.buyer_id join profiles h on h.id = m.host_id), '[]'::jsonb);
end $$;

create or replace function public.admin_listing_detail(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l listings;
begin
  perform _need_admin();
  select * into l from listings where id = p_id;
  if not found then raise exception 'Listing not found.'; end if;
  return _listing_obj(p_id) || jsonb_build_object(
    'access_details', coalesce((select details from listing_access where listing_id = p_id), ''),
    'proof_path', l.proof_path, 'proof_note', l.proof_note, 'proof_status', l.proof_status, 'review_note', l.review_note, 'submitted_at', l.submitted_at,
    'agreement_at', l.agreement_accepted_at, 'agreement_text', l.agreement_text,
    'host_paid_until', l.host_paid_until, 'host_stopping', l.host_stopping, 'renew_paused', l.renew_paused,
    'proofs', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'file_path', h.file_path, 'status', h.status, 'reason', h.reason,
        'submitted_at', h.submitted_at) order by h.submitted_at desc) from host_proofs h where h.listing_id = p_id), '[]'::jsonb),
    'host_email', (select email from profiles where id = l.host_id), 'host_phone', (select phone from profiles where id = l.host_id),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'buyer', b.username, 'contact', m.contact, 'status', m.status,
        'escrow', m.escrow, 'amount_kobo', m.amount_kobo, 'starts_at', m.starts_at, 'ends_at', m.ends_at, 'period_no', m.period_no, 'periods', m.periods,
        'auto_renew', m.auto_renew) order by m.starts_at desc)
      from memberships m join profiles b on b.id = m.buyer_id where m.listing_id = p_id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 12. MOVING A MEMBER TO ANOTHER PLAN OR HOST (admin)
--  * The unused part of the old seat (today until the end, plus months not started) is credited.
--    The old host keeps the money for the days already used (or nothing, if the admin chooses).
--  * The new seat keeps the same end date. It costs the new plan's price for those days.
--  * New plan cheaper  -> the change stays in the member's wallet.
--    New plan dearer   -> the member pays only the difference (never a minus balance), or SplitSub covers it.
-- ---------------------------------------------------------------------
create or replace function public._move_plan(p_membership uuid, p_target uuid, p_pay_old boolean) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m memberships; tl listings; tp service_plans; ts services; v_price bigint; r record; v_old jsonb := '[]'::jsonb; v_new jsonb := '[]'::jsonb;
        v_credit bigint := 0; v_cost bigint := 0; v_unused bigint; v_from timestamptz; v_c bigint; v_span numeric; v_total numeric; v_end timestamptz;
begin
  select * into m from memberships where id = p_membership;
  if not found then raise exception 'Seat not found.'; end if;
  select * into tl from listings where id = p_target;
  if not found then raise exception 'Pick the plan to move to.'; end if;
  select * into tp from service_plans where id = tl.plan_id;
  select * into ts from services where id = tp.service_id;
  v_price := _seat_price(tp.normal_price_kobo, tp.max_seats, tl.markup_pct);
  for r in select * from memberships x where x.buyer_id = m.buyer_id and x.listing_id = m.listing_id
           and x.status in ('ACTIVE','DISPUTED') and x.ends_at > now() order by x.starts_at loop
    if r.status = 'DISPUTED' then raise exception 'This seat has an open report. Close the report first.'; end if;
    if r.escrow <> 'HELD' then raise exception 'Part of this seat was already paid to the host. Refund it by hand instead.'; end if;
    v_from := greatest(r.starts_at, now());
    v_total := extract(epoch from (r.ends_at - r.starts_at));
    v_span := extract(epoch from (r.ends_at - v_from));
    if not coalesce(p_pay_old, true) or r.starts_at >= now() then v_unused := r.amount_kobo;
    else v_unused := least(r.amount_kobo, (floor(r.amount_kobo * v_span / v_total / 100) * 100)::bigint); end if;
    v_c := greatest(100, (floor(v_price * v_span / (tp.duration_days * 86400.0) / 100) * 100)::bigint);
    v_credit := v_credit + v_unused;
    v_cost := v_cost + v_c;
    v_end := r.ends_at;
    v_old := v_old || jsonb_build_object('id', r.id, 'unused_kobo', v_unused, 'amount_kobo', r.amount_kobo);
    v_new := v_new || jsonb_build_object('starts_at', v_from, 'ends_at', r.ends_at, 'price_kobo', v_c);
  end loop;
  if jsonb_array_length(v_old) = 0 then raise exception 'This seat is not active, so it cannot be moved.'; end if;
  return jsonb_build_object('buyer_id', m.buyer_id, 'from_listing', m.listing_id, 'to_listing', tl.id,
    'service', ts.name, 'plan', tp.name, 'access_type', tp.access_type, 'host', (select username from profiles where id = tl.host_id),
    'seat_kobo', v_price, 'credit_kobo', v_credit, 'cost_kobo', v_cost, 'difference_kobo', v_cost - v_credit, 'ends_at', v_end,
    'months', jsonb_array_length(v_old), 'old', v_old, 'new', v_new,
    'wallet_kobo', _balance(m.buyer_id, 'WALLET'));
end $$;

-- settle one old month for a move: refund the unused part, pay the host for the used part
create or replace function public._settle_move(p_id uuid, p_unused bigint, p_why text) returns void
language plpgsql security definer set search_path = public as $$
declare m memberships; v_service text; v_ref text; v_rest bigint; v_fee bigint;
begin
  select * into m from memberships where id = p_id for update;
  if not found or m.escrow <> 'HELD' then raise exception 'This payment is already settled.'; end if;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  v_ref := _ref('MVR');
  if p_unused > 0 then
    perform _post(m.buyer_id, 'WALLET', 'REFUND', p_unused, v_service || ' · unused part credited for your move', v_ref, m.id, m.listing_id);
  end if;
  perform _post(m.host_id, 'PENDING', 'EARNING_REVERSED', -m.host_kobo, v_service || ' seat moved: ' || p_why, v_ref, m.id, m.listing_id);
  v_rest := m.amount_kobo - p_unused;
  if v_rest > 0 then
    v_fee := _fee(v_rest);
    perform _post(m.host_id, 'EARNINGS', 'HOST_EARNING', v_rest - v_fee, v_service || ' seat · days used before the move', v_ref, m.id, m.listing_id);
    perform _post(null, 'PLATFORM', 'PLATFORM_FEE', v_fee, v_service || ' seat fee (moved)', v_ref, m.id, m.listing_id);
    update memberships set escrow = 'SETTLED', status = 'PARTIALLY_REFUNDED', refund_kobo = p_unused, ends_at = least(ends_at, now()) where id = m.id;
  else
    update memberships set escrow = 'REFUNDED', status = 'REFUNDED', refund_kobo = p_unused where id = m.id;
  end if;
end $$;

create or replace function public._do_move(p_membership uuid, p_target uuid, p_pay_old boolean, p_contact text, p_note text, p_cover boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare m memberships; tl listings; tp service_plans; ts services; q jsonb; v_diff bigint; x jsonb; v_ref text; v_first uuid; v_id uuid; v_prev uuid;
        v_contact text; v_digits text; v_buyer profiles; v_auto boolean; v_old_host uuid; v_old_svc text; i int := 0; v_n int; v_cref text;
begin
  select * into m from memberships where id = p_membership;
  if not found then raise exception 'Seat not found.'; end if;
  perform 1 from memberships where buyer_id = m.buyer_id and listing_id = m.listing_id and status in ('ACTIVE','DISPUTED') and ends_at > now() for update;
  select * into tl from listings where id = p_target for update;
  if not found then raise exception 'Pick the plan to move to.'; end if;
  if tl.id = m.listing_id then raise exception 'The member is already in this plan. Pick a different one.'; end if;
  if tl.status not in ('LIVE','PAUSED') then raise exception 'You can only move members into a live or paused listing.'; end if;
  if tl.host_id = m.buyer_id then raise exception 'The member hosts that plan, so they cannot join it.'; end if;
  if exists (select 1 from memberships where listing_id = tl.id and buyer_id = m.buyer_id and (status = 'DISPUTED' or (status = 'ACTIVE' and ends_at > now()))) then
    raise exception 'The member already has a seat in that plan.';
  end if;
  if _occupied(tl.id) >= tl.seats_offered then raise exception 'That plan is full. Pick another one or add seats first.'; end if;
  select * into tp from service_plans where id = tl.plan_id;
  select * into ts from services where id = tp.service_id;
  select * into v_buyer from profiles where id = m.buyer_id;
  -- where the new host sends access
  v_contact := trim(coalesce(nullif(trim(coalesce(p_contact, '')), ''), m.contact, ''));
  if tp.access_type in ('INVITE','FAMILY','TEAM') then
    if v_contact !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_contact := v_buyer.email; end if;
    if coalesce(v_contact, '') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter the email address the new host should invite.'; end if;
  elsif tp.access_type = 'DATA' then
    v_digits := regexp_replace(v_contact, '\D', '', 'g');
    if v_digits !~ '^(0|234)[789][01]\d{8}$' then v_contact := v_buyer.phone; v_digits := regexp_replace(coalesce(v_contact, ''), '\D', '', 'g'); end if;
    if v_digits !~ '^(0|234)[789][01]\d{8}$' then raise exception 'Enter the phone number that should receive the data.'; end if;
  end if;
  q := _move_plan(p_membership, p_target, p_pay_old);
  v_diff := (q ->> 'difference_kobo')::bigint;
  v_cref := _ref('MOV');
  if v_diff > 0 and coalesce(p_cover, false) then
    perform _post(m.buyer_id, 'WALLET', 'ADMIN_CREDIT', v_diff, 'SplitSub paid the difference for your move to ' || ts.name, v_cref);
    perform _post(null, 'PLATFORM', 'ADMIN_CREDIT', -v_diff, 'Covered move difference · @' || v_buyer.username, v_cref);
  elsif v_diff > 0 and _balance(m.buyer_id, 'WALLET') < v_diff then
    raise exception 'Add % to your wallet to finish the move.', _naira(v_diff - _balance(m.buyer_id, 'WALLET'));
  end if;
  select auto_renew, host_id into v_auto, v_old_host from memberships where id = (select id from _seat_tip(m.buyer_id, m.listing_id));
  select s.name into v_old_svc from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  -- 1. close the old months
  for x in select * from jsonb_array_elements(q -> 'old') loop
    perform _settle_move((x ->> 'id')::uuid, (x ->> 'unused_kobo')::bigint, 'moved to ' || ts.name);
  end loop;
  -- 2. open the same dates in the new plan
  v_ref := v_cref;
  v_n := jsonb_array_length(q -> 'new');
  for x in select * from jsonb_array_elements(q -> 'new') loop
    i := i + 1;
    if v_prev is not null then update memberships set renewed = true where id = v_prev; end if;
    insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, buyer_fee_kobo, contact, starts_at, ends_at,
                             access_status, txn_ref, release_at, renewed_from, order_ref, period_no, periods, auto_renew, moved_from)
    values (tl.id, tp.id, m.buyer_id, tl.host_id, (x ->> 'price_kobo')::bigint, _fee((x ->> 'price_kobo')::bigint),
            (x ->> 'price_kobo')::bigint - _fee((x ->> 'price_kobo')::bigint), 0, v_contact, (x ->> 'starts_at')::timestamptz, (x ->> 'ends_at')::timestamptz,
            case when tp.access_type = 'LOGIN' then 'READY' else 'WAITING' end, case when i = 1 then v_ref else v_ref || '-' || i end,
            greatest((x ->> 'ends_at')::timestamptz, now() + make_interval(days => escrow_days())), v_prev, v_ref, i, v_n, coalesce(v_auto, false),
            (q -> 'old' -> (i - 1) ->> 'id')::uuid)
    returning id into v_id;
    if i = 1 then v_first := v_id; end if;
    perform _post(m.buyer_id, 'WALLET', 'SUBSCRIPTION', -(x ->> 'price_kobo')::bigint, 'Seat (moved): ' || ts.name || ' · ' || tp.name, v_ref, v_id, tl.id);
    perform _post(tl.host_id, 'PENDING', 'HOST_EARNING_PENDING', (x ->> 'price_kobo')::bigint - _fee((x ->> 'price_kobo')::bigint),
      ts.name || ' seat · @' || v_buyer.username || ' (moved in)', v_ref, v_id, tl.id);
    perform _creator_commission(m.buyer_id, v_id, (x ->> 'price_kobo')::bigint);
    v_prev := v_id;
  end loop;
  update memberships set moved_to = v_first where id in (select (e ->> 'id')::uuid from jsonb_array_elements(q -> 'old') e);
  -- 3. tell everyone
  perform _notify(m.buyer_id, 'SEAT_MOVED', 'SplitSub moved your seat to ' || ts.name,
    'Your seat is now ' || ts.name || ' · ' || tp.name || ' with @' || (q ->> 'host') || ' until ' || _lagos_day((q ->> 'ends_at')::timestamptz) || '. '
    || case when v_diff < 0 then _naira(-v_diff) || ' was left over and is in your wallet. '
            when v_diff > 0 and coalesce(p_cover, false) then 'SplitSub paid the ' || _naira(v_diff) || ' difference. '
            when v_diff > 0 then 'You paid the ' || _naira(v_diff) || ' difference. ' else '' end
    || case when tp.access_type = 'LOGIN' then 'Your new access details are in My Subs.' else 'The new host will send your access to ' || v_contact || '.' end, v_first::text);
  perform _notify(tl.host_id, 'NEW_MEMBER', 'New member for your ' || ts.name || ' plan',
    '@' || v_buyer.username || ' was moved to your plan by SplitSub (order ' || v_ref || ').'
    || case when tp.access_type = 'LOGIN' then '' else ' Please send access to ' || v_contact || ' and mark it as sent.' end, v_first::text);
  if v_old_host is not null then
    perform _notify(v_old_host, 'REFUND', '@' || v_buyer.username || ' moved out of your ' || v_old_svc || ' plan',
      'SplitSub moved this member to another plan. ' || case when coalesce(p_pay_old, true) then 'You were paid for the days already used.' else 'The payment was returned to the member.' end
      || ' The seat is free again.', m.id::text);
  end if;
  perform _chat_system(m.id, 'SplitSub moved this member to ' || ts.name || ' · ' || tp.name || '.' || case when coalesce(p_note, '') <> '' then ' Note: ' || left(p_note, 300) else '' end);
  perform _chat_system(v_first, 'Order ' || v_ref || ': moved here from ' || v_old_svc || ' by SplitSub. Use this chat for anything about this order.'
    || case when tp.access_type = 'LOGIN' then '' else ' Host: please send access to the member and tap "Mark sent".' end);
  return v_first;
end $$;

create or replace function public.admin_move_quote(p_membership uuid, p_target uuid, p_pay_old boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb; tl listings;
begin
  perform _need_admin();
  q := _move_plan(p_membership, p_target, p_pay_old);
  select * into tl from listings where id = p_target;
  return q || jsonb_build_object('target_status', tl.status, 'seats_free', greatest(tl.seats_offered - _occupied(tl.id), 0));
end $$;

-- listings an admin can move a member into
create or replace function public.admin_move_targets(p_membership uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m memberships;
begin
  perform _need_admin();
  select * into m from memberships where id = p_membership;
  if not found then raise exception 'Seat not found.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'service', s.name, 'plan', p.name, 'host', h.username, 'status', l.status,
      'seat_kobo', _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct), 'seats_free', greatest(l.seats_offered - _occupied(l.id), 0),
      'same_plan', p.id = m.plan_id, 'access_type', p.access_type) order by (p.id = m.plan_id) desc, s.name, p.name, h.username)
    from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id join profiles h on h.id = l.host_id
    where l.status in ('LIVE','PAUSED') and l.id <> m.listing_id and l.host_id <> m.buyer_id), '[]'::jsonb);
end $$;

create or replace function public.admin_move_member(p_membership uuid, p_target uuid, p_pay_old boolean default true, p_cover boolean default false,
  p_contact text default '', p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare q jsonb; v_diff bigint; v_id uuid; v_move uuid; m memberships;
begin
  perform _need_admin();
  select * into m from memberships where id = p_membership;
  if not found then raise exception 'Seat not found.'; end if;
  q := _move_plan(p_membership, p_target, p_pay_old);
  v_diff := (q ->> 'difference_kobo')::bigint;
  if v_diff <= 0 or coalesce(p_cover, false) then
    v_id := _do_move(p_membership, p_target, p_pay_old, p_contact, p_note, p_cover);
    update seat_moves set status = 'CANCELLED', note = note || ' (replaced by a direct move)' where buyer_id = m.buyer_id and from_listing = m.listing_id and status = 'AWAITING_PAYMENT';
    perform _audit('MOVE_MEMBER', 'membership', p_membership::text, null,
      jsonb_build_object('to_listing', p_target, 'new_membership', v_id, 'difference_kobo', v_diff, 'covered', coalesce(p_cover, false) and v_diff > 0,
                         'pay_old_host', coalesce(p_pay_old, true)), coalesce(p_note, ''));
    return jsonb_build_object('done', true, 'membership_id', v_id, 'difference_kobo', v_diff);
  end if;
  -- the new plan costs more: the member pays the difference in the app (the old seat keeps working until then)
  if exists (select 1 from seat_moves where buyer_id = m.buyer_id and from_listing = m.listing_id and status = 'AWAITING_PAYMENT') then
    raise exception 'This member already has a move waiting for payment. Cancel it first.';
  end if;
  insert into seat_moves (membership_id, buyer_id, from_listing, to_listing, pay_old_host, contact, note, quoted_difference_kobo, created_by)
  values (p_membership, m.buyer_id, m.listing_id, p_target, coalesce(p_pay_old, true), trim(coalesce(p_contact, '')), left(trim(coalesce(p_note, '')), 300), v_diff, auth.uid())
  returning id into v_move;
  perform _notify(m.buyer_id, 'MOVE_PAYMENT', 'Pay ' || _naira(v_diff) || ' to move to ' || (q ->> 'service'),
    'SplitSub is moving your seat to ' || (q ->> 'service') || ' · ' || (q ->> 'plan') || '. It costs ' || _naira(v_diff)
    || ' more for the time you have left. Open My Subs and tap "Pay and move". Your current seat keeps working until then.', v_move::text);
  perform _audit('MOVE_MEMBER_REQUESTED', 'membership', p_membership::text, null,
    jsonb_build_object('to_listing', p_target, 'difference_kobo', v_diff, 'move', v_move), coalesce(p_note, ''));
  return jsonb_build_object('done', false, 'move_id', v_move, 'difference_kobo', v_diff);
end $$;

create or replace function public.admin_seat_moves(p_status text default 'AWAITING_PAYMENT') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', sm.id, 'status', sm.status, 'buyer', b.username, 'membership_id', sm.membership_id,
      'from', fs.name || ' · ' || fp.name, 'to', ts.name || ' · ' || tp.name, 'difference_kobo', sm.quoted_difference_kobo,
      'note', sm.note, 'created_at', sm.created_at, 'done_at', sm.done_at) order by sm.created_at desc)
    from seat_moves sm join profiles b on b.id = sm.buyer_id
    join listings fl on fl.id = sm.from_listing join service_plans fp on fp.id = fl.plan_id join services fs on fs.id = fp.service_id
    join listings tl on tl.id = sm.to_listing join service_plans tp on tp.id = tl.plan_id join services ts on ts.id = tp.service_id
    where p_status is null or p_status = '' or sm.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.admin_cancel_move(p_id uuid, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare sm seat_moves;
begin
  perform _need_admin();
  select * into sm from seat_moves where id = p_id for update;
  if not found or sm.status <> 'AWAITING_PAYMENT' then raise exception 'This move is not waiting any more.'; end if;
  update seat_moves set status = 'CANCELLED', done_at = now(), note = left(trim(note || ' ' || coalesce(p_note, '')), 300) where id = p_id;
  perform _notify(sm.buyer_id, 'SEAT_MOVED', 'Seat move cancelled', 'SplitSub cancelled the move. Your current seat stays as it is.', p_id::text);
  perform _audit('MOVE_CANCELLED', 'seat_move', p_id::text, null, null, coalesce(p_note, ''));
end $$;

-- the member pays the difference and the move happens at once
create or replace function public.complete_seat_move(p_move uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; sm seat_moves; v_id uuid; mm text;
begin
  me := _me();
  mm := maintenance_on();
  if mm is not null then raise exception 'Purchases are paused for maintenance. %', mm; end if;
  select * into sm from seat_moves where id = p_move and buyer_id = me.id for update;
  if not found or sm.status <> 'AWAITING_PAYMENT' then raise exception 'This move is not waiting any more.'; end if;
  v_id := _do_move(sm.membership_id, sm.to_listing, sm.pay_old_host, sm.contact, sm.note, false);
  update seat_moves set status = 'DONE', done_at = now(), new_membership_id = v_id where id = sm.id;
  return jsonb_build_object('membership_id', v_id);
end $$;

create or replace function public.decline_seat_move(p_move uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; sm seat_moves;
begin
  me := _me();
  select * into sm from seat_moves where id = p_move and buyer_id = me.id for update;
  if not found or sm.status <> 'AWAITING_PAYMENT' then raise exception 'This move is not waiting any more.'; end if;
  update seat_moves set status = 'DECLINED', done_at = now() where id = sm.id;
  perform _notify_admins('ADMIN_ALERT', 'Seat move declined', '@' || me.username || ' chose to keep their current seat.', sm.id::text);
end $$;

-- what the member will pay right now (the amount shrinks a little every day)
create or replace function public.seat_move_quote(p_move uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; sm seat_moves; q jsonb;
begin
  me := _me();
  select * into sm from seat_moves where id = p_move and buyer_id = me.id;
  if not found or sm.status <> 'AWAITING_PAYMENT' then raise exception 'This move is not waiting any more.'; end if;
  q := _move_plan(sm.membership_id, sm.to_listing, sm.pay_old_host);
  return jsonb_build_object('difference_kobo', greatest((q ->> 'difference_kobo')::bigint, 0), 'service', q ->> 'service', 'plan', q ->> 'plan',
    'host', q ->> 'host', 'ends_at', q -> 'ends_at', 'credit_kobo', q -> 'credit_kobo', 'cost_kobo', q -> 'cost_kobo', 'wallet_kobo', q -> 'wallet_kobo');
end $$;

-- ---------------------------------------------------------------------
-- 13. CREATORS & PARTNERS
--  The creator signs up normally. The admin registers them by username with a code (e.g. ADEDIPUPO).
--  Their link is splitsub.app/adedipupo (or splitsub.app/?ref=ADEDIPUPO). Everyone who signs up with the
--  link or code counts as theirs. Commission is a % of each seat month, or a flat ₦ per order, on what their
--  people buy. It becomes payable when the host's escrow for that month is released.
-- ---------------------------------------------------------------------
create or replace function public._creator_json(c creators) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', c.id, 'user_id', c.user_id, 'username', u.username, 'full_name', u.full_name, 'email', u.email, 'phone', u.phone,
    'code', c.code, 'link_slug', lower(c.code), 'commission_type', c.commission_type, 'commission_bps', c.commission_bps,
    'commission_flat_kobo', c.commission_flat_kobo, 'first_purchase_only', c.first_purchase_only,
    'bank_name', c.bank_name, 'account_number', c.account_number, 'account_name', c.account_name, 'notes', c.notes, 'active', c.active,
    'created_at', c.created_at,
    'signups', (select count(*) from referrals r where r.referrer_id = c.user_id),
    'buyers', (select count(distinct e.referred_id) from creator_earnings e where e.creator_id = c.id and e.status <> 'CANCELLED'),
    'sales_kobo', coalesce((select sum(e.basis_kobo) from creator_earnings e where e.creator_id = c.id and e.status <> 'CANCELLED'), 0),
    'pending_kobo', coalesce((select sum(e.amount_kobo) from creator_earnings e where e.creator_id = c.id and e.status = 'PENDING'), 0),
    'payable_kobo', coalesce((select sum(e.amount_kobo) from creator_earnings e where e.creator_id = c.id and e.status = 'PAYABLE' and e.payout_id is null), 0),
    'due_kobo', coalesce((select sum(x.amount_kobo) from creator_payouts x where x.creator_id = c.id and x.status = 'DUE'), 0),
    'paid_kobo', coalesce((select sum(x.amount_kobo) from creator_payouts x where x.creator_id = c.id and x.status = 'PAID'), 0),
    'total_kobo', coalesce((select sum(e.amount_kobo) from creator_earnings e where e.creator_id = c.id and e.status <> 'CANCELLED'), 0))
  from profiles u where u.id = c.user_id;
$$;

create or replace function public.admin_creators() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  perform _creator_refresh();
  return coalesce((select jsonb_agg(_creator_json(c) order by c.active desc, c.created_at desc) from creators c), '[]'::jsonb);
end $$;

create or replace function public.admin_save_creator(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_user profiles; c creators; old creators; v_code text; v_type text; v_bps int; v_flat bigint; v_acct text; v_id uuid;
        v_reserved text[] := array['ADMIN','API','APP','HELP','TERMS','PRIVACY','LEGAL','LOGIN','SIGNUP','SPLITSUB','SUPPORT','WALLET','INDEX','REFUND','POLICY','ACCOUNT','EXPLORE'];
begin
  perform _need_admin();
  v_code := upper(regexp_replace(coalesce(p ->> 'code', ''), '[^A-Za-z0-9]', '', 'g'));
  if v_code !~ '^[A-Z0-9]{3,12}$' then raise exception 'The code must be 3 to 12 letters or numbers, for example ADEDIPUPO.'; end if;
  if v_code = any (v_reserved) then raise exception 'That code is reserved. Pick another one.'; end if;
  v_type := coalesce(p ->> 'commission_type', 'PERCENT');
  if v_type not in ('PERCENT','FLAT') then raise exception 'Pick percentage or flat amount.'; end if;
  v_bps := coalesce((p ->> 'commission_bps')::int, 0);
  v_flat := coalesce((p ->> 'commission_flat_kobo')::bigint, 0);
  if v_type = 'PERCENT' and v_bps not between 1 and 5000 then raise exception 'Enter a percentage between 0.01%% and 50%%.'; end if;
  if v_type = 'FLAT' and v_flat not between 100 and 10000000 then raise exception 'Enter a flat amount between ₦1 and ₦100,000.'; end if;
  v_acct := regexp_replace(coalesce(p ->> 'account_number', ''), '\D', '', 'g');
  if v_acct <> '' and v_acct !~ '^\d{10}$' then raise exception 'Account numbers have 10 digits.'; end if;
  if nullif(p ->> 'id', '') is null then
    select * into v_user from profiles where username = lower(trim(coalesce(p ->> 'username', ''))) or username = trim(coalesce(p ->> 'username', ''));
    if not found then raise exception 'No user with that username. Ask the creator to sign up first, then copy their @username.'; end if;
    if v_user.status <> 'ACTIVE' then raise exception 'That account is suspended.'; end if;
    if exists (select 1 from creators where user_id = v_user.id) then raise exception '@% is already a creator.', v_user.username; end if;
  else
    select * into old from creators where id = (p ->> 'id')::uuid for update;
    if not found then raise exception 'Creator not found.'; end if;
    select * into v_user from profiles where id = old.user_id;
  end if;
  if exists (select 1 from creators where code = v_code and user_id <> v_user.id)
     or exists (select 1 from profiles where referral_code = v_code and id <> v_user.id) then
    raise exception 'The code % is already used. Pick another one.', v_code;
  end if;
  if old.id is null then
    insert into creators (user_id, code, commission_type, commission_bps, commission_flat_kobo, first_purchase_only, bank_name, account_number, account_name, notes, active, created_by)
    values (v_user.id, v_code, v_type, case when v_type = 'PERCENT' then v_bps else 0 end, case when v_type = 'FLAT' then v_flat else 0 end,
      coalesce((p ->> 'first_purchase_only')::boolean, false), left(trim(coalesce(p ->> 'bank_name', '')), 60), v_acct,
      left(trim(coalesce(p ->> 'account_name', '')), 100), left(trim(coalesce(p ->> 'notes', '')), 500), coalesce((p ->> 'active')::boolean, true), auth.uid())
    returning * into c;
    perform _audit('CREATE_CREATOR', 'creator', c.id::text, null, to_jsonb(c));
    perform _notify(v_user.id, 'ADMIN_ALERT', 'You are now a SplitSub creator',
      'Your code is ' || v_code || '. Share splitsub.app/' || lower(v_code) || ' and see your sign-ups and earnings in Account.', c.id::text);
  else
    update creators set code = v_code, commission_type = v_type, commission_bps = case when v_type = 'PERCENT' then v_bps else 0 end,
      commission_flat_kobo = case when v_type = 'FLAT' then v_flat else 0 end,
      first_purchase_only = coalesce((p ->> 'first_purchase_only')::boolean, first_purchase_only),
      bank_name = left(trim(coalesce(p ->> 'bank_name', bank_name)), 60), account_number = v_acct,
      account_name = left(trim(coalesce(p ->> 'account_name', account_name)), 100), notes = left(trim(coalesce(p ->> 'notes', notes)), 500),
      active = coalesce((p ->> 'active')::boolean, active), updated_at = now()
    where id = old.id returning * into c;
    perform _audit('UPDATE_CREATOR', 'creator', c.id::text, to_jsonb(old), to_jsonb(c));
  end if;
  -- the creator's code is also their personal invite code, so sign-up links just work
  update profiles set referral_code = v_code where id = v_user.id and referral_code is distinct from v_code;
  return _creator_json(c);
end $$;

create or replace function public.admin_creator_detail(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c creators;
begin
  perform _need_admin();
  perform _creator_refresh();
  select * into c from creators where id = p_id;
  if not found then raise exception 'Creator not found.'; end if;
  return _creator_json(c) || jsonb_build_object(
    'people', coalesce((select jsonb_agg(jsonb_build_object('username', u.username, 'joined_at', r.created_at,
        'orders', (select count(distinct m.order_ref) from memberships m where m.buyer_id = r.referred_id),
        'earned_kobo', coalesce((select sum(e.amount_kobo) from creator_earnings e where e.creator_id = c.id and e.referred_id = r.referred_id and e.status <> 'CANCELLED'), 0))
        order by r.created_at desc)
      from (select * from referrals where referrer_id = c.user_id order by created_at desc limit 300) r join profiles u on u.id = r.referred_id), '[]'::jsonb),
    'earnings', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'username', u.username, 'service', s.name, 'basis_kobo', e.basis_kobo,
        'amount_kobo', e.amount_kobo, 'status', e.status, 'payout_id', e.payout_id, 'created_at', e.created_at, 'release_at', m.release_at) order by e.created_at desc)
      from (select * from creator_earnings where creator_id = c.id order by created_at desc limit 300) e
      join profiles u on u.id = e.referred_id join memberships m on m.id = e.membership_id
      join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id), '[]'::jsonb),
    'payouts', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from creator_payouts x where x.creator_id = c.id), '[]'::jsonb));
end $$;

-- End of month: group everything payable into one payout per creator.
create or replace function public.admin_prepare_creator_payouts(p_label text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record; v_id uuid; n int := 0; v_total bigint := 0; v_label text;
begin
  perform _need_admin();
  perform _creator_refresh();
  v_label := coalesce(nullif(trim(coalesce(p_label, '')), ''), to_char(now() at time zone 'Africa/Lagos', 'Mon YYYY'));
  for c in select cr.*, sum(e.amount_kobo) amt, count(e.id) cnt from creators cr join creator_earnings e on e.creator_id = cr.id
           where e.status = 'PAYABLE' and e.payout_id is null group by cr.id having sum(e.amount_kobo) > 0 loop
    insert into creator_payouts (creator_id, period_label, amount_kobo, items, bank_name, account_number, account_name, reference, created_by)
    values (c.id, left(v_label, 40), c.amt, c.cnt, c.bank_name, c.account_number, c.account_name, _ref('CRP'), auth.uid())
    returning id into v_id;
    update creator_earnings set payout_id = v_id where creator_id = c.id and status = 'PAYABLE' and payout_id is null;
    n := n + 1; v_total := v_total + c.amt;
  end loop;
  perform _audit('PREPARE_CREATOR_PAYOUTS', 'creator_payout', null, null, jsonb_build_object('payouts', n, 'total_kobo', v_total, 'label', v_label));
  return jsonb_build_object('payouts', n, 'total_kobo', v_total);
end $$;

create or replace function public.admin_creator_payouts(p_status text default 'DUE') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(to_jsonb(x) || jsonb_build_object('username', u.username, 'code', c.code) order by x.created_at desc)
    from creator_payouts x join creators c on c.id = x.creator_id join profiles u on u.id = c.user_id
    where p_status is null or p_status = '' or x.status = p_status), '[]'::jsonb);
end $$;

-- PAID = you sent it from your bank. WALLET = put it in the creator's SplitSub wallet. CANCEL = undo the payout.
create or replace function public.admin_creator_payout_action(p_id uuid, p_action text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare x creator_payouts; c creators;
begin
  perform _need_admin();
  select * into x from creator_payouts where id = p_id for update;
  if not found then raise exception 'Payout not found.'; end if;
  if x.status <> 'DUE' then raise exception 'This payout is already %.', lower(x.status); end if;
  select * into c from creators where id = x.creator_id;
  if p_action = 'PAID' then
    update creator_payouts set status = 'PAID', method = 'BANK', paid_at = now(), paid_by = auth.uid(), note = left(trim(coalesce(p_note, '')), 300) where id = x.id;
    update creator_earnings set status = 'PAID', decided_at = now() where payout_id = x.id;
    perform _post(null, 'PLATFORM', 'REFERRAL_REWARD', -x.amount_kobo, 'Creator payout to bank · ' || c.code || ' · ' || x.period_label, x.reference);
    perform _notify(c.user_id, 'CREATOR_PAYOUT', _naira(x.amount_kobo) || ' creator earnings sent to your bank',
      x.period_label || ' · ' || x.bank_name || ' ' || right(x.account_number, 4) || ' · ' || x.reference, x.id::text);
  elsif p_action = 'WALLET' then
    update creator_payouts set status = 'PAID', method = 'WALLET', paid_at = now(), paid_by = auth.uid(), note = left(trim(coalesce(p_note, '')), 300) where id = x.id;
    update creator_earnings set status = 'PAID', decided_at = now() where payout_id = x.id;
    perform _post(c.user_id, 'WALLET', 'REFERRAL_REWARD', x.amount_kobo, 'Creator earnings · ' || x.period_label, x.reference);
    perform _post(null, 'PLATFORM', 'REFERRAL_REWARD', -x.amount_kobo, 'Creator payout to wallet · ' || c.code || ' · ' || x.period_label, x.reference);
    perform _notify(c.user_id, 'CREATOR_PAYOUT', _naira(x.amount_kobo) || ' creator earnings added to your wallet', x.period_label || ' · ' || x.reference, x.id::text);
  elsif p_action = 'CANCEL' then
    update creator_payouts set status = 'CANCELLED', note = left(trim(coalesce(p_note, '')), 300) where id = x.id;
    update creator_earnings set payout_id = null where payout_id = x.id;
  else
    raise exception 'Unknown action.';
  end if;
  perform _audit('CREATOR_PAYOUT_' || p_action, 'creator_payout', p_id::text, jsonb_build_object('status', x.status),
    jsonb_build_object('amount_kobo', x.amount_kobo, 'creator', c.code), coalesce(p_note, ''));
end $$;

-- the creator's own dashboard (Account page)
create or replace function public.my_creator() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; c creators;
begin
  me := _me();
  select * into c from creators where user_id = me.id;
  if not found then return null; end if;
  perform _creator_refresh();
  return jsonb_build_object('code', c.code, 'link_slug', lower(c.code), 'active', c.active,
    'commission_type', c.commission_type, 'commission_bps', c.commission_bps, 'commission_flat_kobo', c.commission_flat_kobo,
    'first_purchase_only', c.first_purchase_only,
    'bank', case when c.account_number <> '' then c.bank_name || ' ••••' || right(c.account_number, 4) else '' end,
    'signups', (select count(*) from referrals r where r.referrer_id = me.id),
    'buyers', (select count(distinct e.referred_id) from creator_earnings e where e.creator_id = c.id and e.status <> 'CANCELLED'),
    'pending_kobo', coalesce((select sum(amount_kobo) from creator_earnings where creator_id = c.id and status = 'PENDING'), 0),
    'payable_kobo', coalesce((select sum(amount_kobo) from creator_earnings where creator_id = c.id and status = 'PAYABLE'), 0),
    'paid_kobo', coalesce((select sum(amount_kobo) from creator_earnings where creator_id = c.id and status = 'PAID'), 0),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('who', left(u.username, 3) || '***', 'joined_at', r.created_at,
        'bought', exists (select 1 from creator_earnings e where e.creator_id = c.id and e.referred_id = r.referred_id and e.status <> 'CANCELLED'))
        order by r.created_at desc)
      from (select * from referrals where referrer_id = me.id order by created_at desc limit 20) r join profiles u on u.id = r.referred_id), '[]'::jsonb),
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('period', x.period_label, 'amount_kobo', x.amount_kobo, 'status', x.status,
        'method', x.method, 'paid_at', x.paid_at) order by x.created_at desc) from creator_payouts x where x.creator_id = c.id and x.status <> 'CANCELLED'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 14. BULK MESSAGES (admin): email, SMS, WhatsApp
--  The admin pastes numbers or emails. The bulk-send Edge Function sends them in small batches
--  using the admin's own login, so only admins can ever send.
-- ---------------------------------------------------------------------
create table if not exists public.broadcast_jobs (
  id uuid primary key default gen_random_uuid(),
  channel text not null check (channel in ('EMAIL','SMS','WHATSAPP')),
  subject text not null default '',
  message text not null check (length(message) between 1 and 5000),
  total int not null default 0,
  sent int not null default 0,
  failed int not null default 0,
  status text not null default 'QUEUED' check (status in ('QUEUED','SENDING','DONE','CANCELLED')),
  created_by uuid,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create table if not exists public.broadcast_items (
  id bigint generated always as identity primary key,
  job_id uuid not null references public.broadcast_jobs(id) on delete cascade,
  recipient text not null,
  status text not null default 'PENDING' check (status in ('PENDING','SENT','FAILED','CANCELLED')),
  attempts int not null default 0,
  error text not null default '',
  sent_at timestamptz,
  unique (job_id, recipient)
);
create index if not exists broadcast_items_pending_idx on public.broadcast_items (job_id, id) where status = 'PENDING';
alter table public.broadcast_jobs enable row level security;
alter table public.broadcast_items enable row level security;
revoke all on public.broadcast_jobs, public.broadcast_items from anon, authenticated;

-- Nigerian numbers become 234XXXXXXXXXX; other countries need the + and country code.
create or replace function public._norm_phone(p text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g'); plus boolean := trim(coalesce(p, '')) like '+%';
begin
  if d ~ '^0[789][01]\d{8}$' then return '234' || substr(d, 2); end if;
  if d ~ '^234[789][01]\d{8}$' then return d; end if;
  if d ~ '^[789][01]\d{8}$' then return '234' || d; end if;
  if plus and length(d) between 10 and 15 then return d; end if;
  return null;
end $$;

create or replace function public.admin_bulk_create(p_channel text, p_subject text, p_message text, p_recipients text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_job uuid; v_ok text[] := '{}'; v_bad text[] := '{}'; v_part text; v_sub text; v_val text; v_parts text[]; v_msg text := trim(coalesce(p_message, ''));
begin
  perform _need_admin();
  if p_channel not in ('EMAIL','SMS','WHATSAPP') then raise exception 'Pick email, SMS or WhatsApp.'; end if;
  if length(v_msg) < 2 then raise exception 'Write the message first.'; end if;
  if p_channel = 'EMAIL' and length(trim(coalesce(p_subject, ''))) < 2 then raise exception 'Add an email subject.'; end if;
  if p_channel = 'SMS' and length(v_msg) > 640 then raise exception 'SMS messages can be up to 640 characters (4 SMS pages). Yours is %.', length(v_msg); end if;
  if p_channel = 'WHATSAPP' and length(v_msg) > 1000 then raise exception 'WhatsApp messages can be up to 1,000 characters.'; end if;
  for v_part in select trim(x) from regexp_split_to_table(coalesce(p_recipients, ''), '[\n\r,;]+') x where trim(x) <> '' loop
    -- one per line is best; several on one line are split by spaces (a phone number may itself contain spaces)
    if p_channel = 'EMAIL' or length(regexp_replace(v_part, '\D', '', 'g')) > 15 then v_parts := regexp_split_to_array(v_part, '\s+');
    else v_parts := array[v_part]; end if;
    foreach v_sub in array v_parts loop
      continue when trim(v_sub) = '';
      if p_channel = 'EMAIL' then
        v_val := lower(trim(v_sub));
        v_val := case when v_val ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then v_val end;
      else
        v_val := _norm_phone(v_sub);
      end if;
      if v_val is null then v_bad := v_bad || left(v_sub, 60);
      elsif not (v_val = any (v_ok)) then v_ok := v_ok || v_val; end if;
    end loop;
  end loop;
  if cardinality(v_ok) = 0 then raise exception 'No valid % found. Put one per line.', case p_channel when 'EMAIL' then 'email addresses' else 'phone numbers' end; end if;
  if cardinality(v_ok) > 2000 then raise exception 'Send to at most 2,000 people at a time. You have %.', cardinality(v_ok); end if;
  insert into broadcast_jobs (channel, subject, message, total, created_by)
  values (p_channel, left(trim(coalesce(p_subject, '')), 150), v_msg, cardinality(v_ok), auth.uid()) returning id into v_job;
  insert into broadcast_items (job_id, recipient) select v_job, x from unnest(v_ok) x;
  perform _audit('BULK_MESSAGE', 'broadcast_job', v_job::text, null,
    jsonb_build_object('channel', p_channel, 'recipients', cardinality(v_ok), 'invalid', cardinality(v_bad), 'subject', p_subject));
  return jsonb_build_object('job_id', v_job, 'valid', cardinality(v_ok), 'invalid', to_jsonb(v_bad));
end $$;

-- everyone's email or phone, to fill the box quickly
create or replace function public.admin_bulk_audience(p_channel text) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  if p_channel = 'EMAIL' then
    return coalesce((select string_agg(email, E'\n' order by created_at) from profiles where status = 'ACTIVE' and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
                     and email not like '%@splitsub.invalid'), '');
  end if;
  return coalesce((select string_agg(x, E'\n') from (select distinct _norm_phone(phone) x from profiles where status = 'ACTIVE') t where x is not null), '');
end $$;

create or replace function public.admin_bulk_jobs() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'channel', j.channel, 'subject', j.subject, 'message', left(j.message, 160),
      'total', j.total, 'sent', j.sent, 'failed', j.failed, 'status', j.status, 'created_at', j.created_at, 'finished_at', j.finished_at,
      'by', (select username from profiles where id = j.created_by),
      'pending', (select count(*) from broadcast_items i where i.job_id = j.id and i.status = 'PENDING'),
      'errors', (select jsonb_agg(jsonb_build_object('to', i.recipient, 'error', i.error)) from
                  (select * from broadcast_items where job_id = j.id and status = 'FAILED' order by id limit 20) i)) order by j.created_at desc)
    from (select * from broadcast_jobs order by created_at desc limit 50) j), '[]'::jsonb);
end $$;

-- the Edge Function takes a batch (as the signed-in admin)
create or replace function public.admin_bulk_claim(p_job uuid, p_limit int default 25) returns jsonb
language plpgsql security definer set search_path = public as $$
declare j broadcast_jobs; v_items jsonb := '[]'::jsonb; r record;
begin
  perform _need_admin();
  select * into j from broadcast_jobs where id = p_job for update;
  if not found then raise exception 'Message not found.'; end if;
  if j.status in ('DONE','CANCELLED') then return jsonb_build_object('job', jsonb_build_object('id', j.id, 'status', j.status), 'items', '[]'::jsonb); end if;
  update broadcast_jobs set status = 'SENDING' where id = j.id and status = 'QUEUED';
  -- anything tried 3 times without an answer is given up on, so the job can finish
  update broadcast_items set status = 'FAILED', error = case when error = '' then 'Gave up after 3 tries' else error end
  where job_id = j.id and status = 'PENDING' and attempts >= 3;
  for r in select id, recipient from broadcast_items where job_id = j.id and status = 'PENDING' and attempts < 3
           order by id limit greatest(1, least(coalesce(p_limit, 25), 50)) for update skip locked loop
    update broadcast_items set attempts = attempts + 1 where id = r.id;
    v_items := v_items || jsonb_build_object('id', r.id, 'to', r.recipient);
  end loop;
  return jsonb_build_object('job', jsonb_build_object('id', j.id, 'channel', j.channel, 'subject', j.subject, 'message', j.message, 'status', 'SENDING'),
                            'items', v_items);
end $$;

create or replace function public.admin_bulk_mark(p_job uuid, p_results jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; v_left int; j broadcast_jobs;
begin
  perform _need_admin();
  for x in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    update broadcast_items set
      status = case when (x ->> 'ok')::boolean then 'SENT' when attempts >= 3 or coalesce((x ->> 'final')::boolean, false) then 'FAILED' else 'PENDING' end,
      error = case when (x ->> 'ok')::boolean then '' else left(coalesce(x ->> 'error', 'Failed'), 300) end,
      sent_at = case when (x ->> 'ok')::boolean then now() else sent_at end
    where id = (x ->> 'id')::bigint and job_id = p_job and status = 'PENDING';
  end loop;
  select count(*) into v_left from broadcast_items where job_id = p_job and status = 'PENDING';
  update broadcast_jobs set
    sent = (select count(*) from broadcast_items where job_id = p_job and status = 'SENT'),
    failed = (select count(*) from broadcast_items where job_id = p_job and status = 'FAILED'),
    status = case when v_left = 0 and status <> 'CANCELLED' then 'DONE' else status end,
    finished_at = case when v_left = 0 then coalesce(finished_at, now()) else finished_at end
  where id = p_job returning * into j;
  return jsonb_build_object('sent', j.sent, 'failed', j.failed, 'pending', v_left, 'total', j.total, 'status', j.status);
end $$;

create or replace function public.admin_bulk_cancel(p_job uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  update broadcast_items set status = 'CANCELLED' where job_id = p_job and status = 'PENDING';
  update broadcast_jobs set status = 'CANCELLED', finished_at = now() where id = p_job and status in ('QUEUED','SENDING');
end $$;

-- ---------------------------------------------------------------------
-- 15. WHO CAN CALL WHAT
-- ---------------------------------------------------------------------
revoke execute on function
  public._lagos_day(timestamptz), public._start_on(date), public._plan_months(service_plans, int), public._period_word(int),
  public._seat_tip(uuid, uuid), public._fix_tip(uuid, uuid), public._creator_commission(uuid, uuid, bigint), public._creator_refresh(),
  public._buy_periods(uuid, uuid, int, timestamptz, text, text, uuid, bigint), public._join2(uuid, uuid, text, text, int, date),
  public._renew(uuid, int, boolean), public._listing_cycle(), public.process_renewals(),
  public._move_plan(uuid, uuid, boolean), public._settle_move(uuid, bigint, text), public._do_move(uuid, uuid, boolean, text, text, boolean),
  public._creator_json(creators), public._norm_phone(text),
  public.join_with_wallet(uuid, text, int, date), public.payment_create(uuid, text, text, bigint, uuid, text, int, date),
  public.renew_membership(uuid, int), public.set_auto_renew(uuid, boolean), public.member_renew_choice(uuid, text),
  public.host_renew_answer(uuid, boolean), public.admin_set_card_payments(boolean),
  public.admin_move_quote(uuid, uuid, boolean), public.admin_move_targets(uuid), public.admin_move_member(uuid, uuid, boolean, boolean, text, text),
  public.admin_seat_moves(text), public.admin_cancel_move(uuid, text), public.complete_seat_move(uuid), public.decline_seat_move(uuid),
  public.seat_move_quote(uuid), public.admin_creators(), public.admin_save_creator(jsonb), public.admin_creator_detail(uuid),
  public.admin_prepare_creator_payouts(text), public.admin_creator_payouts(text), public.admin_creator_payout_action(uuid, text, text),
  public.my_creator(), public.admin_bulk_create(text, text, text, text), public.admin_bulk_audience(text), public.admin_bulk_jobs(),
  public.admin_bulk_claim(uuid, int), public.admin_bulk_mark(uuid, jsonb), public.admin_bulk_cancel(uuid)
from public, anon, authenticated;

grant execute on function
  public.join_with_wallet(uuid, text, int, date), public.renew_membership(uuid, int), public.set_auto_renew(uuid, boolean),
  public.member_renew_choice(uuid, text), public.host_renew_answer(uuid, boolean), public.complete_seat_move(uuid),
  public.decline_seat_move(uuid), public.seat_move_quote(uuid), public.my_creator(),
  public.admin_set_card_payments(boolean), public.admin_move_quote(uuid, uuid, boolean), public.admin_move_targets(uuid),
  public.admin_move_member(uuid, uuid, boolean, boolean, text, text), public.admin_seat_moves(text), public.admin_cancel_move(uuid, text),
  public.admin_creators(), public.admin_save_creator(jsonb), public.admin_creator_detail(uuid), public.admin_prepare_creator_payouts(text),
  public.admin_creator_payouts(text), public.admin_creator_payout_action(uuid, text, text),
  public.admin_bulk_create(text, text, text, text), public.admin_bulk_audience(text), public.admin_bulk_jobs(),
  public.admin_bulk_claim(uuid, int), public.admin_bulk_mark(uuid, jsonb), public.admin_bulk_cancel(uuid)
to authenticated;
grant execute on function public.payment_create(uuid, text, text, bigint, uuid, text, int, date), public.process_renewals() to service_role;

-- fixed search path for the two small helpers (security advisor)
alter function public._period_word(int) set search_path = public;
alter function public._norm_phone(text) set search_path = public;
