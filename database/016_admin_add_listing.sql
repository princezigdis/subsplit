-- 016: Admins can add a listing under their own account, with proof of purchase, and it goes live at once.
--
-- How the admin app uses it (Admin > Listings > Add listing):
--   1. The browser makes a new listing ID and uploads the proof to the private bucket
--      host-proofs/<admin user id>/<listing id>/proof-....  (the normal "own folder" storage rule)
--   2. It calls admin_add_listing(...) once. In ONE transaction this checks the admin, the plan rules
--      (markup range, seat limit, login details), and that the proof file really exists in that folder,
--      then creates the listing, saves the access details, records the proof as APPROVED, records the
--      30-day escrow agreement, makes the listing LIVE and writes the audit log.
--   If anything fails, nothing is created. The listing then behaves like any host listing: buyers pay into
--   escrow and the admin's share reaches the admin's wallet when each 30-day period ends.

create or replace function public.admin_add_listing(
  p_listing uuid, p_plan uuid, p_markup_pct int, p_seats int,
  p_access text default '', p_note text default '', p_proof_path text default '', p_proof_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare me profiles; p service_plans; s services; v_path text := trim(coalesce(p_proof_path, ''));
begin
  perform _need_admin();
  me := _me();
  if p_listing is null then raise exception 'Something went wrong. Refresh the page and try again.'; end if;
  if exists (select 1 from listings where id = p_listing) then raise exception 'This listing was already added. Refresh the page.'; end if;

  select * into p from service_plans where id = p_plan;
  if not found or not p.active then raise exception 'Pick a plan that is switched on.'; end if;
  select * into s from services where id = p.service_id;
  if not s.active then raise exception '% is switched off. Turn it on in Services first.', s.name; end if;
  if p_markup_pct is null or p_markup_pct < p.min_markup_pct or p_markup_pct > p.max_markup_pct then
    raise exception using message = format('Markup for %s must be between %s%% and %s%%.', s.name, p.min_markup_pct, p.max_markup_pct);
  end if;
  if p_seats is null or p_seats < 1 or p_seats > p.max_seats then
    raise exception 'SplitSub allows 1 to % seats for % %.', p.max_seats, s.name, p.name;
  end if;
  if p.access_type = 'LOGIN' and length(trim(coalesce(p_access, ''))) < 5 then
    raise exception 'Add the login details members will use. Only paying members can see them.';
  end if;

  if v_path = '' then raise exception 'Upload proof of the plan (a receipt or a screenshot of the subscription page).'; end if;
  if v_path not like me.id::text || '/' || p_listing::text || '/%' or v_path like '%..%' then
    raise exception 'That proof file does not belong to this listing.';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'host-proofs' and name = v_path) then
    raise exception 'We could not find the uploaded proof. Please upload it again.';
  end if;

  insert into listings (id, host_id, plan_id, markup_pct, seats_offered, note, status, proof_path, proof_note, proof_status,
                        submitted_at, agreement_accepted_at, agreement_text, reviewed_at, reviewed_by, review_note)
  values (p_listing, me.id, p.id, p_markup_pct, p_seats, left(trim(coalesce(p_note, '')), 300), 'DRAFT', v_path,
          left(trim(coalesce(p_proof_note, '')), 500), 'APPROVED', now(), now(), _agreement_text(), now(), me.id,
          'Added by an admin with proof.');
  insert into listing_access (listing_id, details) values (p_listing, left(trim(coalesce(p_access, '')), 2000));
  insert into host_proofs (listing_id, host_id, service_name, file_path, note, status, reviewed_at, reviewed_by)
  values (p_listing, me.id, s.name, v_path, left(trim(coalesce(p_proof_note, '')), 500), 'APPROVED', now(), me.id);
  -- The live guard trigger still runs here: it needs the approved proof and the accepted agreement above.
  update listings set status = 'LIVE', updated_at = now() where id = p_listing;

  perform _audit('ADMIN_ADD_LISTING', 'listing', p_listing::text, null,
    jsonb_build_object('status', 'LIVE', 'service', s.name, 'plan', p.name, 'markup_pct', p_markup_pct, 'seats', p_seats, 'proof', v_path),
    'Added and published by an admin with proof');
  return jsonb_build_object('listing_id', p_listing, 'status', 'LIVE', 'service', s.name, 'plan', p.name);
end $$;

revoke all on function public.admin_add_listing(uuid, uuid, int, int, text, text, text, text) from public, anon;
grant execute on function public.admin_add_listing(uuid, uuid, int, int, text, text, text, text) to authenticated;
