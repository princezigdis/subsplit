-- 015: Flutterwave wording, manual bank-transfer funding, admin alert email, collaboration inquiries.
-- (No destructive statements on purpose.)

-- ---------------------------------------------------------------------
-- 1. Settings: manual funding + admin alert email (all editable in Admin)
-- ---------------------------------------------------------------------
alter table public.platform_settings add column if not exists manual_funding_enabled boolean not null default false;
alter table public.platform_settings add column if not exists manual_bank_name text not null default 'Smart Cash PSB';
alter table public.platform_settings add column if not exists manual_account_number text not null default '7085002123';
alter table public.platform_settings add column if not exists manual_account_name text not null default 'Owolola Adedipupo Timileyin';
alter table public.platform_settings add column if not exists admin_notify_email text not null default 'support@splitsub.app';

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

create or replace function public.public_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'settings', (select jsonb_build_object('site_name', site_name, 'hero_title', hero_title, 'hero_text', hero_text, 'notice', notice,
                   'support_whatsapp', support_whatsapp, 'support_whatsapp_link', support_whatsapp_link, 'support_email', support_email,
                   'categories', to_jsonb(categories), 'min_withdrawal_kobo', min_withdrawal_kobo, 'min_topup_kobo', min_topup_kobo,
                   'max_topup_kobo', max_topup_kobo, 'renewal_window_days', renewal_window_days,
                   'buyer_fee_kobo', buyer_fee_kobo(), 'withdrawal_fee_kobo', withdrawal_fee_kobo(), 'withdrawal_fee_tiers', withdrawal_fee_tiers, 'escrow_days', escrow_days(),
                   'agreement_text', _agreement_text(),
                   'maintenance', case when maintenance_mode then maintenance_message end,
                   'manual_funding', manual_funding_enabled) from platform_settings where id = 1),
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

-- ---------------------------------------------------------------------
-- 2. Admin alerts: one email to the editable alert address; instant send
-- ---------------------------------------------------------------------
create or replace function public._kick_emails() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://merpfrmpxsvtxbkazgdy.supabase.co/functions/v1/send-emails',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-token', (select value from public.internal_secrets where name = 'email_cron')),
    body := '{}'::jsonb);
exception when others then
  null;  -- never block a payment step because an email could not be triggered
end $$;
revoke execute on function public._kick_emails() from public, anon, authenticated;

create or replace function public._notify_admins(p_type text, p_title text, p_body text default ''::text, p_ref text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r record; v_to text;
begin
  select nullif(trim(admin_notify_email), '') into v_to from platform_settings where id = 1;
  for r in select a.user_id from admin_users a join profiles p on p.id = a.user_id where p.status = 'ACTIVE' loop
    if v_to is null then
      perform _notify(r.user_id, p_type, p_title, p_body, p_ref);
    else
      insert into notifications (user_id, type, title, body, ref) values (r.user_id, p_type, p_title, coalesce(p_body, ''), p_ref);
    end if;
  end loop;
  if v_to is not null then
    insert into email_outbox (to_user, to_email, type, subject, body) values (null, v_to, 'ADMIN_ALERT', left(p_title, 200), coalesce(p_body, ''));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Payment wording: provider-neutral (card / bank transfer via Flutterwave)
-- ---------------------------------------------------------------------
create or replace function public.payment_complete(p_reference text, p_paid_kobo bigint, p_currency text, p_provider_id text, p_channel text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare x payments; v_ref text; v_joined boolean := false; v_mid uuid; v_msg text := '';
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

-- ---------------------------------------------------------------------
-- 4. Manual bank-transfer deposits
-- ---------------------------------------------------------------------
create table if not exists public.manual_deposits (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount_kobo bigint not null check (amount_kobo > 0),
  status text not null default 'PENDING' check (status in ('PENDING','SENT','APPROVED','REJECTED','CANCELLED')),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  support_at timestamptz,
  sender_name text not null default '',
  receipt_path text,
  user_note text not null default '',
  credited_kobo bigint,
  admin_note text not null default '',
  decided_at timestamptz,
  decided_by uuid references public.profiles(id) on delete set null
);
create index if not exists manual_deposits_status_idx on public.manual_deposits (status, created_at desc);
create index if not exists manual_deposits_user_idx on public.manual_deposits (user_id, created_at desc);
alter table public.manual_deposits enable row level security;
revoke all on public.manual_deposits from anon, authenticated;

-- private bucket for transfer receipts (same rules as host proofs)
insert into storage.buckets (id, name, public) values ('deposit-receipts', 'deposit-receipts', false)
on conflict (id) do update set public = false;
update storage.buckets set file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf'] where id = 'deposit-receipts';
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='deposit receipts: upload own folder') then
    create policy "deposit receipts: upload own folder" on storage.objects for insert to authenticated
      with check (bucket_id = 'deposit-receipts' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='deposit receipts: read own or admin') then
    create policy "deposit receipts: read own or admin" on storage.objects for select to authenticated
      using (bucket_id = 'deposit-receipts' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='deposit receipts: replace own') then
    create policy "deposit receipts: replace own" on storage.objects for update to authenticated
      using (bucket_id = 'deposit-receipts' and (storage.foldername(name))[1] = auth.uid()::text)
      with check (bucket_id = 'deposit-receipts' and (storage.foldername(name))[1] = auth.uid()::text);
  end if;
end $$;

create or replace function public.manual_deposit_start(p_amount_kobo bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; s platform_settings; v_id uuid; v_ref text; m text;
begin
  me := _me();
  m := maintenance_on();
  if m is not null then raise exception 'Payments are paused for maintenance. %', m; end if;
  select * into s from platform_settings where id = 1;
  if not s.manual_funding_enabled then raise exception 'Bank transfer funding is not available right now. Please pay online.'; end if;
  if p_amount_kobo is null or p_amount_kobo < s.min_topup_kobo or p_amount_kobo > s.max_topup_kobo then
    raise exception 'Enter an amount between % and %.', _naira(s.min_topup_kobo), _naira(s.max_topup_kobo);
  end if;
  if (select count(*) from manual_deposits where user_id = me.id and status in ('PENDING','SENT')) >= 3 then
    raise exception 'You already have bank transfers waiting. Finish or cancel one first.';
  end if;
  v_ref := _ref('MD');
  insert into manual_deposits (reference, user_id, amount_kobo) values (v_ref, me.id, p_amount_kobo) returning id into v_id;
  return jsonb_build_object('id', v_id, 'reference', v_ref, 'amount_kobo', p_amount_kobo, 'status', 'PENDING',
    'bank_name', s.manual_bank_name, 'account_number', s.manual_account_number, 'account_name', s.manual_account_name);
end $$;

create or replace function public.manual_deposit_sent(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; d manual_deposits;
begin
  me := _me();
  select * into d from manual_deposits where id = p_id and user_id = me.id for update;
  if not found then raise exception 'Transfer not found.'; end if;
  if d.status = 'SENT' then return jsonb_build_object('id', d.id, 'status', 'SENT', 'sent_at', d.sent_at); end if;
  if d.status <> 'PENDING' then raise exception 'This transfer is already %.', lower(d.status); end if;
  update manual_deposits set status = 'SENT', sent_at = now() where id = d.id returning * into d;
  perform _notify_admins('ADMIN_ALERT', 'Bank transfer to check: ' || _naira(d.amount_kobo),
    '@' || me.username || ' says they sent ' || _naira(d.amount_kobo) || ' (ref ' || d.reference || '). Check your bank app, then approve or reject it in Admin > Bank transfers.', d.id::text);
  perform _kick_emails();
  return jsonb_build_object('id', d.id, 'status', 'SENT', 'sent_at', d.sent_at);
end $$;

create or replace function public.manual_deposit_support(p_id uuid, p_sender_name text, p_receipt_path text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; d manual_deposits;
begin
  me := _me();
  select * into d from manual_deposits where id = p_id and user_id = me.id for update;
  if not found then raise exception 'Transfer not found.'; end if;
  if d.status <> 'SENT' then raise exception 'This transfer is already %.', lower(d.status); end if;
  if now() < d.sent_at + interval '4 minutes' then raise exception 'You can contact support 4 minutes after you tap "I have sent the money".'; end if;
  if d.support_at is not null and d.support_at > now() - interval '5 minutes' then raise exception 'Support was just notified. Please wait a few minutes.'; end if;
  if length(trim(coalesce(p_sender_name, ''))) < 2 then raise exception 'Enter the name on the account you sent the money from.'; end if;
  if p_receipt_path is null or left(p_receipt_path, 37) <> me.id::text || '/' or length(p_receipt_path) > 300 then raise exception 'Upload your receipt first.'; end if;
  update manual_deposits set support_at = now(), sender_name = left(trim(p_sender_name), 120), receipt_path = p_receipt_path,
    user_note = left(coalesce(p_note, ''), 500) where id = d.id returning * into d;
  perform _notify_admins('ADMIN_ALERT', 'Transfer not confirmed yet: ' || _naira(d.amount_kobo),
    '@' || me.username || ' sent ' || _naira(d.amount_kobo) || ' from "' || d.sender_name || '" (ref ' || d.reference || ') and uploaded a receipt. Open Admin > Bank transfers to check it.', d.id::text);
  perform _kick_emails();
  return jsonb_build_object('id', d.id, 'status', 'SENT', 'support_at', d.support_at);
end $$;

create or replace function public.manual_deposit_cancel(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles;
begin
  me := _me();
  update manual_deposits set status = 'CANCELLED', decided_at = now() where id = p_id and user_id = me.id and status = 'PENDING';
  if not found then raise exception 'This transfer can no longer be cancelled.'; end if;
  return jsonb_build_object('status', 'CANCELLED');
end $$;

create or replace function public.my_manual_deposits() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me profiles; s platform_settings;
begin
  me := _me();
  select * into s from platform_settings where id = 1;
  return jsonb_build_object('enabled', s.manual_funding_enabled,
    'bank_name', s.manual_bank_name, 'account_number', s.manual_account_number, 'account_name', s.manual_account_name,
    'now', now(),
    'items', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
        select id, reference, amount_kobo, status, created_at, sent_at, support_at, sender_name, credited_kobo, admin_note as note, decided_at
        from manual_deposits where user_id = me.id order by created_at desc limit 10) x), '[]'::jsonb));
end $$;

create or replace function public.admin_manual_deposits(p_status text default 'OPEN') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.sort_at desc) from (
    select d.id, d.reference, d.amount_kobo, d.status, d.created_at, d.sent_at, d.support_at, d.sender_name, d.receipt_path, d.user_note,
           d.credited_kobo, d.admin_note, d.decided_at, p.username, p.full_name, p.email, p.phone,
           coalesce(d.support_at, d.sent_at, d.created_at) as sort_at
    from manual_deposits d join profiles p on p.id = d.user_id
    where case coalesce(p_status, '') when 'OPEN' then d.status in ('PENDING','SENT') when '' then true else d.status = p_status end
    order by coalesce(d.support_at, d.sent_at, d.created_at) desc limit 200) x), '[]'::jsonb);
end $$;

create or replace function public.admin_manual_deposit_action(p_id uuid, p_action text, p_amount_kobo bigint default null, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare d manual_deposits; s platform_settings; v_amt bigint;
begin
  perform _need_admin();
  select * into d from manual_deposits where id = p_id for update;
  if not found then raise exception 'Transfer not found.'; end if;
  if d.status not in ('PENDING','SENT') then raise exception 'This transfer was already %.', lower(d.status); end if;
  if p_action = 'APPROVE' then
    select * into s from platform_settings where id = 1;
    v_amt := coalesce(p_amount_kobo, d.amount_kobo);
    if v_amt < s.min_topup_kobo or v_amt > s.max_topup_kobo then
      raise exception 'The amount must be between % and %.', _naira(s.min_topup_kobo), _naira(s.max_topup_kobo);
    end if;
    perform _post(d.user_id, 'WALLET', 'TOP_UP', v_amt, 'Added money · Bank transfer', d.reference);
    update manual_deposits set status = 'APPROVED', credited_kobo = v_amt, admin_note = left(coalesce(p_note, ''), 300), decided_at = now(), decided_by = auth.uid() where id = d.id;
    perform _notify(d.user_id, 'PAYMENT_SUCCESS', 'Payment successful', _naira(v_amt) || ' was added to your wallet.');
    perform _audit('APPROVE_BANK_TRANSFER', 'manual_deposit', d.id::text,
      jsonb_build_object('status', d.status, 'amount_kobo', d.amount_kobo), jsonb_build_object('status', 'APPROVED', 'credited_kobo', v_amt, 'reference', d.reference), p_note);
    return jsonb_build_object('status', 'APPROVED', 'credited_kobo', v_amt);
  elsif p_action = 'REJECT' then
    if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write the reason so the user understands.'; end if;
    update manual_deposits set status = 'REJECTED', admin_note = left(trim(p_note), 300), decided_at = now(), decided_by = auth.uid() where id = d.id;
    perform _notify(d.user_id, 'PAYMENT_FAILED', 'Bank transfer not confirmed',
      'We could not confirm your transfer of ' || _naira(d.amount_kobo) || '. Reason: ' || left(trim(p_note), 300) || ' If you did send it, message support.');
    perform _audit('REJECT_BANK_TRANSFER', 'manual_deposit', d.id::text,
      jsonb_build_object('status', d.status, 'amount_kobo', d.amount_kobo), jsonb_build_object('status', 'REJECTED', 'reference', d.reference), p_note);
    return jsonb_build_object('status', 'REJECTED');
  end if;
  raise exception 'Unknown action.';
end $$;

-- ---------------------------------------------------------------------
-- 5. Collaboration / investment messages
-- ---------------------------------------------------------------------
create table if not exists public.partner_inquiries (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('COLLABORATE','INVEST','OTHER')),
  user_id uuid references public.profiles(id) on delete set null,
  name text not null,
  contact text not null,
  message text not null,
  status text not null default 'NEW' check (status in ('NEW','READ','REPLIED','CLOSED')),
  admin_note text not null default '',
  created_at timestamptz not null default now(),
  handled_at timestamptz
);
create index if not exists partner_inquiries_status_idx on public.partner_inquiries (status, created_at desc);
alter table public.partner_inquiries enable row level security;
revoke all on public.partner_inquiries from anon, authenticated;

create or replace function public.submit_partner_inquiry(p_kind text, p_name text, p_contact text, p_message text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_kind text := upper(coalesce(p_kind, 'OTHER')); v_id uuid; v_name text := left(trim(coalesce(p_name, '')), 120);
        v_contact text := left(trim(coalesce(p_contact, '')), 160); v_msg text := left(trim(coalesce(p_message, '')), 2000);
begin
  if v_kind not in ('COLLABORATE','INVEST','OTHER') then v_kind := 'OTHER'; end if;
  if length(v_name) < 2 then raise exception 'Enter your name.'; end if;
  if length(v_contact) < 5 then raise exception 'Enter an email or phone number so we can reply.'; end if;
  if length(v_msg) < 10 then raise exception 'Write a short message (at least 10 characters).'; end if;
  if auth.uid() is not null and (select count(*) from partner_inquiries where user_id = auth.uid() and created_at > now() - interval '1 day') >= 5 then
    raise exception 'You have sent several messages today. We will reply soon.';
  end if;
  if (select count(*) from partner_inquiries where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many messages right now. Please try again later.';
  end if;
  insert into partner_inquiries (kind, user_id, name, contact, message) values (v_kind, auth.uid(), v_name, v_contact, v_msg) returning id into v_id;
  perform _notify_admins('ADMIN_ALERT', 'New ' || lower(v_kind) || ' message from ' || v_name, v_name || ' (' || v_contact || '): ' || left(v_msg, 400), v_id::text);
  perform _kick_emails();
  return jsonb_build_object('id', v_id);
end $$;
grant execute on function public.submit_partner_inquiry(text, text, text, text) to anon, authenticated;

create or replace function public.admin_inquiries(p_status text default '') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select i.id, i.kind, i.name, i.contact, i.message, i.status, i.admin_note, i.created_at, i.handled_at, p.username
    from partner_inquiries i left join profiles p on p.id = i.user_id
    where coalesce(p_status, '') = '' or i.status = p_status order by i.created_at desc limit 200) x), '[]'::jsonb);
end $$;

create or replace function public.admin_inquiry_update(p_id uuid, p_status text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  if p_status not in ('NEW','READ','REPLIED','CLOSED') then raise exception 'Unknown status.'; end if;
  update partner_inquiries set status = p_status, admin_note = left(coalesce(p_note, admin_note), 500),
    handled_at = case when p_status = 'NEW' then null else now() end where id = p_id;
  if not found then raise exception 'Message not found.'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. Badges
-- ---------------------------------------------------------------------
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
    'deposits', (select count(*) from manual_deposits where status = 'SENT'),
    'inquiries', (select count(*) from partner_inquiries where status = 'NEW'),
    'desk', (select count(*) from payments where status = 'PENDING') + (select count(*) from withdrawals where status in ('PENDING','APPROVED'))
          + (select count(*) from memberships where status = 'DISPUTED'));
end $$;

-- ---------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------
revoke execute on function public.manual_deposit_start(bigint), public.manual_deposit_sent(uuid), public.manual_deposit_support(uuid, text, text, text),
  public.manual_deposit_cancel(uuid), public.my_manual_deposits(), public.admin_manual_deposits(text),
  public.admin_manual_deposit_action(uuid, text, bigint, text), public.admin_inquiries(text), public.admin_inquiry_update(uuid, text, text)
  from public, anon;
grant execute on function public.manual_deposit_start(bigint), public.manual_deposit_sent(uuid), public.manual_deposit_support(uuid, text, text, text),
  public.manual_deposit_cancel(uuid), public.my_manual_deposits(), public.admin_manual_deposits(text),
  public.admin_manual_deposit_action(uuid, text, bigint, text), public.admin_inquiries(text), public.admin_inquiry_update(uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- 8. Receipts show the new payment partner
-- ---------------------------------------------------------------------
do $$ declare d text;
begin
  d := pg_get_functiondef('public._receipt(text,uuid)'::regprocedure);
  d := replace(d, '''Paystack''', '''Flutterwave''');
  execute d;
end $$;
