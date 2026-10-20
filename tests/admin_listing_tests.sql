-- Tests for migration 016: an admin adds a listing with proof and it goes live at once.
\set ON_ERROR_STOP 0
\set A '00000000-0000-0000-0000-00000000000a'
\set H '00000000-0000-0000-0000-00000000000b'
\set B '00000000-0000-0000-0000-00000000000d'
\set L1 '11111111-1111-4111-8111-111111111111'
\set L2 '22222222-2222-4222-8222-222222222222'
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
 (:'A', 'owner@subsplit.test', '{"full_name":"Owner Admin"}'), (:'H', 'host@subsplit.test', '{"full_name":"Hannah Host"}'),
 (:'B', 'buyer@subsplit.test', '{"full_name":"Bola Buyer"}') on conflict do nothing;
insert into public.admin_users (user_id) values (:'A') on conflict do nothing;
select t.setv('netflix', (select p.id::text from service_plans p join services s on s.id = p.service_id where s.name = 'Netflix'));
select t.setv('youtube', (select p.id::text from service_plans p join services s on s.id = p.service_id where s.name = 'YouTube Premium'));

-- ---------- only admins ----------
set role authenticated; set "request.jwt.claim.sub" = :'H';
insert into storage.objects (bucket_id, name) values ('host-proofs', :'H' || '/' || :'L1' || '/proof.png');
select t.err('A normal host cannot use the admin shortcut',
  format($$select admin_add_listing(%L, %L, 20, 2, 'Email: a@b.ng Pass: 123456', '', %L, '')$$, :'L1', t.v('netflix'), :'H' || '/' || :'L1' || '/proof.png'), '%admins only%');
reset role;
set role anon;
select t.err('A visitor cannot call it',
  format($$select admin_add_listing(%L, %L, 20, 2, 'x', '', 'x', '')$$, :'L1', t.v('netflix')), '%permission denied%');
reset role;
select t.ok('Nothing was created by those attempts', (select count(*) = 0 from listings));

-- ---------- the admin's input is still checked ----------
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('Proof is required',
  format($$select admin_add_listing(%L, %L, 20, 2, 'Email: a@b.ng Pass: 123456', '', '', '')$$, :'L1', t.v('netflix')), '%Upload proof%');
select t.err('Proof from another user''s folder is refused',
  format($$select admin_add_listing(%L, %L, 20, 2, 'Email: a@b.ng Pass: 123456', '', %L, '')$$, :'L1', t.v('netflix'), :'H' || '/' || :'L1' || '/proof.png'), '%does not belong%');
select t.err('Path tricks are refused',
  format($$select admin_add_listing(%L, %L, 20, 2, 'Email: a@b.ng Pass: 123456', '', %L, '')$$, :'L1', t.v('netflix'), :'A' || '/' || :'L1' || '/../x.png'), '%does not belong%');
select t.err('The proof file must really be uploaded',
  format($$select admin_add_listing(%L, %L, 20, 2, 'Email: a@b.ng Pass: 123456', '', %L, '')$$, :'L1', t.v('netflix'), :'A' || '/' || :'L1' || '/missing.png'), '%could not find%');
insert into storage.objects (bucket_id, name) values ('host-proofs', :'A' || '/' || :'L1' || '/proof.png');
select t.err('Markup above the plan maximum is refused',
  format($$select admin_add_listing(%L, %L, 31, 2, 'Email: a@b.ng Pass: 123456', '', %L, '')$$, :'L1', t.v('netflix'), :'A' || '/' || :'L1' || '/proof.png'), '%between%');
select t.err('Markup below the plan minimum is refused',
  format($$select admin_add_listing(%L, %L, 5, 2, 'Email: a@b.ng Pass: 123456', '', %L, '')$$, :'L1', t.v('netflix'), :'A' || '/' || :'L1' || '/proof.png'), '%between%');
select t.err('More seats than the plan allows is refused',
  format($$select admin_add_listing(%L, %L, 20, 9, 'Email: a@b.ng Pass: 123456', '', %L, '')$$, :'L1', t.v('netflix'), :'A' || '/' || :'L1' || '/proof.png'), '%seats%');
select t.err('Login plans need the login details',
  format($$select admin_add_listing(%L, %L, 20, 2, '', '', %L, '')$$, :'L1', t.v('netflix'), :'A' || '/' || :'L1' || '/proof.png'), '%login details%');
reset role;
select t.ok('Still nothing created after the refusals', (select count(*) = 0 from listings));

-- ---------- happy path ----------
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('Admin adds Netflix with proof: it is LIVE at once',
  (admin_add_listing(:'L1', t.v('netflix')::uuid, 20, 3, 'Email: fam@splitsub.ng  Password: S3cret!', 'One profile per member',
     :'A' || '/' || :'L1' || '/proof.png', 'Renews on the 5th') ->> 'status') = 'LIVE');
select t.err('The same listing cannot be added twice',
  format($$select admin_add_listing(%L, %L, 20, 3, 'Email: a@b.ng Pass: 123456', '', %L, '')$$, :'L1', t.v('netflix'), :'A' || '/' || :'L1' || '/proof.png'), '%already added%');
reset role;
select t.ok('Listing: LIVE, admin is the host, 3 seats, 20% markup',
  (select status = 'LIVE' and host_id = :'A' and seats_offered = 3 and markup_pct = 20 from listings where id = :'L1'));
select t.ok('Proof saved and marked approved by the admin',
  (select proof_status = 'APPROVED' and proof_path like :'A' || '/%' from listings where id = :'L1')
  and (select count(*) = 1 from host_proofs where listing_id = :'L1' and status = 'APPROVED' and reviewed_by = :'A'));
select t.ok('30-day escrow agreement recorded',
  (select agreement_accepted_at is not null and agreement_text like '%30-day escrow%' from listings where id = :'L1'));
select t.ok('Login details saved privately', (select details like '%S3cret%' from listing_access where listing_id = :'L1'));
select t.ok('Audit log written', (select count(*) = 1 from admin_audit_logs where action = 'ADMIN_ADD_LISTING' and entity_id = :'L1' and admin_id = :'A'));
select t.ok('No "listing to review" alert was raised', (select count(*) = 0 from notifications where title like 'New listing to review%'));

-- ---------- it works like any other listing ----------
set role anon;
select t.ok('Visitors see it on Explore', explore_listings()::text like '%' || :'L1' || '%');
select t.ok('Explore never shows the login details', explore_listings()::text not ilike '%s3cret%');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.ok('Seat price follows the platform rules (N8,500 +20% / 4 seats = N2,550)',
  (listing_detail(:'L1'::uuid) ->> 'seat_kobo')::bigint = 255000, listing_detail(:'L1'::uuid) ->> 'seat_kobo');
reset role;
set role service_role;
select payment_create(:'B', 'REF-B1', 'TOPUP', 1000000) is not null;
select payment_complete('REF-B1', 1000000, 'NGN', 'flw_1', 'card');
reset role;
set role authenticated; set "request.jwt.claim.sub" = :'B';
select t.ok('A buyer joins it with the wallet', join_with_wallet(:'L1'::uuid) ? 'membership_id');
select t.ok('The paying member sees the login details', (get_access(:'L1'::uuid) ->> 'details') ilike '%s3cret%');
reset role;
select t.ok('The seat money is held in escrow with the admin as host',
  (select count(*) = 1 from memberships where listing_id = :'L1' and host_id = :'A' and buyer_id = :'B'));
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('It shows in the admin''s own hosting list in the app', my_listings()::text like '%' || :'L1' || '%');
reset role;

-- ---------- switched-off plans and services ----------
update service_plans set active = false where id = t.v('youtube')::uuid;
set role authenticated; set "request.jwt.claim.sub" = :'A';
insert into storage.objects (bucket_id, name) values ('host-proofs', :'A' || '/' || :'L2' || '/p.png');
select t.err('A plan that is off is refused',
  format($$select admin_add_listing(%L, %L, 10, 5, '', '', %L, '')$$, :'L2', t.v('youtube'), :'A' || '/' || :'L2' || '/p.png'), '%switched on%');
reset role;
update service_plans set active = true where id = t.v('youtube')::uuid;
update services set active = false where id = (select service_id from service_plans where id = t.v('youtube')::uuid);
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.err('A service that is off is refused',
  format($$select admin_add_listing(%L, %L, 10, 5, '', '', %L, '')$$, :'L2', t.v('youtube'), :'A' || '/' || :'L2' || '/p.png'), '%switched off%');
reset role;
update services set active = true where id = (select service_id from service_plans where id = t.v('youtube')::uuid);
set role authenticated; set "request.jwt.claim.sub" = :'A';
select t.ok('Family plan: member instructions are optional, goes live',
  (admin_add_listing(:'L2', t.v('youtube')::uuid, 10, 5, '', '', :'A' || '/' || :'L2' || '/p.png', '') ->> 'status') = 'LIVE');
reset role;

-- ---------- normal hosts still go through review ----------
set role authenticated; set "request.jwt.claim.sub" = :'H';
select t.setv('hl', (host_create_listing(t.v('netflix')::uuid, 20, 2, 'Email: h@b.ng Pass: 123456', '') ->> 'listing_id'));
insert into storage.objects (bucket_id, name) values ('host-proofs', :'H' || '/' || t.v('hl') || '/proof.png');
select t.ok('A normal host listing still waits for admin review',
  (host_submit_listing(t.v('hl')::uuid, :'H' || '/' || t.v('hl') || '/proof.png', '', true) ->> 'status') = 'PENDING_REVIEW');
reset role;

select t.ok('Every wallet still matches its ledger',
  (select count(*) = 0 from wallet_accounts a left join (select account_id, sum(amount_kobo) s from wallet_transactions group by account_id) x on x.account_id = a.id
   where a.balance_kobo <> coalesce(x.s, 0)));
