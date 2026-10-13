-- 009: tiered withdrawal fee (replaces the flat N200 for bigger withdrawals).
-- Amounts are in kobo. Each range includes its upper boundary; the next range starts one kobo above it.
--   up to N2,999.99        -> N200 flat
--   N3,000.00 - N50,000    -> 8%
--   N50,000.01 - N200,000  -> 9%
--   N200,000.01 - N300,000 -> 10%
--   above N300,000         -> 10.19%   (also used above N500,000, which the table did not cover)
-- Fee = amount x rate, rounded to the nearest kobo (half up). Stored on the withdrawal, so old withdrawals never change.
create or replace function public._withdrawal_fee_for(p_amount_kobo bigint) returns bigint
language sql immutable set search_path = public as $$
  select case
    when p_amount_kobo < 300000 then 20000::bigint
    else (p_amount_kobo * (case when p_amount_kobo <= 5000000  then 800
                                when p_amount_kobo <= 20000000 then 900
                                when p_amount_kobo <= 30000000 then 1000
                                else 1019 end) + 5000) / 10000
  end $$;
revoke execute on function public._withdrawal_fee_for(bigint) from public, anon, authenticated;

create or replace function public.request_withdrawal(p_amount_kobo bigint, p_bank text, p_account_number text, p_account_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_min bigint; v_fee bigint; v_ref text; v_id uuid; v_avail bigint;
begin
  me := _me();
  select min_withdrawal_kobo into v_min from platform_settings where id = 1;
  if p_amount_kobo is null or p_amount_kobo < v_min then raise exception 'The smallest withdrawal is %.', _naira(v_min); end if;
  v_fee := _withdrawal_fee_for(p_amount_kobo);
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
