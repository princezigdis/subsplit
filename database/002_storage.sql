-- =====================================================================
--  SUBSPLIT · 002_storage.sql   (run after 001_schema.sql)
--  Private bucket for host proof (receipts / screenshots).
--  Hosts can upload only into their own folder: <their user id>/...
--  Only the host who uploaded a file and admins can read it.
-- =====================================================================
insert into storage.buckets (id, name, public) values ('host-proofs', 'host-proofs', false)
on conflict (id) do update set public = false;

update storage.buckets
   set file_size_limit = 5242880,  -- 5 MB
       allowed_mime_types = array['image/jpeg','image/png','image/webp','application/pdf']
 where id = 'host-proofs';

drop policy if exists "host proofs: upload own folder" on storage.objects;
create policy "host proofs: upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'host-proofs' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "host proofs: read own or admin" on storage.objects;
create policy "host proofs: read own or admin" on storage.objects for select to authenticated
  using (bucket_id = 'host-proofs' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

drop policy if exists "host proofs: replace own" on storage.objects;
create policy "host proofs: replace own" on storage.objects for update to authenticated
  using (bucket_id = 'host-proofs' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'host-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
