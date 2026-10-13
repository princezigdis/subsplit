-- 014: logo upload fix, maintenance mode, search history.
-- (No destructive statements on purpose.)

-- 1. Public read of the public bucket (needed by the upload API) so admin uploads work.
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='promo banners: public read') then
    create policy "promo banners: public read" on storage.objects for select to anon, authenticated
      using (bucket_id = 'promo-banners');
  end if;
end $$;
update storage.buckets set file_size_limit = 2097152,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/svg+xml'] where id = 'promo-banners';

-- 2. Maintenance mode
alter table public.platform_settings add column if not exists maintenance_mode boolean not null default false;
alter table public.platform_settings add column if not exists maintenance_message text not null default 'We are making quick improvements. Please check back soon.';

create or replace function public.maintenance_on() returns text language sql stable security definer set search_path = public as $$
  select case when maintenance_mode then maintenance_message end from platform_settings where id = 1 $$;
grant execute on function public.maintenance_on() to anon, authenticated, service_role;

create or replace function public.join_with_wallet(p_listing uuid, p_contact text default ''::text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; v_id uuid; m text;
begin
  me := _me();
  m := maintenance_on();
  if m is not null then raise exception 'Purchases are paused for maintenance. %', m; end if;
  v_id := _join(me.id, p_listing, p_contact, null);
  return jsonb_build_object('membership_id', v_id);
end $$;

create or replace function public.admin_save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare old platform_settings; v_link text;
begin
  perform _need_admin();
  select * into old from platform_settings where id = 1 for update;
  v_link := case when p ? 'support_whatsapp_link' then trim(coalesce(p ->> 'support_whatsapp_link', '')) end;
  if v_link is not null and v_link <> '' and v_link !~* '^https://(wa\.me|wa\.link|api\.whatsapp\.com|chat\.whatsapp\.com)/\S+$' then
    raise exception 'Use a WhatsApp link, for example https://wa.me/2348012345678 or a chat.whatsapp.com invite link.';
  end if;
  update platform_settings set
    site_name = coalesce(nullif(trim(p ->> 'site_name'), ''), site_name),
    hero_title = coalesce(nullif(trim(p ->> 'hero_title'), ''), hero_title),
    hero_text = coalesce(p ->> 'hero_text', hero_text),
    notice = coalesce(p ->> 'notice', notice),
    support_whatsapp = coalesce(regexp_replace(p ->> 'support_whatsapp', '\D', '', 'g'), support_whatsapp),
    support_whatsapp_link = coalesce(v_link, support_whatsapp_link),
    support_email = coalesce(p ->> 'support_email', support_email),
    categories = coalesce((select array_agg(trim(x)) from jsonb_array_elements_text(p -> 'categories') x where trim(x) <> ''), categories),
    min_withdrawal_kobo = coalesce((p ->> 'min_withdrawal_kobo')::bigint, min_withdrawal_kobo),
    min_topup_kobo = coalesce((p ->> 'min_topup_kobo')::bigint, min_topup_kobo),
    max_topup_kobo = coalesce((p ->> 'max_topup_kobo')::bigint, max_topup_kobo),
    auto_approve_listings = coalesce((p ->> 'auto_approve_listings')::boolean, auto_approve_listings),
    renewal_window_days = coalesce((p ->> 'renewal_window_days')::int, renewal_window_days),
    reminder_days = coalesce((p ->> 'reminder_days')::int, reminder_days),
    maintenance_mode = coalesce((p ->> 'maintenance_mode')::boolean, maintenance_mode),
    maintenance_message = coalesce(nullif(left(trim(p ->> 'maintenance_message'), 300), ''), maintenance_message),
    updated_at = now()
  where id = 1;
  perform _audit('UPDATE_SETTINGS', 'platform_settings', '1', to_jsonb(old), (select to_jsonb(s) from platform_settings s where id = 1));
end $$;

create or replace function public.public_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'settings', (select jsonb_build_object('site_name', site_name, 'hero_title', hero_title, 'hero_text', hero_text, 'notice', notice,
                   'support_whatsapp', support_whatsapp, 'support_whatsapp_link', support_whatsapp_link, 'support_email', support_email,
                   'categories', to_jsonb(categories), 'min_withdrawal_kobo', min_withdrawal_kobo, 'min_topup_kobo', min_topup_kobo,
                   'max_topup_kobo', max_topup_kobo, 'renewal_window_days', renewal_window_days,
                   'buyer_fee_kobo', buyer_fee_kobo(), 'withdrawal_fee_kobo', withdrawal_fee_kobo(), 'withdrawal_fee_tiers', withdrawal_fee_tiers, 'escrow_days', escrow_days(),
                   'agreement_text', _agreement_text(),
                   'maintenance', case when maintenance_mode then maintenance_message end) from platform_settings where id = 1),
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

-- 3. Search history
create table if not exists public.search_log (
  id bigserial primary key,
  term text not null,
  results int not null default 0,
  user_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists search_log_term_idx on public.search_log (term, created_at desc);
create index if not exists search_log_time_idx on public.search_log (created_at desc);
alter table public.search_log enable row level security;
revoke all on public.search_log from anon, authenticated;

create or replace function public.log_search(p_term text, p_results int default 0) returns void
language plpgsql security definer set search_path = public as $$
declare t text := lower(regexp_replace(trim(coalesce(p_term, '')), '\s+', ' ', 'g'));
begin
  if length(t) < 2 or length(t) > 60 then return; end if;
  if exists (select 1 from search_log where term = t and user_id is not distinct from auth.uid() and created_at > now() - interval '1 minute') then return; end if;
  insert into search_log (term, results, user_id) values (t, greatest(coalesce(p_results, 0), 0), auth.uid());
end $$;
grant execute on function public.log_search(text, int) to anon, authenticated;

create or replace function public.admin_top_searches(p_days int default 30) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d int := least(greatest(coalesce(p_days, 30), 1), 365);
begin
  perform _need_admin();
  return jsonb_build_object(
    'total', (select count(*) from search_log where created_at > now() - make_interval(days => d)),
    'top', coalesce((select jsonb_agg(r order by r.searches desc, r.last_at desc) from (
        select term, count(*)::int as searches, count(distinct coalesce(user_id::text, id::text))::int as people,
               round(avg(results))::int as avg_results, max(created_at) as last_at
        from search_log where created_at > now() - make_interval(days => d)
        group by term order by count(*) desc, max(created_at) desc limit 100) r), '[]'::jsonb),
    'no_results', coalesce((select jsonb_agg(r order by r.searches desc) from (
        select term, count(*)::int as searches, max(created_at) as last_at
        from search_log where created_at > now() - make_interval(days => d)
        group by term having max(results) = 0 order by count(*) desc limit 50) r), '[]'::jsonb));
end $$;
revoke execute on function public.admin_top_searches(int) from public, anon;
grant execute on function public.admin_top_searches(int) to authenticated;
