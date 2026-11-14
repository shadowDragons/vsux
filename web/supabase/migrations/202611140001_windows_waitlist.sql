begin;

create table public.windows_waitlist (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check (email = lower(btrim(email)) and length(email) between 3 and 254 and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  platform text not null default 'windows' check (platform = 'windows'),
  language text not null check (language in ('zh', 'en')),
  created_at timestamptz not null default now(),
  consent_version text not null default 'windows-launch-v1' check (consent_version = 'windows-launch-v1')
);

create table public.waitlist_rate_limits (
  rate_key text primary key check (rate_key ~ '^[a-f0-9]{64}$'),
  attempts integer not null,
  expires_at timestamptz not null default now() + interval '2 hours'
);
create index waitlist_rate_limits_expiry on public.waitlist_rate_limits (expires_at);

alter table public.windows_waitlist enable row level security;
alter table public.waitlist_rate_limits enable row level security;
revoke all on public.windows_waitlist, public.waitlist_rate_limits from public, anon, authenticated;
grant select, insert, update, delete on public.windows_waitlist, public.waitlist_rate_limits to service_role;

-- No public policies. Only the server's service role and project admins can access the rows.
-- Rate limiting and signup share a transaction; duplicate/concurrent submissions stay safe.
create function public.join_windows_waitlist(p_email text, p_language text, p_rate_key text)
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  request_count integer;
begin
  delete from public.waitlist_rate_limits where expires_at < now();
  insert into public.waitlist_rate_limits (rate_key, attempts)
    values (p_rate_key, 1)
    on conflict (rate_key) do update set attempts = least(public.waitlist_rate_limits.attempts + 1, 6)
    returning attempts into request_count;
  if request_count > 5 then return 'rate_limited'; end if;
  insert into public.windows_waitlist (email, language)
    values (p_email, p_language)
    on conflict (email) do nothing;
  return 'saved';
end;
$$;

revoke all on function public.join_windows_waitlist(text, text, text) from public, anon, authenticated;
grant execute on function public.join_windows_waitlist(text, text, text) to service_role;

commit;
