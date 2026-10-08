-- Pop-by upgrade 4: push notifications (alerts that reach phones even when the app is closed).
-- Safe to run more than once. Paste into Supabase SQL Editor and press Run.
-- After this, follow the "Push notifications" steps in the README (deploy the send-push function,
-- then run push-config.sql once).

create extension if not exists pg_net with schema extensions;

-- One row per phone/browser that turned notifications on.
create table if not exists push_subscriptions (
  endpoint   text primary key,
  parent_id  uuid not null references parents(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
alter table push_subscriptions enable row level security;
revoke all on push_subscriptions from anon, authenticated;   -- the app only uses the functions below

-- Where to send the "a plan was posted" signal (filled in by push-config.sql).
create table if not exists private.push_config (
  id     int primary key default 1 check (id = 1),
  url    text,
  secret text
);
revoke all on private.push_config from public, anon, authenticated;

create or replace function save_push_sub(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into push_subscriptions (endpoint, parent_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update
    set parent_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function drop_push_sub(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and parent_id = auth.uid();
$$;

-- Who should be told about a plan. Mirrors the privacy rules: approved members of a running circle,
-- not the host, not muted, not on the host's hide list, not someone who blocked the host.
create or replace function push_targets(p_plan uuid)
returns table (endpoint text, p256dh text, auth text, host_name text, title text,
               place_name text, starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.p256dh, s.auth, h.display_name, p.title, p.place_name, p.starts_at, p.ends_at
  from plans p
  join parents h on h.id = p.host_id
  join circle_members m on m.circle_id = p.circle_id and m.status = 'approved'
       and m.parent_id <> p.host_id and not m.muted
  join push_subscriptions s on s.parent_id = m.parent_id
  where p.id = p_plan
    and circle_active(p.circle_id)
    and not exists (select 1 from hidden_from x where x.owner_id = p.host_id and x.hidden_id = m.parent_id)
    and not exists (select 1 from blocks b where b.blocker_id = m.parent_id and b.blocked_id = p.host_id);
$$;

revoke all on function save_push_sub(text, text, text), drop_push_sub(text), push_targets(uuid)
  from public, anon, authenticated;
grant execute on function save_push_sub(text, text, text), drop_push_sub(text) to authenticated;
grant execute on function push_targets(uuid) to service_role;

-- Tell the send-push function when a plan is posted or changed. Never blocks posting if anything fails.
create or replace function private.notify_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg record;
begin
  begin
    select url, secret into cfg from private.push_config where id = 1;
    if cfg.url is not null and cfg.url not like 'PASTE%' then
      perform net.http_post(
        url := cfg.url,
        body := jsonb_build_object('plan_id', new.id,
                  'kind', case when tg_op = 'INSERT' then 'new' else 'updated' end),
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cfg.secret));
    end if;
  exception when others then
    null;
  end;
  return new;
end $$;

drop trigger if exists plans_push_insert on plans;
create trigger plans_push_insert after insert on plans
  for each row execute function private.notify_push();

drop trigger if exists plans_push_update on plans;
create trigger plans_push_update after update on plans
  for each row when (new.edited_at is not null and old.edited_at is distinct from new.edited_at)
  execute function private.notify_push();
