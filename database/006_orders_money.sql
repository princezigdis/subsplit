-- =====================================================================
--  SUBSPLIT · 006_orders_money.sql   (run after 001-005; safe to re-run)
--  Adds on top of the existing marketplace (nothing is removed):
--   * flat N200 fee when a buyer pays, flat N200 fee on withdrawals
--   * N100 minimum deposit, N1,000 minimum withdrawal (database-enforced)
--   * 30-day escrow clock per seat, "available" vs "pending" wallet views
--   * immutable ledger, unique transaction ID per order
--   * receipts (purchase + withdrawal)
--   * order chat (buyer, host, admin), report / distress alarm, mark completed
--   * host proof queue + 30-day escrow agreement + "no proof, no live listing"
--   * email outbox (sent by the send-emails Edge Function)
--  Existing users, listings, seats and payments are kept and back-filled.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. FIXED CONSTANTS (no admin screen; edit here to change)
-- ---------------------------------------------------------------------
create or replace function public.buyer_fee_kobo() returns bigint
language sql immutable set search_path = public as $$ select 20000::bigint $$;      -- N200 on every purchase
create or replace function public.withdrawal_fee_kobo() returns bigint
language sql immutable set search_path = public as $$ select 20000::bigint $$;      -- N200 on every withdrawal
create or replace function public.escrow_days() returns int
language sql immutable set search_path = public as $$ select 30 $$;                 -- host earnings locked 30 days
create or replace function public._agreement_text() returns text
language sql immutable set search_path = public as $$
  select 'I understand and agree that funds from this listing will be held in a 30-day escrow cycle before becoming available for withdrawal.' $$;

-- ---------------------------------------------------------------------
-- 2. SETTINGS FLOORS: deposit >= N100, withdrawal >= N1,000
-- ---------------------------------------------------------------------
update public.platform_settings set
  min_topup_kobo = greatest(min_topup_kobo, 10000),
  min_withdrawal_kobo = greatest(min_withdrawal_kobo, 100000),
  max_topup_kobo = greatest(max_topup_kobo, 10000)
where id = 1;
do $$ declare c record; begin
  for c in select conname from pg_constraint where conrelid = 'public.platform_settings'::regclass and contype = 'c'
           and (pg_get_constraintdef(oid) like '%min_topup_kobo >= 5000%' or pg_get_constraintdef(oid) like '%min_withdrawal_kobo >= 0%')
  loop execute format('alter table public.platform_settings drop constraint %I', c.conname); end loop;
end $$;
alter table public.platform_settings drop constraint if exists min_topup_floor;
alter table public.platform_settings drop constraint if exists min_withdrawal_floor;
alter table public.platform_settings add constraint min_topup_floor check (min_topup_kobo >= 10000);
alter table public.platform_settings add constraint min_withdrawal_floor check (min_withdrawal_kobo >= 100000);

-- ---------------------------------------------------------------------
-- 3. NEW COLUMNS
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists referral_code text;
alter table public.profiles add column if not exists referred_by uuid references public.profiles(id) on delete set null;
update public.profiles set referral_code = upper(substr(md5(id::text || 'subsplit'), 1, 8)) where referral_code is null;
create unique index if not exists profiles_referral_code_key on public.profiles (referral_code);

alter table public.notifications add column if not exists ref text;

alter table public.memberships add column if not exists txn_ref text;
alter table public.memberships add column if not exists buyer_fee_kobo bigint not null default 0 check (buyer_fee_kobo >= 0);
alter table public.memberships add column if not exists release_at timestamptz;
alter table public.memberships add column if not exists completed_at timestamptz;
alter table public.memberships add column if not exists host_reminder_sent boolean not null default false;
update public.memberships m set txn_ref = coalesce(
  (select t.reference from public.wallet_transactions t where t.membership_id = m.id and t.type = 'SUBSCRIPTION' order by t.id limit 1),
  public._ref('SUB')) where txn_ref is null;
update public.memberships set release_at = greatest(starts_at, created_at) + make_interval(days => public.escrow_days()) where release_at is null;
alter table public.memberships alter column release_at set default (now() + interval '30 days');
alter table public.memberships alter column release_at set not null;
create unique index if not exists memberships_txn_ref_key on public.memberships (txn_ref);
create index if not exists memberships_release_idx on public.memberships (escrow, status, release_at);

alter table public.withdrawals add column if not exists fee_kobo bigint not null default 0 check (fee_kobo >= 0);
alter table public.withdrawals add column if not exists payout_kobo bigint;
update public.withdrawals set payout_kobo = amount_kobo - fee_kobo where payout_kobo is null;
alter table public.withdrawals drop constraint if exists withdrawals_payout_positive;
alter table public.withdrawals add constraint withdrawals_payout_positive check (payout_kobo is null or payout_kobo > 0);

alter table public.disputes add column if not exists raised_by uuid;
alter table public.disputes add column if not exists raised_by_role text not null default 'BUYER';
update public.disputes set raised_by = buyer_id where raised_by is null;

alter table public.listings add column if not exists agreement_accepted_at timestamptz;
alter table public.listings add column if not exists agreement_text text not null default '';
alter table public.listings add column if not exists proof_status text not null default 'NONE';
alter table public.listings drop constraint if exists listings_proof_status_check;
alter table public.listings add constraint listings_proof_status_check check (proof_status in ('NONE','PENDING','APPROVED','REJECTED'));

-- ledger types: add purchase fee, withdrawal fee, admin credit, referral reward
alter table public.wallet_transactions drop constraint if exists wallet_transactions_type_check;
alter table public.wallet_transactions add constraint wallet_transactions_type_check check (type in (
  'TOP_UP','SUBSCRIPTION','REFUND','HOST_EARNING_PENDING','PENDING_RELEASED','HOST_EARNING','EARNING_REVERSED','PLATFORM_FEE',
  'WITHDRAWAL','WITHDRAWAL_REVERSED','TRANSFER_IN','TRANSFER_OUT','ADJUSTMENT',
  'PURCHASE_FEE','WITHDRAWAL_FEE','ADMIN_CREDIT','REFERRAL_REWARD'));

-- the ledger can never be edited or deleted
create or replace function public._ledger_immutable() returns trigger
language plpgsql set search_path = public as $$
begin raise exception 'Ledger records cannot be changed or deleted.'; end $$;
create or replace trigger ledger_no_change before update or delete on public.wallet_transactions
  for each row execute function public._ledger_immutable();

-- ---------------------------------------------------------------------
-- 4. NEW TABLES
-- ---------------------------------------------------------------------
create table if not exists public.host_proofs (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings(id) on delete cascade,
  host_id uuid not null references public.profiles(id) on delete restrict,
  service_name text not null,
  file_path text not null default '',
  note text not null default '',
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED')),
  reason text not null default '',
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid
);
create index if not exists host_proofs_status_idx on public.host_proofs (status, submitted_at desc);
create index if not exists host_proofs_listing_idx on public.host_proofs (listing_id, submitted_at desc);

-- carry existing proofs over
insert into public.host_proofs (listing_id, host_id, service_name, file_path, note, status, submitted_at, reviewed_at)
select l.id, l.host_id, s.name, l.proof_path, l.proof_note,
       case when l.status = 'PENDING_REVIEW' then 'PENDING' when l.status = 'REJECTED' then 'REJECTED' else 'APPROVED' end,
       coalesce(l.submitted_at, l.created_at), l.reviewed_at
from public.listings l join public.service_plans p on p.id = l.plan_id join public.services s on s.id = p.service_id
where l.proof_path <> '' and not exists (select 1 from public.host_proofs h where h.listing_id = l.id);
update public.listings l set proof_status = (select h.status from public.host_proofs h where h.listing_id = l.id order by h.submitted_at desc limit 1)
 where exists (select 1 from public.host_proofs h where h.listing_id = l.id);

create table if not exists public.order_messages (
  id bigint generated always as identity primary key,
  membership_id uuid not null references public.memberships(id) on delete cascade,
  sender_id uuid references public.profiles(id) on delete set null,
  sender_role text not null check (sender_role in ('BUYER','HOST','ADMIN','SYSTEM')),
  body text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists order_messages_idx on public.order_messages (membership_id, id);
create table if not exists public.order_reads (
  membership_id uuid not null references public.memberships(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  last_read_id bigint not null default 0,
  primary key (membership_id, user_id)
);

create table if not exists public.email_outbox (
  id bigint generated always as identity primary key,
  to_user uuid references public.profiles(id) on delete set null,
  to_email text not null,
  type text not null,
  subject text not null,
  body text not null default '',
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0,
  last_error text not null default ''
);
create index if not exists email_outbox_pending_idx on public.email_outbox (id) where sent_at is null;

-- a private place for server-only secrets (no browser can read it)
create table if not exists public.internal_secrets (name text primary key, value text not null);
insert into public.internal_secrets (name, value) values ('email_cron', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')) on conflict (name) do nothing;

alter table public.host_proofs enable row level security;
alter table public.order_messages enable row level security;
alter table public.order_reads enable row level security;
alter table public.email_outbox enable row level security;
alter table public.internal_secrets enable row level security;
revoke all on public.host_proofs, public.order_messages, public.order_reads, public.email_outbox, public.internal_secrets from anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. HELPERS
-- ---------------------------------------------------------------------
create or replace function public._order_status(m memberships) returns text
language sql stable set search_path = public as $$
  select case when m.status in ('REFUNDED','PARTIALLY_REFUNDED','DISPUTED') then m.status
              when m.completed_at is not null or m.status = 'COMPLETED' then 'COMPLETED' else 'ACTIVE' end $$;

do $$ begin
  if to_regprocedure('public._notify(uuid,text,text,text)') is not null then
    execute 'alter function public._notify(uuid,text,text,text) rename to _notify_old_v1';
  end if;
end $$;
create or replace function public._notify(p_user uuid, p_type text, p_title text, p_body text default '', p_ref text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  insert into notifications (user_id, type, title, body, ref) values (p_user, p_type, p_title, coalesce(p_body, ''), p_ref);
  if p_type = any (array['PAYMENT_SUCCESS','PAYMENT_FAILED','SUBSCRIPTION_JOINED','SUBSCRIPTION_RENEWED','NEW_MEMBER','ACCESS_AVAILABLE',
      'EXPIRING','EXPIRING_HOST','EARNING_AVAILABLE','REFUND','WITHDRAWAL_REQUESTED','WITHDRAWAL_APPROVED','WITHDRAWAL_PAID',
      'WITHDRAWAL_REJECTED','DISPUTE_OPENED','DISPUTE_RESOLVED','DISPUTE_PROOF','LISTING_APPROVED','LISTING_REJECTED','LISTING_SUSPENDED',
      'REFERRAL_REWARD','REQUEST_ADDED','REQUEST_DECLINED','ADMIN_CREDIT','ADJUSTMENT','SUPPORT_REPLY','ADMIN_ALERT']) then
    select email into v_email from profiles where id = p_user;
    if coalesce(v_email, '') <> '' then
      insert into email_outbox (to_user, to_email, type, subject, body) values (p_user, v_email, p_type, left(p_title, 200), coalesce(p_body, ''));
    end if;
  end if;
end $$;

create or replace function public._notify_admins(p_type text, p_title text, p_body text default '', p_ref text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select a.user_id from admin_users a join profiles p on p.id = a.user_id where p.status = 'ACTIVE' loop
    perform _notify(r.user_id, p_type, p_title, p_body, p_ref);
  end loop;
end $$;

create or replace function public._audit_system(p_action text, p_entity text, p_entity_id text, p_old jsonb, p_new jsonb, p_note text default '')
returns void language sql security definer set search_path = public as $$
  insert into admin_audit_logs (admin_id, action, entity, entity_id, old_data, new_data, note)
  values (null, p_action, p_entity, p_entity_id, p_old, p_new, coalesce(p_note, ''));
$$;

create or replace function public._chat_system(p_membership uuid, p_body text) returns void
language sql security definer set search_path = public as $$
  insert into order_messages (membership_id, sender_id, sender_role, body) values (p_membership, null, 'SYSTEM', left(p_body, 2000));
$$;

-- Take money from "available": host earnings first, then wallet. Writes one ledger row per account used.
create or replace function public._debit_available(p_user uuid, p_amount bigint, p_type text, p_desc text, p_ref text, p_withdrawal uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_take bigint;
begin
  if p_amount <= 0 then return; end if;
  v_take := least(_balance(p_user, 'EARNINGS'), p_amount);
  if v_take > 0 then perform _post(p_user, 'EARNINGS', p_type, -v_take, p_desc, p_ref, null, null, null, p_withdrawal); end if;
  if p_amount - v_take > 0 then perform _post(p_user, 'WALLET', p_type, -(p_amount - v_take), p_desc, p_ref, null, null, null, p_withdrawal); end if;
end $$;

-- placeholder; 007 replaces it with the referral engine
create or replace function public._referral_check(p_buyer uuid, p_membership uuid, p_amount bigint) returns void
language sql security definer set search_path = public as $$ select 1; $$;

-- ---------------------------------------------------------------------
-- 6. LISTINGS: agreement + proof guard (backend, not just the screen)
-- ---------------------------------------------------------------------
create or replace function public._listing_live_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare p service_plans;
begin
  if new.status = 'LIVE' and (tg_op = 'INSERT' or old.status is distinct from 'LIVE') then
    select * into p from service_plans where id = new.plan_id;
    if p.host_proof_required and not exists (select 1 from host_proofs h where h.listing_id = new.id and h.status = 'APPROVED') then
      raise exception 'This listing cannot go live until its proof of purchase is approved by an admin.';
    end if;
    if tg_op = 'UPDATE' and old.status in ('DRAFT','PENDING_REVIEW','REJECTED') and new.agreement_accepted_at is null then
      raise exception 'The host must accept the 30-day escrow agreement before this listing can go live.';
    end if;
  end if;
  return new;
end $$;
create or replace trigger listing_live_guard before insert or update of status on public.listings
  for each row execute function public._listing_live_guard();

do $$ begin
  if to_regprocedure('public.host_submit_listing(uuid,text,text)') is not null then
    execute 'alter function public.host_submit_listing(uuid,text,text) rename to host_submit_listing_old_v1';
  end if;
end $$;
create or replace function public.host_submit_listing(p_listing uuid, p_proof_path text default '', p_proof_note text default '', p_agree boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; l listings; p service_plans; s services; v_auto boolean; v_status text; v_has_file boolean := false; v_last text;
begin
  me := _me();
  select * into l from listings where id = p_listing and host_id = me.id for update;
  if not found then raise exception 'Listing not found.'; end if;
  if l.status not in ('DRAFT','REJECTED') then raise exception 'This listing was already submitted.'; end if;
  if not coalesce(p_agree, false) then
    raise exception 'Tick the box to agree to the 30-day escrow cycle before you publish.';
  end if;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  if coalesce(p_proof_path, '') <> '' then
    if p_proof_path not like me.id || '/' || l.id || '/%' then raise exception 'That proof file does not belong to this listing.'; end if;
    select exists (select 1 from storage.objects where bucket_id = 'host-proofs' and name = p_proof_path) into v_has_file;
    if not v_has_file then raise exception 'We could not find your uploaded proof. Please upload it again.'; end if;
  end if;
  select status into v_last from host_proofs where listing_id = l.id order by submitted_at desc limit 1;
  if p.host_proof_required and not v_has_file and (v_last is null or v_last = 'REJECTED') then
    raise exception 'Upload proof that you own this plan (a receipt or a screenshot of the subscription page).';
  end if;
  if v_has_file then
    insert into host_proofs (listing_id, host_id, service_name, file_path, note)
    values (l.id, me.id, s.name, p_proof_path, left(trim(coalesce(p_proof_note, '')), 500));
  end if;
  select auto_approve_listings into v_auto from platform_settings where id = 1;
  v_status := case when v_auto and not p.verification_required and not p.host_proof_required then 'LIVE' else 'PENDING_REVIEW' end;
  update listings set status = v_status, submitted_at = now(), updated_at = now(),
    proof_path = case when v_has_file then p_proof_path else proof_path end,
    proof_note = left(trim(coalesce(p_proof_note, proof_note)), 500),
    proof_status = case when v_has_file then 'PENDING' else proof_status end,
    agreement_accepted_at = now(), agreement_text = _agreement_text()
  where id = l.id;
  if v_status = 'PENDING_REVIEW' then
    perform _notify_admins('ADMIN_ALERT', 'New listing to review: ' || s.name, '@' || me.username || ' submitted a ' || s.name || ' listing.', l.id::text);
  end if;
  return jsonb_build_object('status', v_status);
end $$;

create or replace function public.admin_proofs(p_status text default 'PENDING') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'listing_id', h.listing_id, 'service', h.service_name,
      'plan', p.name, 'host_id', h.host_id, 'host', u.username, 'host_name', u.full_name, 'host_email', u.email, 'host_phone', u.phone,
      'host_verified', u.verified_host, 'file_path', h.file_path, 'note', h.note, 'status', h.status, 'reason', h.reason,
      'listing_status', l.status, 'agreement_at', l.agreement_accepted_at, 'submitted_at', h.submitted_at, 'reviewed_at', h.reviewed_at)
      order by (h.status = 'PENDING') desc, h.submitted_at desc)
    from (select * from host_proofs where p_status is null or p_status = '' or status = p_status order by submitted_at desc limit 300) h
    join listings l on l.id = h.listing_id join service_plans p on p.id = l.plan_id join profiles u on u.id = h.host_id), '[]'::jsonb);
end $$;

create or replace function public.admin_proof_action(p_id uuid, p_action text, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
declare hp host_proofs; l listings; v_reason text; v_name text;
begin
  perform _need_admin();
  select * into hp from host_proofs where id = p_id for update;
  if not found then raise exception 'Proof not found.'; end if;
  if hp.status <> 'PENDING' then raise exception 'This proof was already %.', lower(hp.status); end if;
  select * into l from listings where id = hp.listing_id for update;
  v_name := hp.service_name;
  if p_action = 'APPROVE' then
    update host_proofs set status = 'APPROVED', reviewed_at = now(), reviewed_by = auth.uid() where id = hp.id;
    update listings set proof_status = 'APPROVED', updated_at = now() where id = l.id;
    if l.status = 'PENDING_REVIEW' then
      update listings set status = 'LIVE', reviewed_at = now(), reviewed_by = auth.uid(), review_note = '', updated_at = now() where id = l.id;
      perform _notify(l.host_id, 'LISTING_APPROVED', 'Your ' || v_name || ' listing is live', 'Your proof was approved. Members can now join.', l.id::text);
    else
      perform _notify(l.host_id, 'LISTING_APPROVED', 'Your ' || v_name || ' proof was approved', '', l.id::text);
    end if;
  elsif p_action = 'REJECT' then
    v_reason := coalesce(nullif(trim(p_reason), ''), 'We could not verify your proof. Please upload a clearer receipt or a screenshot of the subscription page.');
    update host_proofs set status = 'REJECTED', reason = v_reason, reviewed_at = now(), reviewed_by = auth.uid() where id = hp.id;
    update listings set proof_status = 'REJECTED', updated_at = now() where id = l.id;
    if l.status = 'PENDING_REVIEW' then
      update listings set status = 'REJECTED', review_note = v_reason, reviewed_at = now(), reviewed_by = auth.uid(), updated_at = now() where id = l.id;
    end if;
    perform _notify(l.host_id, 'LISTING_REJECTED', 'Your ' || v_name || ' proof needs changes', v_reason, l.id::text);
  else
    raise exception 'Unknown action.';
  end if;
  perform _audit(p_action || '_PROOF', 'host_proof', p_id::text, jsonb_build_object('status', hp.status),
    jsonb_build_object('status', case p_action when 'APPROVE' then 'APPROVED' else 'REJECTED' end, 'listing', l.id), coalesce(p_reason, ''));
end $$;

create or replace function public.admin_listings(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(_listing_obj(l.id) || jsonb_build_object('proof_uploaded', l.proof_path <> '', 'proof_status', l.proof_status,
      'agreed', l.agreement_accepted_at is not null, 'submitted_at', l.submitted_at,
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
    'proof_path', l.proof_path, 'proof_note', l.proof_note, 'proof_status', l.proof_status, 'review_note', l.review_note, 'submitted_at', l.submitted_at,
    'agreement_at', l.agreement_accepted_at, 'agreement_text', l.agreement_text,
    'proofs', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'file_path', h.file_path, 'status', h.status, 'reason', h.reason,
        'submitted_at', h.submitted_at) order by h.submitted_at desc) from host_proofs h where h.listing_id = p_id), '[]'::jsonb),
    'host_email', (select email from profiles where id = l.host_id), 'host_phone', (select phone from profiles where id = l.host_id),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'buyer', b.username, 'contact', m.contact, 'status', m.status,
        'escrow', m.escrow, 'amount_kobo', m.amount_kobo, 'ends_at', m.ends_at) order by m.starts_at desc)
      from memberships m join profiles b on b.id = m.buyer_id where m.listing_id = p_id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 7. SEAT PURCHASE with N200 fee, 30-day escrow clock, chat, receipt id
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

create or replace function public._join(p_user uuid, p_listing uuid, p_contact text, p_payment text) returns uuid
language plpgsql security definer set search_path = public as $$
declare l listings; p service_plans; s services; v_buyer text; v_price bigint; v_fee bigint; v_bfee bigint; v_id uuid; v_ref text; v_ready boolean;
begin
  perform release_due_escrow();
  v_price := _join_check(p_user, p_listing, p_contact);   -- also locks the listing row (no overselling)
  select * into l from listings where id = p_listing;
  select * into p from service_plans where id = l.plan_id;
  select * into s from services where id = p.service_id;
  select username into v_buyer from profiles where id = p_user;
  v_fee := _fee(v_price);
  v_bfee := buyer_fee_kobo();
  v_ref := _ref('SUB');
  v_ready := p.access_type = 'LOGIN';
  insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, buyer_fee_kobo, contact, starts_at, ends_at,
                           access_status, payment_reference, txn_ref, release_at)
  values (l.id, p.id, p_user, l.host_id, v_price, v_fee, v_price - v_fee, v_bfee, trim(coalesce(p_contact, '')), now(),
          now() + make_interval(days => p.duration_days), case when v_ready then 'READY' else 'WAITING' end, p_payment, v_ref,
          now() + make_interval(days => escrow_days()))
  returning id into v_id;
  perform _post(p_user, 'WALLET', 'SUBSCRIPTION', -v_price, 'Seat: ' || s.name || ' · ' || p.name, v_ref, v_id, l.id, p_payment);
  perform _post(p_user, 'WALLET', 'PURCHASE_FEE', -v_bfee, 'Transaction fee · ' || s.name, v_ref, v_id, l.id, p_payment);
  perform _post(null, 'PLATFORM', 'PLATFORM_FEE', v_bfee, 'Transaction fee · ' || s.name, v_ref, v_id, l.id);
  perform _post(l.host_id, 'PENDING', 'HOST_EARNING_PENDING', v_price - v_fee, s.name || ' seat · @' || v_buyer, v_ref, v_id, l.id, p_payment);
  perform _notify(p_user, 'SUBSCRIPTION_JOINED', 'You joined ' || s.name,
    'Order ' || v_ref || '. ' || case when v_ready then 'Your access details are ready in My Subs.'
         else 'The host will send your access to ' || trim(p_contact) || '. We will let you know when it is sent.' end, v_id::text);
  perform _notify(l.host_id, 'NEW_MEMBER', 'New order for your ' || s.name || ' plan',
    '@' || v_buyer || ' paid for a seat (order ' || v_ref || ').' || case when v_ready then '' else ' Please send access to ' || trim(p_contact) || ' and mark it as sent.' end, v_id::text);
  perform _chat_system(v_id, 'Order ' || v_ref || ' created for ' || s.name || ' · ' || p.name || '. Use this chat for anything about this order.'
    || case when v_ready then '' else ' Host: please send access to the member and tap "Mark sent".' end);
  perform _referral_check(p_user, v_id, v_price);
  return v_id;
end $$;

create or replace function public.renew_membership(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; l listings; p service_plans; s services; v_price bigint; v_fee bigint; v_bfee bigint; v_id uuid; v_ref text; v_window int;
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
  v_bfee := buyer_fee_kobo();
  v_ref := _ref('REN');
  update memberships set renewed = true where id = m.id;
  insert into memberships (listing_id, plan_id, buyer_id, host_id, amount_kobo, fee_kobo, host_kobo, buyer_fee_kobo, contact, starts_at, ends_at,
                           access_status, renewed_from, txn_ref, release_at)
  values (l.id, p.id, me.id, l.host_id, v_price, v_fee, v_price - v_fee, v_bfee, m.contact, m.ends_at,
          m.ends_at + make_interval(days => p.duration_days), m.access_status, m.id, v_ref,
          greatest(m.ends_at, now()) + make_interval(days => escrow_days()))
  returning id into v_id;
  perform _post(me.id, 'WALLET', 'SUBSCRIPTION', -v_price, 'Renewal: ' || s.name || ' · ' || p.name, v_ref, v_id, l.id);
  perform _post(me.id, 'WALLET', 'PURCHASE_FEE', -v_bfee, 'Transaction fee · ' || s.name || ' renewal', v_ref, v_id, l.id);
  perform _post(null, 'PLATFORM', 'PLATFORM_FEE', v_bfee, 'Transaction fee · ' || s.name || ' renewal', v_ref, v_id, l.id);
  perform _post(l.host_id, 'PENDING', 'HOST_EARNING_PENDING', v_price - v_fee, s.name || ' renewal · @' || me.username, v_ref, v_id, l.id);
  perform _notify(me.id, 'SUBSCRIPTION_RENEWED', s.name || ' renewed', 'Order ' || v_ref || '. Your next period starts on ' || to_char(m.ends_at, 'DD Mon YYYY') || '.', v_id::text);
  perform _notify(l.host_id, 'NEW_MEMBER', '@' || me.username || ' renewed their ' || s.name || ' seat', 'Order ' || v_ref, v_id::text);
  perform _chat_system(v_id, 'Renewal order ' || v_ref || ' created.');
  return jsonb_build_object('membership_id', v_id);
end $$;

-- escrow: released 30 days after the money was paid (or after the period starts, for renewals)
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
  update memberships set escrow = 'RELEASED', status = case when ends_at <= now() then 'COMPLETED' else status end where id = m.id;
  perform _notify(m.host_id, 'EARNING_AVAILABLE', _naira(m.host_kobo) || ' is ready to withdraw', 'From a ' || v_service || ' seat (order ' || coalesce(m.txn_ref, '') || ').', m.id::text);
end $$;

create or replace function public.release_due_escrow() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id from memberships where escrow = 'HELD' and status = 'ACTIVE' and release_at <= now()
           order by release_at for update skip locked
  loop
    perform _release(r.id, '30-day escrow completed');
    n := n + 1;
  end loop;
  return n;
end $$;

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
    v_amount := _join_check(p_user, p_listing, p_contact) + buyer_fee_kobo();   -- backend seat price + N200 fee; the browser's amount is ignored
  else
    raise exception 'Unknown payment type.';
  end if;
  insert into payments (reference, user_id, purpose, listing_id, contact, amount_kobo)
  values (p_reference, p_user, p_purpose, case when p_purpose = 'SEAT' then p_listing end, trim(coalesce(p_contact, '')), v_amount);
  return jsonb_build_object('reference', p_reference, 'amount_kobo', v_amount, 'email', v_email);
end $$;

-- ---------------------------------------------------------------------
-- 8. MEMBER VIEWS: dual wallet, orders
-- ---------------------------------------------------------------------
create or replace function public.my_overview() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return jsonb_build_object(
    'profile', jsonb_build_object('id', me.id, 'full_name', me.full_name, 'username', me.username, 'phone', me.phone, 'email', me.email,
                                  'verified_host', me.verified_host, 'created_at', me.created_at, 'referral_code', me.referral_code),
    'balances', jsonb_build_object(
       'wallet_kobo', _balance(me.id, 'WALLET'), 'earnings_kobo', _balance(me.id, 'EARNINGS'), 'pending_kobo', _balance(me.id, 'PENDING'),
       'available_kobo', _balance(me.id, 'WALLET') + _balance(me.id, 'EARNINGS'),
       'pending_matures_at', (select min(release_at) from memberships where host_id = me.id and escrow = 'HELD' and status = 'ACTIVE'),
       'withdrawn_kobo', coalesce((select sum(amount_kobo) from withdrawals where user_id = me.id and status = 'PAID'), 0),
       'processing_kobo', coalesce((select sum(amount_kobo) from withdrawals where user_id = me.id and status in ('PENDING','APPROVED')), 0),
       'total_earned_kobo', coalesce((select sum(amount_kobo) from wallet_transactions where user_id = me.id and type = 'HOST_EARNING'), 0)),
    'unread', (select count(*) from notifications where user_id = me.id and read_at is null),
    'unread_chats', (select count(*) from order_messages x join memberships m on m.id = x.membership_id
                     left join order_reads r on r.membership_id = x.membership_id and r.user_id = me.id
                     where (m.buyer_id = me.id or m.host_id = me.id) and x.sender_role <> 'SYSTEM' and x.sender_id is distinct from me.id
                       and x.id > coalesce(r.last_read_id, 0)));
end $$;

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
    'withdrawals', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'amount_kobo', w.amount_kobo, 'fee_kobo', w.fee_kobo,
        'payout_kobo', coalesce(w.payout_kobo, w.amount_kobo), 'reference', w.ledger_reference, 'bank_name', w.bank_name,
        'account_number', w.account_number, 'account_name', w.account_name, 'status', w.status, 'note', w.admin_note,
        'created_at', w.created_at) order by w.created_at desc) from withdrawals w where w.user_id = me.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('reference', x.reference, 'purpose', x.purpose, 'amount_kobo', x.amount_kobo,
        'status', x.status, 'created_at', x.created_at) order by x.created_at desc)
      from (select * from payments where user_id = me.id order by created_at desc limit 30) x), '[]'::jsonb),
    'pending_items', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'txn_ref', m.txn_ref, 'service', s.name, 'host_kobo', m.host_kobo,
        'release_at', m.release_at, 'status', m.status) order by m.release_at)
      from memberships m join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id
      where m.host_id = me.id and m.escrow = 'HELD'), '[]'::jsonb));
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
    'buyer_fee_kobo', m.buyer_fee_kobo, 'total_kobo', m.amount_kobo + m.buyer_fee_kobo, 'txn_ref', m.txn_ref,
    'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'order_status', _order_status(m), 'completed_at', m.completed_at,
    'access_status', m.access_status, 'renewed', m.renewed, 'contact', m.contact,
    'renew_price_kobo', case when l.status = 'LIVE' then _seat_price(p.normal_price_kobo, p.max_seats, l.markup_pct) end,
    'can_renew', (m.status = 'ACTIVE' and not m.renewed and m.ends_at > now() and m.starts_at <= now()
                  and m.ends_at <= now() + make_interval(days => v_window) and l.status = 'LIVE' and p.active and s.active),
    'can_complete', (m.status = 'ACTIVE' and m.completed_at is null and m.access_status in ('READY','SENT')),
    'unread', (select count(*) from order_messages x where x.membership_id = m.id and x.sender_role <> 'SYSTEM'
               and x.sender_id is distinct from me.id and x.id > coalesce((select r.last_read_id from order_reads r where r.membership_id = m.id and r.user_id = me.id), 0)),
    'dispute', (select jsonb_build_object('id', d.id, 'status', d.status, 'reason', d.reason, 'resolution', d.resolution, 'raised_by_role', d.raised_by_role)
                from disputes d where d.membership_id = m.id order by d.created_at desc limit 1))
    order by m.starts_at desc)
  from memberships m join listings l on l.id = m.listing_id join service_plans p on p.id = m.plan_id
  join services s on s.id = p.service_id join profiles h on h.id = m.host_id
  where m.buyer_id = me.id), '[]'::jsonb);
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
      'proof_status', l.proof_status,
      'proof_reason', coalesce((select h.reason from host_proofs h where h.listing_id = l.id order by h.submitted_at desc limit 1), ''),
      'agreement_accepted_at', l.agreement_accepted_at,
      'review_note', l.review_note, 'created_at', l.created_at,
      'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'buyer_username', b.username, 'buyer_name', split_part(b.full_name, ' ', 1),
            'contact', m.contact, 'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'access_status', m.access_status,
            'host_kobo', m.host_kobo, 'escrow', m.escrow, 'txn_ref', m.txn_ref, 'release_at', m.release_at,
            'order_status', _order_status(m), 'completed_at', m.completed_at,
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

-- ---------------------------------------------------------------------
-- 9. WITHDRAWALS: N200 fee, "available" = wallet + matured earnings
-- ---------------------------------------------------------------------
create or replace function public.request_withdrawal(p_amount_kobo bigint, p_bank text, p_account_number text, p_account_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_min bigint; v_fee bigint := withdrawal_fee_kobo(); v_ref text; v_id uuid; v_avail bigint;
begin
  me := _me();
  select min_withdrawal_kobo into v_min from platform_settings where id = 1;
  if p_amount_kobo is null or p_amount_kobo < v_min then raise exception 'The smallest withdrawal is %.', _naira(v_min); end if;
  v_avail := _balance(me.id, 'WALLET') + _balance(me.id, 'EARNINGS');
  if p_amount_kobo > v_avail then raise exception 'You can withdraw up to %.', _naira(v_avail); end if;
  if coalesce(p_account_number, '') !~ '^\d{10}$' then raise exception 'Account numbers have 10 digits.'; end if;
  if length(trim(coalesce(p_bank, ''))) < 2 then raise exception 'Pick your bank.'; end if;
  if length(trim(coalesce(p_account_name, ''))) < 3 then raise exception 'Enter the name on the bank account.'; end if;
  v_ref := _ref('WDR');
  insert into withdrawals (user_id, amount_kobo, fee_kobo, payout_kobo, bank_name, account_number, account_name, ledger_reference)
  values (me.id, p_amount_kobo, v_fee, p_amount_kobo - v_fee, trim(p_bank), p_account_number, left(trim(p_account_name), 80), v_ref) returning id into v_id;
  perform _debit_available(me.id, p_amount_kobo - v_fee, 'WITHDRAWAL', 'Withdrawal to ' || trim(p_bank) || ' ' || p_account_number, v_ref, v_id);
  perform _debit_available(me.id, v_fee, 'WITHDRAWAL_FEE', 'Withdrawal fee', v_ref, v_id);
  perform _notify(me.id, 'WITHDRAWAL_REQUESTED', 'Withdrawal requested',
    _naira(p_amount_kobo - v_fee) || ' will be sent to ' || trim(p_bank) || ' (fee ' || _naira(v_fee) || '). Reference ' || v_ref || '.', v_id::text);
  perform _notify_admins('ADMIN_ALERT', 'Withdrawal to pay: ' || _naira(p_amount_kobo - v_fee), '@' || me.username || ' · ' || trim(p_bank) || ' · ' || v_ref, v_id::text);
  return jsonb_build_object('withdrawal_id', v_id, 'reference', v_ref, 'fee_kobo', v_fee, 'payout_kobo', p_amount_kobo - v_fee);
end $$;

create or replace function public.admin_withdrawals(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'user', p.username, 'full_name', p.full_name, 'amount_kobo', w.amount_kobo,
      'fee_kobo', w.fee_kobo, 'payout_kobo', coalesce(w.payout_kobo, w.amount_kobo), 'reference', w.ledger_reference,
      'bank_name', w.bank_name, 'account_number', w.account_number, 'account_name', w.account_name, 'status', w.status,
      'admin_note', w.admin_note, 'created_at', w.created_at, 'paid_at', w.paid_at)
      order by (w.status in ('PENDING','APPROVED')) desc, w.created_at desc)
    from withdrawals w join profiles p on p.id = w.user_id
    where p_status is null or p_status = '' or w.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.admin_withdrawal_action(p_id uuid, p_action text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare w withdrawals; r record; v_pay bigint;
begin
  perform _need_admin();
  select * into w from withdrawals where id = p_id for update;
  if not found then raise exception 'Withdrawal not found.'; end if;
  v_pay := coalesce(w.payout_kobo, w.amount_kobo);
  if p_action = 'APPROVE' and w.status = 'PENDING' then
    update withdrawals set status = 'APPROVED', approved_at = now(), processed_by = auth.uid(), admin_note = coalesce(nullif(trim(p_note), ''), admin_note) where id = w.id;
    perform _notify(w.user_id, 'WITHDRAWAL_APPROVED', 'Withdrawal approved', _naira(v_pay) || ' is on its way to ' || w.bank_name || '.', w.id::text);
  elsif p_action = 'PAID' and w.status in ('PENDING','APPROVED') then
    update withdrawals set status = 'PAID', paid_at = now(), approved_at = coalesce(approved_at, now()), processed_by = auth.uid(),
      admin_note = coalesce(nullif(trim(p_note), ''), admin_note) where id = w.id;
    if w.fee_kobo > 0 then
      perform _post(null, 'PLATFORM', 'PLATFORM_FEE', w.fee_kobo, 'Withdrawal fee', w.ledger_reference, null, null, null, w.id);
    end if;
    perform _notify(w.user_id, 'WITHDRAWAL_PAID', _naira(v_pay) || ' sent to your bank', w.bank_name || ' · ' || w.account_number || ' · ' || w.ledger_reference, w.id::text);
  elsif p_action = 'REJECT' and w.status in ('PENDING','APPROVED') then
    if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write the reason so the user knows what to fix.'; end if;
    update withdrawals set status = 'REJECTED', processed_by = auth.uid(), admin_note = trim(p_note) where id = w.id;
    for r in select account_kind, amount_kobo from wallet_transactions where withdrawal_id = w.id and type in ('WITHDRAWAL','WITHDRAWAL_FEE') order by id loop
      perform _post(w.user_id, r.account_kind, 'WITHDRAWAL_REVERSED', -r.amount_kobo, 'Withdrawal returned: ' || trim(p_note), w.ledger_reference, null, null, null, w.id);
    end loop;
    perform _notify(w.user_id, 'WITHDRAWAL_REJECTED', 'Withdrawal not completed', trim(p_note) || ' The full ' || _naira(w.amount_kobo) || ' (fee included) is back in your balance.', w.id::text);
  else
    raise exception 'This withdrawal is already %.', lower(w.status);
  end if;
  perform _audit(p_action || '_WITHDRAWAL', 'withdrawal', p_id::text, jsonb_build_object('status', w.status),
    jsonb_build_object('amount_kobo', w.amount_kobo, 'fee_kobo', w.fee_kobo, 'payout_kobo', v_pay), p_note);
end $$;

-- ---------------------------------------------------------------------
-- 10. RECEIPTS
-- ---------------------------------------------------------------------
create or replace function public._receipt(p_ref text, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m memberships; w withdrawals; u profiles; v_item text; v_method text; v_host text; v_chan text;
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
      v_method := 'Paystack' || case when coalesce(v_chan, '') <> '' then ' (' || v_chan || ')' else '' end;
    else v_method := 'SubSplit wallet'; end if;
    return jsonb_build_object('kind', 'PURCHASE', 'txn_id', m.txn_ref, 'created_at', m.created_at,
      'user', jsonb_build_object('name', u.full_name, 'username', u.username, 'email', u.email),
      'item', v_item, 'host', v_host, 'period_start', m.starts_at, 'period_end', m.ends_at,
      'price_kobo', m.amount_kobo, 'fee_kobo', m.buyer_fee_kobo, 'total_kobo', m.amount_kobo + m.buyer_fee_kobo,
      'refund_kobo', m.refund_kobo, 'method', v_method,
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

create or replace function public.my_receipt(p_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; r jsonb;
begin
  me := _me();
  r := _receipt(p_ref, me.id);
  if r is null then raise exception 'Receipt not found.'; end if;
  return r;
end $$;

create or replace function public.admin_receipt(p_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  perform _need_admin();
  r := _receipt(p_ref, null);
  if r is null then raise exception 'Receipt not found.'; end if;
  return r;
end $$;

-- ---------------------------------------------------------------------
-- 11. ORDER CHAT, REPORT / DISTRESS ALARM, MARK COMPLETED
-- ---------------------------------------------------------------------
create or replace function public._chat_role(p_membership uuid, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when m.buyer_id = p_user then 'BUYER' when m.host_id = p_user then 'HOST'
              when exists (select 1 from admin_users a join profiles pr on pr.id = a.user_id where a.user_id = p_user and pr.status = 'ACTIVE') then 'ADMIN' end
  from memberships m where m.id = p_membership;
$$;

create or replace function public._order_obj(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', m.id, 'txn_ref', m.txn_ref, 'service', s.name, 'plan', p.name, 'logo_color', s.logo_color, 'logo_url', s.logo_url,
    'access_type', p.access_type, 'buyer', b.username, 'host', h.username, 'status', m.status, 'order_status', _order_status(m),
    'escrow', m.escrow, 'amount_kobo', m.amount_kobo, 'buyer_fee_kobo', m.buyer_fee_kobo, 'total_kobo', m.amount_kobo + m.buyer_fee_kobo,
    'host_kobo', m.host_kobo, 'release_at', m.release_at, 'starts_at', m.starts_at, 'ends_at', m.ends_at, 'completed_at', m.completed_at,
    'access_status', m.access_status, 'created_at', m.created_at,
    'dispute', (select jsonb_build_object('id', d.id, 'status', d.status, 'reason', d.reason, 'resolution', d.resolution, 'raised_by_role', d.raised_by_role)
                from disputes d where d.membership_id = m.id order by d.created_at desc limit 1))
  from memberships m join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id
  join profiles b on b.id = m.buyer_id join profiles h on h.id = m.host_id where m.id = p_id;
$$;

create or replace function public._chat_json(p_membership uuid, p_me uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'role', x.sender_role,
      'sender', case x.sender_role when 'ADMIN' then 'SubSplit support' when 'SYSTEM' then 'SubSplit' else coalesce(pr.username, 'user') end,
      'body', x.body, 'created_at', x.created_at, 'mine', x.sender_id is not distinct from p_me and x.sender_id is not null) order by x.id), '[]'::jsonb)
  from (select * from order_messages where membership_id = p_membership order by id desc limit 300) x
  left join profiles pr on pr.id = x.sender_id;
$$;

create or replace function public.order_chat(p_membership uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_role text; v_max bigint; v_order jsonb; v_contact text;
begin
  me := _me();
  v_role := _chat_role(p_membership, me.id);
  if v_role is null then raise exception using errcode = '42501', message = 'Order not found.'; end if;
  if v_role in ('BUYER','HOST') then
    select coalesce(max(id), 0) into v_max from order_messages where membership_id = p_membership;
    insert into order_reads (membership_id, user_id, last_read_id) values (p_membership, me.id, v_max)
    on conflict (membership_id, user_id) do update set last_read_id = greatest(order_reads.last_read_id, excluded.last_read_id);
  end if;
  v_order := _order_obj(p_membership);
  if v_role in ('HOST','ADMIN') then select contact into v_contact from memberships where id = p_membership; v_order := v_order || jsonb_build_object('contact', v_contact); end if;
  return jsonb_build_object('role', v_role, 'order', v_order, 'messages', _chat_json(p_membership, me.id));
end $$;

create or replace function public.order_send(p_membership uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_role text; m memberships; v_other uuid; v_service text;
begin
  me := _me();
  v_role := _chat_role(p_membership, me.id);
  if coalesce(v_role, '') not in ('BUYER','HOST') then raise exception using errcode = '42501', message = 'Order not found.'; end if;
  p_body := trim(coalesce(p_body, ''));
  if length(p_body) < 1 then raise exception 'Write a message first.'; end if;
  if length(p_body) > 2000 then raise exception 'That message is too long.'; end if;
  if (select count(*) from order_messages where sender_id = me.id and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'You are sending messages too fast. Please wait a moment.';
  end if;
  select * into m from memberships where id = p_membership;
  insert into order_messages (membership_id, sender_id, sender_role, body) values (p_membership, me.id, v_role, p_body);
  v_other := case when v_role = 'BUYER' then m.host_id else m.buyer_id end;
  if not exists (select 1 from notifications where user_id = v_other and type = 'ORDER_MESSAGE' and ref = p_membership::text and read_at is null) then
    select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
    perform _notify(v_other, 'ORDER_MESSAGE', 'New message about your ' || v_service || ' order', '@' || me.username || ': ' || left(p_body, 100), p_membership::text);
  end if;
  update order_reads set last_read_id = (select max(id) from order_messages where membership_id = p_membership)
   where membership_id = p_membership and user_id = me.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.my_orders() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return coalesce((select jsonb_agg(_order_obj(m.id) || jsonb_build_object(
      'role', case when m.buyer_id = me.id then 'BUYER' else 'HOST' end,
      'counterparty', case when m.buyer_id = me.id then h.username else b.username end,
      'unread', (select count(*) from order_messages x where x.membership_id = m.id and x.sender_role <> 'SYSTEM' and x.sender_id is distinct from me.id
                 and x.id > coalesce((select r.last_read_id from order_reads r where r.membership_id = m.id and r.user_id = me.id), 0)),
      'last_message_at', (select max(created_at) from order_messages x where x.membership_id = m.id),
      'can_complete', (m.buyer_id = me.id and m.status = 'ACTIVE' and m.completed_at is null and m.access_status in ('READY','SENT')))
      order by m.created_at desc)
    from memberships m join profiles b on b.id = m.buyer_id join profiles h on h.id = m.host_id
    where m.buyer_id = me.id or m.host_id = me.id), '[]'::jsonb);
end $$;

create or replace function public.complete_order(p_membership uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; v_service text;
begin
  me := _me();
  select * into m from memberships where id = p_membership and buyer_id = me.id for update;
  if not found then raise exception using errcode = '42501', message = 'Order not found.'; end if;
  if m.completed_at is not null or m.status = 'COMPLETED' then raise exception 'This order is already completed.'; end if;
  if m.status = 'DISPUTED' then raise exception 'This order has an open report. Support will close it first.'; end if;
  if m.status <> 'ACTIVE' then raise exception 'This order cannot be completed.'; end if;
  if m.access_status = 'WAITING' then raise exception 'Wait until the host has sent your access, then complete the order.'; end if;
  update memberships set completed_at = now() where id = m.id;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  perform _notify(m.host_id, 'ORDER_COMPLETED', 'Order completed: ' || v_service, '@' || me.username || ' marked order ' || coalesce(m.txn_ref, '') || ' as completed.', m.id::text);
  perform _chat_system(m.id, '@' || me.username || ' marked this order as completed.');
end $$;

create or replace function public.report_order(p_membership uuid, p_reason text, p_details text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; m memberships; v_id uuid; v_service text; v_role text; v_other uuid;
begin
  me := _me();
  if coalesce(p_reason, '') not in ('HOST_NO_RESPONSE','INVALID_CREDENTIALS','ACCESS_NOT_WORKING','WRONG_SUBSCRIPTION','PAYMENT_ORDER',
                                    'NOT_WORKING','NO_ACCESS','WRONG_PLAN','REMOVED','OTHER') then
    raise exception 'Pick what went wrong.';
  end if;
  if length(trim(coalesce(p_details, ''))) < 10 then raise exception 'Tell us a little more (at least 10 letters) so we can help.'; end if;
  select * into m from memberships where id = p_membership and (buyer_id = me.id or host_id = me.id) for update;
  if not found then raise exception 'You can only report an order that is yours.'; end if;
  v_role := case when m.buyer_id = me.id then 'BUYER' else 'HOST' end;
  if m.status = 'DISPUTED' then raise exception 'This order already has an open report.'; end if;
  if m.status <> 'ACTIVE' or m.escrow <> 'HELD' then raise exception 'You can only report an order that is active.'; end if;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  insert into disputes (membership_id, listing_id, buyer_id, host_id, reason, details, raised_by, raised_by_role)
  values (m.id, m.listing_id, m.buyer_id, m.host_id, p_reason, left(trim(p_details), 2000), me.id, v_role) returning id into v_id;
  update memberships set status = 'DISPUTED' where id = m.id;
  v_other := case when v_role = 'BUYER' then m.host_id else m.buyer_id end;
  perform _notify(me.id, 'DISPUTE_OPENED', 'We got your report', 'Our team will look into your ' || v_service || ' order and get back to you.', m.id::text);
  perform _notify(v_other, 'DISPUTE_OPENED', 'A report was opened on your ' || v_service || ' order',
    case when v_role = 'BUYER' then 'The member needs help. Please reply in the order chat.' else 'The host reported a problem. Support will review it.' end, m.id::text);
  perform _notify_admins('ADMIN_ALERT', 'Distress alarm: ' || v_service || ' order', 'Raised by the ' || lower(v_role) || ' @' || me.username || ' (' || p_reason || ').', v_id::text);
  perform _chat_system(m.id, 'Report opened by the ' || lower(v_role) || ' (' || replace(lower(p_reason), '_', ' ') || '). SubSplit support has been alerted and the money for this order is on hold.');
  return jsonb_build_object('dispute_id', v_id);
end $$;

create or replace function public.open_dispute(p_membership uuid, p_reason text, p_details text default '') returns jsonb
language sql security definer set search_path = public as $$ select public.report_order(p_membership, p_reason, p_details) $$;

create or replace function public._dispute_closed_note() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status in ('OPEN','IN_REVIEW') and new.status in ('RESOLVED','CLOSED') then
    perform _chat_system(new.membership_id, 'Report resolved by SubSplit support' ||
      case new.resolution when 'REFUND' then ': the member was refunded in full.' when 'PARTIAL_REFUND' then ': the member got a partial refund.'
        when 'RELEASE' then ': the host was paid.' else '.' end);
  end if;
  return new;
end $$;
create or replace trigger dispute_closed_note after update of status on public.disputes
  for each row execute function public._dispute_closed_note();

-- admin side of chats
create or replace function public.admin_order_chats(p_search text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare q text := '%' || lower(trim(coalesce(p_search, ''))) || '%';
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(_order_obj(m.id) || jsonb_build_object(
      'messages', (select count(*) from order_messages x where x.membership_id = m.id and x.sender_role <> 'SYSTEM'),
      'last_message_at', (select max(created_at) from order_messages x where x.membership_id = m.id),
      'last_message', (select left(body, 90) from order_messages x where x.membership_id = m.id and x.sender_role <> 'SYSTEM' order by id desc limit 1))
      order by (m.status = 'DISPUTED') desc, coalesce((select max(created_at) from order_messages x where x.membership_id = m.id), m.created_at) desc)
    from (select * from memberships order by created_at desc limit 400) m
    join profiles b on b.id = m.buyer_id join profiles h on h.id = m.host_id
    where lower(coalesce(m.txn_ref, '') || ' ' || b.username || ' ' || h.username) like q), '[]'::jsonb);
end $$;

create or replace function public.admin_order_chat(p_membership uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  if not exists (select 1 from memberships where id = p_membership) then raise exception 'Order not found.'; end if;
  return jsonb_build_object('role', 'ADMIN', 'order', _order_obj(p_membership) || jsonb_build_object('contact', (select contact from memberships where id = p_membership)),
    'messages', _chat_json(p_membership, auth.uid()));
end $$;

create or replace function public.admin_order_send(p_membership uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare m memberships; v_service text;
begin
  perform _need_admin();
  p_body := trim(coalesce(p_body, ''));
  if length(p_body) < 1 then raise exception 'Write a message first.'; end if;
  select * into m from memberships where id = p_membership;
  if not found then raise exception 'Order not found.'; end if;
  insert into order_messages (membership_id, sender_id, sender_role, body) values (p_membership, auth.uid(), 'ADMIN', left(p_body, 2000));
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = m.plan_id;
  perform _notify(m.buyer_id, 'ORDER_MESSAGE', 'SubSplit support wrote about your ' || v_service || ' order', left(p_body, 100), p_membership::text);
  perform _notify(m.host_id, 'ORDER_MESSAGE', 'SubSplit support wrote about a ' || v_service || ' order', left(p_body, 100), p_membership::text);
  perform _audit('ORDER_CHAT_MESSAGE', 'membership', p_membership::text, null, null, left(p_body, 200));
end $$;

-- ---------------------------------------------------------------------
-- 12. EMAIL OUTBOX (used by the send-emails Edge Function, server key only)
-- ---------------------------------------------------------------------
create or replace function public.email_check_token(p_token text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from internal_secrets where name = 'email_cron' and value = coalesce(p_token, ''));
$$;

create or replace function public.email_claim(p_limit int default 25) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; out jsonb := '[]'::jsonb;
begin
  for r in select id, to_email, type, subject, body from email_outbox
           where sent_at is null and attempts < 5 order by id limit greatest(1, least(p_limit, 100)) for update skip locked
  loop
    update email_outbox set attempts = attempts + 1 where id = r.id;
    out := out || jsonb_build_object('id', r.id, 'to', r.to_email, 'type', r.type, 'subject', r.subject, 'body', r.body);
  end loop;
  return out;
end $$;

create or replace function public.email_mark(p_id bigint, p_ok boolean, p_err text default '') returns void
language sql security definer set search_path = public as $$
  update email_outbox set sent_at = case when p_ok then now() end, last_error = case when p_ok then '' else left(coalesce(p_err, ''), 300) end where id = p_id;
$$;

-- review from the Listings screen also settles the proof (one decision, one record)
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
  if p_action = 'APPROVE' then
    update host_proofs set status = 'APPROVED', reviewed_at = now(), reviewed_by = auth.uid() where listing_id = l.id and status = 'PENDING';
    update listings set proof_status = 'APPROVED' where id = l.id and exists (select 1 from host_proofs where listing_id = l.id and status = 'APPROVED');
  elsif p_action = 'REJECT' then
    update host_proofs set status = 'REJECTED', reason = coalesce(nullif(trim(p_note), ''), reason), reviewed_at = now(), reviewed_by = auth.uid()
      where listing_id = l.id and status = 'PENDING';
    update listings set proof_status = 'REJECTED' where id = l.id and l.proof_path <> '' and l.status = 'PENDING_REVIEW';
  end if;
  update listings set status = v_new, review_note = coalesce(nullif(trim(p_note), ''), review_note), reviewed_at = now(),
    reviewed_by = auth.uid(), updated_at = now() where id = p_id;
  select s.name into v_service from service_plans p join services s on s.id = p.service_id where p.id = l.plan_id;
  if p_action = 'APPROVE' or (p_action = 'RELIST' and l.status <> 'PAUSED') then
    perform _notify(l.host_id, 'LISTING_APPROVED', 'Your ' || v_service || ' listing is live', 'Members can now join it.', l.id::text);
  elsif p_action = 'REJECT' then
    perform _notify(l.host_id, 'LISTING_REJECTED', 'Your ' || v_service || ' listing needs changes', trim(p_note), l.id::text);
  elsif p_action = 'SUSPEND' then
    perform _notify(l.host_id, 'LISTING_SUSPENDED', 'Your ' || v_service || ' listing was suspended', coalesce(nullif(trim(p_note), ''), 'Please contact support.'), l.id::text);
  end if;
  perform _audit(p_action || '_LISTING', 'listing', p_id::text, jsonb_build_object('status', l.status), jsonb_build_object('status', v_new), p_note);
end $$;

-- ---------------------------------------------------------------------
-- 13. PERMISSIONS: lock every function, then open only the public API
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.is_admin(), public.public_catalog(), public.explore_listings(), public.listing_detail(uuid), public.release_due_escrow()
  to anon, authenticated;
do $$ declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' and p.proname !~ '^_'
             and p.proname not in ('payment_create','payment_complete','payment_fail','send_expiry_reminders','email_claim','email_mark','email_check_token',
                                   'handle_new_user','handle_user_email','platform_fee_bps','buyer_fee_kobo','withdrawal_fee_kobo','escrow_days',
                                   'is_admin','public_catalog','explore_listings','listing_detail','release_due_escrow')
  loop execute format('grant execute on function %s to authenticated', r.sig); end loop;
end $$;
grant execute on function public.payment_create(uuid, text, text, bigint, uuid, text), public.payment_complete(text, bigint, text, text, text),
  public.payment_fail(text, text, text) to service_role;
grant execute on function public.send_expiry_reminders(), public.release_due_escrow(), public.email_claim(int), public.email_mark(bigint, boolean, text),
  public.email_check_token(text) to service_role;
