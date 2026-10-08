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
