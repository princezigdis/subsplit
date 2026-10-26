-- 020 Owner change codes (2026-10-26)
-- Before Claude changes anything in this database it must email a 6-digit code to the owner
-- and get it back in the chat. Everything lives in the "owner_guard" schema, which the website
-- API does not expose, and only the database owner role can run these functions.
--   select owner_guard.send_code();          -- emails a code (10-minute life, one use)
--   select owner_guard.check_code('123456'); -- 'OK' when right; wrong 3 times = locked 15 minutes
-- The code is stored only as a hash. After it is used, the copy in the email queue is blanked.

create schema if not exists owner_guard;
revoke all on schema owner_guard from public, anon, authenticated, service_role;

create table if not exists owner_guard.settings (
  id int primary key default 1 check (id = 1),
  owner_email text not null,
  code_minutes int not null default 10,
  max_wrong int not null default 3,
  lock_minutes int not null default 15
);
insert into owner_guard.settings (id, owner_email) values (1, 'adedipupoprince@gmail.com') on conflict (id) do nothing;

create table if not exists owner_guard.codes (
  id bigint generated always as identity primary key,
  code_hash text not null,
  salt text not null,
  email_id bigint,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  wrong int not null default 0,
  used_at timestamptz,
  dead boolean not null default false
);
revoke all on all tables in schema owner_guard from public, anon, authenticated, service_role;

create or replace function owner_guard.send_code() returns text
language plpgsql security definer set search_path = owner_guard, public, extensions as $$
declare s owner_guard.settings; v_code text; v_salt text; v_mail bigint; v_locked timestamptz;
begin
  select * into s from owner_guard.settings where id = 1;
  select max(created_at) + make_interval(mins => s.lock_minutes) into v_locked
    from owner_guard.codes where wrong >= s.max_wrong;
  if v_locked > now() then
    return 'LOCKED: too many wrong codes. Try again after ' || to_char(v_locked at time zone 'Africa/Lagos', 'HH12:MI AM') || ' (Lagos time).';
  end if;
  if (select count(*) from owner_guard.codes where created_at > now() - interval '10 minutes') >= 3 then
    return 'WAIT: 3 codes were sent in the last 10 minutes. Use the newest one or wait a few minutes.';
  end if;
  update owner_guard.codes set dead = true where used_at is null and not dead;   -- only the newest code works
  v_code := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  v_salt := encode(gen_random_bytes(16), 'hex');
  insert into public.email_outbox (to_email, type, subject, body)
  values (s.owner_email, 'OWNER_CODE', 'Your change code: ' || left(v_code, 3) || ' ' || right(v_code, 3),
    'Someone asked Claude to make changes to your SplitSub database. Your code is ' || v_code ||
    '. It works once and expires in ' || s.code_minutes || ' minutes. Only paste it into the chat if YOU asked for the change. If you did not, ignore this email and nothing will be changed.')
  returning id into v_mail;
  insert into owner_guard.codes (code_hash, salt, email_id, expires_at)
  values (encode(digest(v_salt || v_code, 'sha256'), 'hex'), v_salt, v_mail, now() + make_interval(mins => s.code_minutes));
  perform public._kick_emails();
  return 'SENT: a code was emailed to ' || left(s.owner_email, 2) || '***' || substr(s.owner_email, position('@' in s.owner_email)) || '. It expires in ' || s.code_minutes || ' minutes.';
end $$;

create or replace function owner_guard.check_code(p_code text) returns text
language plpgsql security definer set search_path = owner_guard, public, extensions as $$
declare s owner_guard.settings; c owner_guard.codes; v text := regexp_replace(coalesce(p_code, ''), '\D', '', 'g');
begin
  select * into s from owner_guard.settings where id = 1;
  select * into c from owner_guard.codes where used_at is null and not dead order by id desc limit 1 for update;
  if not found then return 'NO CODE: there is no waiting code. Send a new one.'; end if;
  if c.expires_at < now() then
    update owner_guard.codes set dead = true where id = c.id;
    return 'EXPIRED: that code is too old. Send a new one.';
  end if;
  if encode(digest(c.salt || v, 'sha256'), 'hex') <> c.code_hash then
    update owner_guard.codes set wrong = wrong + 1, dead = (wrong + 1 >= s.max_wrong) where id = c.id;
    if c.wrong + 1 >= s.max_wrong then
      return 'WRONG: code locked after ' || s.max_wrong || ' wrong tries. New codes can be sent after ' || s.lock_minutes || ' minutes.';
    end if;
    return 'WRONG: ' || (s.max_wrong - c.wrong - 1) || ' tries left.';
  end if;
  update owner_guard.codes set used_at = now() where id = c.id;
  update public.email_outbox set body = 'Code hidden after use.', subject = 'Your change code (used)'
   where id = c.email_id and sent_at is not null;
  return 'OK: code accepted.';
end $$;

revoke all on all functions in schema owner_guard from public, anon, authenticated, service_role;
