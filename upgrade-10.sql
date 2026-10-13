-- Pop-by upgrade 10: optional first and last name on your Profile.
-- These are PRIVATE: only you can see them (they are not shown to anyone in your circles).
-- Safe to run more than once. Paste into Supabase > SQL Editor and Run (after upgrade-9.sql).

create table if not exists profiles_private (
  parent_id  uuid primary key references parents(id) on delete cascade,
  first_name text check (first_name is null or char_length(first_name) <= 40),
  last_name  text check (last_name  is null or char_length(last_name)  <= 40)
);
alter table profiles_private enable row level security;
drop policy if exists "own private profile" on profiles_private;
create policy "own private profile" on profiles_private for all
  using (parent_id = auth.uid()) with check (parent_id = auth.uid());
revoke all on profiles_private from anon;
grant select, insert, update, delete on profiles_private to authenticated;
