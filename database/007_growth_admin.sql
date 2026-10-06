-- =====================================================================
--  SUBSPLIT · 007_growth_admin.sql   (run after 006; safe to re-run)
--  Referrals + promotions, subscription requests, admin wallet credits,
--  transaction search, approval desk, full user view, WhatsApp link,
--  expiry reminders for buyer AND host, sidebar badges.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. WhatsApp support link (admin setting) + public catalog
-- ---------------------------------------------------------------------
alter table public.platform_settings add column if not exists support_whatsapp_link text not null default '';
update public.platform_settings set support_whatsapp_link = 'https://wa.me/' || support_whatsapp
 where support_whatsapp_link = '' and support_whatsapp ~ '^\d{8,15}$';

create or replace function public.admin_save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare old platform_settings; v_link text;
begin
  perform _need_admin();
  select * into old from platform_settings where id = 1 for update;
  v_link := case when p ? 'support_whatsapp_link' then trim(coalesce(p ->> 'support_whatsapp_link', '')) end;
  if v_link is not null and v_link <> '' and v_link !~* '^https://(wa\.me|wa\.link|api\.whatsapp\.com|chat\.whatsapp\.com)/\S+$' then
    raise exception 'Use a WhatsApp link, for example https://wa.me/2348012345678 or a chat.whatsapp.com invite link.';
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
    updated_at = now()
  where id = 1;
  perform _audit('UPDATE_SETTINGS', 'platform_settings', '1', to_jsonb(old), (select to_jsonb(s) from platform_settings s where id = 1));
end $$;

-- ---------------------------------------------------------------------
-- 2. Promotions + referrals
-- ---------------------------------------------------------------------
create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 3 and 80),
  banner_url text not null default '',
  description text not null default '',
  terms text not null default '',
  reward_referrer_kobo bigint not null default 0 check (reward_referrer_kobo between 0 and 50000000),
  reward_referee_kobo bigint not null default 0 check (reward_referee_kobo between 0 and 50000000),
  min_purchase_kobo bigint not null default 0 check (min_purchase_kobo >= 0),
  requires_referral boolean not null default true,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  active boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at)
);
create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references public.profiles(id) on delete restrict,
  referred_id uuid not null unique references public.profiles(id) on delete restrict,
  code text not null,
  status text not null default 'SIGNED_UP' check (status in ('SIGNED_UP','REWARDED')),
  promo_id uuid references public.promotions(id) on delete set null,
  membership_id uuid,
  reward_referrer_kobo bigint not null default 0,
  reward_referee_kobo bigint not null default 0,
  created_at timestamptz not null default now(),
  rewarded_at timestamptz,
  check (referrer_id <> referred_id)
);
create index if not exists referrals_referrer_idx on public.referrals (referrer_id, created_at desc);
create table if not exists public.promo_claims (
  promo_id uuid not null references public.promotions(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  membership_id uuid,
  amount_kobo bigint not null,
  created_at timestamptz not null default now(),
  primary key (promo_id, user_id)
);
alter table public.promotions enable row level security;
alter table public.referrals enable row level security;
alter table public.promo_claims enable row level security;
revoke all on public.promotions, public.referrals, public.promo_claims from anon, authenticated;

-- signup: referral code is optional; bad codes are ignored (never block signup)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare base text; uname text; v_code text; v_ref uuid; v_my text;
begin
  base := left(lower(regexp_replace(split_part(coalesce(new.email, 'user'), '@', 1), '[^a-zA-Z0-9]', '', 'g')), 12);
  if length(base) < 3 then base := 'user' || base; end if;
  loop
    uname := base || (floor(random() * 9000) + 1000)::int;
    exit when not exists (select 1 from profiles where username = uname);
  end loop;
  loop
    v_my := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from profiles where referral_code = v_my);
  end loop;
  v_code := upper(trim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  if v_code <> '' then select id into v_ref from profiles where referral_code = v_code and status = 'ACTIVE'; end if;
  insert into profiles (id, full_name, phone, email, username, referral_code, referred_by)
  values (new.id, left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 80),
          left(coalesce(new.raw_user_meta_data ->> 'phone', ''), 20), coalesce(new.email, ''), uname, v_my, v_ref)
  on conflict (id) do nothing;
  if v_ref is not null and v_ref <> new.id then
    insert into referrals (referrer_id, referred_id, code) values (v_ref, new.id, v_code) on conflict (referred_id) do nothing;
  end if;
  perform _account(new.id, 'WALLET'); perform _account(new.id, 'EARNINGS'); perform _account(new.id, 'PENDING');
  return new;
end $$;

-- Reward rule: the referred person's FIRST qualifying purchase during an active promotion.
create or replace function public._referral_check(p_buyer uuid, p_membership uuid, p_amount bigint) returns void
language plpgsql security definer set search_path = public as $$
declare pr promotions; rf referrals; v_ref text; v_title text;
begin
  select * into pr from promotions where active and starts_at <= now() and (ends_at is null or ends_at > now())
    and p_amount >= min_purchase_kobo order by created_at desc limit 1;
  if not found then return; end if;
  select * into rf from referrals where referred_id = p_buyer and status = 'SIGNED_UP' for update;
  if found then
    v_ref := _ref('REF');
    update referrals set status = 'REWARDED', promo_id = pr.id, membership_id = p_membership, rewarded_at = now(),
      reward_referrer_kobo = pr.reward_referrer_kobo, reward_referee_kobo = pr.reward_referee_kobo where id = rf.id;
    if pr.reward_referrer_kobo > 0 then
      perform _post(rf.referrer_id, 'WALLET', 'REFERRAL_REWARD', pr.reward_referrer_kobo, 'Referral reward · ' || pr.title, v_ref, p_membership);
      perform _post(null, 'PLATFORM', 'REFERRAL_REWARD', -pr.reward_referrer_kobo, 'Referral reward · ' || pr.title, v_ref, p_membership);
      perform _notify(rf.referrer_id, 'REFERRAL_REWARD', 'You earned ' || _naira(pr.reward_referrer_kobo),
        'A friend you invited made their first purchase. It is in your wallet.', p_membership::text);
    end if;
    if pr.reward_referee_kobo > 0 then
      perform _post(p_buyer, 'WALLET', 'REFERRAL_REWARD', pr.reward_referee_kobo, 'Welcome bonus · ' || pr.title, v_ref, p_membership);
      perform _post(null, 'PLATFORM', 'REFERRAL_REWARD', -pr.reward_referee_kobo, 'Welcome bonus · ' || pr.title, v_ref, p_membership);
      perform _notify(p_buyer, 'REFERRAL_REWARD', 'Welcome bonus: ' || _naira(pr.reward_referee_kobo), 'Thanks for joining through a friend. It is in your wallet.', p_membership::text);
    end if;
    perform _audit_system('REFERRAL_REWARD', 'referral', rf.id::text, null,
      jsonb_build_object('promo', pr.id, 'referrer', rf.referrer_id, 'referred', p_buyer, 'referrer_kobo', pr.reward_referrer_kobo, 'referee_kobo', pr.reward_referee_kobo), pr.title);
  elsif not pr.requires_referral and pr.reward_referee_kobo > 0 then
    insert into promo_claims (promo_id, user_id, membership_id, amount_kobo) values (pr.id, p_buyer, p_membership, pr.reward_referee_kobo)
      on conflict do nothing;
    if found then
      v_ref := _ref('PRM');
      perform _post(p_buyer, 'WALLET', 'REFERRAL_REWARD', pr.reward_referee_kobo, 'Promo bonus · ' || pr.title, v_ref, p_membership);
      perform _post(null, 'PLATFORM', 'REFERRAL_REWARD', -pr.reward_referee_kobo, 'Promo bonus · ' || pr.title, v_ref, p_membership);
      perform _notify(p_buyer, 'REFERRAL_REWARD', 'Promo bonus: ' || _naira(pr.reward_referee_kobo), pr.title, p_membership::text);
      perform _audit_system('PROMO_REWARD', 'promotion', pr.id::text, null, jsonb_build_object('user', p_buyer, 'amount_kobo', pr.reward_referee_kobo), pr.title);
    end if;
  end if;
end $$;

create or replace function public.public_promos() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'banner_url', banner_url, 'description', description, 'terms', terms,
      'reward_referrer_kobo', reward_referrer_kobo, 'reward_referee_kobo', reward_referee_kobo, 'min_purchase_kobo', min_purchase_kobo,
      'requires_referral', requires_referral, 'ends_at', ends_at) order by created_at desc), '[]'::jsonb)
  from promotions where active and starts_at <= now() and (ends_at is null or ends_at > now());
$$;

create or replace function public.my_referrals() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return jsonb_build_object('code', me.referral_code, 'referred_by', (select username from profiles where id = me.referred_by),
    'invited', (select count(*) from referrals where referrer_id = me.id),
    'rewarded', (select count(*) from referrals where referrer_id = me.id and status = 'REWARDED'),
    'earned_kobo', coalesce((select sum(reward_referrer_kobo) from referrals where referrer_id = me.id and status = 'REWARDED'), 0),
    'items', coalesce((select jsonb_agg(jsonb_build_object('username', left(p.username, 3) || '***', 'status', r.status,
        'reward_kobo', r.reward_referrer_kobo, 'joined_at', r.created_at) order by r.created_at desc)
      from referrals r join profiles p on p.id = r.referred_id where r.referrer_id = me.id), '[]'::jsonb));
end $$;

create or replace function public.admin_promos() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object(
      'referrals', (select count(*) from referrals r where r.promo_id = p.id), 'rewards_paid_kobo',
      coalesce((select sum(reward_referrer_kobo + reward_referee_kobo) from referrals r where r.promo_id = p.id), 0)
        + coalesce((select sum(amount_kobo) from promo_claims c where c.promo_id = p.id), 0),
      'live', p.active and p.starts_at <= now() and (p.ends_at is null or p.ends_at > now())) order by p.created_at desc)
    from promotions p), '[]'::jsonb);
end $$;

create or replace function public.admin_save_promo(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; old promotions;
begin
  perform _need_admin();
  if length(trim(coalesce(p ->> 'title', ''))) < 3 then raise exception 'Give the promotion a title.'; end if;
  if coalesce(p ->> 'banner_url', '') <> '' and (p ->> 'banner_url') !~* '^https://\S+$' then raise exception 'The banner must be an https:// image link.'; end if;
  if nullif(p ->> 'ends_at', '') is not null and nullif(p ->> 'starts_at', '') is not null and (p ->> 'ends_at')::timestamptz <= (p ->> 'starts_at')::timestamptz then
    raise exception 'The end date must be after the start date.';
  end if;
  v_id := nullif(p ->> 'id', '')::uuid;
  if v_id is null then
    insert into promotions (title, banner_url, description, terms, reward_referrer_kobo, reward_referee_kobo, min_purchase_kobo, requires_referral,
                            starts_at, ends_at, active, created_by)
    values (trim(p ->> 'title'), coalesce(p ->> 'banner_url', ''), coalesce(p ->> 'description', ''), coalesce(p ->> 'terms', ''),
            coalesce((p ->> 'reward_referrer_kobo')::bigint, 0), coalesce((p ->> 'reward_referee_kobo')::bigint, 0),
            coalesce((p ->> 'min_purchase_kobo')::bigint, 0), coalesce((p ->> 'requires_referral')::boolean, true),
            coalesce(nullif(p ->> 'starts_at', '')::timestamptz, now()), nullif(p ->> 'ends_at', '')::timestamptz,
            coalesce((p ->> 'active')::boolean, true), auth.uid()) returning id into v_id;
    perform _audit('CREATE_PROMO', 'promotion', v_id::text, null, p);
  else
    select * into old from promotions where id = v_id for update;
    if not found then raise exception 'Promotion not found.'; end if;
    update promotions set title = trim(p ->> 'title'), banner_url = coalesce(p ->> 'banner_url', banner_url), description = coalesce(p ->> 'description', description),
      terms = coalesce(p ->> 'terms', terms), reward_referrer_kobo = coalesce((p ->> 'reward_referrer_kobo')::bigint, reward_referrer_kobo),
      reward_referee_kobo = coalesce((p ->> 'reward_referee_kobo')::bigint, reward_referee_kobo),
      min_purchase_kobo = coalesce((p ->> 'min_purchase_kobo')::bigint, min_purchase_kobo),
      requires_referral = coalesce((p ->> 'requires_referral')::boolean, requires_referral),
      starts_at = coalesce(nullif(p ->> 'starts_at', '')::timestamptz, starts_at),
      ends_at = case when p ? 'ends_at' then nullif(p ->> 'ends_at', '')::timestamptz else ends_at end,
      active = coalesce((p ->> 'active')::boolean, active) where id = v_id;
    perform _audit('UPDATE_PROMO', 'promotion', v_id::text, to_jsonb(old), p);
  end if;
  return v_id;
end $$;

create or replace function public.admin_referrals() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'referrer', a.username, 'referred', b.username, 'code', r.code, 'status', r.status,
      'promo', (select title from promotions where id = r.promo_id), 'reward_referrer_kobo', r.reward_referrer_kobo,
      'reward_referee_kobo', r.reward_referee_kobo, 'created_at', r.created_at, 'rewarded_at', r.rewarded_at) order by r.created_at desc)
    from (select * from referrals order by created_at desc limit 300) r
    join profiles a on a.id = r.referrer_id join profiles b on b.id = r.referred_id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- 3. "Suggest a subscription"
-- ---------------------------------------------------------------------
create table if not exists public.subscription_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  service_name text not null check (length(trim(service_name)) between 2 and 80),
  details text not null default '',
  status text not null default 'PENDING' check (status in ('PENDING','IN_PROGRESS','ADDED','DECLINED')),
  admin_note text not null default '',
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists sub_requests_idx on public.subscription_requests (status, created_at desc);
create index if not exists sub_requests_user_idx on public.subscription_requests (user_id, created_at desc);
alter table public.subscription_requests enable row level security;
revoke all on public.subscription_requests from anon, authenticated;

create or replace function public.suggest_subscription(p_name text, p_details text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_id uuid;
begin
  me := _me();
  p_name := trim(coalesce(p_name, ''));
  if length(p_name) < 2 then raise exception 'Type the name of the subscription you want.'; end if;
  if length(p_name) > 80 then raise exception 'That name is too long.'; end if;
  if exists (select 1 from services s join service_plans p on p.service_id = s.id where s.active and p.active and lower(s.name) = lower(p_name)) then
    raise exception '% is already on SubSplit. Search for it on Explore.', p_name;
  end if;
  if exists (select 1 from subscription_requests where user_id = me.id and lower(service_name) = lower(p_name) and status in ('PENDING','IN_PROGRESS')) then
    raise exception 'You already asked for this one. We will tell you when it is added.';
  end if;
  if (select count(*) from subscription_requests where user_id = me.id and created_at > now() - interval '1 day') >= 5 then
    raise exception 'You can send up to 5 requests a day. Please try again tomorrow.';
  end if;
  insert into subscription_requests (user_id, service_name, details) values (me.id, p_name, left(trim(coalesce(p_details, '')), 500)) returning id into v_id;
  perform _notify_admins('ADMIN_ALERT', 'Subscription requested: ' || p_name, '@' || me.username || ' wants ' || p_name || ' on SubSplit.', v_id::text);
  perform _notify(me.id, 'REQUEST_RECEIVED', 'We got your request for ' || p_name, 'We will tell you as soon as it is added.', v_id::text);
  return jsonb_build_object('request_id', v_id);
end $$;

create or replace function public.my_requests() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'service_name', r.service_name, 'details', r.details, 'status', r.status,
      'note', r.admin_note, 'created_at', r.created_at, 'resolved_at', r.resolved_at) order by r.created_at desc)
    from subscription_requests r where r.user_id = me.id), '[]'::jsonb);
end $$;

create or replace function public.admin_requests(p_status text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'user', u.username, 'email', u.email, 'service_name', r.service_name,
      'details', r.details, 'status', r.status, 'admin_note', r.admin_note, 'created_at', r.created_at, 'resolved_at', r.resolved_at,
      'same_requests', (select count(*) from subscription_requests x where lower(x.service_name) = lower(r.service_name)))
      order by (r.status in ('PENDING','IN_PROGRESS')) desc, r.created_at desc)
    from (select * from subscription_requests where p_status is null or p_status = '' or status = p_status order by created_at desc limit 300) r
    join profiles u on u.id = r.user_id), '[]'::jsonb);
end $$;

create or replace function public.admin_request_action(p_id uuid, p_action text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare r subscription_requests; v_new text;
begin
  perform _need_admin();
  select * into r from subscription_requests where id = p_id for update;
  if not found then raise exception 'Request not found.'; end if;
  v_new := case p_action when 'PROGRESS' then 'IN_PROGRESS' when 'ADDED' then 'ADDED' when 'DECLINE' then 'DECLINED' end;
  if v_new is null then raise exception 'Unknown action.'; end if;
  if r.status in ('ADDED','DECLINED') then raise exception 'This request is already %.', lower(r.status); end if;
  if v_new = 'DECLINED' and length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write a short reason so the user knows why.'; end if;
  update subscription_requests set status = v_new, admin_note = coalesce(nullif(trim(p_note), ''), admin_note),
    resolved_at = case when v_new in ('ADDED','DECLINED') then now() end where id = p_id;
  if v_new = 'ADDED' then
    perform _notify(r.user_id, 'REQUEST_ADDED', r.service_name || ' is now on SubSplit', 'You asked for it, so you are the first to know. Open Explore to find it.', p_id::text);
  elsif v_new = 'DECLINED' then
    perform _notify(r.user_id, 'REQUEST_DECLINED', 'About your ' || r.service_name || ' request', trim(p_note), p_id::text);
  elsif v_new = 'IN_PROGRESS' then
    perform _notify(r.user_id, 'REQUEST_PROGRESS', 'We are working on ' || r.service_name, 'We will tell you as soon as it is ready.', p_id::text);
  end if;
  perform _audit(p_action || '_REQUEST', 'subscription_request', p_id::text, jsonb_build_object('status', r.status), jsonb_build_object('status', v_new), p_note);
end $$;

-- when a service with the same name goes live, close matching requests and tell the people who asked
create or replace function public._service_added() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if new.active and (tg_op = 'INSERT' or not coalesce(old.active, false)) then
    for r in select * from subscription_requests where lower(service_name) = lower(new.name) and status in ('PENDING','IN_PROGRESS') for update loop
      update subscription_requests set status = 'ADDED', resolved_at = now(), admin_note = 'Added automatically' where id = r.id;
      perform _notify(r.user_id, 'REQUEST_ADDED', new.name || ' is now on SubSplit', 'You asked for it, so you are the first to know. Open Explore to find it.', r.id::text);
    end loop;
  end if;
  return new;
end $$;
create or replace trigger service_added after insert or update of active on public.services for each row execute function public._service_added();

-- ---------------------------------------------------------------------
-- 4. Admin wallet credits (single, batch, everyone). Always: ledger row + reason + admin + audit.
-- ---------------------------------------------------------------------
create or replace function public._credit_one(p_user uuid, p_amount bigint, p_reason text, p_ref text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _post(p_user, 'WALLET', 'ADMIN_CREDIT', p_amount, 'Credit from SubSplit: ' || p_reason, p_ref);
  perform _post(null, 'PLATFORM', 'ADMIN_CREDIT', -p_amount, 'Credit to user: ' || p_reason, p_ref);
  perform _notify(p_user, 'ADMIN_CREDIT', _naira(p_amount) || ' added to your wallet', p_reason);
end $$;

create or replace function public.admin_credit_user(p_user uuid, p_amount_kobo bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ref text := _ref('CRD');
begin
  perform _need_admin();
  if p_amount_kobo is null or p_amount_kobo < 10000 or p_amount_kobo > 50000000 then raise exception 'Credit between N100 and N500,000.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write the reason for this credit.'; end if;
  if not exists (select 1 from profiles where id = p_user and status = 'ACTIVE') then raise exception 'User not found or suspended.'; end if;
  perform _credit_one(p_user, p_amount_kobo, trim(p_reason), v_ref);
  perform _audit('CREDIT_USER', 'wallet', p_user::text, null, jsonb_build_object('amount_kobo', p_amount_kobo, 'reference', v_ref), p_reason);
  return jsonb_build_object('reference', v_ref, 'users', 1, 'total_kobo', p_amount_kobo);
end $$;

create or replace function public.admin_credit_batch(p_users uuid[], p_amount_kobo bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ref text := _ref('CRB'); u uuid; n int := 0;
begin
  perform _need_admin();
  if p_users is null or cardinality(p_users) = 0 then raise exception 'Pick at least one user.'; end if;
  if cardinality(p_users) > 200 then raise exception 'Pick up to 200 users at a time.'; end if;
  if p_amount_kobo is null or p_amount_kobo < 10000 or p_amount_kobo > 50000000 then raise exception 'Credit between N100 and N500,000 each.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write the reason for this credit.'; end if;
  for u in select distinct x from unnest(p_users) x loop
    if exists (select 1 from profiles where id = u and status = 'ACTIVE') then
      perform _credit_one(u, p_amount_kobo, trim(p_reason), v_ref || '-' || (n + 1));
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'None of those users can receive credit.'; end if;
  perform _audit('CREDIT_BATCH', 'wallet', v_ref, null, jsonb_build_object('users', n, 'amount_kobo', p_amount_kobo, 'total_kobo', n * p_amount_kobo), p_reason);
  return jsonb_build_object('reference', v_ref, 'users', n, 'total_kobo', n * p_amount_kobo);
end $$;

create or replace function public.admin_credit_all(p_amount_kobo bigint, p_reason text, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ref text := _ref('CRA'); u uuid; n int := 0; v_count int;
begin
  perform _need_admin();
  if coalesce(p_confirm, '') <> 'CREDIT ALL' then raise exception 'Type CREDIT ALL to confirm.'; end if;
  if p_amount_kobo is null or p_amount_kobo < 10000 or p_amount_kobo > 5000000 then raise exception 'Credit between N100 and N50,000 each for everyone.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write the reason for this credit.'; end if;
  select count(*) into v_count from profiles where status = 'ACTIVE';
  if v_count * p_amount_kobo > 500000000 then raise exception 'That would credit more than N5,000,000 in total. Use a smaller amount.'; end if;
  for u in select id from profiles where status = 'ACTIVE' order by created_at loop
    perform _credit_one(u, p_amount_kobo, trim(p_reason), v_ref || '-' || (n + 1));
    n := n + 1;
  end loop;
  perform _audit('CREDIT_ALL', 'wallet', v_ref, null, jsonb_build_object('users', n, 'amount_kobo', p_amount_kobo, 'total_kobo', n * p_amount_kobo), p_reason);
  return jsonb_build_object('reference', v_ref, 'users', n, 'total_kobo', n * p_amount_kobo);
end $$;

-- ---------------------------------------------------------------------
-- 5. Transaction search: type any ID and see the whole story
-- ---------------------------------------------------------------------
create or replace function public.admin_txn_search(p_ref text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ref text := trim(coalesce(p_ref, '')); v_mid uuid; v_pay text; v_wid uuid; v_uid uuid; v_did uuid; v_kind text; m memberships; w withdrawals; x payments; t wallet_transactions;
begin
  perform _need_admin();
  if length(v_ref) < 3 then raise exception 'Type a transaction ID, order ID, payment reference or withdrawal reference.'; end if;
  select * into m from memberships where txn_ref = v_ref or id::text = v_ref or payment_reference = v_ref limit 1;
  if found then v_kind := 'ORDER'; v_mid := m.id; v_pay := m.payment_reference; v_uid := m.buyer_id; end if;
  if v_kind is null then
    select * into x from payments where reference = v_ref;
    if found then v_kind := 'PAYMENT'; v_pay := x.reference; v_mid := x.membership_id; v_uid := x.user_id; end if;
  end if;
  if v_kind is null then
    select * into w from withdrawals where ledger_reference = v_ref or id::text = v_ref;
    if found then v_kind := 'WITHDRAWAL'; v_wid := w.id; v_uid := w.user_id; end if;
  end if;
  if v_kind is null then
    select * into t from wallet_transactions where reference = v_ref order by id limit 1;
    if found then v_kind := 'LEDGER'; v_mid := t.membership_id; v_pay := t.payment_reference; v_wid := t.withdrawal_id; v_uid := t.user_id; end if;
  end if;
  if v_kind is null then
    select membership_id into v_did from disputes where id::text = v_ref;
    if v_did is not null then v_kind := 'DISPUTE'; v_mid := v_did; select buyer_id into v_uid from memberships where id = v_mid; end if;
  end if;
  if v_kind is null then return jsonb_build_object('found', false, 'ref', v_ref); end if;
  if v_mid is not null and v_pay is null then select payment_reference into v_pay from memberships where id = v_mid; end if;
  if v_mid is not null then select * into m from memberships where id = v_mid; end if;
  if v_pay is not null and x.reference is distinct from v_pay then select * into x from payments where reference = v_pay; end if;
  return jsonb_build_object('found', true, 'kind', v_kind, 'ref', v_ref,
    'user', (select jsonb_build_object('id', u.id, 'username', u.username, 'full_name', u.full_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
        'wallet_kobo', _balance(u.id, 'WALLET'), 'earnings_kobo', _balance(u.id, 'EARNINGS'), 'pending_kobo', _balance(u.id, 'PENDING'))
      from profiles u where u.id = v_uid),
    'order', case when v_mid is not null then _order_obj(v_mid) || jsonb_build_object('contact', m.contact, 'refund_kobo', m.refund_kobo, 'fee_kobo', m.fee_kobo,
        'listing_id', m.listing_id, 'created_at', m.created_at) end,
    'payment', case when v_pay is not null then (select to_jsonb(p) from payments p where p.reference = v_pay) end,
    'withdrawal', case when v_wid is not null then (select to_jsonb(q) - 'user_id' from withdrawals q where q.id = v_wid) end,
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'type', l.type, 'account', l.account_kind, 'amount_kobo', l.amount_kobo,
        'balance_after_kobo', l.balance_after_kobo, 'description', l.description, 'reference', l.reference, 'user', (select username from profiles where id = l.user_id),
        'created_at', l.created_at) order by l.id)
      from wallet_transactions l where l.reference = v_ref or (v_mid is not null and l.membership_id = v_mid)
        or (v_pay is not null and l.payment_reference = v_pay) or (v_wid is not null and l.withdrawal_id = v_wid)), '[]'::jsonb),
    'disputes', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'status', d.status, 'reason', d.reason, 'raised_by_role', d.raised_by_role,
        'resolution', d.resolution, 'created_at', d.created_at) order by d.created_at) from disputes d where v_mid is not null and d.membership_id = v_mid), '[]'::jsonb),
    'chat_messages', case when v_mid is not null then (select count(*) from order_messages where membership_id = v_mid and sender_role <> 'SYSTEM') end,
    'receipt', case when v_mid is not null then _receipt(m.txn_ref, null) when v_wid is not null then _receipt(w.ledger_reference, null) end,
    'audit', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'admin', (select username from profiles where id = a.admin_id), 'action', a.action,
        'entity', a.entity, 'note', a.note, 'created_at', a.created_at) order by a.id)
      from admin_audit_logs a where a.entity_id = any (array_remove(array[v_ref, v_mid::text, v_pay, v_wid::text, v_did::text], null))), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 6. Payment & Order Approval Desk
-- ---------------------------------------------------------------------
create or replace function public.admin_approval_desk() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return jsonb_build_object(
    'totals', jsonb_build_object(
      'pending_payments', (select count(*) from payments where status = 'PENDING'),
      'pending_payments_kobo', coalesce((select sum(amount_kobo) from payments where status = 'PENDING'), 0),
      'pending_withdrawals', (select count(*) from withdrawals where status in ('PENDING','APPROVED')),
      'pending_withdrawals_kobo', coalesce((select sum(coalesce(payout_kobo, amount_kobo)) from withdrawals where status in ('PENDING','APPROVED')), 0),
      'attention_orders', (select count(*) from memberships where status = 'DISPUTED' or (status = 'ACTIVE' and access_status = 'WAITING' and created_at < now() - interval '24 hours')),
      'rejected', (select count(*) from payments where status in ('FAILED','ABANDONED') and created_at > now() - interval '7 days')
                + (select count(*) from withdrawals where status = 'REJECTED' and created_at > now() - interval '7 days')),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('reference', x.reference, 'user', u.username, 'purpose', x.purpose, 'amount_kobo', x.amount_kobo,
        'status', x.status, 'note', x.note, 'created_at', x.created_at) order by x.created_at desc)
      from (select * from payments where status = 'PENDING' order by created_at desc limit 100) x join profiles u on u.id = x.user_id), '[]'::jsonb),
    'withdrawals', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'user', u.username, 'amount_kobo', w.amount_kobo, 'fee_kobo', w.fee_kobo,
        'payout_kobo', coalesce(w.payout_kobo, w.amount_kobo), 'bank_name', w.bank_name, 'account_number', w.account_number, 'account_name', w.account_name,
        'reference', w.ledger_reference, 'status', w.status, 'created_at', w.created_at) order by w.created_at)
      from withdrawals w join profiles u on u.id = w.user_id where w.status in ('PENDING','APPROVED')), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(_order_obj(m.id) || jsonb_build_object('why', case when m.status = 'DISPUTED' then 'Open report' else 'Access not sent for over 24 hours' end)
        order by m.created_at desc)
      from (select * from memberships where status = 'DISPUTED' or (status = 'ACTIVE' and access_status = 'WAITING' and created_at < now() - interval '24 hours')
            order by created_at desc limit 100) m), '[]'::jsonb),
    'rejected', coalesce((select jsonb_agg(r order by (r ->> 'at') desc) from (
        select jsonb_build_object('kind', 'PAYMENT', 'ref', x.reference, 'user', u.username, 'amount_kobo', x.amount_kobo, 'status', x.status, 'note', x.note, 'at', x.created_at) r
          from payments x join profiles u on u.id = x.user_id where x.status in ('FAILED','ABANDONED') and x.created_at > now() - interval '7 days'
        union all
        select jsonb_build_object('kind', 'WITHDRAWAL', 'ref', w.ledger_reference, 'user', u.username, 'amount_kobo', w.amount_kobo, 'status', w.status, 'note', w.admin_note, 'at', w.created_at)
          from withdrawals w join profiles u on u.id = w.user_id where w.status = 'REJECTED' and w.created_at > now() - interval '7 days'
        limit 100) z), '[]'::jsonb),
    'by_user', coalesce((select jsonb_agg(jsonb_build_object('user', a.username, 'user_id', a.id, 'payments', a.p, 'withdrawals', a.w, 'amount_kobo', a.amt) order by a.amt desc)
      from (select u.id, u.username,
              (select count(*) from payments x where x.user_id = u.id and x.status = 'PENDING') p,
              (select count(*) from withdrawals w where w.user_id = u.id and w.status in ('PENDING','APPROVED')) w,
              coalesce((select sum(x.amount_kobo) from payments x where x.user_id = u.id and x.status = 'PENDING'), 0)
              + coalesce((select sum(w.amount_kobo) from withdrawals w where w.user_id = u.id and w.status in ('PENDING','APPROVED')), 0) amt
            from profiles u) a where a.p + a.w > 0), '[]'::jsonb));
end $$;

create or replace function public.admin_payment_reject(p_reference text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare x payments;
begin
  perform _need_admin();
  if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write the reason for rejecting.'; end if;
  select * into x from payments where reference = p_reference for update;
  if not found then raise exception 'Payment not found.'; end if;
  if x.status <> 'PENDING' then raise exception 'Only pending payments can be rejected. This one is %.', lower(x.status); end if;
  update payments set status = 'FAILED', note = 'Rejected by admin: ' || trim(p_note), verified_at = now() where reference = x.reference;
  perform _notify(x.user_id, 'PAYMENT_FAILED', 'Payment not completed', trim(p_note), x.reference);
  perform _audit('REJECT_PAYMENT', 'payment', x.reference, jsonb_build_object('status', x.status), jsonb_build_object('status', 'FAILED'), p_note);
end $$;

-- ---------------------------------------------------------------------
-- 7. Full user view + edit + delete
-- ---------------------------------------------------------------------
create or replace function public.admin_user_full(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u profiles;
begin
  perform _need_admin();
  select * into u from profiles where id = p_id;
  if not found then raise exception 'User not found.'; end if;
  return jsonb_build_object(
    'profile', jsonb_build_object('id', u.id, 'username', u.username, 'full_name', u.full_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
        'verified_host', u.verified_host, 'is_admin', exists (select 1 from admin_users where user_id = u.id), 'created_at', u.created_at,
        'referral_code', u.referral_code, 'referred_by', (select username from profiles where id = u.referred_by)),
    'balances', jsonb_build_object('wallet_kobo', _balance(u.id, 'WALLET'), 'earnings_kobo', _balance(u.id, 'EARNINGS'), 'pending_kobo', _balance(u.id, 'PENDING'),
        'available_kobo', _balance(u.id, 'WALLET') + _balance(u.id, 'EARNINGS')),
    'last_activity', greatest((select max(created_at) from wallet_transactions where user_id = u.id), (select max(created_at) from notifications where user_id = u.id),
        (select max(created_at) from order_messages where sender_id = u.id)),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'type', t.type, 'account', t.account_kind, 'amount_kobo', t.amount_kobo,
        'balance_after_kobo', t.balance_after_kobo, 'description', t.description, 'reference', t.reference, 'created_at', t.created_at) order by t.id desc)
      from (select * from wallet_transactions where user_id = p_id order by id desc limit 100) t), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('reference', x.reference, 'purpose', x.purpose, 'amount_kobo', x.amount_kobo, 'status', x.status,
        'created_at', x.created_at) order by x.created_at desc) from (select * from payments where user_id = p_id order by created_at desc limit 50) x), '[]'::jsonb),
    'withdrawals', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'reference', w.ledger_reference, 'amount_kobo', w.amount_kobo, 'fee_kobo', w.fee_kobo,
        'status', w.status, 'created_at', w.created_at) order by w.created_at desc) from withdrawals w where w.user_id = p_id), '[]'::jsonb),
    'listings', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'service', s.name, 'plan', p.name, 'status', l.status, 'proof_status', l.proof_status,
        'seats', l.seats_offered, 'occupied', _occupied(l.id)) order by l.created_at desc)
      from listings l join service_plans p on p.id = l.plan_id join services s on s.id = p.service_id where l.host_id = p_id), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(_order_obj(m.id) || jsonb_build_object('as', case when m.buyer_id = p_id then 'BUYER' else 'HOST' end) order by m.created_at desc)
      from (select * from memberships where buyer_id = p_id or host_id = p_id order by created_at desc limit 100) m), '[]'::jsonb),
    'disputes', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'status', d.status, 'reason', d.reason, 'raised_by_role', d.raised_by_role,
        'created_at', d.created_at) order by d.created_at desc) from disputes d where d.buyer_id = p_id or d.host_id = p_id), '[]'::jsonb),
    'referrals', jsonb_build_object('invited', (select count(*) from referrals where referrer_id = p_id),
        'earned_kobo', coalesce((select sum(reward_referrer_kobo) from referrals where referrer_id = p_id and status = 'REWARDED'), 0)),
    'audit', coalesce((select jsonb_agg(jsonb_build_object('action', a.action, 'note', a.note, 'admin', (select username from profiles where id = a.admin_id),
        'created_at', a.created_at) order by a.id desc) from (select * from admin_audit_logs where entity_id = p_id::text order by id desc limit 30) a), '[]'::jsonb));
end $$;

create or replace function public.admin_edit_user(p_id uuid, p_full_name text, p_phone text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare old profiles;
begin
  perform _need_admin();
  select * into old from profiles where id = p_id for update;
  if not found then raise exception 'User not found.'; end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then raise exception 'Enter the full name.'; end if;
  update profiles set full_name = left(trim(p_full_name), 80), phone = left(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), 20) where id = p_id;
  perform _audit('EDIT_USER', 'profile', p_id::text, jsonb_build_object('full_name', old.full_name, 'phone', old.phone),
    jsonb_build_object('full_name', trim(p_full_name), 'phone', p_phone), p_note);
end $$;

-- Delete only accounts with no history (the ledger must stay complete). Everyone else: suspend.
create or replace function public.admin_delete_user(p_id uuid, p_confirm text) returns void
language plpgsql security definer set search_path = public as $$
declare u profiles;
begin
  perform _need_admin();
  select * into u from profiles where id = p_id;
  if not found then raise exception 'User not found.'; end if;
  if p_id = auth.uid() then raise exception 'You cannot delete your own account.'; end if;
  if exists (select 1 from admin_users where user_id = p_id) then raise exception 'Remove admin access first.'; end if;
  if coalesce(p_confirm, '') <> u.username then raise exception 'Type the username (%) to confirm.', u.username; end if;
  if exists (select 1 from wallet_transactions where user_id = p_id) or exists (select 1 from payments where user_id = p_id)
     or exists (select 1 from memberships where buyer_id = p_id or host_id = p_id) or exists (select 1 from listings where host_id = p_id)
     or exists (select 1 from withdrawals where user_id = p_id) or exists (select 1 from referrals where referrer_id = p_id or referred_id = p_id) then
    raise exception 'This user has money or order history that must be kept. Suspend the account instead.';
  end if;
  perform _audit('DELETE_USER', 'profile', p_id::text, jsonb_build_object('username', u.username, 'email', u.email), null, 'No history');
  delete from wallet_accounts where owner_id = p_id;
  delete from auth.users where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 8. Expiry reminders: buyer AND host, once each
-- ---------------------------------------------------------------------
create or replace function public.send_expiry_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_days int;
begin
  select reminder_days into v_days from platform_settings where id = 1;
  for r in select m.id, m.buyer_id, m.host_id, m.ends_at, m.reminder_sent, m.host_reminder_sent, s.name, b.username buyer
           from memberships m join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id join profiles b on b.id = m.buyer_id
           where m.status = 'ACTIVE' and not m.renewed and (not m.reminder_sent or not m.host_reminder_sent)
             and m.ends_at > now() and m.ends_at <= now() + make_interval(days => v_days)
           for update of m skip locked
  loop
    if not r.reminder_sent then
      perform _notify(r.buyer_id, 'EXPIRING', 'Your ' || r.name || ' seat ends soon',
        'It ends on ' || to_char(r.ends_at, 'DD Mon YYYY') || '. Renew from My Subs to keep your access.', r.id::text);
      update memberships set reminder_sent = true where id = r.id;
      n := n + 1;
    end if;
    if not r.host_reminder_sent then
      perform _notify(r.host_id, 'EXPIRING_HOST', '@' || r.buyer || '''s ' || r.name || ' seat ends soon',
        'It ends on ' || to_char(r.ends_at, 'DD Mon YYYY') || '. If they renew, you get paid again; if not, the seat opens up.', r.id::text);
      update memberships set host_reminder_sent = true where id = r.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 9. Public catalog (adds fees, escrow, WhatsApp link) + admin sidebar badges
-- ---------------------------------------------------------------------
create or replace function public.public_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'settings', (select jsonb_build_object('site_name', site_name, 'hero_title', hero_title, 'hero_text', hero_text, 'notice', notice,
                   'support_whatsapp', support_whatsapp, 'support_whatsapp_link', support_whatsapp_link, 'support_email', support_email,
                   'categories', to_jsonb(categories), 'min_withdrawal_kobo', min_withdrawal_kobo, 'min_topup_kobo', min_topup_kobo,
                   'max_topup_kobo', max_topup_kobo, 'renewal_window_days', renewal_window_days,
                   'buyer_fee_kobo', buyer_fee_kobo(), 'withdrawal_fee_kobo', withdrawal_fee_kobo(), 'escrow_days', escrow_days(),
                   'agreement_text', _agreement_text()) from platform_settings where id = 1),
    'fee_bps', platform_fee_bps(),
    'promos', public_promos(),
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

create or replace function public.admin_memberships(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'service', s.name, 'plan', p.name, 'buyer', b.username, 'host', h.username,
      'amount_kobo', m.amount_kobo, 'fee_kobo', m.fee_kobo, 'host_kobo', m.host_kobo, 'refund_kobo', m.refund_kobo, 'contact', m.contact,
      'starts_at', m.starts_at, 'ends_at', m.ends_at, 'status', m.status, 'escrow', m.escrow, 'access_status', m.access_status,
      'txn_ref', m.txn_ref, 'buyer_fee_kobo', m.buyer_fee_kobo, 'release_at', m.release_at, 'completed_at', m.completed_at)
      order by m.created_at desc)
    from (select * from memberships where p_status is null or p_status = '' or status = p_status order by created_at desc limit 300) m
    join service_plans p on p.id = m.plan_id join services s on s.id = p.service_id
    join profiles b on b.id = m.buyer_id join profiles h on h.id = m.host_id), '[]'::jsonb);
end $$;

create or replace function public.admin_disputes(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'membership_id', d.membership_id, 'listing_id', d.listing_id,
      'service', s.name, 'plan', p.name, 'buyer', b.username, 'buyer_email', b.email, 'host', h.username, 'host_email', h.email,
      'host_id', d.host_id, 'contact', m.contact, 'amount_kobo', m.amount_kobo, 'escrow', m.escrow, 'reason', d.reason, 'details', d.details,
      'host_response', d.host_response, 'status', d.status, 'resolution', d.resolution, 'refund_kobo', d.refund_kobo,
      'admin_note', d.admin_note, 'created_at', d.created_at, 'resolved_at', d.resolved_at,
      'raised_by_role', d.raised_by_role, 'txn_ref', m.txn_ref)
      order by (d.status in ('OPEN','IN_REVIEW')) desc, d.created_at desc)
    from disputes d join memberships m on m.id = d.membership_id join service_plans p on p.id = m.plan_id
    join services s on s.id = p.service_id join profiles b on b.id = d.buyer_id join profiles h on h.id = d.host_id
    where p_status is null or p_status = '' or d.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.my_notifications() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'type', type, 'title', title, 'body', body, 'ref', ref, 'read', read_at is not null,
           'created_at', created_at) order by created_at desc)
         from (select * from notifications where user_id = me.id order by created_at desc limit 60) n), '[]'::jsonb);
end $$;

create or replace function public.admin_badges() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return jsonb_build_object(
    'proofs', (select count(*) from host_proofs where status = 'PENDING'),
    'listings', (select count(*) from listings where status = 'PENDING_REVIEW'),
    'withdrawals', (select count(*) from withdrawals where status in ('PENDING','APPROVED')),
    'disputes', (select count(*) from disputes where status in ('OPEN','IN_REVIEW')),
    'support', (select count(*) from support_tickets where status = 'OPEN'),
    'requests', (select count(*) from subscription_requests where status in ('PENDING','IN_PROGRESS')),
    'desk', (select count(*) from payments where status = 'PENDING') + (select count(*) from withdrawals where status in ('PENDING','APPROVED'))
          + (select count(*) from memberships where status = 'DISPUTED'));
end $$;

-- ---------------------------------------------------------------------
-- 10. PERMISSIONS (same rule as 006: lock everything, open only the public API)
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.is_admin(), public.public_catalog(), public.public_promos(), public.explore_listings(),
  public.listing_detail(uuid), public.release_due_escrow() to anon, authenticated;
do $$ declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' and p.proname !~ '^_'
             and p.proname not in ('payment_create','payment_complete','payment_fail','send_expiry_reminders','email_claim','email_mark','email_check_token',
                                   'handle_new_user','handle_user_email','platform_fee_bps','buyer_fee_kobo','withdrawal_fee_kobo','escrow_days',
                                   'is_admin','public_catalog','public_promos','explore_listings','listing_detail','release_due_escrow')
  loop execute format('grant execute on function %s to authenticated', r.sig); end loop;
end $$;
grant execute on function public.payment_create(uuid, text, text, bigint, uuid, text), public.payment_complete(text, bigint, text, text, text),
  public.payment_fail(text, text, text) to service_role;
grant execute on function public.send_expiry_reminders(), public.release_due_escrow(), public.email_claim(int), public.email_mark(bigint, boolean, text),
  public.email_check_token(text) to service_role;
