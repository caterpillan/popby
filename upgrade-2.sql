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
