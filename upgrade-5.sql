-- Pop-by upgrade 5
-- Adds: family members (children and adults), "who is going" on an activity,
-- two-way blocking with unblock, and reports. Safe to run more than once.
-- Paste into Supabase > SQL Editor and Run (run upgrade-3.sql and upgrade-4.sql first if you haven't).

-- ---------------------------------------------------------------------------
-- 1. Family members and "who is going"
-- ---------------------------------------------------------------------------
alter table children add column if not exists kind text not null default 'child';
do $$ begin
  alter table children add constraint children_kind_check check (kind in ('child', 'adult'));
exception when duplicate_object then null; end $$;

-- The names shown on an activity, e.g. "Priya, Leo". Stored on the activity itself, so it
-- is hidden by exactly the same rules as the activity.
alter table plans add column if not exists who_names text;

-- ---------------------------------------------------------------------------
-- 2. Two-way blocking
-- ---------------------------------------------------------------------------
create schema if not exists private;
grant usage on schema private to authenticated;

create or replace function private.is_blocked_pair(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks
    where (blocker_id = auth.uid() and blocked_id = other)
       or (blocker_id = other and blocked_id = auth.uid()));
$$;
revoke all on function private.is_blocked_pair(uuid) from public, anon;
grant execute on function private.is_blocked_pair(uuid) to authenticated;

drop policy if exists "members see plans" on plans;
create policy "members see plans" on plans for select using (
  is_member(circle_id)
  and not private.is_blocked_pair(host_id)
  and not private.is_hidden_from(host_id)
);

drop policy if exists "members see replies" on plan_replies;
create policy "members see replies" on plan_replies for select using (
  exists (select 1 from plans p where p.id = plan_replies.plan_id)
  and not private.is_blocked_pair(parent_id)
);

drop policy if exists "see fellow members" on parents;
create policy "see fellow members" on parents for select using (
  exists (select 1 from circle_members a join circle_members b on a.circle_id = b.circle_id
          where a.parent_id = auth.uid() and a.status = 'approved' and circle_active(a.circle_id)
            and b.parent_id = parents.id and b.status = 'approved')
  and not private.is_blocked_pair(parents.id)
);

-- Member list: people you blocked, or who blocked you, are left out (organisers still see everyone
-- so they can manage their circle).
create or replace function circle_roster(p_circle uuid)
returns table (parent_id uuid, display_name text, role text, status text)
language sql stable security definer set search_path = public as $$
  select m.parent_id, p.display_name, m.role, m.status
  from circle_members m join parents p on p.id = m.parent_id
  where m.circle_id = p_circle
    and circle_active(p_circle)
    and ((is_member(p_circle) and m.status = 'approved')
         or (is_organiser(p_circle) and m.status in ('approved', 'removed')))
    and (is_organiser(p_circle) or not private.is_blocked_pair(m.parent_id))
  order by (m.role = 'organiser') desc, p.display_name;
$$;

create or replace function pending_requests()
returns table (circle_id uuid, circle_name text, parent_id uuid, display_name text)
language sql stable security definer set search_path = public as $$
  select m.circle_id, c.name, m.parent_id, p.display_name
  from circle_members m
  join circles c on c.id = m.circle_id
  join parents p on p.id = m.parent_id
  where m.status = 'pending' and is_organiser(m.circle_id) and circle_active(m.circle_id)
    and not private.is_blocked_pair(m.parent_id);
$$;

-- Joining: removed people stay removed, and anyone blocked by an organiser (or who blocked one)
-- gets the same quiet "ok" as everyone else. Nothing is signalled and no request is created.
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
  if exists (select 1 from circle_members o
             where o.circle_id = c.id and o.role = 'organiser' and o.status = 'approved'
               and private.is_blocked_pair(o.parent_id)) then
    return 'ok';
  end if;
  insert into circle_members (circle_id, parent_id, role, status)
    values (c.id, auth.uid(), 'member', 'pending')
  on conflict (circle_id, parent_id) do update set status = 'pending'
    where circle_members.status = 'declined';
  return 'ok';
end $$;

create or replace function block_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_user = auth.uid() then raise exception 'You cannot block yourself'; end if;
  insert into blocks (blocker_id, blocked_id) values (auth.uid(), p_user) on conflict do nothing;
  -- Their pending requests to join circles you organise are quietly declined.
  update circle_members m set status = 'declined'
   where m.parent_id = p_user and m.status = 'pending' and is_organiser(m.circle_id);
end $$;

create or replace function unblock_user(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from blocks where blocker_id = auth.uid() and blocked_id = p_user;
$$;

create or replace function my_blocks()
returns table (blocked_id uuid, display_name text)
language sql stable security definer set search_path = public as $$
  select b.blocked_id, coalesce(p.display_name, 'Former member')
  from blocks b left join parents p on p.id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by 2;
$$;

-- ---------------------------------------------------------------------------
-- 3. Reports (for the person running Pop-by to review)
-- ---------------------------------------------------------------------------
alter table reports add column if not exists circle_id uuid references circles(id) on delete set null;
alter table reports add column if not exists status text not null default 'new';
revoke all on reports from anon, authenticated;     -- reports go in through the functions below only

create or replace function report_user(p_user uuid, p_reason text, p_circle uuid default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_user = auth.uid() then raise exception 'You cannot report yourself'; end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'Say briefly what the problem is.'; end if;
  if not exists (select 1 from circle_members a join circle_members b on a.circle_id = b.circle_id
                 where a.parent_id = auth.uid() and a.status = 'approved'
                   and b.parent_id = p_user and b.status = 'approved') then
    raise exception 'You can only report people in your circles.';
  end if;
  insert into reports (reporter_id, parent_id, circle_id, reason)
    values (auth.uid(), p_user, p_circle, left(trim(p_reason), 1000));
end $$;

create or replace function report_plan(p_plan uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare pl plans%rowtype;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then raise exception 'Say briefly what the problem is.'; end if;
  select * into pl from plans where id = p_plan;
  if not found or not is_member(pl.circle_id) then raise exception 'You cannot report that.'; end if;
  insert into reports (reporter_id, plan_id, parent_id, circle_id, reason)
    values (auth.uid(), p_plan, pl.host_id, pl.circle_id, left(trim(p_reason), 1000));
end $$;

-- ---------------------------------------------------------------------------
-- 4. Push notifications: skip anyone blocked either way
-- ---------------------------------------------------------------------------
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
    and not exists (select 1 from blocks b
                    where (b.blocker_id = m.parent_id and b.blocked_id = p.host_id)
                       or (b.blocker_id = p.host_id and b.blocked_id = m.parent_id));
$$;

-- ---------------------------------------------------------------------------
-- 5. Permissions
-- ---------------------------------------------------------------------------
revoke all on function block_user(uuid), unblock_user(uuid), my_blocks(),
  report_user(uuid, text, uuid), report_plan(uuid, text) from public, anon;
grant execute on function block_user(uuid), unblock_user(uuid), my_blocks(),
  report_user(uuid, text, uuid), report_plan(uuid, text) to authenticated;
revoke all on function push_targets(uuid) from public, anon, authenticated;
grant execute on function push_targets(uuid) to service_role;
