-- Tests for migration 015: manual bank-transfer funding, admin alerts, partner inquiries.
\set ON_ERROR_STOP 0
\set A '00000000-0000-0000-0000-00000000000a'
\set B '00000000-0000-0000-0000-00000000000d'
\set E '00000000-0000-0000-0000-00000000000f'
reset role;
create schema if not exists t;
drop table if exists t.results; create table t.results (n serial, name text, ok boolean, detail text);
create table if not exists t.vars (k text primary key, v text);
grant usage on schema t to anon, authenticated, service_role;
grant all on t.results, t.vars to anon, authenticated, service_role;
grant usage on sequence t.results_n_seq to anon, authenticated, service_role;
create or replace function t.err(p_name text, p_sql text, p_like text default '%') returns void language plpgsql as $$
begin
  begin execute p_sql; insert into t.results (name, ok, detail) values (p_name, false, 'NO ERROR (should have been blocked)');
  exception when others then insert into t.results (name, ok, detail) values (p_name, sqlerrm ilike p_like, sqlstate || ': ' || sqlerrm); end;
end $$;
create or replace function t.ok(p_name text, p_cond boolean, p_detail text default '') returns void language sql as $$
  insert into t.results (name, ok, detail) values (p_name, coalesce(p_cond, false), p_detail) $$;
create or replace function t.v(k text) returns text language sql as $$ select v from t.vars where t.vars.k = $1 $$;
create or replace function t.setv(k text, v text) returns void language sql as $$
  insert into t.vars values ($1, $2) on conflict (k) do update set v = excluded.v $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
 (:'A', 'owner@subsplit.test', '{"full_name":"Owner Admin"}'), (:'B', 'buyer@subsplit.test', '{"full_name":"Bola Buyer"}'),
 (:'E', 'eve@subsplit.test', '{"full_name":"Eve Hacker"}') on conflict do nothing;
insert into public.admin_users (user_id) values (:'A') on conflict do nothing;

-- OFF by default
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Manual deposit refused while switched OFF', $$select manual_deposit_start(100000)$$, '%not available%');
select t.ok('Catalog flag is false', (public_catalog() -> 'settings' ->> 'manual_funding') = 'false');
reset role;

-- admin switches ON and edits account details
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Non-admin cannot save settings', $$select admin_save_settings('{"manual_funding_enabled":true}')$$, '%admin%');
set "request.jwt.claim.sub" = :'A';
select admin_save_settings('{"manual_funding_enabled":true,"manual_account_number":"1234 567 890","manual_bank_name":"Test Bank","manual_account_name":"Ada Test","admin_notify_email":"Alerts@Example.com"}');
select t.err('Bad alert email refused', $$select admin_save_settings('{"admin_notify_email":"nope"}')$$, '%valid email%');
select t.err('Bad account number refused', $$select admin_save_settings('{"manual_account_number":"12ab"}')$$, '%digits%');
reset role;
select t.ok('Settings stored', (select manual_funding_enabled and manual_account_number = '1234567890' and admin_notify_email = 'alerts@example.com' from platform_settings where id = 1));

-- user flow
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Amount below minimum refused', $$select manual_deposit_start(100)$$, '%between%');
select t.setv('md', (manual_deposit_start(500000) ->> 'id'));
select t.ok('Details come from settings', (select (my_manual_deposits() ->> 'account_number') = '1234567890'));
select t.err('Support before "sent" refused', format($$select manual_deposit_support(%L, 'Bola', %L)$$, t.v('md'), :'B' || '/x.png'), '%already pending%');
select manual_deposit_sent(t.v('md')::uuid);
reset role;
select t.ok('Admin got in-app alert', (select count(*) = 1 from notifications where user_id = :'A' and title like 'Bank transfer to check%'));
select t.ok('ONE alert email to support address, none to the admin user', (select count(*) = 1 from email_outbox where to_email = 'alerts@example.com' and to_user is null) and (select count(*) = 0 from email_outbox where to_user = :'A' and subject like 'Bank transfer%'));
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('4-minute rule enforced on server', format($$select manual_deposit_support(%L, 'Bola', %L)$$, t.v('md'), :'B' || '/x.png'), '%4 minutes%');
reset role;
update manual_deposits set sent_at = now() - interval '5 minutes' where id = t.v('md')::uuid;
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Receipt must be in own folder', format($$select manual_deposit_support(%L, 'Bola', %L)$$, t.v('md'), :'E' || '/x.png'), '%receipt%');
select t.err('Sender name required', format($$select manual_deposit_support(%L, '', %L)$$, t.v('md'), :'B' || '/x.png'), '%name%');
select manual_deposit_support(t.v('md')::uuid, 'Bola Buyer', :'B' || '/x.png', 'please check');
reset role;
select t.ok('Support alert created', (select count(*) = 1 from notifications where user_id = :'A' and title like 'Transfer not confirmed%'));

-- another user cannot touch it; non-admin cannot approve
set role authenticated; set "request.jwt.claim.sub" = :'E';
select t.err('Other user cannot mark sent', format($$select manual_deposit_sent(%L)$$, t.v('md')), '%not found%');
select t.err('Non-admin cannot approve', format($$select admin_manual_deposit_action(%L, 'APPROVE')$$, t.v('md')), '%admin%');
select t.err('Non-admin cannot list', $$select admin_manual_deposits('OPEN')$$, '%admin%');
reset role;

-- admin approves once only
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('Admin sees it open', jsonb_array_length(admin_manual_deposits('OPEN')) = 1);
select t.ok('Badge counts it', (admin_badges() ->> 'deposits')::int = 1);
select t.err('Reject needs a reason', format($$select admin_manual_deposit_action(%L, 'REJECT')$$, t.v('md')), '%reason%');
select admin_manual_deposit_action(t.v('md')::uuid, 'APPROVE', 450000, 'ok');
select t.err('Cannot approve twice', format($$select admin_manual_deposit_action(%L, 'APPROVE')$$, t.v('md')), '%already%');
reset role;
select t.ok('Wallet credited the approved amount exactly once', (select balance_kobo from wallet_accounts where owner_id = :'B' and kind = 'WALLET') = 450000);
select t.ok('Ledger has one TOP_UP of the approved amount', (select count(*) = 1 from wallet_transactions where type = 'TOP_UP' and amount_kobo = 450000));
select t.ok('User told', (select count(*) = 1 from notifications where user_id = :'B' and title = 'Payment successful'));

-- reject path
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.setv('md2', (manual_deposit_start(100000) ->> 'id'));
select manual_deposit_sent(t.v('md2')::uuid);
select manual_deposit_cancel(t.v('md2')::uuid) is not null as cancelled_after_sent_should_fail;
reset role;
select t.ok('Cannot cancel after sent', (select status = 'SENT' from manual_deposits where id = t.v('md2')::uuid));
set role authenticated; set "request.jwt.claim.sub" = :'A';
select admin_manual_deposit_action(t.v('md2')::uuid, 'REJECT', null, 'No money received');
reset role;
select t.ok('Rejected leaves wallet unchanged', (select balance_kobo from wallet_accounts where owner_id = :'B' and kind = 'WALLET') = 450000);

-- direct table access blocked
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.err('Direct table read blocked', $$select * from manual_deposits$$, '%permission%');
select t.err('Direct table write blocked', $$update manual_deposits set status = 'APPROVED'$$, '%permission%');
reset role;

-- inquiries
set role anon;
select t.err('Short message refused', $$select submit_partner_inquiry('INVEST', 'Ife', 'ife@x.com', 'hi')$$, '%short message%');
select t.ok('Anon can send a message', (submit_partner_inquiry('invest', 'Ife Investor', 'ife@x.com', 'I would like to talk about investing.') ->> 'id') is not null);
select t.err('Anon cannot read inquiries', $$select admin_inquiries('')$$, '%admin%');
reset role;
select t.ok('Inquiry alert + one email', (select count(*) = 1 from notifications where user_id = :'A' and title like 'New invest%') and (select count(*) = 1 from email_outbox where subject like 'New invest%' and to_email = 'alerts@example.com'));
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('Admin lists NEW inquiries + badge', jsonb_array_length(admin_inquiries('NEW')) = 1 and (admin_badges() ->> 'inquiries')::int = 1);
select admin_inquiry_update((admin_inquiries('NEW') -> 0 ->> 'id')::uuid, 'REPLIED', 'called');
select t.ok('Marked replied', jsonb_array_length(admin_inquiries('REPLIED')) = 1);
reset role;
-- empty alert address falls back to per-admin emails
update platform_settings set admin_notify_email = '' where id = 1;
set role anon; select submit_partner_inquiry('OTHER', 'Zed', 'zed@x.com', 'Hello there, just a question.'); reset role;
select t.ok('Fallback emails the admin user when address is empty', (select count(*) >= 1 from email_outbox where to_user = :'A' and subject like 'New other%'));

select case when ok then 'PASS ' else 'FAIL ' end || name || case when ok then '' else '  -> ' || coalesce(detail, '') end from t.results order by n;
