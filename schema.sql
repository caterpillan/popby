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
