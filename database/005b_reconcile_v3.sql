-- =====================================================================
--  SUBSPLIT · 005b_reconcile_v3.sql  (run BEFORE 006/007; safe to re-run)
--  The live project held an earlier, differently-shaped set of order/chat/
--  proof/promo objects (subsplit_v3_*). Nothing is deleted. This step:
--    1. copies every one of those tables into schema v3_backup
--    2. moves the v3 tables into schema v3_archive (out of the way)
--    3. switches off the v3 triggers and the v3 e-mail cron job
--    4. renames v3-only functions to _v3_* (006/007 lock them from the API)
--  Users, listings, memberships, payments, wallets and the ledger are kept.
-- =====================================================================
create schema if not exists v3_backup;
create schema if not exists v3_archive;
revoke all on schema v3_backup from public, anon, authenticated;
revoke all on schema v3_archive from public, anon, authenticated;

do $$ declare t text; begin
  foreach t in array array['host_proofs','order_chats','order_chat_reads','order_messages','email_outbox','promotions','referrals','promo_claims','subscription_requests','admin_credit_batches'] loop
    if to_regclass('public.'||t) is not null then
      if to_regclass('v3_backup.'||t) is null then
        execute format('create table v3_backup.%I as table public.%I', t, t);
      end if;
      if to_regclass('v3_archive.'||t) is null then
        execute format('alter table public.%I set schema v3_archive', t);
      end if;
    end if;
  end loop;
end $$;
do $$ declare c record; begin
  -- archived tables must never block deleting a user / listing / order
  for c in select conrelid::regclass::text t, conname from pg_constraint
           where contype = 'f' and connamespace = 'v3_archive'::regnamespace loop
    execute format('alter table %s drop constraint %I', c.t, c.conname);
  end loop;
end $$;

alter table public.memberships add column if not exists txn_ref text;
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='memberships' and column_name='order_no') then
    update public.memberships set txn_ref = order_no where txn_ref is null;
  end if;
end $$;

do $$ begin
  if to_regclass('public.services') is not null and exists (select 1 from pg_trigger where tgname='services_added_notify') then
    alter table public.services disable trigger services_added_notify; end if;
  if exists (select 1 from pg_trigger where tgname='wallet_tx_immutable') then
    alter table public.wallet_transactions disable trigger wallet_tx_immutable; end if;
  if exists (select 1 from pg_trigger where tgname='listings_live_guard') then
    alter table public.listings disable trigger listings_live_guard; end if;
end $$;

do $$ begin
  if to_namespace('cron') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'subsplit-send-emails';
  end if;
exception when others then null; end $$;

alter table public.listings drop constraint if exists listings_proof_status_check;
update public.listings set proof_status = 'NONE' where proof_status = 'NOT_REQUIRED';

-- v3-only functions: rename, never delete
do $$ declare r record; keep text[] := array[
    '_account(p_owner uuid, p_kind text)',
    '_agreement_text()',
    '_audit(p_action text, p_entity text, p_entity_id text, p_old jsonb, p_new jsonb, p_note text)',
    '_audit_system(p_action text, p_entity text, p_entity_id text, p_old jsonb, p_new jsonb, p_note text)',
    '_balance(p_owner uuid, p_kind text)',
    '_chat_json(p_membership uuid, p_me uuid)',
    '_chat_role(p_membership uuid, p_user uuid)',
    '_chat_system(p_membership uuid, p_body text)',
    '_credit_one(p_user uuid, p_amount bigint, p_reason text, p_ref text)',
    '_debit_available(p_user uuid, p_amount bigint, p_type text, p_desc text, p_ref text, p_withdrawal uuid)',
    '_dispute_closed_note()',
    '_fee(p_amount bigint)',
    '_join(p_user uuid, p_listing uuid, p_contact text, p_payment text)',
    '_join_check(p_user uuid, p_listing uuid, p_contact text)',
    '_ledger_immutable()',
    '_listing_live_guard()',
    '_listing_obj(p_id uuid)',
    '_me()',
    '_naira(k bigint)',
    '_need_admin()',
    '_notify(p_user uuid, p_type text, p_title text, p_body text, p_ref text)',
    '_notify_admins(p_type text, p_title text, p_body text, p_ref text)',
    '_occupied(p_listing uuid)',
    '_order_obj(p_id uuid)',
    '_order_status(m memberships)',
    '_post(p_owner uuid, p_kind text, p_type text, p_amount bigint, p_desc text, p_ref text, p_membership uuid, p_listing uuid, p_payment text, p_withdrawal uuid)',
    '_receipt(p_ref text, p_user uuid)',
    '_ref(p_prefix text)',
    '_referral_check(p_buyer uuid, p_membership uuid, p_amount bigint)',
    '_refund(p_id uuid, p_amount bigint, p_why text)',
    '_release(p_id uuid, p_why text)',
    '_seat_price(p_normal bigint, p_seats integer, p_markup integer)',
    '_service_added()',
    'admin_adjust_wallet(p_id uuid, p_kind text, p_amount_kobo bigint, p_note text)',
    'admin_approval_desk()',
    'admin_audit_logs()',
    'admin_badges()',
    'admin_broadcast(p_title text, p_body text, p_username text)',
    'admin_credit_all(p_amount_kobo bigint, p_reason text, p_confirm text)',
    'admin_credit_batch(p_users uuid[], p_amount_kobo bigint, p_reason text)',
    'admin_credit_user(p_user uuid, p_amount_kobo bigint, p_reason text)',
    'admin_dashboard()',
    'admin_delete_user(p_id uuid, p_confirm text)',
    'admin_dispute_action(p_id uuid, p_action text, p_amount_kobo bigint, p_note text)',
    'admin_disputes(p_status text)',
    'admin_edit_user(p_id uuid, p_full_name text, p_phone text, p_note text)',
    'admin_get_settings()',
    'admin_ledger(p_type text)',
    'admin_ledger_check()',
    'admin_listing_detail(p_id uuid)',
    'admin_listings(p_status text)',
    'admin_me()',
    'admin_memberships(p_status text)',
    'admin_order_chat(p_membership uuid)',
    'admin_order_chats(p_search text)',
    'admin_order_send(p_membership uuid, p_body text)',
    'admin_payment_reject(p_reference text, p_note text)',
    'admin_payments(p_status text)',
    'admin_promos()',
    'admin_proof_action(p_id uuid, p_action text, p_reason text)',
    'admin_proofs(p_status text)',
    'admin_receipt(p_ref text)',
    'admin_referrals()',
    'admin_refund(p_id uuid, p_amount_kobo bigint, p_note text)',
    'admin_release(p_id uuid, p_note text)',
    'admin_reply_ticket(p_id uuid, p_body text, p_close boolean)',
    'admin_request_action(p_id uuid, p_action text, p_note text)',
    'admin_requests(p_status text)',
    'admin_review_listing(p_id uuid, p_action text, p_note text)',
    'admin_save_plan(p jsonb)',
    'admin_save_promo(p jsonb)',
    'admin_save_service(p jsonb)',
    'admin_save_settings(p jsonb)',
    'admin_services()',
    'admin_tickets(p_status text)',
    'admin_txn_search(p_ref text)',
    'admin_update_user(p_id uuid, p_status text, p_verified boolean, p_is_admin boolean, p_note text)',
    'admin_user_detail(p_id uuid)',
    'admin_user_full(p_id uuid)',
    'admin_users(p_search text)',
    'admin_withdrawal_action(p_id uuid, p_action text, p_note text)',
    'admin_withdrawals(p_status text)',
    'armor(bytea)',
    'armor(bytea, text[], text[])',
    'buyer_fee_kobo()',
    'complete_order(p_membership uuid)',
    'create_ticket(p_subject text, p_body text)',
    'crypt(text, text)',
    'dearmor(text)',
    'decrypt(bytea, bytea, text)',
    'decrypt_iv(bytea, bytea, bytea, text)',
    'digest(bytea, text)',
    'digest(text, text)',
    'email_check_token(p_token text)',
    'email_claim(p_limit integer)',
    'email_mark(p_id bigint, p_ok boolean, p_err text)',
    'encrypt(bytea, bytea, text)',
    'encrypt_iv(bytea, bytea, bytea, text)',
    'escrow_days()',
    'explore_listings()',
    'gen_random_bytes(integer)',
    'gen_random_uuid()',
    'gen_salt(text)',
    'gen_salt(text, integer)',
    'get_access(p_listing uuid)',
    'handle_new_user()',
    'handle_user_email()',
    'hmac(bytea, bytea, text)',
    'hmac(text, text, text)',
    'host_create_listing(p_plan uuid, p_markup_pct integer, p_seats integer, p_access text, p_note text)',
    'host_mark_access_sent(p_membership uuid)',
    'host_respond_dispute(p_dispute uuid, p_text text)',
    'host_set_paused(p_listing uuid, p_paused boolean)',
    'host_submit_listing(p_listing uuid, p_proof_path text, p_proof_note text, p_agree boolean)',
    'host_update_listing(p_listing uuid, p_markup_pct integer, p_seats integer, p_access text, p_note text)',
    'is_admin()',
    'join_with_wallet(p_listing uuid, p_contact text)',
    'listing_detail(p_id uuid)',
    'mark_notifications_read()',
    'move_earnings(p_amount_kobo bigint)',
    'my_listings()',
    'my_notifications()',
    'my_orders()',
    'my_overview()',
    'my_receipt(p_ref text)',
    'my_referrals()',
    'my_requests()',
    'my_subscriptions()',
    'my_tickets()',
    'my_wallet()',
    'open_dispute(p_membership uuid, p_reason text, p_details text)',
    'order_chat(p_membership uuid)',
    'order_send(p_membership uuid, p_body text)',
    'payment_complete(p_reference text, p_paid_kobo bigint, p_currency text, p_provider_id text, p_channel text)',
    'payment_create(p_user uuid, p_reference text, p_purpose text, p_amount_kobo bigint, p_listing uuid, p_contact text)',
    'payment_fail(p_reference text, p_status text, p_note text)',
    'pgp_armor_headers(text, OUT key text, OUT value text)',
    'pgp_key_id(bytea)',
    'pgp_pub_decrypt(bytea, bytea)',
    'pgp_pub_decrypt(bytea, bytea, text)',
    'pgp_pub_decrypt(bytea, bytea, text, text)',
    'pgp_pub_decrypt_bytea(bytea, bytea)',
    'pgp_pub_decrypt_bytea(bytea, bytea, text)',
    'pgp_pub_decrypt_bytea(bytea, bytea, text, text)',
    'pgp_pub_encrypt(text, bytea)',
    'pgp_pub_encrypt(text, bytea, text)',
    'pgp_pub_encrypt_bytea(bytea, bytea)',
    'pgp_pub_encrypt_bytea(bytea, bytea, text)',
    'pgp_sym_decrypt(bytea, text)',
    'pgp_sym_decrypt(bytea, text, text)',
    'pgp_sym_decrypt_bytea(bytea, text)',
    'pgp_sym_decrypt_bytea(bytea, text, text)',
    'pgp_sym_encrypt(text, text)',
    'pgp_sym_encrypt(text, text, text)',
    'pgp_sym_encrypt_bytea(bytea, text)',
    'pgp_sym_encrypt_bytea(bytea, text, text)',
    'platform_fee_bps()',
    'public_catalog()',
    'public_promos()',
    'release_due_escrow()',
    'renew_membership(p_id uuid)',
    'reply_ticket(p_ticket uuid, p_body text)',
    'report_order(p_membership uuid, p_reason text, p_details text)',
    'request_withdrawal(p_amount_kobo bigint, p_bank text, p_account_number text, p_account_name text)',
    'send_expiry_reminders()',
    'suggest_subscription(p_name text, p_details text)',
    'update_my_profile(p_full_name text, p_phone text, p_username text)',
    'withdrawal_fee_kobo()'
  ];
begin
  for r in select p.oid, p.proname, p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' sig
           from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and p.proname not like '\_v3\_%' loop
    if not (r.sig = any (keep)) then
      begin execute format('alter function public.%s rename to %I', r.sig, '_v3_'||r.proname||'_'||r.oid);
      exception when others then raise notice 'kept %', r.sig; end;
    end if;
  end loop;
end $$;
