-- Pop-by upgrade 6
-- Adds: optional end time ("until it ends"), "might pop by" / "see you there" replies,
-- and "Not for me" (hide an activity from your own home screen only).
-- Safe to run more than once. Paste into Supabase > SQL Editor and Run (after upgrade-5.sql).

-- ---------------------------------------------------------------------------
-- 1. Optional end time. An activity with no end time stores an assumed end
--    (start + 4 hours) so it still fades out and disappears on its own.
-- ---------------------------------------------------------------------------
do $$ begin
  -- First run only: old drop-in replies meant "I might pop by", so they become "maybe".
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'plans' and column_name = 'open_ended') then
    update plan_replies r set status = 'maybe'
      from plans p where p.id = r.plan_id and p.kind = 'dropin' and r.status = 'going';
  end if;
end $$;

alter table plans add column if not exists open_ended boolean not null default false;

create or replace function plans_before_update() returns trigger
language plpgsql as $$
begin
  new.host_id := old.host_id;
  new.circle_id := old.circle_id;
  if new.starts_at is distinct from old.starts_at
     or new.ends_at is distinct from old.ends_at
     or new.open_ended is distinct from old.open_ended
     or new.place_name is distinct from old.place_name
     or new.title is distinct from old.title then
    new.edited_at := now();
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 2. "Not for me": hides one activity from your own screen. The host is not told.
-- ---------------------------------------------------------------------------
create table if not exists plan_dismissals (
  plan_id    uuid not null references plans(id) on delete cascade,
  parent_id  uuid not null references parents(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (plan_id, parent_id)
);
alter table plan_dismissals enable row level security;
drop policy if exists "own dismissals" on plan_dismissals;
create policy "own dismissals" on plan_dismissals for all
  using (parent_id = auth.uid())
  with check (parent_id = auth.uid() and exists (select 1 from plans p where p.id = plan_id));
grant select, insert, update, delete on plan_dismissals to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Push notifications know about open-ended activities
-- ---------------------------------------------------------------------------
drop function if exists push_targets(uuid);
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
    and not exists (select 1 from blocks b
                    where (b.blocker_id = m.parent_id and b.blocked_id = p.host_id)
                       or (b.blocker_id = p.host_id and b.blocked_id = m.parent_id));
$$;
revoke all on function push_targets(uuid) from public, anon, authenticated;
grant execute on function push_targets(uuid) to service_role;
