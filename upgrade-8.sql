-- Pop-by upgrade 8
-- Adds: (1) a secret-word check when joining a circle, (2) a per-circle choice of whether your name
-- shows on replies (off by default), (3) "leave by" reminders sent as phone notifications.
-- Safe to run more than once. Paste into Supabase > SQL Editor and Run (after upgrade-7.sql).

-- ---------------------------------------------------------------------------
-- 1. Secret word check
--    The organiser picks one secret word plus a few decoys. A joiner sees them all mixed up and
--    gets ONE pick. A wrong pick quietly puts them on the "Removed" list (they are not told)
--    until the organiser taps "Allow back". The word is never sent to anyone by Pop-by: the
--    organiser tells people the word in person, by text, etc.
-- ---------------------------------------------------------------------------
create table if not exists circle_keywords (
  circle_id uuid primary key references circles(id) on delete cascade,
  secret    text not null,
  decoys    text[] not null
);
alter table circle_keywords enable row level security;
revoke all on circle_keywords from anon, authenticated;   -- only reachable through the functions below

create or replace function set_circle_keyword(p_circle uuid, p_secret text, p_decoys text[])
returns void language plpgsql security definer set search_path = public as $$
declare s text; d text[]; w text;
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  s := trim(coalesce(p_secret, ''));
  d := array(select trim(x) from unnest(coalesce(p_decoys, '{}')) x where length(trim(x)) > 0);
  if length(s) < 2 or length(s) > 30 then raise exception 'The secret word needs 2 to 30 letters.'; end if;
  if array_length(d, 1) is null or array_length(d, 1) < 2 or array_length(d, 1) > 5 then
    raise exception 'Add between 2 and 5 decoy words.';
  end if;
  foreach w in array d loop
    if length(w) > 30 then raise exception 'Words can be up to 30 letters.'; end if;
    if lower(w) = lower(s) then raise exception 'A decoy cannot be the same as the secret word.'; end if;
  end loop;
  if (select count(distinct lower(x)) from unnest(d) x) <> array_length(d, 1) then
    raise exception 'The decoy words must all be different.';
  end if;
  insert into circle_keywords (circle_id, secret, decoys) values (p_circle, s, d)
  on conflict (circle_id) do update set secret = excluded.secret, decoys = excluded.decoys;
end $$;

create or replace function clear_circle_keyword(p_circle uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  delete from circle_keywords where circle_id = p_circle;
end $$;

-- Organisers can read back their own word list.
create or replace function get_circle_keyword(p_circle uuid)
returns table (secret text, decoys text[])
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  return query select k.secret, k.decoys from circle_keywords k where k.circle_id = p_circle;
end $$;

-- What a joiner sees: the words in a random order, with no hint which one is right.
create or replace function circle_join_options(p_code text)
returns table (has_keyword boolean, options text[])
language sql volatile security definer set search_path = public as $$
  select true,
         array(select w from unnest(array[k.secret] || k.decoys) w order by random())
  from circles c join circle_keywords k on k.circle_id = c.id
  where c.invite_code = upper(trim(p_code))
    and (c.ends_on is null or c.ends_on >= circle_today());
$$;

-- ---------------------------------------------------------------------------
-- 2. Show my name on replies (per circle, off by default)
--    Off: only the person who posted the activity sees your name on your reply.
--    Everyone still sees the totals ("3 going").
-- ---------------------------------------------------------------------------
alter table circle_members add column if not exists show_names boolean not null default false;

create or replace function set_show_names(p_circle uuid, p_show boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  update circle_members set show_names = coalesce(p_show, false)
   where circle_id = p_circle and parent_id = auth.uid() and status = 'approved';
end $$;

create or replace function private.reply_name_visible(p_plan uuid, p_who uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from plans p join circle_members m
                   on m.circle_id = p.circle_id and m.parent_id = p_who
                  where p.id = p_plan and m.status = 'approved' and m.show_names);
$$;
grant execute on function private.reply_name_visible(uuid, uuid) to authenticated;

drop policy if exists "members see replies" on plan_replies;
create policy "members see replies" on plan_replies for select using (
  exists (select 1 from plans p where p.id = plan_replies.plan_id)
  and not private.is_blocked_pair(parent_id)
  and (parent_id = auth.uid()
       or exists (select 1 from plans h where h.id = plan_replies.plan_id and h.host_id = auth.uid())
       or private.reply_name_visible(plan_id, parent_id))
);

-- Totals for every activity you can see, whoever chose to show their name.
create or replace function reply_counts()
returns table (plan_id uuid, status text, n int)
language sql stable security definer set search_path = public as $$
  select r.plan_id, r.status, count(*)::int
  from plan_replies r join plans p on p.id = r.plan_id
  where r.status in ('going', 'maybe')
    and p.ends_at >= now() - interval '2 days'
    and is_member(p.circle_id)
    and not private.is_blocked_pair(p.host_id)
    and not private.is_hidden_from(p.host_id)
    and not private.is_plan_hidden(p.id)
    and not private.is_blocked_pair(r.parent_id)
  group by r.plan_id, r.status;
$$;

-- ---------------------------------------------------------------------------
-- 3. "Leave by" reminders
-- ---------------------------------------------------------------------------
create table if not exists leave_reminders (
  plan_id   uuid not null references plans(id) on delete cascade,
  parent_id uuid not null references parents(id) on delete cascade,
  remind_at timestamptz not null,
  sent_at   timestamptz,
  primary key (plan_id, parent_id)
);
create index if not exists leave_reminders_due on leave_reminders (remind_at) where sent_at is null;
alter table leave_reminders enable row level security;
drop policy if exists "own reminders" on leave_reminders;
create policy "own reminders" on leave_reminders for select using (parent_id = auth.uid());
revoke all on leave_reminders from anon, authenticated;
grant select on leave_reminders to authenticated;

create or replace function set_leave_reminder(p_plan uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = public as $$
declare pe timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not exists (select 1 from plan_replies where plan_id = p_plan and parent_id = auth.uid()
                  and status in ('going', 'maybe')) then
    raise exception 'Reply to the activity first.';
  end if;
  select ends_at into pe from plans where id = p_plan;
  if pe is null then raise exception 'That activity is no longer there.'; end if;
  if p_at <= now() then raise exception 'That time has already passed.'; end if;
  if p_at > pe then raise exception 'Pick a time before the activity ends.'; end if;
  insert into leave_reminders (plan_id, parent_id, remind_at) values (p_plan, auth.uid(), p_at)
  on conflict (plan_id, parent_id) do update set remind_at = excluded.remind_at, sent_at = null;
end $$;

create or replace function clear_leave_reminder(p_plan uuid) returns void
language sql security definer set search_path = public as $$
  delete from leave_reminders where plan_id = p_plan and parent_id = auth.uid();
$$;

-- Taking back your reply (or hitting "Not for me") also cancels the reminder.
create or replace function private.drop_reminder_on_reply_gone() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from leave_reminders where plan_id = old.plan_id and parent_id = old.parent_id;
  return old;
end $$;
drop trigger if exists plan_replies_drop_reminder on plan_replies;
create trigger plan_replies_drop_reminder after delete on plan_replies
  for each row execute function private.drop_reminder_on_reply_gone();

-- Who to notify for one reminder (used only by the send-push function).
create or replace function leave_targets(p_plan uuid, p_parent uuid)
returns table (endpoint text, p256dh text, auth text, host_name text, title text,
               place_name text, starts_at timestamptz, ends_at timestamptz, open_ended boolean)
language sql stable security definer set search_path = public as $$
  select s.endpoint, s.p256dh, s.auth, h.display_name, p.title, p.place_name,
         p.starts_at, p.ends_at, p.open_ended
  from plans p
  join parents h on h.id = p.host_id
  join plan_replies r on r.plan_id = p.id and r.parent_id = p_parent and r.status in ('going', 'maybe')
  join push_subscriptions s on s.parent_id = p_parent
  where p.id = p_plan;
$$;

-- Runs every minute (see the schedule at the bottom): sends reminders that are due.
create or replace function private.send_due_reminders() returns void
language plpgsql security definer set search_path = public as $$
declare cfg record; r record;
begin
  select url, secret into cfg from private.push_config where id = 1;
  for r in
    select plan_id, parent_id, remind_at from leave_reminders
     where sent_at is null and remind_at <= now()
     for update skip locked
  loop
    begin
      -- Anything more than 30 minutes late (server was off, push not set up yet) is dropped, not sent.
      if cfg.url is not null and cfg.url not like 'PASTE%' and r.remind_at > now() - interval '30 minutes' then
        perform net.http_post(
          url := cfg.url,
          body := jsonb_build_object('kind', 'leave', 'plan_id', r.plan_id, 'parent_id', r.parent_id),
          headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cfg.secret));
      end if;
    exception when others then
      null;
    end;
    update leave_reminders set sent_at = now() where plan_id = r.plan_id and parent_id = r.parent_id;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Joining: secret word + name choice
-- ---------------------------------------------------------------------------
drop function if exists join_circle(text);
create or replace function join_circle(p_code text, p_word text default null, p_show_names boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare c circles%rowtype; existing text; k circle_keywords%rowtype;
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

  select * into k from circle_keywords where circle_id = c.id;
  if found then
    if p_word is null or length(trim(p_word)) = 0 then raise exception 'Pick a word to continue.'; end if;
    if lower(trim(p_word)) <> lower(k.secret) then
      -- One try. Wrong pick: same friendly "ok" as everyone, but they are quietly parked as removed.
      insert into circle_members (circle_id, parent_id, role, status)
        values (c.id, auth.uid(), 'member', 'removed')
      on conflict (circle_id, parent_id) do update set status = 'removed'
        where circle_members.status in ('declined', 'pending');
      return 'ok';
    end if;
  end if;

  insert into circle_members (circle_id, parent_id, role, status, show_names)
    values (c.id, auth.uid(), 'member', 'pending', coalesce(p_show_names, false))
  on conflict (circle_id, parent_id) do update
    set status = 'pending', show_names = coalesce(p_show_names, false)
    where circle_members.status = 'declined';
  return 'ok';
end $$;

-- ---------------------------------------------------------------------------
-- 5. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function
  set_circle_keyword(uuid, text, text[]), clear_circle_keyword(uuid), get_circle_keyword(uuid),
  circle_join_options(text), set_show_names(uuid, boolean), reply_counts(),
  set_leave_reminder(uuid, timestamptz), clear_leave_reminder(uuid),
  join_circle(text, text, boolean), leave_targets(uuid, uuid), private.send_due_reminders()
from public, anon, authenticated;
grant execute on function
  set_circle_keyword(uuid, text, text[]), clear_circle_keyword(uuid), get_circle_keyword(uuid),
  circle_join_options(text), set_show_names(uuid, boolean), reply_counts(),
  set_leave_reminder(uuid, timestamptz), clear_leave_reminder(uuid),
  join_circle(text, text, boolean)
to authenticated;
grant execute on function leave_targets(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 6. Schedule the reminder sender (every minute) with pg_cron.
--    If this part says "pg_cron" is not available: Supabase > Database > Extensions > turn on
--    pg_cron, then run this whole file again.
-- ---------------------------------------------------------------------------
do $$ begin
  begin
    create extension if not exists pg_cron;
    perform cron.schedule('popby-leave-reminders', '* * * * *', 'select private.send_due_reminders()');
  exception when others then
    raise notice 'pg_cron is not switched on yet. Turn it on (Database > Extensions), then run this file again so reminders can be sent. Everything else works without it.';
  end;
end $$;
