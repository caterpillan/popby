-- Pop-by upgrade 7
-- Adds: circle colour and emoji icons, starred circles (private to each person), and hiding a single
-- activity from chosen people. Safe to run more than once.
-- Paste into Supabase > SQL Editor and Run (after upgrade-6.sql).

-- ---------------------------------------------------------------------------
-- 1. Circle colour and emoji (chosen by the organiser, seen by everyone in the circle)
-- ---------------------------------------------------------------------------
alter table circles add column if not exists color text not null default '#4361EE';
alter table circles add column if not exists emoji text not null default '👋';
do $$ begin
  alter table circles add constraint circles_color_check check (color ~ '^#[0-9A-Fa-f]{6}$');
exception when duplicate_object then null; end $$;
do $$ begin
  alter table circles add constraint circles_emoji_check
    check (char_length(emoji) between 1 and 16 and emoji !~ '[[:alnum:]<>&"''`\\ ]');
exception when duplicate_object then null; end $$;

drop function if exists create_circle(text, date);
create or replace function create_circle(p_name text, p_ends date default null,
                                         p_color text default '#4361EE', p_emoji text default '👋')
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if length(trim(p_name)) = 0 then raise exception 'Give your circle a name'; end if;
  if p_ends is not null and p_ends < circle_today() then
    raise exception 'The end date has to be today or later.';
  end if;
  insert into circles (name, created_by, ends_on, color, emoji)
    values (trim(p_name), auth.uid(), p_ends, p_color, p_emoji)
    returning id into cid;
  insert into circle_members (circle_id, parent_id, role, status)
    values (cid, auth.uid(), 'organiser', 'approved');
  return cid;
end $$;

create or replace function set_circle_style(p_circle uuid, p_color text, p_emoji text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  update circles set color = p_color, emoji = p_emoji where id = p_circle;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Starred circles. Private: only you can see or change your own stars.
-- ---------------------------------------------------------------------------
create table if not exists circle_prefs (
  circle_id uuid not null references circles(id) on delete cascade,
  parent_id uuid not null references parents(id) on delete cascade,
  starred   boolean not null default false,
  primary key (circle_id, parent_id)
);
alter table circle_prefs enable row level security;
drop policy if exists "own circle prefs" on circle_prefs;
create policy "own circle prefs" on circle_prefs for all
  using (parent_id = auth.uid())
  with check (parent_id = auth.uid() and is_member(circle_id));
grant select, insert, update, delete on circle_prefs to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Hide one activity from chosen people (on top of your "hide my activities from" list)
-- ---------------------------------------------------------------------------
create table if not exists plan_hidden_from (
  plan_id   uuid not null references plans(id) on delete cascade,
  hidden_id uuid not null references parents(id) on delete cascade,
  primary key (plan_id, hidden_id)
);
alter table plan_hidden_from enable row level security;
drop policy if exists "host manages plan hides" on plan_hidden_from;
create policy "host manages plan hides" on plan_hidden_from for all
  using (exists (select 1 from plans p where p.id = plan_id and p.host_id = auth.uid()))
  with check (exists (select 1 from plans p where p.id = plan_id and p.host_id = auth.uid()));
grant select, insert, update, delete on plan_hidden_from to authenticated;

create or replace function private.is_plan_hidden(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from plan_hidden_from where plan_id = pid and hidden_id = auth.uid());
$$;
revoke all on function private.is_plan_hidden(uuid) from public, anon;
grant execute on function private.is_plan_hidden(uuid) to authenticated;

drop policy if exists "members see plans" on plans;
create policy "members see plans" on plans for select using (
  is_member(circle_id)
  and not private.is_blocked_pair(host_id)
  and not private.is_hidden_from(host_id)
  and not private.is_plan_hidden(id)
);

-- Post an activity and its hide list in one step, so nobody on the list can glimpse it
-- (or get an alert) before the hide list exists.
create or replace function create_plan(
  p_circle uuid, p_child uuid, p_who text, p_kind text, p_title text, p_place text,
  p_starts timestamptz, p_ends timestamptz, p_open boolean, p_note text,
  p_hide uuid[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare pid uuid; child uuid;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not is_member(p_circle) then raise exception 'You are not in that circle'; end if;
  if length(trim(coalesce(p_title, ''))) = 0 then raise exception 'Add what the activity is'; end if;
  if coalesce(array_length(p_hide, 1), 0) > 200 then raise exception 'Too many people to hide from'; end if;
  child := case when exists (select 1 from children where id = p_child and parent_id = auth.uid())
                then p_child else null end;
  insert into plans (circle_id, host_id, child_id, who_names, kind, title, place_name,
                     starts_at, ends_at, open_ended, note)
  values (p_circle, auth.uid(), child, p_who, p_kind, trim(p_title), p_place,
          p_starts, p_ends, coalesce(p_open, false), p_note)
  returning id into pid;
  insert into plan_hidden_from (plan_id, hidden_id)
    select pid, h from unnest(coalesce(p_hide, '{}')) as h where h <> auth.uid()
  on conflict do nothing;
  return pid;
end $$;

create or replace function set_plan_hidden(p_plan uuid, p_hide uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from plans where id = p_plan and host_id = auth.uid()) then
    raise exception 'Only the host can do that';
  end if;
  if coalesce(array_length(p_hide, 1), 0) > 200 then raise exception 'Too many people to hide from'; end if;
  delete from plan_hidden_from where plan_id = p_plan;
  insert into plan_hidden_from (plan_id, hidden_id)
    select p_plan, h from unnest(coalesce(p_hide, '{}')) as h where h <> auth.uid()
  on conflict do nothing;
end $$;

-- Push alerts skip people the activity is hidden from.
create or replace function push_targets(p_plan uuid)
returns table (endpoint text, p256dh text, auth text, host_name text, title text,
               place_name text, starts_at timestamptz, ends_at timestamptz, open_ended boolean)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.p256dh, s.auth, h.display_name, p.title, p.place_name,
         p.starts_at, p.ends_at, p.open_ended
  from plans p
  join parents h on h.id = p.host_id
  join circle_members m on m.circle_id = p.circle_id and m.status = 'approved'
       and m.parent_id <> p.host_id and not m.muted
  join push_subscriptions s on s.parent_id = m.parent_id
  where p.id = p_plan
    and circle_active(p.circle_id)
    and not exists (select 1 from hidden_from x where x.owner_id = p.host_id and x.hidden_id = m.parent_id)
    and not exists (select 1 from plan_hidden_from y where y.plan_id = p.id and y.hidden_id = m.parent_id)
    and not exists (select 1 from blocks b
                    where (b.blocker_id = m.parent_id and b.blocked_id = p.host_id)
                       or (b.blocker_id = p.host_id and b.blocked_id = m.parent_id));
$$;
revoke all on function push_targets(uuid) from public, anon, authenticated;
grant execute on function push_targets(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Permissions
-- ---------------------------------------------------------------------------
revoke all on function create_circle(text, date, text, text), set_circle_style(uuid, text, text),
  create_plan(uuid, uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, uuid[]),
  set_plan_hidden(uuid, uuid[]) from public, anon;
grant execute on function create_circle(text, date, text, text), set_circle_style(uuid, text, text),
  create_plan(uuid, uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, uuid[]),
  set_plan_hidden(uuid, uuid[]) to authenticated;
