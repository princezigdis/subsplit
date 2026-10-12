-- Rename the brand from SubSplit to SplitSub in an existing database.
-- Fresh installs already use SplitSub (001-007). Safe to run more than once.
do $$
declare r record;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public' and p.prosrc like '%SubSplit%' and p.proname not like '\_v3%'
  loop
    execute replace(pg_get_functiondef(r.oid), 'SubSplit', 'SplitSub');
  end loop;
end $$;
update platform_settings set site_name = 'SplitSub' where site_name = 'SubSplit';
alter table platform_settings alter column site_name set default 'SplitSub';
