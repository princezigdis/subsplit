-- TEST ONLY: give the SQL test suites the pre-019 read rights so their checks can look at tables.
grant select on public.platform_settings, public.services, public.service_plans to anon, authenticated;
grant select on public.profiles, public.listings, public.listing_access, public.memberships, public.wallet_accounts,
  public.wallet_transactions, public.payments, public.withdrawals, public.disputes, public.notifications,
  public.support_tickets, public.support_messages, public.admin_audit_logs, public.admin_users to authenticated;
