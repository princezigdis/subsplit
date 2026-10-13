-- 012: speed. _balance() is called for every money action and every admin user row; the old
-- "owner_id is not distinct from" form cannot use an index, so it scanned the whole wallet table each call.
-- Same answer, now index-friendly.
create or replace function public._balance(p_owner uuid, p_kind text) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(case when p_owner is null
    then (select balance_kobo from wallet_accounts where owner_id is null and kind = p_kind)
    else (select balance_kobo from wallet_accounts where owner_id = p_owner and kind = p_kind) end, 0);
$$;
