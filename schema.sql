-- Pop-by database setup for Supabase.
-- Paste this whole file into Supabase > SQL Editor and run it once.

-- Pop-by database schema (Postgres / Supabase)
-- Design rules: parents are the only users; children are records, never accounts;
-- every plan is visible only to approved members of the circle it was shared with.

create extension if not exists "pgcrypto";

-- Parents (links to Supabase auth.users)
create table parents (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,                  -- "Priya S."
  push_token   text,
  created_at   timestamptz not null default now()
);

-- Children: first name only, owned by one parent record
create table children (
  id         uuid primary key default gen_random_uuid(),
  parent_id  uuid not null references parents(id) on delete cascade,
  first_name text not null,
  year_group text,
  created_at timestamptz not null default now()
);

-- Circles: a class, team or street
create table circles (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  invite_code text not null unique default upper(substr(encode(gen_random_bytes(6),'hex'),1,6)),
  created_by  uuid not null references parents(id),
  created_at  timestamptz not null default now()
);

-- Membership with approval. Nothing is visible until status = 'approved'.
create table circle_members (
  circle_id  uuid references circles(id) on delete cascade,
  parent_id  uuid references parents(id) on delete cascade,
  role       text not null default 'member' check (role in ('organiser','member')),
  status     text not null default 'pending' check (status in ('pending','approved','declined','removed')),
  muted      boolean not null default false,   -- per-circle notification mute
  joined_at  timestamptz not null default now(),
  primary key (circle_id, parent_id)
);

-- Plans: drop-ins and parties
create table plans (
  id          uuid primary key default gen_random_uuid(),
  circle_id   uuid not null references circles(id) on delete cascade,
  host_id     uuid not null references parents(id) on delete cascade,
  child_id    uuid references children(id) on delete set null,
  kind        text not null check (kind in ('dropin','party')),
  title       text not null,
  place_name  text,
  lat         double precision,                -- set only for this plan, never live tracking
  lng         double precision,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null check (ends_at > starts_at),
  note        text,
  created_at  timestamptz not null default now()
);
create index on plans (circle_id, starts_at);

-- Replies: "I might pop by" (dropin) or "I'm going" (party)
create table plan_replies (
  plan_id    uuid references plans(id) on delete cascade,
  parent_id  uuid references parents(id) on delete cascade,
  status     text not null default 'going' check (status in ('going','maybe','not_going')),
  created_at timestamptz not null default now(),
  primary key (plan_id, parent_id)
);

-- Safety: block and report
create table blocks (
  blocker_id uuid references parents(id) on delete cascade,
  blocked_id uuid references parents(id) on delete cascade,
  primary key (blocker_id, blocked_id)
);
create table reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references parents(id),
  plan_id     uuid references plans(id) on delete set null,
  parent_id   uuid references parents(id) on delete set null,
  reason      text not null,
  created_at  timestamptz not null default now()
);

-- Helper: is the current user an approved member of this circle?
create or replace function is_member(cid uuid) returns boolean
language sql stable security definer as $$
  select exists (
    select 1 from circle_members
    where circle_id = cid and parent_id = auth.uid() and status = 'approved'
  );
$$;

-- Row-level security
alter table parents        enable row level security;
alter table children       enable row level security;
alter table circles        enable row level security;
alter table circle_members enable row level security;
alter table plans          enable row level security;
alter table plan_replies   enable row level security;
alter table blocks         enable row level security;
alter table reports        enable row level security;

create policy "own profile" on parents for all using (id = auth.uid());
create policy "see fellow members" on parents for select using (
  exists (select 1 from circle_members a join circle_members b on a.circle_id = b.circle_id
          where a.parent_id = auth.uid() and a.status='approved'
            and b.parent_id = parents.id and b.status='approved'));

create policy "own children" on children for all using (parent_id = auth.uid());
create policy "see children of hosts in shared plans" on children for select using (
  exists (select 1 from plans p where p.child_id = children.id and is_member(p.circle_id)));

create policy "members see circle" on circles for select using (is_member(id) or created_by = auth.uid());
create policy "create circle" on circles for insert with check (created_by = auth.uid());

create policy "see own and circle memberships" on circle_members for select using (parent_id = auth.uid() or is_member(circle_id));
create policy "request to join" on circle_members for insert with check (parent_id = auth.uid() and status = 'pending' and role = 'member');
create policy "organiser manages" on circle_members for update using (
  exists (select 1 from circle_members o where o.circle_id = circle_members.circle_id
          and o.parent_id = auth.uid() and o.role='organiser' and o.status='approved'));

create policy "members see plans" on plans for select using (
  is_member(circle_id) and not exists (select 1 from blocks b where b.blocker_id = auth.uid() and b.blocked_id = plans.host_id));
create policy "members post plans" on plans for insert with check (host_id = auth.uid() and is_member(circle_id));
create policy "host edits plan" on plans for update using (host_id = auth.uid());
create policy "host deletes plan" on plans for delete using (host_id = auth.uid());

create policy "members see replies" on plan_replies for select using (
  exists (select 1 from plans p where p.id = plan_id and is_member(p.circle_id)));
create policy "reply as self" on plan_replies for all using (parent_id = auth.uid()) with check (
  parent_id = auth.uid() and exists (select 1 from plans p where p.id = plan_id and is_member(p.circle_id)));

create policy "own blocks"  on blocks  for all using (blocker_id = auth.uid());
create policy "file report" on reports for insert with check (reporter_id = auth.uid());

-- Cleanup: remove precise coordinates once a plan has ended (run daily via pg_cron or an edge function)
-- update plans set lat = null, lng = null where ends_at < now() - interval '1 day';

-- ===== Fixes and app functions =====
-- Fixes: (1) the "organiser manages" policy queried its own table (infinite recursion),
--        (2) a creator had no way to become the first organiser,
--        (3) joining by code needs a safe lookup because non-members can't read circles.

-- Reliable invite code default (6 characters)
alter table circles alter column invite_code
  set default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));

-- Helpers (security definer avoids recursive policy checks)
create or replace function is_member(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from circle_members
    where circle_id = cid and parent_id = auth.uid() and status = 'approved');
$$;

create or replace function is_organiser(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from circle_members
    where circle_id = cid and parent_id = auth.uid() and role = 'organiser' and status = 'approved');
$$;

-- Replace the recursive policy, and let people leave a circle
drop policy if exists "organiser manages" on circle_members;
create policy "organiser manages" on circle_members for update using (is_organiser(circle_id));
drop policy if exists "leave circle" on circle_members;
create policy "leave circle" on circle_members for delete using (parent_id = auth.uid());

-- Create a circle and become its organiser in one step
create or replace function create_circle(p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if length(trim(p_name)) = 0 then raise exception 'Give your circle a name'; end if;
  insert into circles (name, created_by) values (trim(p_name), auth.uid()) returning id into cid;
  insert into circle_members (circle_id, parent_id, role, status) values (cid, auth.uid(), 'organiser', 'approved');
  return cid;
end $$;

-- Request to join with an invite code (organiser must approve)
create or replace function join_circle(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare c circles%rowtype;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into c from circles where invite_code = upper(trim(p_code));
  if not found then raise exception 'No circle with that code. Check it and try again.'; end if;
  insert into circle_members (circle_id, parent_id, role, status)
    values (c.id, auth.uid(), 'member', 'pending')
  on conflict (circle_id, parent_id) do update set status = 'pending'
    where circle_members.status in ('declined', 'removed');
  return 'ok';
end $$;

-- Requests waiting for circles I organise
create or replace function pending_requests()
returns table (circle_id uuid, circle_name text, parent_id uuid, display_name text)
language sql stable security definer set search_path = public as $$
  select m.circle_id, c.name, m.parent_id, p.display_name
  from circle_members m
  join circles c on c.id = m.circle_id
  join parents p on p.id = m.parent_id
  where m.status = 'pending' and is_organiser(m.circle_id);
$$;

-- Approve or decline a request
create or replace function decide_request(p_circle uuid, p_parent uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser(p_circle) then raise exception 'Only the organiser can do that'; end if;
  update circle_members set status = case when p_approve then 'approved' else 'declined' end
   where circle_id = p_circle and parent_id = p_parent and status = 'pending';
end $$;

revoke all on function create_circle(text), join_circle(text), pending_requests(), decide_request(uuid, uuid, boolean) from public, anon;
grant execute on function create_circle(text), join_circle(text), pending_requests(), decide_request(uuid, uuid, boolean) to authenticated;

-- Live updates in the app
alter publication supabase_realtime add table plans, plan_replies, circle_members;

-- Let signed-in users reach the tables. Row-level security (above) still decides which rows.
-- Without these grants Supabase reports "permission denied for table ...".
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;

-- Pop-by upgrade 2
-- Adds: circle end dates, silent removal with block-until-allowed, make organiser,
-- leave rules, private circle nicknames, and "hide my plans from" lists.
-- Safe to run more than once, and safe on an existing database. Paste into Supabase > SQL Editor and Run.

-- ---------------------------------------------------------------------------
-- 1. Circle end dates (dates are read in UK time)
-- ---------------------------------------------------------------------------
alter table circles add column if not exists ends_on date;

create or replace function circle_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/London')::date $$;

create or replace function circle_active(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from circles
    where id = cid and (ends_on is null or ends_on >= circle_today()));
$$;

-- Membership now also requires the circle to still be running.
-- When a circle ends, its plans, member names and replies stop being visible to everyone.
create or replace function is_member(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select circle_active(cid) and exists (select 1 from circle_members
    where circle_id = cid and parent_id = auth.uid() and status = 'approved');
$$;

-- ---------------------------------------------------------------------------
-- 2. "Hide my plans from" lists. Kept in a private schema so the app's public
--    API cannot be used to ask "am I hidden from this person?".
-- ---------------------------------------------------------------------------
create schema if not exists private;
grant usage on schema private to authenticated;

create table if not exists hidden_from (
  owner_id  uuid not null references parents(id) on delete cascade,
  hidden_id uuid not null references parents(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, hidden_id),
  check (owner_id <> hidden_id)
);
alter table hidden_from enable row level security;
drop policy if exists "own hide list" on hidden_from;
create policy "own hide list" on hidden_from for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function private.is_hidden_from(host uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from hidden_from where owner_id = host and hidden_id = auth.uid());
$$;
revoke all on function private.is_hidden_from(uuid) from public, anon;
grant execute on function private.is_hidden_from(uuid) to authenticated;

-- Plans: circle members see them, unless the host hid them from you (or you blocked the host).
drop policy if exists "members see plans" on plans;
create policy "members see plans" on plans for select using (
  is_member(circle_id)
  and not exists (select 1 from blocks b where b.blocker_id = auth.uid() and b.blocked_id = plans.host_id)
  and not private.is_hidden_from(host_id)
);

-- Replies follow the plan: if you cannot see the plan, you cannot see who replied to it.
drop policy if exists "members see replies" on plan_replies;
create policy "members see replies" on plan_replies for select using (
  exists (select 1 from plans p where p.id = plan_replies.plan_id)
);

-- ---------------------------------------------------------------------------
-- 3. Who can see whom
-- ---------------------------------------------------------------------------
drop policy if exists "see fellow members" on parents;
create policy "see fellow members" on parents for select using (
  exists (select 1 from circle_members a join circle_members b on a.circle_id = b.circle_id
          where a.parent_id = auth.uid() and a.status = 'approved' and circle_active(a.circle_id)
            and b.parent_id = parents.id and b.status = 'approved'));

-- Members only see approved members. Removed and declined rows are visible to the person
-- themselves and to organisers, never to other members.
drop policy if exists "see own and circle memberships" on circle_members;
create policy "see own and circle memberships" on circle_members for select using (
  parent_id = auth.uid()
  or (is_member(circle_id) and (status = 'approved' or is_organiser(circle_id)))
);

-- People can no longer delete their own membership row directly. That would let a removed
-- person erase the block. They use leave_circle() instead.
drop policy if exists "leave circle" on circle_members;

-- ---------------------------------------------------------------------------
-- 4. Private circle nicknames (only you can see your own)
-- ---------------------------------------------------------------------------
create table if not exists circle_nicknames (
  circle_id uuid not null references circles(id) on delete cascade,
  parent_id uuid not null references parents(id) on delete cascade,
  nickname  text not null check (length(trim(nickname)) between 1 and 60),
  primary key (circle_id, parent_id)
);
alter table circle_nicknames enable row level security;
drop policy if exists "own nicknames" on circle_nicknames;
create policy "own nicknames" on circle_nicknames for all
  using (parent_id = auth.uid())
  with check (parent_id = auth.uid() and is_member(circle_id));

-- ---------------------------------------------------------------------------
-- 5. Circle functions
-- ---------------------------------------------------------------------------
drop function if exists create_circle(text);
create or replace function create_circle(p_name text, p_ends date default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if length(trim(p_name)) = 0 then raise exception 'Give your circle a name'; end if;
  if p_ends is not null and p_ends < circle_today() then
    raise exception 'The end date has to be today or later.';
  end if;
  insert into circles (name, created_by, ends_on) values (trim(p_name), auth.uid(), p_ends)
    returning id into cid;
  insert into circle_members (circle_id, parent_id, role, status)
    values (cid, auth.uid(), 'organiser', 'approved');
  return cid;
end $$;

-- Let someone see a circle's name, organiser and end date before they ask to join.
create or replace function circle_preview(p_code text)
returns table (name text, ends_on date, organiser text)
language sql stable security definer set search_path = public as $$
  select c.name, c.ends_on, p.display_name
  from circles c join parents p on p.id = c.created_by
  where c.invite_code = upper(trim(p_code))
    and (c.ends_on is null or c.ends_on >= circle_today());
$$;

-- Joining: removed people stay removed. They get the same reply as anyone else, so nothing is signalled.
create or replace function join_circle(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare c circles%rowtype; existing text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into c from circles where invite_code = upper(trim(p_code));
  if not found then raise exception 'No circle with that code. Check it and try again.'; end if;
  if c.ends_on is not null and c.ends_on < circle_today() then
    raise exception 'That circle has ended.';
  end if;
  select status into existing from circle_members where circle_id = c.id and parent_id = auth.uid();
  if existing = 'approved' then return 'member'; end if;
  if existing = 'removed' then return 'ok'; end if;
  insert into circle_members (circle_id, parent_id, role, status)
    values (c.id, auth.uid(), 'member', 'pending')
  on conflict (circle_id, parent_id) do update set status = 'pending'
    where circle_members.status = 'declined';
  return 'ok';
end $$;

create or replace function pending_requests()
returns table (circle_id uuid, circle_name text, parent_id uuid, display_name text)
language sql stable security definer set search_path = public as $$
  select m.circle_id, c.name, m.parent_id, p.display_name
  from circle_members m
  join circles c on c.id = m.circle_id
  join parents p on p.id = m.parent_id
  where m.status = 'pending' and is_organiser(m.circle_id) and circle_active(m.circle_id);
$$;

-- Member list. Everyone in the circle sees approved members. Organisers also see removed members.
create or replace function circle_roster(p_circle uuid)
returns table (parent_id uuid, display_name text, role text, status text)
language sql stable security definer set search_path = public as $$
  select m.parent_id, p.display_name, m.role, m.status
  from circle_members m join parents p on p.id = m.parent_id
  where m.circle_id = p_circle
    and circle_active(p_circle)
    and ((is_member(p_circle) and m.status = 'approved')
         or (is_organiser(p_circle) and m.status in ('approved', 'removed')))
  order by (m.role = 'organiser') desc, p.display_name;
$$;

-- Silent removal. Their plans and replies in this circle are cleared. They are not told.
create or replace function remove_member(p_circle uuid, p_parent uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  if p_parent = auth.uid() then raise exception 'Use Leave circle to remove yourself'; end if;
  if exists (select 1 from circle_members
             where circle_id = p_circle and parent_id = p_parent and role = 'organiser') then
    raise exception 'Organisers cannot be removed';
  end if;
  update circle_members set status = 'removed'
    where circle_id = p_circle and parent_id = p_parent and status in ('approved', 'pending', 'declined');
  delete from plan_replies r using plans p
    where r.plan_id = p.id and p.circle_id = p_circle and r.parent_id = p_parent;
  delete from plans where circle_id = p_circle and host_id = p_parent;
end $$;

-- Let a removed person back in.
create or replace function allow_member(p_circle uuid, p_parent uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  update circle_members set status = 'approved'
    where circle_id = p_circle and parent_id = p_parent and status = 'removed';
end $$;

create or replace function make_organiser(p_circle uuid, p_parent uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  update circle_members set role = 'organiser'
    where circle_id = p_circle and parent_id = p_parent and status = 'approved';
end $$;

-- Leaving. A sole organiser must hand over first. A sole member closes the circle.
-- A removed person leaving does nothing, so the block stays.
create or replace function leave_circle(p_circle uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m circle_members%rowtype; other_orgs int; others int;
begin
  select * into m from circle_members where circle_id = p_circle and parent_id = auth.uid();
  if not found or m.status = 'removed' then return; end if;
  if m.status = 'approved' and m.role = 'organiser' then
    select count(*) into other_orgs from circle_members
      where circle_id = p_circle and role = 'organiser' and status = 'approved' and parent_id <> auth.uid();
    select count(*) into others from circle_members
      where circle_id = p_circle and status = 'approved' and parent_id <> auth.uid();
    if other_orgs = 0 and others > 0 then
      raise exception 'Make another member an organiser before you leave.';
    end if;
    if others = 0 then
      delete from circles where id = p_circle;
      return;
    end if;
  end if;
  delete from plan_replies r using plans p
    where r.plan_id = p.id and p.circle_id = p_circle and r.parent_id = auth.uid();
  delete from plans where circle_id = p_circle and host_id = auth.uid();
  delete from circle_members where circle_id = p_circle and parent_id = auth.uid();
end $$;

create or replace function set_circle_end(p_circle uuid, p_ends date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  if p_ends is not null and p_ends < circle_today() then
    raise exception 'The end date has to be today or later.';
  end if;
  update circles set ends_on = p_ends where id = p_circle;
end $$;

-- Deletes circles 30 days after they ended, with all their plans, replies and members.
-- Not callable from the app. To run it daily: Database > Extensions > enable pg_cron, then run:
--   select cron.schedule('popby-purge', '0 3 * * *', 'select purge_expired_circles()');
create or replace function purge_expired_circles() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  delete from circles where ends_on is not null and ends_on < circle_today() - 30;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Permissions for the new pieces
-- ---------------------------------------------------------------------------
revoke all on function
  create_circle(text, date), circle_preview(text), join_circle(text), pending_requests(),
  circle_roster(uuid), remove_member(uuid, uuid), allow_member(uuid, uuid),
  make_organiser(uuid, uuid), leave_circle(uuid), set_circle_end(uuid, date),
  purge_expired_circles()
from public, anon;
grant execute on function
  create_circle(text, date), circle_preview(text), join_circle(text), pending_requests(),
  circle_roster(uuid), remove_member(uuid, uuid), allow_member(uuid, uuid),
  make_organiser(uuid, uuid), leave_circle(uuid), set_circle_end(uuid, date)
to authenticated;
revoke all on function purge_expired_circles() from authenticated;

grant select, insert, update, delete on hidden_from, circle_nicknames to authenticated;
-- Pop-by upgrade 3: hosts can edit a plan; the circle sees an "Updated" badge.
-- Safe to run more than once. Paste into Supabase SQL Editor and press Run.

alter table plans add column if not exists edited_at timestamptz;

create or replace function plans_before_update() returns trigger
language plpgsql as $$
begin
  -- who posted it and which circle it is in can never change
  new.host_id := old.host_id;
  new.circle_id := old.circle_id;
  if new.starts_at is distinct from old.starts_at
     or new.ends_at is distinct from old.ends_at
     or new.place_name is distinct from old.place_name
     or new.title is distinct from old.title then
    new.edited_at := now();
  end if;
  return new;
end $$;

drop trigger if exists plans_before_update on plans;
create trigger plans_before_update before update on plans
  for each row execute function plans_before_update();

drop policy if exists "host edits plan" on plans;
create policy "host edits plan" on plans for update
  using (host_id = auth.uid() and is_member(circle_id))
  with check (host_id = auth.uid() and is_member(circle_id));
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
