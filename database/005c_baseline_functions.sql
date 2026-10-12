-- =====================================================================
--  SUBSPLIT · 005c_baseline_functions.sql (run after 005b, before 006)
--  Puts the original marketplace functions back to their tested bodies where
--  an earlier experiment had changed them. Safe to re-run.
-- =====================================================================
CREATE OR REPLACE FUNCTION public._fee(p_amount bigint)
 RETURNS bigint
 LANGUAGE sql
 IMMUTABLE
AS $function$ select round(p_amount::numeric * platform_fee_bps() / 10000)::bigint $function$
;
CREATE OR REPLACE FUNCTION public._naira(k bigint)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select '₦' || case when k % 100 = 0 then to_char(k / 100, 'FM999,999,999,990')
                     else to_char(k / 100.0, 'FM999,999,999,990.00') end;
$function$
;
CREATE OR REPLACE FUNCTION public._ref(p_prefix text)
 RETURNS text
 LANGUAGE sql
AS $function$ select p_prefix || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 14)) $function$
;
CREATE OR REPLACE FUNCTION public._refund(p_id uuid, p_amount bigint, p_why text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public._seat_price(p_normal bigint, p_seats integer, p_markup integer)
 RETURNS bigint
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select (round(p_normal::numeric * (100 + p_markup) / 100 / p_seats / 100) * 100)::bigint;
$function$
;
CREATE OR REPLACE FUNCTION public.admin_adjust_wallet(p_id uuid, p_kind text, p_amount_kobo bigint, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_dashboard()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_get_settings()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform _need_admin();
  return (select to_jsonb(s) - 'id' from platform_settings s where id = 1) || jsonb_build_object('fee_bps', platform_fee_bps());
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_ledger(p_type text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'user', coalesce(p.username, 'SplitSub'), 'account', t.account_kind, 'type', t.type,
      'amount_kobo', t.amount_kobo, 'balance_after_kobo', t.balance_after_kobo, 'description', t.description, 'reference', t.reference,
      'created_at', t.created_at) order by t.id desc)
    from (select * from wallet_transactions where p_type is null or p_type = '' or type = p_type order by id desc limit 300) t
    left join profiles p on p.id = t.user_id), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_payments(p_status text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('reference', x.reference, 'user', p.username, 'purpose', x.purpose, 'amount_kobo', x.amount_kobo,
      'paid_kobo', x.paid_kobo, 'status', x.status, 'channel', x.channel, 'note', x.note, 'created_at', x.created_at, 'verified_at', x.verified_at)
      order by x.created_at desc)
    from (select * from payments where p_status is null or p_status = '' or status = p_status order by created_at desc limit 300) x
    join profiles p on p.id = x.user_id), '[]'::jsonb);
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_user_detail(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_users(p_search text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.host_create_listing(p_plan uuid, p_markup_pct integer, p_seats integer, p_access text, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.listing_detail(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
CREATE OR REPLACE FUNCTION public.move_earnings(p_amount_kobo bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me profiles; v_ref text;
begin
  me := _me();
  if p_amount_kobo is null or p_amount_kobo <= 0 then raise exception 'Enter an amount.'; end if;
  v_ref := _ref('TRF');
  perform _post(me.id, 'EARNINGS', 'TRANSFER_OUT', -p_amount_kobo, 'Moved to wallet', v_ref);
  perform _post(me.id, 'WALLET', 'TRANSFER_IN', p_amount_kobo, 'From host earnings', v_ref);
end $function$
;
CREATE OR REPLACE FUNCTION public.platform_fee_bps()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$ select 1000 $function$
;
