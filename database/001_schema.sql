-- =====================================================================
--  SUBSPLIT · 001_schema.sql
--  Run in Supabase -> SQL Editor (paste all, Run). Safe to re-run.
--
--  RULES THIS FILE ENFORCES (the database is the source of truth):
--   * Money is stored as integer KOBO (N1 = 100 kobo). No floats.
--   * Browsers never write tables directly. Every change goes through a
--     function below that checks WHO is calling and WHAT they may do.
--   * Admins are listed in public.admin_users. Nobody can add themselves:
--     only an existing admin (or you, in the SQL Editor) can.
--   * Normal price, seat limit, markup range and access type belong to the
--     platform (service_plans). Hosts only pick a markup inside the range.
--   * Platform commission is fixed at 10% (platform_fee_bps below).
--   * Every balance change writes a ledger row (wallet_transactions).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- FIXED BUSINESS CONSTANTS
-- ---------------------------------------------------------------------
-- 10% platform commission, in basis points. Fixed by design: there is no
-- admin screen for it. To change it you must edit this line in SQL.
create or replace function public.platform_fee_bps() returns int
language sql immutable as $$ select 1000 $$;

-- ---------------------------------------------------------------------
-- TABLES
-- ---------------------------------------------------------------------
create table if not exists public.platform_settings (
  id int primary key default 1 check (id = 1),
  site_name text not null default 'SplitSub',
  hero_title text not null default 'Split premium subscriptions. Pay only for your seat.',
  hero_text text not null default 'Join verified groups for streaming, music, software, data and more. Or earn from the empty seats on your own plan.',
  notice text not null default '',
  support_whatsapp text not null default '',
  support_email text not null default '',
  categories text[] not null default array['Entertainment','Music','AI','Software','Education','Cloud Storage','Gaming','VPN','Data','Other'],
  min_withdrawal_kobo bigint not null default 100000 check (min_withdrawal_kobo >= 0),
  min_topup_kobo bigint not null default 10000 check (min_topup_kobo >= 5000),
  max_topup_kobo bigint not null default 50000000 check (max_topup_kobo >= min_topup_kobo),
  auto_approve_listings boolean not null default false,
  renewal_window_days int not null default 7 check (renewal_window_days between 1 and 30),
  reminder_days int not null default 3 check (reminder_days between 1 and 14),
  updated_at timestamptz not null default now()
);
insert into public.platform_settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  username text not null unique,
  phone text not null default '',
  email text not null default '',
  status text not null default 'ACTIVE' check (status in ('ACTIVE','SUSPENDED')),
  verified_host boolean not null default false,
  created_at timestamptz not null default now()
);

-- Who is an admin. No browser can write this table.
create table if not exists public.admin_users (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  granted_by uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.services (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  category text not null default 'Other',
  logo_color text not null default '#5B5BD6' check (logo_color ~ '^#[0-9A-Fa-f]{6}$'),
  logo_url text not null default '',
  description text not null default '',
  sharing_rules text not null default '',   -- the sharing method the real service allows
  notes text not null default '',           -- admin-only notes
  active boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.service_plans (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete restrict,
  name text not null,
  normal_price_kobo bigint not null check (normal_price_kobo > 0),
  -- What ONE customer would pay buying alone (shown crossed out). Empty = normal price.
  compare_price_kobo bigint check (compare_price_kobo is null or compare_price_kobo > 0),
  currency text not null default 'NGN' check (currency = 'NGN'),
  max_seats int not null check (max_seats between 1 and 20),
  access_type text not null check (access_type in ('LOGIN','INVITE','FAMILY','TEAM','DATA','OTHER')),
  duration_days int not null default 30 check (duration_days between 1 and 365),
  min_markup_pct int not null default 10,
  max_markup_pct int not null default 30,
  verification_required boolean not null default true,  -- admin must review every listing
  host_proof_required boolean not null default true,    -- host must upload proof of the plan
  active boolean not null default true,
  customer_instructions text not null default '',
  host_instructions text not null default '',
  notes text not null default '',
  sort int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (service_id, name),
  constraint markup_range check (min_markup_pct >= 10 and max_markup_pct <= 30 and min_markup_pct <= max_markup_pct)
);

create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references public.profiles(id) on delete restrict,
  plan_id uuid not null references public.service_plans(id) on delete restrict,
  markup_pct int not null check (markup_pct between 10 and 30),
  seats_offered int not null check (seats_offered between 1 and 20),
  note text not null default '',
  status text not null default 'DRAFT' check (status in ('DRAFT','PENDING_REVIEW','LIVE','PAUSED','REJECTED','SUSPENDED','EXPIRED')),
  proof_path text not null default '',
  proof_note text not null default '',
  review_note text not null default '',
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists listings_status_idx on public.listings (status);
create index if not exists listings_host_idx on public.listings (host_id);

-- Login details / invite instructions. Never part of public listing data.
create table if not exists public.listing_access (
  listing_id uuid primary key references public.listings(id) on delete cascade,
  details text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings(id) on delete restrict,
  plan_id uuid not null references public.service_plans(id),
  buyer_id uuid not null references public.profiles(id) on delete restrict,
  host_id uuid not null references public.profiles(id) on delete restrict,
  amount_kobo bigint not null check (amount_kobo > 0),     -- gross paid by buyer
  fee_kobo bigint not null check (fee_kobo >= 0),          -- platform 10%
  host_kobo bigint not null check (host_kobo >= 0),        -- host share
  refund_kobo bigint not null default 0 check (refund_kobo >= 0),
  contact text not null default '',                         -- email / phone the host needs
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','DISPUTED','COMPLETED','REFUNDED','PARTIALLY_REFUNDED')),
  escrow text not null default 'HELD' check (escrow in ('HELD','RELEASED','REFUNDED','SETTLED')),
  access_status text not null default 'WAITING' check (access_status in ('READY','WAITING','SENT')),
  renewed boolean not null default false,
  renewed_from uuid,
  reminder_sent boolean not null default false,
  payment_reference text,
  created_at timestamptz not null default now(),
  check (fee_kobo + host_kobo = amount_kobo)
);
create index if not exists memberships_listing_idx on public.memberships (listing_id);
create index if not exists memberships_buyer_idx on public.memberships (buyer_id);
create index if not exists memberships_host_idx on public.memberships (host_id);
create index if not exists memberships_due_idx on public.memberships (escrow, status, ends_at);
-- One live (not yet renewed) seat per buyer per listing: blocks duplicate memberships.
create unique index if not exists memberships_one_live_seat
  on public.memberships (listing_id, buyer_id) where status in ('ACTIVE','DISPUTED') and not renewed;

-- Ledger accounts. WALLET = money to spend. EARNINGS = host money ready to withdraw.
-- PENDING = host money waiting for the cycle to end. PLATFORM = SplitSub's 10% fees.
create table if not exists public.wallet_accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references public.profiles(id) on delete restrict,
  kind text not null check (kind in ('WALLET','EARNINGS','PENDING','PLATFORM')),
  balance_kobo bigint not null default 0,
  updated_at timestamptz not null default now(),
  unique (owner_id, kind),
  check ((kind = 'PLATFORM') = (owner_id is null)),
  check (kind = 'PLATFORM' or balance_kobo >= 0)
);
create unique index if not exists wallet_accounts_one_platform on public.wallet_accounts (kind) where owner_id is null;

create table if not exists public.wallet_transactions (
  id bigint generated always as identity primary key,
  account_id uuid not null references public.wallet_accounts(id),
  user_id uuid references public.profiles(id) on delete restrict,
  account_kind text not null,
  type text not null check (type in ('TOP_UP','SUBSCRIPTION','REFUND','HOST_EARNING_PENDING','PENDING_RELEASED','HOST_EARNING',
                                     'EARNING_REVERSED','PLATFORM_FEE','WITHDRAWAL','WITHDRAWAL_REVERSED','TRANSFER_IN','TRANSFER_OUT','ADJUSTMENT')),
  amount_kobo bigint not null check (amount_kobo <> 0),
  balance_after_kobo bigint not null,
  description text not null default '',
  reference text not null,            -- groups all rows of one money operation
  membership_id uuid,
  listing_id uuid,
  payment_reference text,
  withdrawal_id uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists wallet_tx_user_idx on public.wallet_transactions (user_id, id desc);
create index if not exists wallet_tx_account_idx on public.wallet_transactions (account_id);

create table if not exists public.payments (
  reference text primary key,
  user_id uuid not null references public.profiles(id) on delete restrict,
  purpose text not null check (purpose in ('TOPUP','SEAT')),
  listing_id uuid references public.listings(id),
  contact text not null default '',
  amount_kobo bigint not null check (amount_kobo > 0),
  paid_kobo bigint,
  status text not null default 'PENDING' check (status in ('PENDING','SUCCESS','FAILED','ABANDONED')),
  provider_id text,
  channel text,
  note text not null default '',
  membership_id uuid,
  created_at timestamptz not null default now(),
  verified_at timestamptz
);
create index if not exists payments_user_idx on public.payments (user_id, created_at desc);

create table if not exists public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete restrict,
  amount_kobo bigint not null check (amount_kobo > 0),
  bank_name text not null,
  account_number text not null check (account_number ~ '^\d{10}$'),
  account_name text not null,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','PAID','REJECTED')),
  admin_note text not null default '',
  ledger_reference text not null,
  processed_by uuid,
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  paid_at timestamptz
);

create table if not exists public.disputes (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references public.memberships(id) on delete restrict,
  listing_id uuid not null references public.listings(id),
  buyer_id uuid not null references public.profiles(id),
  host_id uuid not null references public.profiles(id),
  reason text not null,
  details text not null default '',
  host_response text not null default '',
  status text not null default 'OPEN' check (status in ('OPEN','IN_REVIEW','RESOLVED','CLOSED')),
  resolution text not null default '' check (resolution in ('','REFUND','PARTIAL_REFUND','RELEASE','NO_ACTION')),
  refund_kobo bigint not null default 0,
  admin_note text not null default '',
  resolved_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index if not exists disputes_one_open on public.disputes (membership_id) where status in ('OPEN','IN_REVIEW');

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);

create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  subject text not null,
  status text not null default 'OPEN' check (status in ('OPEN','ANSWERED','CLOSED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.support_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null,
  from_admin boolean not null default false,
  body text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.admin_audit_logs (
  id bigint generated always as identity primary key,
  admin_id uuid,
  action text not null,
  entity text not null,
  entity_id text,
  old_data jsonb,
  new_data jsonb,
  note text not null default '',
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- INTERNAL HELPERS (not callable from browsers; see GRANTS at the end)
-- ---------------------------------------------------------------------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admin_users a join profiles p on p.id = a.user_id
                 where a.user_id = auth.uid() and p.status = 'ACTIVE');
$$;

create or replace function public._need_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then
    raise exception using errcode = '42501', message = 'Access denied. This area is for SplitSub admins only.';
  end if;
end $$;

create or replace function public._me() returns profiles
language plpgsql stable security definer set search_path = public as $$
declare me profiles;
begin
  if auth.uid() is null then raise exception using errcode = '28000', message = 'Please sign in first.'; end if;
  select * into me from profiles where id = auth.uid();
  if not found then raise exception 'Your profile was not found. Sign out and sign in again.'; end if;
  if me.status <> 'ACTIVE' then raise exception 'Your account is suspended. Please contact support.'; end if;
  return me;
end $$;

create or replace function public._naira(k bigint) returns text
language sql immutable as $$
  select '₦' || case when k % 100 = 0 then to_char(k / 100, 'FM999,999,999,990')
                     else to_char(k / 100.0, 'FM999,999,999,990.00') end;
$$;

-- Price of one seat: (normal price + markup) / platform seats, rounded to the nearest naira.
create or replace function public._seat_price(p_normal bigint, p_seats int, p_markup int) returns bigint
language sql immutable as $$
  select (round(p_normal::numeric * (100 + p_markup) / 100 / p_seats / 100) * 100)::bigint;
$$;

create or replace function public._fee(p_amount bigint) returns bigint
language sql immutable as $$ select round(p_amount::numeric * platform_fee_bps() / 10000)::bigint $$;

create or replace function public._ref(p_prefix text) returns text
language sql volatile as $$ select p_prefix || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 14)) $$;

-- Seats taken: one per distinct buyer with a live seat.
create or replace function public._occupied(p_listing uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(distinct buyer_id)::int from memberships
  where listing_id = p_listing and (status = 'DISPUTED' or (status = 'ACTIVE' and ends_at > now()));
$$;

create or replace function public._account(p_owner uuid, p_kind text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from wallet_accounts where owner_id is not distinct from p_owner and kind = p_kind;
  if v is null then
    insert into wallet_accounts (owner_id, kind) values (p_owner, p_kind) on conflict do nothing;
    select id into v from wallet_accounts where owner_id is not distinct from p_owner and kind = p_kind;
  end if;
  return v;
end $$;

-- The ONLY way balances change: lock the account, check, update, write a ledger row.
create or replace function public._post(p_owner uuid, p_kind text, p_type text, p_amount bigint, p_desc text, p_ref text,
  p_membership uuid default null, p_listing uuid default null, p_payment text default null, p_withdrawal uuid default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_acc uuid; v_bal bigint;
begin
  if p_amount is null or p_amount = 0 then return null; end if;
  v_acc := _account(p_owner, p_kind);
  select balance_kobo into v_bal from wallet_accounts where id = v_acc for update;
  if p_kind <> 'PLATFORM' and v_bal + p_amount < 0 then
    raise exception '%', case p_kind when 'WALLET' then 'Not enough money in your wallet.' else 'Not enough earnings for this.' end;
  end if;
  update wallet_accounts set balance_kobo = v_bal + p_amount, updated_at = now() where id = v_acc;
  insert into wallet_transactions (account_id, user_id, account_kind, type, amount_kobo, balance_after_kobo, description, reference,
                                   membership_id, listing_id, payment_reference, withdrawal_id, created_by)
  values (v_acc, p_owner, p_kind, p_type, p_amount, v_bal + p_amount, coalesce(p_desc, ''), p_ref,
          p_membership, p_listing, p_payment, p_withdrawal, auth.uid());
  return v_bal + p_amount;
end $$;

create or replace function public._balance(p_owner uuid, p_kind text) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce((select balance_kobo from wallet_accounts where owner_id is not distinct from p_owner and kind = p_kind), 0);
$$;

create or replace function public._notify(p_user uuid, p_type text, p_title text, p_body text default '') returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, type, title, body) values (p_user, p_type, p_title, coalesce(p_body, ''));
$$;

create or replace function public._audit(p_action text, p_entity text, p_entity_id text, p_old jsonb, p_new jsonb, p_note text default '')
returns void language sql security definer set search_path = public as $$
  insert into admin_audit_logs (admin_id, action, entity, entity_id, old_data, new_data, note)
  values (auth.uid(), p_action, p_entity, p_entity_id, p_old, p_new, coalesce(p_note, ''));
$$;

-- New sign-up -> profile + empty wallet accounts. Nobody becomes admin here.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare base text; uname text;
begin
  base := left(lower(regexp_replace(split_part(coalesce(new.email, 'user'), '@', 1), '[^a-zA-Z0-9]', '', 'g')), 12);
  if length(base) < 3 then base := 'user' || base; end if;
  loop
    uname := base || (floor(random() * 9000) + 1000)::int;
    exit when not exists (select 1 from profiles where username = uname);
  end loop;
  insert into profiles (id, full_name, phone, email, username)
  values (new.id, left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 80),
          left(coalesce(new.raw_user_meta_data ->> 'phone', ''), 20), coalesce(new.email, ''), uname)
  on conflict (id) do nothing;
  perform _account(new.id, 'WALLET'); perform _account(new.id, 'EARNINGS'); perform _account(new.id, 'PENDING');
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- Keep profile email in sync if the user changes it.
create or replace function public.handle_user_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles set email = coalesce(new.email, '') where id = new.id;
  return new;
end $$;
drop trigger if exists on_auth_user_email on auth.users;
create trigger on_auth_user_email after update of email on auth.users for each row execute function public.handle_user_email();

-- ---------------------------------------------------------------------
-- PUBLIC READS (anyone, signed in or not)
-- ---------------------------------------------------------------------
create or replace function public._listing_obj(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', l.id, 'status', l.status, 'service_id', s.id, 'service', s.name, 'category', s.category,
    'logo_color', s.logo_color, 'logo_url', s.logo_url, 'sharing_rules', s.sharing_rules,
    'plan_id', p.id, 'plan', p.name, 'access_type', p.access_type, 'duration_days', p.duration_days,
    'customer_instructions', p.customer_instructions,
    'normal_kobo', p.normal_price_kobo, 'compare_kobo', coalesce(p.compare_price_kobo, p.normal_price_kobo), 'markup_pct', l.markup_pct,
    'seat_kobo', _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct),
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
                   'support_whatsapp', support_whatsapp, 'support_email', support_email, 'categories', to_jsonb(categories),
                   'min_withdrawal_kobo', min_withdrawal_kobo, 'min_topup_kobo', min_topup_kobo, 'max_topup_kobo', max_topup_kobo,
                   'renewal_window_days', renewal_window_days) from platform_settings where id = 1),
    'fee_bps', platform_fee_bps(),
    'services', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'category', s.category, 'logo_color', s.logo_color, 'logo_url', s.logo_url,
        'description', s.description, 'sharing_rules', s.sharing_rules,
        'plans', (select jsonb_agg(jsonb_build_object(
            'id', p.id, 'name', p.name, 'normal_kobo', p.normal_price_kobo, 'compare_kobo', coalesce(p.compare_price_kobo, p.normal_price_kobo), 'max_seats', p.max_seats, 'access_type', p.access_type,
            'duration_days', p.duration_days, 'min_markup_pct', p.min_markup_pct, 'max_markup_pct', p.max_markup_pct,
            'host_proof_required', p.host_proof_required, 'verification_required', p.verification_required,
            'host_instructions', p.host_instructions, 'customer_instructions', p.customer_instructions) order by p.sort, p.name)
          from service_plans p where p.service_id = s.id and p.active)) order by s.sort, s.name)
      from services s where s.active and exists (select 1 from service_plans p where p.service_id = s.id and p.active)), '[]'::jsonb));
$$;

create or replace function public.explore_listings() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(_listing_obj(l.id) order by l.created_at desc), '[]'::jsonb)
  from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id join profiles h on h.id = l.host_id
  where l.status = 'LIVE' and p.active and s.active and h.status = 'ACTIVE';
$$;

-- One listing for the join screen. Hidden unless LIVE (or you are its host).
create or replace function public.listing_detail(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o jsonb; l listings;
begin
  select * into l from listings where id = p_id;
  if not found or (l.status <> 'LIVE' and l.host_id is distinct from auth.uid()) then
    raise exception 'This plan is not available right now.';
  end if;
  o := _listing_obj(p_id);
  if auth.uid() is not null then
    o := o || jsonb_build_object('viewer', jsonb_build_object(
      'wallet_kobo', _balance(auth.uid(), 'WALLET'),
      'is_host', l.host_id = auth.uid(),
      'is_member', exists (select 1 from memberships m where m.listing_id = p_id and m.buyer_id = auth.uid()
                           and (m.status = 'DISPUTED' or (m.status = 'ACTIVE' and m.ends_at > now())))));
  end if;
  return o;
end $$;

-- ---------------------------------------------------------------------
-- SEAT PURCHASE (the heart of the marketplace)
-- ---------------------------------------------------------------------
-- Checks a listing can be joined by this user; returns the backend price. Locks the listing row.
create or replace function public._join_check(p_user uuid, p_listing uuid, p_contact text) returns bigint
language plpgsql security definer set search_path = public as $$
declare l listings; p service_plans; s services; v_user_status text; v_host_status text; v_digits text;
begin
  select status into v_user_status from profiles where id = p_user;
  if v_user_status is distinct from 'ACTIVE' then raise exception 'Your account is suspended. Please contact support.'; end if;
  select * into l from listings where id = p_listing for update;
  if not found or l.status <> 'LIVE' then raise exception 'This plan is not open right now.'; end if;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  select status into v_host_status from profiles where id = l.host_id;
  if not p.active or not s.active or v_host_status <> 'ACTIVE' then raise exception 'This plan is not open right now.'; end if;
  if l.host_id = p_user then raise exception 'You cannot join your own plan.'; end if;
  if exists (select 1 from memberships where listing_id = l.id and buyer_id = p_user
             and (status = 'DISPUTED' or (status = 'ACTIVE' and ends_at > now()))) then
    raise exception 'You already have a seat in this plan.';
  end if;
  if _occupied(l.id) >= l.seats_offered then raise exception 'Sorry, this plan is full. Please pick another one.'; end if;
  if p.access_type in ('INVITE','FAMILY','TEAM') and coalesce(p_contact, '') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter the email address the host should invite.';
  end if;
  if p.access_type = 'DATA' then
    v_digits := regexp_replace(coalesce(p_contact, ''), '\D', '', 'g');
    if v_digits !~ '^(0|234)[789][01]\d{8}$' then raise exception 'Enter the phone number that should receive the data.'; end if;
  end if;
  return _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct);
end $$;

create or replace function public._join(p_user uuid, p_listing uuid, p_contact text, p_payment text) returns uuid
language plpgsql security definer set search_path = public as $$
declare l listings; p service_plans; s services; v_buyer text; v_price bigint; v_fee bigint; v_id uuid; v_ref text; v_ready boolean;
begin
  -- Close seats whose time is up so they don't block a new purchase.
  perform release_due_escrow();
  v_price := _join_check(p_user, p_listing, p_contact);   -- also locks the listing row (no overselling)
  select * into l from listings where id = p_listing;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  select username into v_buyer from profiles where id = p_user;
  v_fee := _fee(v_price);
  v_ref := _ref('SUB');
  v_ready := p.access_type = 'LOGIN';
  insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, contact, starts_at, ends_at,
                           access_status, payment_reference)
  values (l.id, p.id, p_user, l.host_id, v_price, v_fee, v_price - v_fee, trim(coalesce(p_contact, '')), now(),
          now() + make_interval(days => p.duration_days), case when v_ready then 'READY' else 'WAITING' end, p_payment)
  returning id into v_id;
  perform _post(p_user, 'WALLET', 'SUBSCRIPTION', -v_price, 'Seat: ' || s.name || ' · ' || p.name, v_ref, v_id, l.id, p_payment);
  perform _post(l.host_id, 'PENDING', 'HOST_EARNING_PENDING', v_price - v_fee, s.name || ' seat · @' || v_buyer, v_ref, v_id, l.id, p_payment);
  perform _notify(p_user, 'SUBSCRIPTION_JOINED', 'You joined ' || s.name,
    case when v_ready then 'Your access details are ready in My Subs.'
         else 'The host will send your access to ' || trim(p_contact) || '. We will let you know when it is sent.' end);
  perform _notify(l.host_id, 'NEW_MEMBER', 'New member in your ' || s.name || ' plan',
    '@' || v_buyer || ' paid for a seat.' || case when v_ready then '' else ' Please send access to ' || trim(p_contact) || ' and mark it as sent.' end);
  return v_id;
end $$;

create or replace function public.join_with_wallet(p_listing uuid, p_contact text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_id uuid;
begin
  me := _me();
  v_id := _join(me.id, p_listing, p_contact, null);
  return jsonb_build_object('membership_id', v_id);
end $$;

create or replace function public.renew_membership(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; l listings; p service_plans; s services; v_price bigint; v_fee bigint; v_id uuid; v_ref text; v_window int;
begin
  me := _me();
  select * into m from memberships where id = p_id and buyer_id = me.id for update;
  if not found or m.status <> 'ACTIVE' or m.ends_at <= now() then raise exception 'Only active subscriptions can be renewed.'; end if;
  if m.renewed then raise exception 'You already renewed this subscription.'; end if;
  select renewal_window_days into v_window from platform_settings where id = 1;
  if m.ends_at > now() + make_interval(days => v_window) then
    raise exception 'You can renew in the last % days of your subscription.', v_window;
  end if;
  select * into l from listings where id = m.listing_id for update;
  if l.status <> 'LIVE' then raise exception 'The host has paused this plan, so it cannot be renewed right now.'; end if;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  if not p.active or not s.active then raise exception 'This service is not available right now.'; end if;
  v_price := _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct);
  v_fee := _fee(v_price);
  v_ref := _ref('REN');
  update memberships set renewed = true where id = m.id;
  insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, contact, starts_at, ends_at,
                           access_status, renewed_from)
  values (l.id, p.id, me.id, l.host_id, v_price, v_fee, v_price - v_fee, m.contact, m.ends_at,
          m.ends_at + make_interval(days => p.duration_days), m.access_status, m.id)
  returning id into v_id;
  perform _post(me.id, 'WALLET', 'SUBSCRIPTION', -v_price, 'Renewal: ' || s.name || ' · ' || p.name, v_ref, v_id, l.id);
  perform _post(l.host_id, 'PENDING', 'HOST_EARNING_PENDING', v_price - v_fee, s.name || ' renewal · @' || me.username, v_ref, v_id, l.id);
  perform _notify(me.id, 'SUBSCRIPTION_RENEWED', s.name || ' renewed', 'Your next period starts on ' || to_char(m.ends_at, 'DD Mon YYYY') || '.');
  perform _notify(l.host_id, 'NEW_MEMBER', '@' || me.username || ' renewed their ' || s.name || ' seat', '');
  return jsonb_build_object('membership_id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- ESCROW: release, refund
-- ---------------------------------------------------------------------
create or replace function public._release(p_id uuid, p_why text) returns void
language plpgsql security definer set search_path = public as $$
declare m memberships; v_service text; v_ref text;
begin
  select * into m from memberships where id = p_id for update;
  if not found or m.escrow <> 'HELD' then raise exception 'This payment is already settled.'; end if;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  v_ref := _ref('REL');
  perform _post(m.host_id, 'PENDING', 'PENDING_RELEASED', -m.host_kobo, v_service || ' seat · ' || p_why, v_ref, m.id, m.listing_id);
  perform _post(m.host_id, 'EARNINGS', 'HOST_EARNING', m.host_kobo, v_service || ' seat · ' || p_why, v_ref, m.id, m.listing_id);
  perform _post(null, 'PLATFORM', 'PLATFORM_FEE', m.fee_kobo, v_service || ' seat fee', v_ref, m.id, m.listing_id);
  update memberships set escrow = 'RELEASED', status = 'COMPLETED' where id = m.id;
  perform _notify(m.host_id, 'EARNING_AVAILABLE', _naira(m.host_kobo) || ' is ready to withdraw', 'From a ' || v_service || ' seat.');
end $$;

create or replace function public.release_due_escrow() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id from memberships where escrow = 'HELD' and status = 'ACTIVE' and ends_at <= now()
           order by ends_at for update skip locked
  loop
    perform _release(r.id, 'period completed');
    n := n + 1;
  end loop;
  return n;
end $$;

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
  perform _notify(m.buyer_id, 'REFUND', _naira(p_amount) || ' refunded to your wallet', v_service || ': ' || p_why);
  perform _notify(m.host_id, 'REFUND', 'A ' || v_service || ' seat was refunded',
    case when v_rest > 0 then 'Part of the payment was refunded to the member.' else 'The full payment was returned to the member.' end);
end $$;

-- ---------------------------------------------------------------------
-- MEMBER ACTIONS
-- ---------------------------------------------------------------------
create or replace function public.my_overview() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return jsonb_build_object(
    'profile', jsonb_build_object('id', me.id, 'full_name', me.full_name, 'username', me.username, 'phone', me.phone, 'email', me.email,
                                  'verified_host', me.verified_host, 'created_at', me.created_at),
    'balances', jsonb_build_object(
       'wallet_kobo', _balance(me.id, 'WALLET'), 'earnings_kobo', _balance(me.id, 'EARNINGS'), 'pending_kobo', _balance(me.id, 'PENDING'),
       'withdrawn_kobo', coalesce((select sum(amount_kobo) from withdrawals where user_id = me.id and status = 'PAID'), 0),
       'processing_kobo', coalesce((select sum(amount_kobo) from withdrawals where user_id = me.id and status in ('PENDING','APPROVED')), 0),
       'total_earned_kobo', coalesce((select sum(amount_kobo) from wallet_transactions where user_id = me.id and type = 'HOST_EARNING'), 0)),
    'unread', (select count(*) from notifications where user_id = me.id and read_at is null));
end $$;

create or replace function public.my_subscriptions() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_window int;
begin
  me := _me();
  select renewal_window_days into v_window from platform_settings where id = 1;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', m.id, 'listing_id', m.listing_id, 'service', s.name, 'plan', p.name, 'logo_color', s.logo_color, 'logo_url', s.logo_url,
    'access_type', p.access_type, 'host_username', h.username, 'amount_kobo', m.amount_kobo, 'refund_kobo', m.refund_kobo,
    'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'access_status', m.access_status, 'renewed', m.renewed,
    'contact', m.contact,
    'renew_price_kobo', case when l.status = 'LIVE' then _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct) end,
    'can_renew', (m.status = 'ACTIVE' and not m.renewed and m.ends_at > now() and m.starts_at <= now()
                  and m.ends_at <= now() + make_interval(days => v_window) and l.status = 'LIVE' and p.active and s.active),
    'dispute', (select jsonb_build_object('id', d.id, 'status', d.status, 'reason', d.reason, 'resolution', d.resolution)
                from disputes d where d.membership_id = m.id order by d.created_at desc limit 1))
    order by m.starts_at desc)
  from memberships m join listings l on l.id = m.listing_id join service_plans p on p.id = m.plan_id
  join services s on s.id = p.service_id join profiles h on h.id = m.host_id
  where m.buyer_id = me.id), '[]'::jsonb);
end $$;

create or replace function public.get_access(p_listing uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; l listings; p service_plans; m memberships; v_details text;
begin
  me := _me();
  select * into l from listings where id = p_listing;
  if not found then raise exception 'Plan not found.'; end if;
  select * into m from memberships where listing_id = p_listing and buyer_id = me.id
    and (status = 'DISPUTED' or (status = 'ACTIVE' and ends_at > now())) order by starts_at limit 1;
  if l.host_id <> me.id and m.id is null and not is_admin() then
    raise exception using errcode = '42501', message = 'Only members of this plan can see its access details.';
  end if;
  select * into p from service_plans where id = l.plan_id;
  select details into v_details from listing_access where listing_id = p_listing;
  return jsonb_build_object('access_type', p.access_type, 'details', coalesce(v_details, ''),
    'customer_instructions', p.customer_instructions, 'access_status', m.access_status, 'contact', m.contact);
end $$;

create or replace function public.open_dispute(p_membership uuid, p_reason text, p_details text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; v_id uuid; v_service text;
begin
  me := _me();
  if coalesce(p_reason, '') not in ('NOT_WORKING','NO_ACCESS','WRONG_PLAN','REMOVED','OTHER') then raise exception 'Pick what went wrong.'; end if;
  if length(trim(coalesce(p_details, ''))) < 10 then raise exception 'Tell us a little more (at least 10 letters) so we can help.'; end if;
  select * into m from memberships where id = p_membership and buyer_id = me.id for update;
  if not found or m.status <> 'ACTIVE' or m.ends_at <= now() then raise exception 'You can only report a subscription that is active.'; end if;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  insert into disputes (membership_id, listing_id, buyer_id, host_id, reason, details)
  values (m.id, m.listing_id, me.id, m.host_id, p_reason, left(trim(p_details), 2000)) returning id into v_id;
  update memberships set status = 'DISPUTED' where id = m.id;
  perform _notify(me.id, 'DISPUTE_OPENED', 'We got your report', 'Our team will look into your ' || v_service || ' seat and get back to you.');
  perform _notify(m.host_id, 'DISPUTE_OPENED', 'A member needs help with ' || v_service, 'Please check My Subs and reply to the report.');
  return jsonb_build_object('dispute_id', v_id);
end $$;

create or replace function public.update_my_profile(p_full_name text, p_phone text, p_username text default null) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  if length(trim(coalesce(p_full_name, ''))) < 2 then raise exception 'Enter your full name.'; end if;
  if p_username is not null and p_username <> me.username then
    if p_username !~ '^[a-z0-9_.]{3,20}$' then raise exception 'Usernames use 3-20 small letters, numbers, dots or underscores.'; end if;
    if exists (select 1 from profiles where username = p_username) then raise exception 'That username is taken.'; end if;
  end if;
  update profiles set full_name = left(trim(p_full_name), 80), phone = left(trim(coalesce(p_phone, '')), 20),
    username = coalesce(p_username, username) where id = me.id;
end $$;

create or replace function public.my_notifications() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'type', type, 'title', title, 'body', body, 'read', read_at is not null,
           'created_at', created_at) order by created_at desc)
         from (select * from notifications where user_id = me.id order by created_at desc limit 60) n), '[]'::jsonb);
end $$;

create or replace function public.mark_notifications_read() returns void
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  update notifications set read_at = now() where user_id = me.id and read_at is null;
end $$;

-- ---------------------------------------------------------------------
-- WALLET, EARNINGS, WITHDRAWALS
-- ---------------------------------------------------------------------
create or replace function public.my_wallet() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return jsonb_build_object(
    'transactions', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'type', t.type, 'account', t.account_kind,
        'amount_kobo', t.amount_kobo, 'balance_after_kobo', t.balance_after_kobo, 'description', t.description,
        'reference', t.reference, 'created_at', t.created_at) order by t.id desc)
      from (select * from wallet_transactions where user_id = me.id order by id desc limit 100) t), '[]'::jsonb),
    'withdrawals', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'amount_kobo', w.amount_kobo, 'bank_name', w.bank_name,
        'account_number', w.account_number, 'account_name', w.account_name, 'status', w.status, 'note', w.admin_note,
        'created_at', w.created_at) order by w.created_at desc) from withdrawals w where w.user_id = me.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('reference', x.reference, 'purpose', x.purpose, 'amount_kobo', x.amount_kobo,
        'status', x.status, 'created_at', x.created_at) order by x.created_at desc)
      from (select * from payments where user_id = me.id order by created_at desc limit 30) x), '[]'::jsonb));
end $$;

create or replace function public.move_earnings(p_amount_kobo bigint) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; v_ref text;
begin
  me := _me();
  if p_amount_kobo is null or p_amount_kobo <= 0 then raise exception 'Enter an amount.'; end if;
  v_ref := _ref('TRF');
  perform _post(me.id, 'EARNINGS', 'TRANSFER_OUT', -p_amount_kobo, 'Moved to wallet', v_ref);
  perform _post(me.id, 'WALLET', 'TRANSFER_IN', p_amount_kobo, 'From host earnings', v_ref);
end $$;

create or replace function public.request_withdrawal(p_amount_kobo bigint, p_bank text, p_account_number text, p_account_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_min bigint; v_ref text; v_id uuid;
begin
  me := _me();
  select min_withdrawal_kobo into v_min from platform_settings where id = 1;
  if p_amount_kobo is null or p_amount_kobo < v_min then raise exception 'The smallest withdrawal is %.', _naira(v_min); end if;
  if p_amount_kobo > _balance(me.id, 'EARNINGS') then raise exception 'You can withdraw up to %.', _naira(_balance(me.id, 'EARNINGS')); end if;
  if coalesce(p_account_number, '') !~ '^\d{10}$' then raise exception 'Account numbers have 10 digits.'; end if;
  if length(trim(coalesce(p_bank, ''))) < 2 then raise exception 'Pick your bank.'; end if;
  if length(trim(coalesce(p_account_name, ''))) < 3 then raise exception 'Enter the name on the bank account.'; end if;
  v_ref := _ref('WDR');
  insert into withdrawals (user_id, amount_kobo, bank_name, account_number, account_name, ledger_reference)
  values (me.id, p_amount_kobo, trim(p_bank), p_account_number, left(trim(p_account_name), 80), v_ref) returning id into v_id;
  perform _post(me.id, 'EARNINGS', 'WITHDRAWAL', -p_amount_kobo, 'Withdrawal to ' || trim(p_bank) || ' ' || p_account_number,
                v_ref, null, null, null, v_id);
  return jsonb_build_object('withdrawal_id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- HOSTING
-- ---------------------------------------------------------------------
create or replace function public.host_create_listing(p_plan uuid, p_markup_pct int, p_seats int, p_access text, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; p service_plans; s services; v_id uuid;
begin
  me := _me();
  select * into p from service_plans where id = p_plan;
  if not found or not p.active then raise exception 'Pick a service plan.'; end if;
  select * into s from services where id = p.service_id;
  if not s.active then raise exception 'This service is not available for sharing right now.'; end if;
  if p_markup_pct is null or p_markup_pct < p.min_markup_pct or p_markup_pct > p.max_markup_pct then
    raise exception using message = format('Markup for %s must be between %s%% and %s%%.', s.name, p.min_markup_pct, p.max_markup_pct);
  end if;
  if p_seats is null or p_seats < 1 or p_seats > p.max_seats then
    raise exception 'SplitSub allows up to % seats for % %.', p.max_seats, s.name, p.name;
  end if;
  if p.access_type = 'LOGIN' and length(trim(coalesce(p_access, ''))) < 5 then
    raise exception 'Add the login details members will use. Only paying members can see them.';
  end if;
  insert into listings (host_id, plan_id, markup_pct, seats_offered, note, status)
  values (me.id, p.id, p_markup_pct, p_seats, left(trim(coalesce(p_note, '')), 300), 'DRAFT') returning id into v_id;
  insert into listing_access (listing_id, details) values (v_id, left(trim(coalesce(p_access, '')), 2000));
  return jsonb_build_object('listing_id', v_id, 'status', 'DRAFT', 'proof_folder', me.id || '/' || v_id || '/');
end $$;

-- Sends a draft (or rejected) listing for review. Checks the uploaded proof belongs to this host and listing.
create or replace function public.host_submit_listing(p_listing uuid, p_proof_path text default '', p_proof_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; l listings; p service_plans; v_auto boolean; v_status text; v_has_file boolean := false;
begin
  me := _me();
  select * into l from listings where id = p_listing and host_id = me.id for update;
  if not found then raise exception 'Listing not found.'; end if;
  if l.status not in ('DRAFT','REJECTED') then raise exception 'This listing was already submitted.'; end if;
  select * into p from service_plans where id = l.plan_id;
  if coalesce(p_proof_path, '') <> '' then
    if p_proof_path not like me.id || '/' || l.id || '/%' then raise exception 'That proof file does not belong to this listing.'; end if;
    select exists (select 1 from storage.objects where bucket_id = 'host-proofs' and name = p_proof_path) into v_has_file;
    if not v_has_file then raise exception 'We could not find your uploaded proof. Please upload it again.'; end if;
  end if;
  if p.host_proof_required and not v_has_file and l.proof_path = '' then
    raise exception 'Upload proof that you own this plan (a receipt or a screenshot of the subscription page).';
  end if;
  select auto_approve_listings into v_auto from platform_settings where id = 1;
  v_status := case when v_auto and not p.verification_required then 'LIVE' else 'PENDING_REVIEW' end;
  update listings set status = v_status, submitted_at = now(), updated_at = now(),
    proof_path = case when v_has_file then p_proof_path else proof_path end,
    proof_note = left(trim(coalesce(p_proof_note, proof_note)), 500)
  where id = l.id;
  return jsonb_build_object('status', v_status);
end $$;

create or replace function public.host_update_listing(p_listing uuid, p_markup_pct int, p_seats int, p_access text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare me profiles; l listings; p service_plans; v_occ int;
begin
  me := _me();
  select * into l from listings where id = p_listing and host_id = me.id for update;
  if not found then raise exception using errcode = '42501', message = 'You can only manage your own listings.'; end if;
  if l.status = 'SUSPENDED' then raise exception 'This listing is suspended. Please contact support.'; end if;
  select * into p from service_plans where id = l.plan_id;
  if p_markup_pct < p.min_markup_pct or p_markup_pct > p.max_markup_pct then
    raise exception using message = format('Markup must be between %s%% and %s%%.', p.min_markup_pct, p.max_markup_pct);
  end if;
  v_occ := _occupied(l.id);
  if p_seats < greatest(v_occ, 1) or p_seats > p.max_seats then
    raise exception 'Seats must be between % and %.', greatest(v_occ, 1), p.max_seats;
  end if;
  if p.access_type = 'LOGIN' and length(trim(coalesce(p_access, ''))) < 5 then raise exception 'Login details cannot be empty.'; end if;
  update listings set markup_pct = p_markup_pct, seats_offered = p_seats, note = left(trim(coalesce(p_note, '')), 300), updated_at = now()
  where id = l.id;
  insert into listing_access (listing_id, details) values (l.id, left(trim(coalesce(p_access, '')), 2000))
  on conflict (listing_id) do update set details = excluded.details, updated_at = now();
end $$;

create or replace function public.host_set_paused(p_listing uuid, p_paused boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; l listings;
begin
  me := _me();
  select * into l from listings where id = p_listing and host_id = me.id for update;
  if not found then raise exception using errcode = '42501', message = 'You can only manage your own listings.'; end if;
  if p_paused and l.status = 'LIVE' then update listings set status = 'PAUSED', updated_at = now() where id = l.id;
  elsif not p_paused and l.status = 'PAUSED' then update listings set status = 'LIVE', updated_at = now() where id = l.id;
  else raise exception 'Only live or paused listings can be paused or resumed.';
  end if;
end $$;

create or replace function public.host_mark_access_sent(p_membership uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; v_service text;
begin
  me := _me();
  select * into m from memberships where id = p_membership and host_id = me.id for update;
  if not found then raise exception using errcode = '42501', message = 'You can only update your own members.'; end if;
  if m.status not in ('ACTIVE','DISPUTED') then raise exception 'This seat is no longer active.'; end if;
  update memberships set access_status = 'SENT' where id = m.id;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  perform _notify(m.buyer_id, 'ACCESS_AVAILABLE', 'Your ' || v_service || ' access was sent',
    'The host sent your access to ' || m.contact || '. Check your inbox or phone.');
end $$;

create or replace function public.host_respond_dispute(p_dispute uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; d disputes;
begin
  me := _me();
  select * into d from disputes where id = p_dispute and host_id = me.id for update;
  if not found then raise exception using errcode = '42501', message = 'Report not found.'; end if;
  if d.status not in ('OPEN','IN_REVIEW') then raise exception 'This report is already closed.'; end if;
  if length(trim(coalesce(p_text, ''))) < 5 then raise exception 'Write a short reply.'; end if;
  update disputes set host_response = left(trim(p_text), 2000), updated_at = now() where id = d.id;
end $$;

create or replace function public.my_listings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
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
      'review_note', l.review_note, 'created_at', l.created_at,
      'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'buyer_username', b.username, 'buyer_name', split_part(b.full_name, ' ', 1),
            'contact', m.contact, 'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'access_status', m.access_status,
            'host_kobo', m.host_kobo, 'escrow', m.escrow) order by m.starts_at desc)
          from memberships m join profiles b on b.id = m.buyer_id where m.listing_id = l.id), '[]'::jsonb),
      'disputes', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'membership_id', d.membership_id, 'status', d.status,
            'reason', d.reason, 'details', d.details, 'host_response', d.host_response, 'resolution', d.resolution, 'created_at', d.created_at)
            order by d.created_at desc) from disputes d where d.listing_id = l.id), '[]'::jsonb))
    order by l.created_at desc)
  from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id
  left join listing_access a on a.listing_id = l.id
  where l.host_id = me.id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- SUPPORT
-- ---------------------------------------------------------------------
create or replace function public.create_ticket(p_subject text, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_id uuid;
begin
  me := _me();
  if length(trim(coalesce(p_subject, ''))) < 3 then raise exception 'Add a short subject.'; end if;
  if length(trim(coalesce(p_body, ''))) < 10 then raise exception 'Tell us a little more (at least 10 letters).'; end if;
  if (select count(*) from support_tickets where user_id = me.id and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'You have sent several messages. Please wait for our reply.';
  end if;
  insert into support_tickets (user_id, subject) values (me.id, left(trim(p_subject), 120)) returning id into v_id;
  insert into support_messages (ticket_id, author_id, body) values (v_id, me.id, left(trim(p_body), 4000));
  return jsonb_build_object('ticket_id', v_id);
end $$;

create or replace function public.reply_ticket(p_ticket uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  if not exists (select 1 from support_tickets where id = p_ticket and user_id = me.id) then
    raise exception using errcode = '42501', message = 'Ticket not found.';
  end if;
  if length(trim(coalesce(p_body, ''))) < 2 then raise exception 'Write a message.'; end if;
  insert into support_messages (ticket_id, author_id, body) values (p_ticket, me.id, left(trim(p_body), 4000));
  update support_tickets set status = 'OPEN', updated_at = now() where id = p_ticket;
end $$;

create or replace function public.my_tickets() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'subject', t.subject, 'status', t.status, 'updated_at', t.updated_at,
      'messages', (select jsonb_agg(jsonb_build_object('from_admin', m.from_admin, 'body', m.body, 'created_at', m.created_at) order by m.created_at)
                   from support_messages m where m.ticket_id = t.id)) order by t.updated_at desc)
    from support_tickets t where t.user_id = me.id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- PAYMENTS (called ONLY by the Edge Functions with the service key)
-- ---------------------------------------------------------------------
create or replace function public.payment_create(p_user uuid, p_reference text, p_purpose text, p_amount_kobo bigint,
  p_listing uuid default null, p_contact text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_status text; v_email text; v_amount bigint; s platform_settings;
begin
  select status, email into v_status, v_email from profiles where id = p_user;
  if v_status is null then raise exception 'Account not found.'; end if;
  if v_status <> 'ACTIVE' then raise exception 'Your account is suspended. Please contact support.'; end if;
  select * into s from platform_settings where id = 1;
  if p_purpose = 'TOPUP' then
    if p_amount_kobo is null or p_amount_kobo < s.min_topup_kobo or p_amount_kobo > s.max_topup_kobo then
      raise exception 'Enter an amount between % and %.', _naira(s.min_topup_kobo), _naira(s.max_topup_kobo);
    end if;
    v_amount := p_amount_kobo;
  elsif p_purpose = 'SEAT' then
    v_amount := _join_check(p_user, p_listing, p_contact);   -- backend price; the browser's amount is ignored
  else
    raise exception 'Unknown payment type.';
  end if;
  insert into payments (reference, user_id, purpose, listing_id, contact, amount_kobo)
  values (p_reference, p_user, p_purpose, case when p_purpose = 'SEAT' then p_listing end, trim(coalesce(p_contact, '')), v_amount);
  return jsonb_build_object('reference', p_reference, 'amount_kobo', v_amount, 'email', v_email);
end $$;

-- Called after the Edge Function has VERIFIED the payment with Paystack. Safe to call many times.
create or replace function public.payment_complete(p_reference text, p_paid_kobo bigint, p_currency text, p_provider_id text, p_channel text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare x payments; v_ref text; v_joined boolean := false; v_mid uuid; v_msg text := '';
begin
  select * into x from payments where reference = p_reference for update;
  if not found then return jsonb_build_object('result', 'UNKNOWN'); end if;
  if x.status = 'SUCCESS' then
    return jsonb_build_object('result', 'ALREADY', 'purpose', x.purpose, 'amount_kobo', x.paid_kobo, 'membership_id', x.membership_id,
                              'joined', x.membership_id is not null);
  end if;
  if coalesce(p_currency, '') <> 'NGN' or p_paid_kobo is null or p_paid_kobo <= 0 then
    update payments set status = 'FAILED', note = 'Invalid currency or amount from Paystack', verified_at = now() where reference = x.reference;
    return jsonb_build_object('result', 'FAILED');
  end if;
  v_ref := _ref('PAY');
  update payments set status = 'SUCCESS', paid_kobo = p_paid_kobo, provider_id = p_provider_id, channel = p_channel, verified_at = now(),
    note = case when p_paid_kobo <> x.amount_kobo then 'Paid amount differs from expected' else '' end
  where reference = x.reference;
  perform _post(x.user_id, 'WALLET', 'TOP_UP', p_paid_kobo, 'Added money · Paystack', v_ref, null, x.listing_id, x.reference);
  perform _notify(x.user_id, 'PAYMENT_SUCCESS', 'Payment successful', _naira(p_paid_kobo) || ' was added to your wallet.');
  if x.purpose = 'SEAT' then
    begin
      v_mid := _join(x.user_id, x.listing_id, x.contact, x.reference);
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

create or replace function public.payment_fail(p_reference text, p_status text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare x payments;
begin
  if p_status not in ('FAILED','ABANDONED') then raise exception 'Bad status'; end if;
  select * into x from payments where reference = p_reference for update;
  if not found then return jsonb_build_object('result', 'UNKNOWN'); end if;
  if x.status <> 'PENDING' then return jsonb_build_object('result', x.status); end if;
  update payments set status = p_status, note = left(coalesce(p_note, ''), 300), verified_at = now() where reference = x.reference;
  if p_status = 'FAILED' then
    perform _notify(x.user_id, 'PAYMENT_FAILED', 'Payment failed', 'Your payment of ' || _naira(x.amount_kobo) || ' did not go through. No money was taken.');
  end if;
  return jsonb_build_object('result', p_status);
end $$;

-- ---------------------------------------------------------------------
-- SCHEDULED JOBS (see 004_cron.sql)
-- ---------------------------------------------------------------------
create or replace function public.send_expiry_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_days int;
begin
  select reminder_days into v_days from platform_settings where id = 1;
  for r in select m.id, m.buyer_id, m.ends_at, s.name from memberships m
             join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id
           where m.status = 'ACTIVE' and not m.renewed and not m.reminder_sent
             and m.ends_at > now() and m.ends_at <= now() + make_interval(days => v_days)
  loop
    perform _notify(r.buyer_id, 'EXPIRING', 'Your ' || r.name || ' seat ends soon',
      'It ends on ' || to_char(r.ends_at, 'DD Mon YYYY') || '. Renew from My Subs to keep your access.');
    update memberships set reminder_sent = true where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- =====================================================================
-- ADMIN FUNCTIONS — every one starts with _need_admin() (403 for others)
-- =====================================================================
create or replace function public.admin_me() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  perform _need_admin();
  select * into me from profiles where id = auth.uid();
  return jsonb_build_object('id', me.id, 'full_name', me.full_name, 'username', me.username, 'email', me.email);
end $$;

create or replace function public.admin_ledger_check() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('account_id', a.id, 'owner', p.username, 'kind', a.kind,
      'balance_kobo', a.balance_kobo, 'ledger_kobo', coalesce(t.s, 0)))
    from wallet_accounts a left join profiles p on p.id = a.owner_id
    left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) t on t.account_id = a.id
    where a.balance_kobo <> coalesce(t.s, 0)), '[]'::jsonb);
end $$;

create or replace function public.admin_dashboard() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  perform release_due_escrow();
  return jsonb_build_object(
    'users', (select count(*) from profiles),
    'hosts', (select count(distinct host_id) from listings),
    'live_listings', (select count(*) from listings where status = 'LIVE'),
    'pending_reviews', (select count(*) from listings where status = 'PENDING_REVIEW'),
    'active_memberships', (select count(*) from memberships where status = 'ACTIVE' and ends_at > now()),
    'escrow_kobo', coalesce((select sum(amount_kobo) from memberships where escrow = 'HELD'), 0),
    'fees_kobo', _balance(null, 'PLATFORM'),
    'wallets_kobo', coalesce((select sum(balance_kobo) from wallet_accounts where kind = 'WALLET'), 0),
    'earnings_kobo', coalesce((select sum(balance_kobo) from wallet_accounts where kind = 'EARNINGS'), 0),
    'withdrawals_due_kobo', coalesce((select sum(amount_kobo) from withdrawals where status in ('PENDING','APPROVED')), 0),
    'withdrawals_due', (select count(*) from withdrawals where status in ('PENDING','APPROVED')),
    'open_disputes', (select count(*) from disputes where status in ('OPEN','IN_REVIEW')),
    'open_tickets', (select count(*) from support_tickets where status = 'OPEN'),
    'pending_payments', (select count(*) from payments where status = 'PENDING' and created_at < now() - interval '15 minutes'),
    'payments_today_kobo', coalesce((select sum(paid_kobo) from payments where status = 'SUCCESS' and verified_at > now() - interval '1 day'), 0),
    'ledger_ok', (select count(*) = 0 from wallet_accounts a
                  left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) t on t.account_id = a.id
                  where a.balance_kobo <> coalesce(t.s, 0)),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('action', x.action, 'entity', x.entity, 'note', x.note, 'created_at', x.created_at,
                 'admin', (select username from profiles where id = x.admin_id)) order by x.id desc)
               from (select * from admin_audit_logs order by id desc limit 8) x), '[]'::jsonb));
end $$;

create or replace function public.admin_users(p_search text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare q text := '%' || lower(trim(coalesce(p_search, ''))) || '%';
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'username', p.username, 'email', p.email,
      'phone', p.phone, 'status', p.status, 'verified_host', p.verified_host,
      'is_admin', exists (select 1 from admin_users a where a.user_id = p.id),
      'wallet_kobo', _balance(p.id, 'WALLET'), 'earnings_kobo', _balance(p.id, 'EARNINGS'), 'pending_kobo', _balance(p.id, 'PENDING'),
      'listings', (select count(*) from listings l where l.host_id = p.id),
      'seats', (select count(*) from memberships m where m.buyer_id = p.id and m.status in ('ACTIVE','DISPUTED')),
      'created_at', p.created_at) order by p.created_at desc)
    from (select * from profiles p where lower(p.full_name || ' ' || p.username || ' ' || p.email || ' ' || p.phone) like q
          order by created_at desc limit 300) p), '[]'::jsonb);
end $$;

create or replace function public.admin_user_detail(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return jsonb_build_object(
    'transactions', coalesce((select jsonb_agg(jsonb_build_object('type', t.type, 'account', t.account_kind, 'amount_kobo', t.amount_kobo,
        'balance_after_kobo', t.balance_after_kobo, 'description', t.description, 'reference', t.reference, 'created_at', t.created_at) order by t.id desc)
      from (select * from wallet_transactions where user_id = p_id order by id desc limit 50) t), '[]'::jsonb),
    'listings', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'service', s.name, 'plan', p.name, 'status', l.status,
        'seats', l.seats_offered, 'occupied', _occupied(l.id)) order by l.created_at desc)
      from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id where l.host_id = p_id), '[]'::jsonb),
    'memberships', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'service', s.name, 'status', m.status, 'amount_kobo', m.amount_kobo,
        'ends_at', m.ends_at) order by m.starts_at desc)
      from memberships m join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id where m.buyer_id = p_id), '[]'::jsonb));
end $$;

create or replace function public.admin_update_user(p_id uuid, p_status text, p_verified boolean, p_is_admin boolean, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare old profiles; was_admin boolean;
begin
  perform _need_admin();
  select * into old from profiles where id = p_id for update;
  if not found then raise exception 'User not found.'; end if;
  if p_status not in ('ACTIVE','SUSPENDED') then raise exception 'Unknown status.'; end if;
  was_admin := exists (select 1 from admin_users where user_id = p_id);
  if p_id = auth.uid() and (p_status <> 'ACTIVE' or not p_is_admin) then
    raise exception 'You cannot suspend yourself or remove your own admin access.';
  end if;
  update profiles set status = p_status, verified_host = coalesce(p_verified, false) where id = p_id;
  if p_is_admin and not was_admin then insert into admin_users (user_id, granted_by) values (p_id, auth.uid());
  elsif not p_is_admin and was_admin then delete from admin_users where user_id = p_id; end if;
  if p_status = 'SUSPENDED' and old.status <> 'SUSPENDED' then
    update listings set status = 'SUSPENDED', updated_at = now() where host_id = p_id and status in ('LIVE','PENDING_REVIEW');
  end if;
  perform _audit('UPDATE_USER', 'profile', p_id::text,
    jsonb_build_object('status', old.status, 'verified_host', old.verified_host, 'is_admin', was_admin),
    jsonb_build_object('status', p_status, 'verified_host', p_verified, 'is_admin', p_is_admin), p_note);
end $$;

create or replace function public.admin_adjust_wallet(p_id uuid, p_kind text, p_amount_kobo bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare v_after bigint;
begin
  perform _need_admin();
  if p_kind not in ('WALLET','EARNINGS') then raise exception 'Pick wallet or earnings.'; end if;
  if p_amount_kobo is null or p_amount_kobo = 0 then raise exception 'Enter an amount.'; end if;
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write the reason for this adjustment.'; end if;
  if not exists (select 1 from profiles where id = p_id) then raise exception 'User not found.'; end if;
  v_after := _post(p_id, p_kind, 'ADJUSTMENT', p_amount_kobo, 'Adjustment: ' || trim(p_note), _ref('ADJ'));
  perform _audit('ADJUST_BALANCE', 'wallet', p_id::text, null,
    jsonb_build_object('kind', p_kind, 'amount_kobo', p_amount_kobo, 'balance_after_kobo', v_after), p_note);
  perform _notify(p_id, 'ADJUSTMENT', 'Your ' || lower(p_kind) || ' was adjusted',
    case when p_amount_kobo > 0 then '+' else '−' end || _naira(abs(p_amount_kobo)) || ': ' || trim(p_note));
end $$;

create or replace function public.admin_services() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('plans',
      coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object('example_seat_kobo', _seat_price(p.normal_price_kobo, p.max_seats, p.max_markup_pct),
          'listings', (select count(*) from listings l where l.plan_id = p.id)) order by p.sort, p.name)
        from service_plans p where p.service_id = s.id), '[]'::jsonb)) order by s.sort, s.name)
    from services s), '[]'::jsonb);
end $$;

create or replace function public.admin_save_service(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare old services; v_id uuid;
begin
  perform _need_admin();
  if length(trim(coalesce(p ->> 'name', ''))) < 2 then raise exception 'Enter the service name.'; end if;
  if nullif(p ->> 'id', '') is not null then
    select * into old from services where id = (p ->> 'id')::uuid for update;
    if not found then raise exception 'Service not found.'; end if;
    update services set name = trim(p ->> 'name'), category = coalesce(p ->> 'category', category),
      logo_color = coalesce(nullif(p ->> 'logo_color', ''), logo_color), logo_url = coalesce(p ->> 'logo_url', logo_url),
      description = coalesce(p ->> 'description', description), sharing_rules = coalesce(p ->> 'sharing_rules', sharing_rules),
      notes = coalesce(p ->> 'notes', notes), active = coalesce((p ->> 'active')::boolean, active),
      sort = coalesce((p ->> 'sort')::int, sort), updated_at = now()
    where id = old.id returning id into v_id;
    perform _audit('UPDATE_SERVICE', 'service', v_id::text, to_jsonb(old), (select to_jsonb(s) from services s where id = v_id));
  else
    insert into services (name, category, logo_color, logo_url, description, sharing_rules, notes, active, sort)
    values (trim(p ->> 'name'), coalesce(p ->> 'category', 'Other'), coalesce(nullif(p ->> 'logo_color', ''), '#5B5BD6'),
      coalesce(p ->> 'logo_url', ''), coalesce(p ->> 'description', ''), coalesce(p ->> 'sharing_rules', ''), coalesce(p ->> 'notes', ''),
      coalesce((p ->> 'active')::boolean, true), coalesce((p ->> 'sort')::int, 0))
    returning id into v_id;
    perform _audit('CREATE_SERVICE', 'service', v_id::text, null, (select to_jsonb(s) from services s where id = v_id));
  end if;
  return jsonb_build_object('id', v_id);
exception when unique_violation then raise exception 'A service with that name already exists.';
end $$;

create or replace function public.admin_save_plan(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare old service_plans; v_id uuid; v_new service_plans;
begin
  perform _need_admin();
  if length(trim(coalesce(p ->> 'name', ''))) < 2 then raise exception 'Enter the plan name.'; end if;
  if coalesce((p ->> 'normal_price_kobo')::bigint, 0) <= 0 then raise exception 'Enter the normal price.'; end if;
  if coalesce((p ->> 'max_seats')::int, 0) not between 1 and 20 then raise exception 'Maximum seats must be between 1 and 20.'; end if;
  if coalesce((p ->> 'min_markup_pct')::int, 0) < 10 or coalesce((p ->> 'max_markup_pct')::int, 99) > 30
     or (p ->> 'min_markup_pct')::int > (p ->> 'max_markup_pct')::int then
    raise exception using message = 'Markup must stay between 10% and 30%, and the minimum cannot be above the maximum.';
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
      sort = coalesce((p ->> 'sort')::int, 0), updated_at = now()
    where id = old.id returning * into v_new;
    v_id := v_new.id;
    -- Existing listings follow the new rules: clamp seats and markup into the new limits.
    update listings l set seats_offered = greatest(_occupied(l.id), v_new.max_seats), updated_at = now()
      where l.plan_id = v_id and l.seats_offered > v_new.max_seats;
    update listings l set markup_pct = least(greatest(l.markup_pct, v_new.min_markup_pct), v_new.max_markup_pct), updated_at = now()
      where l.plan_id = v_id and (l.markup_pct < v_new.min_markup_pct or l.markup_pct > v_new.max_markup_pct);
    perform _audit('UPDATE_PLAN', 'service_plan', v_id::text, to_jsonb(old), to_jsonb(v_new));
  else
    insert into service_plans (service_id, name, normal_price_kobo, compare_price_kobo, max_seats, access_type, duration_days, min_markup_pct, max_markup_pct,
      verification_required, host_proof_required, active, customer_instructions, host_instructions, notes, sort)
    values ((p ->> 'service_id')::uuid, trim(p ->> 'name'), (p ->> 'normal_price_kobo')::bigint, nullif((p ->> 'compare_price_kobo')::bigint, 0), (p ->> 'max_seats')::int, p ->> 'access_type',
      coalesce((p ->> 'duration_days')::int, 30), (p ->> 'min_markup_pct')::int, (p ->> 'max_markup_pct')::int,
      coalesce((p ->> 'verification_required')::boolean, true), coalesce((p ->> 'host_proof_required')::boolean, true),
      coalesce((p ->> 'active')::boolean, true), coalesce(p ->> 'customer_instructions', ''), coalesce(p ->> 'host_instructions', ''),
      coalesce(p ->> 'notes', ''), coalesce((p ->> 'sort')::int, 0))
    returning * into v_new;
    v_id := v_new.id;
    perform _audit('CREATE_PLAN', 'service_plan', v_id::text, null, to_jsonb(v_new));
  end if;
  return jsonb_build_object('id', v_id);
exception
  when unique_violation then raise exception 'This service already has a plan with that name.';
  when check_violation then raise exception 'Some values are outside the allowed limits. Check price, seats, days and access type.';
end $$;

create or replace function public.admin_listings(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(_listing_obj(l.id) || jsonb_build_object('proof_uploaded', l.proof_path <> '', 'submitted_at', l.submitted_at,
      'review_note', l.review_note, 'host_status', h.status) order by (l.status = 'PENDING_REVIEW') desc, l.created_at desc)
    from listings l join profiles h on h.id = l.host_id
    where p_status is null or p_status = '' or l.status = p_status), '[]'::jsonb);
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
    'proof_path', l.proof_path, 'proof_note', l.proof_note, 'review_note', l.review_note, 'submitted_at', l.submitted_at,
    'host_email', (select email from profiles where id = l.host_id), 'host_phone', (select phone from profiles where id = l.host_id),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'buyer', b.username, 'contact', m.contact, 'status', m.status,
        'escrow', m.escrow, 'amount_kobo', m.amount_kobo, 'ends_at', m.ends_at) order by m.starts_at desc)
      from memberships m join profiles b on b.id = m.buyer_id where m.listing_id = p_id), '[]'::jsonb));
end $$;

create or replace function public.admin_review_listing(p_id uuid, p_action text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare l listings; v_new text; v_service text;
begin
  perform _need_admin();
  select * into l from listings where id = p_id for update;
  if not found then raise exception 'Listing not found.'; end if;
  v_new := case p_action
    when 'APPROVE' then case when l.status = 'PENDING_REVIEW' then 'LIVE' end
    when 'REJECT'  then case when l.status in ('PENDING_REVIEW','LIVE','PAUSED') then 'REJECTED' end
    when 'PAUSE'   then case when l.status = 'LIVE' then 'PAUSED' end
    when 'SUSPEND' then case when l.status <> 'SUSPENDED' then 'SUSPENDED' end
    when 'RELIST'  then case when l.status in ('PAUSED','SUSPENDED','EXPIRED','REJECTED') then 'LIVE' end
    when 'EXPIRE'  then case when l.status <> 'EXPIRED' then 'EXPIRED' end end;
  if v_new is null then raise exception 'You cannot % a listing that is %.', lower(p_action), lower(l.status); end if;
  if p_action = 'REJECT' and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write the reason so the host can fix it.'; end if;
  update listings set status = v_new, review_note = coalesce(nullif(trim(p_note), ''), review_note), reviewed_at = now(),
    reviewed_by = auth.uid(), updated_at = now() where id = p_id;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = l.plan_id;
  if p_action = 'APPROVE' or (p_action = 'RELIST' and l.status <> 'PAUSED') then
    perform _notify(l.host_id, 'LISTING_APPROVED', 'Your ' || v_service || ' listing is live', 'Members can now join it.');
  elsif p_action = 'REJECT' then
    perform _notify(l.host_id, 'LISTING_REJECTED', 'Your ' || v_service || ' listing needs changes', trim(p_note));
  elsif p_action = 'SUSPEND' then
    perform _notify(l.host_id, 'LISTING_SUSPENDED', 'Your ' || v_service || ' listing was suspended', coalesce(nullif(trim(p_note), ''), 'Please contact support.'));
  end if;
  perform _audit(p_action || '_LISTING', 'listing', p_id::text, jsonb_build_object('status', l.status), jsonb_build_object('status', v_new), p_note);
end $$;

create or replace function public.admin_memberships(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'service', s.name, 'plan', p.name, 'buyer', b.username, 'host', h.username,
      'amount_kobo', m.amount_kobo, 'fee_kobo', m.fee_kobo, 'host_kobo', m.host_kobo, 'refund_kobo', m.refund_kobo, 'contact', m.contact,
      'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'escrow', m.escrow, 'access_status', m.access_status)
      order by m.created_at desc)
    from (select * from memberships where p_status is null or p_status = '' or status = p_status order by created_at desc limit 300) m
    join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id
    join profiles b on b.id = m.buyer_id join profiles h on h.id = m.host_id), '[]'::jsonb);
end $$;

create or replace function public.admin_release(p_id uuid, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  perform _release(p_id, 'released by SplitSub');
  update disputes set status = 'RESOLVED', resolution = 'RELEASE', admin_note = coalesce(nullif(p_note, ''), admin_note),
    resolved_by = auth.uid(), resolved_at = now(), updated_at = now() where membership_id = p_id and status in ('OPEN','IN_REVIEW');
  perform _audit('RELEASE_PAYMENT', 'membership', p_id::text, null, null, p_note);
end $$;

create or replace function public.admin_refund(p_id uuid, p_amount_kobo bigint default null, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare v_full bigint;
begin
  perform _need_admin();
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write the reason for the refund.'; end if;
  select amount_kobo into v_full from memberships where id = p_id;
  perform _refund(p_id, p_amount_kobo, trim(p_note));
  update disputes set status = 'RESOLVED', resolution = case when coalesce(p_amount_kobo, v_full) < v_full then 'PARTIAL_REFUND' else 'REFUND' end,
    refund_kobo = coalesce(p_amount_kobo, v_full), admin_note = trim(p_note), resolved_by = auth.uid(), resolved_at = now(), updated_at = now()
  where membership_id = p_id and status in ('OPEN','IN_REVIEW');
  perform _audit(case when coalesce(p_amount_kobo, v_full) < v_full then 'PARTIAL_REFUND' else 'REFUND' end, 'membership', p_id::text, null,
    jsonb_build_object('refund_kobo', coalesce(p_amount_kobo, v_full)), p_note);
end $$;

create or replace function public.admin_payments(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('reference', x.reference, 'user', p.username, 'purpose', x.purpose, 'amount_kobo', x.amount_kobo,
      'paid_kobo', x.paid_kobo, 'status', x.status, 'channel', x.channel, 'note', x.note, 'created_at', x.created_at, 'verified_at', x.verified_at)
      order by x.created_at desc)
    from (select * from payments where p_status is null or p_status = '' or status = p_status order by created_at desc limit 300) x
    join profiles p on p.id = x.user_id), '[]'::jsonb);
end $$;

create or replace function public.admin_ledger(p_type text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'user', coalesce(p.username, 'SplitSub'), 'account', t.account_kind, 'type', t.type,
      'amount_kobo', t.amount_kobo, 'balance_after_kobo', t.balance_after_kobo, 'description', t.description, 'reference', t.reference,
      'created_at', t.created_at) order by t.id desc)
    from (select * from wallet_transactions where p_type is null or p_type = '' or type = p_type order by id desc limit 300) t
    left join profiles p on p.id = t.user_id), '[]'::jsonb);
end $$;

create or replace function public.admin_withdrawals(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'user', p.username, 'full_name', p.full_name, 'amount_kobo', w.amount_kobo,
      'bank_name', w.bank_name, 'account_number', w.account_number, 'account_name', w.account_name, 'status', w.status,
      'admin_note', w.admin_note, 'created_at', w.created_at, 'paid_at', w.paid_at)
      order by (w.status in ('PENDING','APPROVED')) desc, w.created_at desc)
    from withdrawals w join profiles p on p.id = w.user_id
    where p_status is null or p_status = '' or w.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.admin_withdrawal_action(p_id uuid, p_action text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare w withdrawals;
begin
  perform _need_admin();
  select * into w from withdrawals where id = p_id for update;
  if not found then raise exception 'Withdrawal not found.'; end if;
  if p_action = 'APPROVE' and w.status = 'PENDING' then
    update withdrawals set status = 'APPROVED', approved_at = now(), processed_by = auth.uid(), admin_note = coalesce(nullif(trim(p_note), ''), admin_note) where id = w.id;
    perform _notify(w.user_id, 'WITHDRAWAL_APPROVED', 'Withdrawal approved', _naira(w.amount_kobo) || ' is on its way to ' || w.bank_name || '.');
  elsif p_action = 'PAID' and w.status in ('PENDING','APPROVED') then
    update withdrawals set status = 'PAID', paid_at = now(), approved_at = coalesce(approved_at, now()), processed_by = auth.uid(),
      admin_note = coalesce(nullif(trim(p_note), ''), admin_note) where id = w.id;
    perform _notify(w.user_id, 'WITHDRAWAL_PAID', _naira(w.amount_kobo) || ' sent to your bank', w.bank_name || ' · ' || w.account_number);
  elsif p_action = 'REJECT' and w.status in ('PENDING','APPROVED') then
    if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write the reason so the host knows what to fix.'; end if;
    update withdrawals set status = 'REJECTED', processed_by = auth.uid(), admin_note = trim(p_note) where id = w.id;
    perform _post(w.user_id, 'EARNINGS', 'WITHDRAWAL_REVERSED', w.amount_kobo, 'Withdrawal returned: ' || trim(p_note), w.ledger_reference,
                  null, null, null, w.id);
    perform _notify(w.user_id, 'WITHDRAWAL_REJECTED', 'Withdrawal not completed', trim(p_note) || ' The money is back in your earnings.');
  else
    raise exception 'This withdrawal is already %.', lower(w.status);
  end if;
  perform _audit(p_action || '_WITHDRAWAL', 'withdrawal', p_id::text, jsonb_build_object('status', w.status),
    jsonb_build_object('amount_kobo', w.amount_kobo), p_note);
end $$;

create or replace function public.admin_disputes(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'membership_id', d.membership_id, 'listing_id', d.listing_id,
      'service', s.name, 'plan', p.name, 'buyer', b.username, 'buyer_email', b.email, 'host', h.username, 'host_email', h.email,
      'host_id', d.host_id, 'contact', m.contact, 'amount_kobo', m.amount_kobo, 'escrow', m.escrow, 'reason', d.reason, 'details', d.details,
      'host_response', d.host_response, 'status', d.status, 'resolution', d.resolution, 'refund_kobo', d.refund_kobo,
      'admin_note', d.admin_note, 'created_at', d.created_at, 'resolved_at', d.resolved_at)
      order by (d.status in ('OPEN','IN_REVIEW')) desc, d.created_at desc)
    from disputes d join memberships m on m.id = d.membership_id join service_plans p on p.id = m.plan_id
    join services s on s.id = p.service_id join profiles b on b.id = d.buyer_id join profiles h on h.id = d.host_id
    where p_status is null or p_status = '' or d.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.admin_dispute_action(p_id uuid, p_action text, p_amount_kobo bigint default null, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare d disputes; v_service text;
begin
  perform _need_admin();
  select * into d from disputes where id = p_id for update;
  if not found then raise exception 'Report not found.'; end if;
  select s.name into v_service from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id where l.id = d.listing_id;
  if p_action in ('IN_REVIEW','REQUEST_PROOF','REFUND','PARTIAL_REFUND','RELEASE','NO_ACTION') and d.status not in ('OPEN','IN_REVIEW') then
    raise exception 'This report is already closed.';
  end if;
  if p_action = 'IN_REVIEW' then
    update disputes set status = 'IN_REVIEW', admin_note = coalesce(nullif(trim(p_note), ''), admin_note), updated_at = now() where id = d.id;
  elsif p_action = 'REQUEST_PROOF' then
    update disputes set status = 'IN_REVIEW', updated_at = now() where id = d.id;
    perform _notify(d.host_id, 'DISPUTE_PROOF', 'Please send proof for a ' || v_service || ' seat',
      coalesce(nullif(trim(p_note), ''), 'Reply to the report in My Subs and contact support with a screenshot showing the member has access.'));
  elsif p_action = 'REFUND' then
    perform admin_refund(d.membership_id, null, coalesce(nullif(trim(p_note), ''), 'Report resolved with a refund'));
  elsif p_action = 'PARTIAL_REFUND' then
    if p_amount_kobo is null or p_amount_kobo <= 0 then raise exception 'Enter the refund amount.'; end if;
    perform admin_refund(d.membership_id, p_amount_kobo, coalesce(nullif(trim(p_note), ''), 'Report resolved with a partial refund'));
  elsif p_action = 'RELEASE' then
    perform admin_release(d.membership_id, p_note);
  elsif p_action = 'NO_ACTION' then
    update memberships set status = 'ACTIVE' where id = d.membership_id and status = 'DISPUTED';
    update disputes set status = 'CLOSED', resolution = 'NO_ACTION', admin_note = trim(coalesce(p_note, '')), resolved_by = auth.uid(),
      resolved_at = now(), updated_at = now() where id = d.id;
  elsif p_action = 'SUSPEND_LISTING' then
    perform admin_review_listing(d.listing_id, 'SUSPEND', p_note);
  elsif p_action = 'SUSPEND_HOST' then
    perform admin_update_user(d.host_id, 'SUSPENDED', (select verified_host from profiles where id = d.host_id),
                              exists (select 1 from admin_users where user_id = d.host_id), coalesce(nullif(trim(p_note), ''), 'Suspended after a report'));
  else
    raise exception 'Unknown action.';
  end if;
  if p_action in ('REFUND','PARTIAL_REFUND','RELEASE','NO_ACTION') then
    perform _notify(d.buyer_id, 'DISPUTE_RESOLVED', 'Your ' || v_service || ' report is resolved', coalesce(nullif(trim(p_note), ''), 'Thanks for your patience.'));
    perform _notify(d.host_id, 'DISPUTE_RESOLVED', 'A ' || v_service || ' report was resolved', coalesce(nullif(trim(p_note), ''), ''));
  end if;
  perform _audit('DISPUTE_' || p_action, 'dispute', p_id::text, jsonb_build_object('status', d.status),
    jsonb_build_object('amount_kobo', p_amount_kobo), p_note);
end $$;

create or replace function public.admin_tickets(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'subject', t.subject, 'status', t.status, 'user', p.username,
      'email', p.email, 'phone', p.phone, 'updated_at', t.updated_at,
      'messages', (select jsonb_agg(jsonb_build_object('from_admin', m.from_admin, 'body', m.body, 'created_at', m.created_at) order by m.created_at)
                   from support_messages m where m.ticket_id = t.id))
      order by (t.status = 'OPEN') desc, t.updated_at desc)
    from support_tickets t join profiles p on p.id = t.user_id
    where p_status is null or p_status = '' or t.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.admin_reply_ticket(p_id uuid, p_body text, p_close boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare t support_tickets;
begin
  perform _need_admin();
  select * into t from support_tickets where id = p_id for update;
  if not found then raise exception 'Ticket not found.'; end if;
  if length(trim(coalesce(p_body, ''))) >= 2 then
    insert into support_messages (ticket_id, author_id, from_admin, body) values (p_id, auth.uid(), true, left(trim(p_body), 4000));
    perform _notify(t.user_id, 'SUPPORT_REPLY', 'Support replied: ' || t.subject, left(trim(p_body), 140));
  elsif not p_close then
    raise exception 'Write a reply.';
  end if;
  update support_tickets set status = case when p_close then 'CLOSED' else 'ANSWERED' end, updated_at = now() where id = p_id;
  perform _audit(case when p_close then 'CLOSE_TICKET' else 'REPLY_TICKET' end, 'support_ticket', p_id::text, null, null, '');
end $$;

create or replace function public.admin_get_settings() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return (select to_jsonb(s) - 'id' from platform_settings s where id = 1) || jsonb_build_object('fee_bps', platform_fee_bps());
end $$;

create or replace function public.admin_save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare old platform_settings;
begin
  perform _need_admin();
  select * into old from platform_settings where id = 1 for update;
  update platform_settings set
    site_name = coalesce(nullif(trim(p ->> 'site_name'), ''), site_name),
    hero_title = coalesce(nullif(trim(p ->> 'hero_title'), ''), hero_title),
    hero_text = coalesce(p ->> 'hero_text', hero_text),
    notice = coalesce(p ->> 'notice', notice),
    support_whatsapp = coalesce(regexp_replace(p ->> 'support_whatsapp', '\D', '', 'g'), support_whatsapp),
    support_email = coalesce(p ->> 'support_email', support_email),
    categories = coalesce((select array_agg(trim(x)) from jsonb_array_elements_text(p -> 'categories') x where trim(x) <> ''), categories),
    min_withdrawal_kobo = coalesce((p ->> 'min_withdrawal_kobo')::bigint, min_withdrawal_kobo),
    min_topup_kobo = coalesce((p ->> 'min_topup_kobo')::bigint, min_topup_kobo),
    max_topup_kobo = coalesce((p ->> 'max_topup_kobo')::bigint, max_topup_kobo),
    auto_approve_listings = coalesce((p ->> 'auto_approve_listings')::boolean, auto_approve_listings),
    renewal_window_days = coalesce((p ->> 'renewal_window_days')::int, renewal_window_days),
    reminder_days = coalesce((p ->> 'reminder_days')::int, reminder_days),
    updated_at = now()
  where id = 1;
  perform _audit('UPDATE_SETTINGS', 'platform_settings', '1', to_jsonb(old), (select to_jsonb(s) from platform_settings s where id = 1));
exception when check_violation then raise exception 'One of the values is outside the allowed range.';
end $$;

create or replace function public.admin_broadcast(p_title text, p_body text, p_username text default null) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _need_admin();
  if length(trim(coalesce(p_title, ''))) < 3 then raise exception 'Add a title.'; end if;
  insert into notifications (user_id, type, title, body)
  select id, 'ANNOUNCEMENT', left(trim(p_title), 120), left(trim(coalesce(p_body, '')), 1000) from profiles
  where status = 'ACTIVE' and (nullif(trim(coalesce(p_username, '')), '') is null or username = trim(p_username));
  get diagnostics n = row_count;
  if n = 0 then raise exception 'No user matched.'; end if;
  perform _audit('BROADCAST', 'notification', null, null, jsonb_build_object('title', p_title, 'to', coalesce(p_username, 'everyone'), 'count', n));
  return n;
end $$;

create or replace function public.admin_audit_logs() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'admin', p.username, 'action', a.action, 'entity', a.entity,
      'entity_id', a.entity_id, 'old_data', a.old_data, 'new_data', a.new_data, 'note', a.note, 'created_at', a.created_at) order by a.id desc)
    from (select * from admin_audit_logs order by id desc limit 300) a left join profiles p on p.id = a.admin_id), '[]'::jsonb);
end $$;

-- =====================================================================
-- ROW LEVEL SECURITY + PERMISSIONS
-- Browsers: read-only access to their OWN rows; every write goes through
-- the functions above. Admin-only tables have no browser access at all.
-- =====================================================================
alter table public.platform_settings  enable row level security;
alter table public.profiles           enable row level security;
alter table public.admin_users        enable row level security;
alter table public.services           enable row level security;
alter table public.service_plans      enable row level security;
alter table public.listings           enable row level security;
alter table public.listing_access     enable row level security;
alter table public.memberships        enable row level security;
alter table public.wallet_accounts    enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.payments           enable row level security;
alter table public.withdrawals        enable row level security;
alter table public.disputes           enable row level security;
alter table public.notifications      enable row level security;
alter table public.support_tickets    enable row level security;
alter table public.support_messages   enable row level security;
alter table public.admin_audit_logs   enable row level security;

do $$ declare r record; begin
  for r in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

create policy "own profile" on public.profiles for select to authenticated using (id = auth.uid() or is_admin());
create policy "active services" on public.services for select to anon, authenticated using (active or is_admin());
create policy "active plans" on public.service_plans for select to anon, authenticated using (active or is_admin());
create policy "own listings" on public.listings for select to authenticated using (host_id = auth.uid() or is_admin());
create policy "entitled access" on public.listing_access for select to authenticated using (
  is_admin()
  or exists (select 1 from listings l where l.id = listing_access.listing_id and l.host_id = auth.uid())
  or exists (select 1 from memberships m where m.listing_id = listing_access.listing_id and m.buyer_id = auth.uid()
             and (m.status = 'DISPUTED' or (m.status = 'ACTIVE' and m.ends_at > now()))));
create policy "own memberships" on public.memberships for select to authenticated using (buyer_id = auth.uid() or host_id = auth.uid() or is_admin());
create policy "own accounts" on public.wallet_accounts for select to authenticated using (owner_id = auth.uid() or is_admin());
create policy "own ledger" on public.wallet_transactions for select to authenticated using (user_id = auth.uid() or is_admin());
create policy "own payments" on public.payments for select to authenticated using (user_id = auth.uid() or is_admin());
create policy "own withdrawals" on public.withdrawals for select to authenticated using (user_id = auth.uid() or is_admin());
create policy "own disputes" on public.disputes for select to authenticated using (buyer_id = auth.uid() or host_id = auth.uid() or is_admin());
create policy "own notifications" on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "own tickets" on public.support_tickets for select to authenticated using (user_id = auth.uid() or is_admin());
create policy "own ticket messages" on public.support_messages for select to authenticated using (
  is_admin() or exists (select 1 from support_tickets t where t.id = support_messages.ticket_id and t.user_id = auth.uid()));
create policy "admins read audit" on public.admin_audit_logs for select to authenticated using (is_admin());
create policy "admins read admin list" on public.admin_users for select to authenticated using (is_admin());
create policy "settings readable" on public.platform_settings for select to anon, authenticated using (true);

-- Table permissions: nobody outside the server can INSERT/UPDATE/DELETE anything.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant usage on schema public to anon, authenticated;
grant select on public.platform_settings, public.services, public.service_plans to anon, authenticated;
grant select on public.profiles, public.listings, public.listing_access, public.memberships, public.wallet_accounts,
  public.wallet_transactions, public.payments, public.withdrawals, public.disputes, public.notifications,
  public.support_tickets, public.support_messages, public.admin_audit_logs, public.admin_users to authenticated;

-- Function permissions: lock everything, then open only the public API.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.public_catalog() to anon, authenticated;
grant execute on function public.explore_listings() to anon, authenticated;
grant execute on function public.listing_detail(uuid) to anon, authenticated;
grant execute on function public.release_due_escrow() to anon, authenticated;
grant execute on function
  public.my_overview(), public.my_subscriptions(), public.my_listings(), public.my_wallet(), public.my_notifications(),
  public.mark_notifications_read(), public.my_tickets(), public.get_access(uuid), public.join_with_wallet(uuid, text),
  public.renew_membership(uuid), public.open_dispute(uuid, text, text), public.update_my_profile(text, text, text),
  public.move_earnings(bigint), public.request_withdrawal(bigint, text, text, text),
  public.host_create_listing(uuid, int, int, text, text), public.host_submit_listing(uuid, text, text),
  public.host_update_listing(uuid, int, int, text, text), public.host_set_paused(uuid, boolean),
  public.host_mark_access_sent(uuid), public.host_respond_dispute(uuid, text),
  public.create_ticket(text, text), public.reply_ticket(uuid, text)
to authenticated;
-- Admin API: callable by signed-in users, but every function rejects non-admins with 403.
grant execute on function
  public.admin_me(), public.admin_dashboard(), public.admin_ledger_check(), public.admin_users(text), public.admin_user_detail(uuid),
  public.admin_update_user(uuid, text, boolean, boolean, text), public.admin_adjust_wallet(uuid, text, bigint, text),
  public.admin_services(), public.admin_save_service(jsonb), public.admin_save_plan(jsonb), public.admin_listings(text),
  public.admin_listing_detail(uuid), public.admin_review_listing(uuid, text, text), public.admin_memberships(text),
  public.admin_release(uuid, text), public.admin_refund(uuid, bigint, text), public.admin_payments(text), public.admin_ledger(text),
  public.admin_withdrawals(text), public.admin_withdrawal_action(uuid, text, text), public.admin_disputes(text),
  public.admin_dispute_action(uuid, text, bigint, text), public.admin_tickets(text), public.admin_reply_ticket(uuid, text, boolean),
  public.admin_get_settings(), public.admin_save_settings(jsonb), public.admin_broadcast(text, text, text), public.admin_audit_logs()
to authenticated;
-- Payment functions: ONLY the server (Edge Functions with the service-role key).
grant execute on function public.payment_create(uuid, text, text, bigint, uuid, text), public.payment_complete(text, bigint, text, text, text),
  public.payment_fail(text, text, text) to service_role;
grant execute on function public.send_expiry_reminders(), public.release_due_escrow() to service_role;

-- Make the platform fee account exist.
select public._account(null, 'PLATFORM');
