-- FRESH START: wipes all test money, orders, listings and approvals.
-- KEEPS: users, admin accounts, services, plans, settings, promotions.
-- Run ONCE in Supabase > SQL Editor. It cannot be undone.
truncate table wallet_transactions, payments, withdrawals, memberships, listings,
  host_proofs, listing_access, disputes, notifications, order_messages, order_reads,
  support_tickets, support_messages, email_outbox, referrals, promo_claims;
update wallet_accounts set balance_kobo = 0;
-- Check: all four numbers should be 0
select (select count(*) from wallet_transactions) as ledger_rows,
       (select count(*) from listings) as listings,
       (select count(*) from host_proofs) as proofs,
       (select coalesce(sum(abs(balance_kobo)),0) from wallet_accounts) as money_left;
