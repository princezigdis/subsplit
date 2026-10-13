-- 010: editable withdrawal fee list + admin account close/removal.
-- (No destructive SQL statements in this file on purpose: removal of the login is done by the
--  account-removal edge function through the Supabase auth API.)

-- ---------------------------------------------------------------------
-- 1. Withdrawal fee list lives in platform_settings and is editable by admins
--    Each row: upto_kobo (null on the last row = "and above"), plus either
--    flat_kobo (a fixed fee in kobo) or bps (percent x 100, e.g. 800 = 8%).
-- ---------------------------------------------------------------------
alter table public.platform_settings add column if not exists withdrawal_fee_tiers jsonb not null default
  '[{"upto_kobo":299999,"flat_kobo":20000},{"upto_kobo":5000000,"bps":800},{"upto_kobo":20000000,"bps":900},{"upto_kobo":30000000,"bps":1000},{"upto_kobo":null,"bps":1019}]'::jsonb;

create or replace function public._withdrawal_fee_for(p_amount_kobo bigint) returns bigint
language sql stable set search_path = public as $$
  select coalesce((
    select case when t ? 'flat_kobo' then (t ->> 'flat_kobo')::bigint
                else (p_amount_kobo * (t ->> 'bps')::bigint + 5000) / 10000 end
    from platform_settings s, jsonb_array_elements(s.withdrawal_fee_tiers) with ordinality as x(t, n)
    where s.id = 1 and ((t ->> 'upto_kobo') is null or p_amount_kobo <= (t ->> 'upto_kobo')::bigint)
    order by n limit 1), 20000::bigint) $$;
revoke execute on function public._withdrawal_fee_for(bigint) from public, anon, authenticated;

create or replace function public.admin_save_fee_tiers(p_tiers jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare t jsonb; i int := 0; n int; prev bigint := 0; up bigint; lowest bigint; fl bigint; bp bigint; v_min bigint; v_out jsonb := '[]'::jsonb; old jsonb;
begin
  perform _need_admin();
  if p_tiers is null or jsonb_typeof(p_tiers) <> 'array' then raise exception 'Send the fee list as a list of rows.'; end if;
  n := jsonb_array_length(p_tiers);
  if n < 1 or n > 12 then raise exception 'Use between 1 and 12 fee rows.'; end if;
  select min_withdrawal_kobo, withdrawal_fee_tiers into v_min, old from platform_settings where id = 1 for update;
  for t in select * from jsonb_array_elements(p_tiers) loop
    i := i + 1;
    if jsonb_typeof(t) <> 'object' then raise exception 'Row % is not valid.', i; end if;
    if (t ? 'flat_kobo') = (t ? 'bps') then raise exception 'Row %: choose a flat fee or a percent, not both.', i; end if;
    if i < n then
      if coalesce(jsonb_typeof(t -> 'upto_kobo'), 'null') <> 'number' then raise exception 'Row %: enter the highest amount for this row.', i; end if;
      if (t ->> 'upto_kobo')::numeric <> trunc((t ->> 'upto_kobo')::numeric) then raise exception 'Row %: amounts must be whole kobo.', i; end if;
      up := (t ->> 'upto_kobo')::bigint;
      if up <= prev then raise exception 'Row %: the amount must be higher than the row above it.', i; end if;
      if up > 100000000000 then raise exception 'Row %: that amount is too large.', i; end if;
    else
      if coalesce(jsonb_typeof(t -> 'upto_kobo'), 'null') <> 'null' then raise exception 'The last row must be "and above" (no upper amount).'; end if;
      up := null;
    end if;
    lowest := greatest(prev + 1, v_min);
    if t ? 'flat_kobo' then
      if jsonb_typeof(t -> 'flat_kobo') <> 'number' or (t ->> 'flat_kobo')::numeric <> trunc((t ->> 'flat_kobo')::numeric) then raise exception 'Row %: the flat fee must be a whole number of kobo.', i; end if;
      fl := (t ->> 'flat_kobo')::bigint;
      if fl < 0 then raise exception 'Row %: the fee cannot be negative.', i; end if;
      if fl >= lowest then raise exception 'Row %: a flat fee of % is not lower than the smallest withdrawal in that row (%).', i, _naira(fl), _naira(lowest); end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('upto_kobo', up, 'flat_kobo', fl));
    else
      if jsonb_typeof(t -> 'bps') <> 'number' or (t ->> 'bps')::numeric <> trunc((t ->> 'bps')::numeric) then raise exception 'Row %: the percent can have at most 2 decimals.', i; end if;
      bp := (t ->> 'bps')::bigint;
      if bp < 0 or bp > 5000 then raise exception 'Row %: the percent must be between 0 and 50.', i; end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('upto_kobo', up, 'bps', bp));
    end if;
    prev := coalesce(up, prev);
  end loop;
  update platform_settings set withdrawal_fee_tiers = v_out, updated_at = now() where id = 1;
  perform _audit('UPDATE_WITHDRAWAL_FEES', 'platform_settings', '1', jsonb_build_object('tiers', old), jsonb_build_object('tiers', v_out), '');
  return v_out;
end $$;
revoke execute on function public.admin_save_fee_tiers(jsonb) from public, anon;
grant execute on function public.admin_save_fee_tiers(jsonb) to authenticated;

-- the customer app reads the list from the public catalog
create or replace function public.public_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'settings', (select jsonb_build_object('site_name', site_name, 'hero_title', hero_title, 'hero_text', hero_text, 'notice', notice,
                   'support_whatsapp', support_whatsapp, 'support_whatsapp_link', support_whatsapp_link, 'support_email', support_email,
                   'categories', to_jsonb(categories), 'min_withdrawal_kobo', min_withdrawal_kobo, 'min_topup_kobo', min_topup_kobo,
                   'max_topup_kobo', max_topup_kobo, 'renewal_window_days', renewal_window_days,
                   'buyer_fee_kobo', buyer_fee_kobo(), 'withdrawal_fee_kobo', withdrawal_fee_kobo(), 'withdrawal_fee_tiers', withdrawal_fee_tiers, 'escrow_days', escrow_days(),
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

-- ---------------------------------------------------------------------
-- 2. Admin: close / remove any account
--    * history-free accounts are removed completely (by the edge function)
--    * accounts with money or order history keep their records (the ledger must stay
--      complete) but their personal details are erased and the login is blocked
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists closed_at timestamptz;

create or replace function public.admin_close_account_plan(p_id uuid, p_confirm text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u profiles; w bigint; e bigint; pe bigint; v_msgs text := ''; v_hist boolean;
begin
  perform _need_admin();
  select * into u from profiles where id = p_id;
  if not found then raise exception 'User not found.'; end if;
  if p_id = auth.uid() then raise exception 'You cannot remove your own account.'; end if;
  if exists (select 1 from admin_users where user_id = p_id) then raise exception 'This person is an admin. Remove their admin access first (untick Admin, Save), then remove the account.'; end if;
  if coalesce(p_confirm, '') <> u.username then raise exception 'Type the username (%) to confirm.', u.username; end if;
  w := _balance(p_id, 'WALLET'); e := _balance(p_id, 'EARNINGS'); pe := _balance(p_id, 'PENDING');
  if w <> 0 or e <> 0 or pe <> 0 then
    v_msgs := v_msgs || format('Balance must be ₦0 first (wallet %s, earnings %s, held in escrow %s): let them withdraw, refund them, or use Adjust balance. ', _naira(w), _naira(e), _naira(pe));
  end if;
  if exists (select 1 from withdrawals where user_id = p_id and status in ('PENDING', 'APPROVED')) then
    v_msgs := v_msgs || 'A withdrawal is still waiting: pay or reject it first. ';
  end if;
  if exists (select 1 from memberships where (buyer_id = p_id or host_id = p_id) and status in ('ACTIVE', 'DISPUTED')) then
    v_msgs := v_msgs || 'They still have active orders: finish or refund them first. ';
  end if;
  if exists (select 1 from disputes where (buyer_id = p_id or host_id = p_id) and status in ('OPEN', 'IN_REVIEW')) then
    v_msgs := v_msgs || 'They have an open report: resolve it first. ';
  end if;
  if v_msgs <> '' then raise exception '%', trim(v_msgs); end if;
  v_hist := exists (select 1 from wallet_transactions where user_id = p_id) or exists (select 1 from payments where user_id = p_id)
         or exists (select 1 from memberships where buyer_id = p_id or host_id = p_id) or exists (select 1 from listings where host_id = p_id)
         or exists (select 1 from withdrawals where user_id = p_id) or exists (select 1 from referrals where referrer_id = p_id or referred_id = p_id)
         or exists (select 1 from disputes where buyer_id = p_id or host_id = p_id);
  return jsonb_build_object('mode', case when v_hist then 'CLOSE' else 'REMOVE' end, 'username', u.username);
end $$;
revoke execute on function public.admin_close_account_plan(uuid, text) from public, anon;
grant execute on function public.admin_close_account_plan(uuid, text) to authenticated;

create or replace function public.admin_close_account_log(p_id uuid, p_mode text, p_username text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  perform _audit('CLOSE_ACCOUNT', 'profile', p_id::text, jsonb_build_object('username', left(coalesce(p_username, ''), 60)),
                 jsonb_build_object('mode', case when p_mode = 'REMOVE' then 'REMOVED' else 'CLOSED' end), coalesce(p_note, ''));
end $$;
revoke execute on function public.admin_close_account_log(uuid, text, text, text) from public, anon;
grant execute on function public.admin_close_account_log(uuid, text, text, text) to authenticated;

create or replace function public.account_anonymize(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update profiles set full_name = 'Removed user', username = 'removed-' || substr(replace(p_id::text, '-', ''), 1, 10), phone = '', email = '',
         status = 'SUSPENDED', verified_host = false, referral_code = null, closed_at = now() where id = p_id;
  update memberships set contact = '' where buyer_id = p_id;
  update listings set status = 'EXPIRED' where host_id = p_id and status in ('DRAFT', 'PENDING_REVIEW', 'APPROVED', 'LIVE', 'PAUSED');
  update email_outbox set attempts = 99, last_error = 'account closed' where to_user = p_id and sent_at is null;
end $$;
revoke execute on function public.account_anonymize(uuid) from public, anon, authenticated;
grant execute on function public.account_anonymize(uuid) to service_role;
