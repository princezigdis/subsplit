-- =====================================================================
--  SUBSPLIT · 005_make_admin.sql
--  1. Create your normal account on the customer site first.
--  2. Put YOUR email below, then run this in Supabase -> SQL Editor.
--  This is the ONLY way the first admin is created. Browsers cannot do it.
--  After that, you can add or remove other admins from Admin -> Users.
-- =====================================================================
insert into public.admin_users (user_id)
select id from auth.users where lower(email) = lower('YOUR-EMAIL@example.com')
on conflict (user_id) do nothing;

-- Check it worked (should show your email):
select u.email, a.created_at from public.admin_users a join auth.users u on u.id = a.user_id;
