-- 019 Security hardening (2026-10-26)
-- 1. The apps only talk to the database through checked functions (rpc). Direct table
--    reads are not used anywhere, so they are switched off. This also hides internal
--    columns such as admin_notify_email and plan host_instructions/notes from the public.
-- 2. New tables/functions made later are locked by default (no automatic public access).
-- 3. Admin withdrawals show a warning when it is the first payout to a bank account.
-- 4. Anonymous search logging gets a global cap so it cannot be flooded.

revoke select on all tables in schema public from anon, authenticated;

alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
-- Postgres itself lets everyone run new functions; that rule lives outside the schema, so remove it there too.
alter default privileges for role postgres revoke execute on functions from public;

create or replace function public.admin_withdrawals(p_status text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _need_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'user', p.username, 'full_name', p.full_name,
      'amount_kobo', w.amount_kobo, 'fee_kobo', w.fee_kobo, 'payout_kobo', coalesce(w.payout_kobo, w.amount_kobo),
      'reference', w.ledger_reference, 'bank_name', w.bank_name, 'account_number', w.account_number,
      'account_name', w.account_name, 'status', w.status, 'admin_note', w.admin_note,
      'created_at', w.created_at, 'paid_at', w.paid_at,
      'new_bank', not exists (select 1 from withdrawals o where o.user_id = w.user_id and o.id <> w.id
                                and o.status = 'PAID' and o.account_number = w.account_number))
    order by (w.status in ('PENDING','APPROVED')) desc, w.created_at desc)
    from withdrawals w join profiles p on p.id = w.user_id
    where p_status is null or p_status = '' or w.status = p_status), '[]'::jsonb);
end $$;

create or replace function public.log_search(p_term text, p_results integer default 0) returns void
language plpgsql security definer set search_path = public as $$
declare t text := lower(regexp_replace(trim(coalesce(p_term, '')), '\s+', ' ', 'g'));
begin
  if length(t) < 2 or length(t) > 60 then return; end if;
  if exists (select 1 from search_log where term = t and user_id is not distinct from auth.uid()
             and created_at > now() - interval '1 minute') then return; end if;
  if (select count(*) from search_log where user_id is not distinct from auth.uid()
      and created_at > now() - interval '1 minute') >= (case when auth.uid() is null then 120 else 30 end) then return;
  end if;
  insert into search_log (term, results, user_id) values (t, greatest(coalesce(p_results, 0), 0), auth.uid());
end $$;

revoke execute on function public.admin_withdrawals(text), public.log_search(text, integer) from public, anon, authenticated;
grant execute on function public.admin_withdrawals(text) to authenticated;
grant execute on function public.log_search(text, integer) to anon, authenticated;
