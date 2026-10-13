-- Pop-by upgrade 9: lets the database send Supabase's public key when it calls the push function.
-- Fixes the "No API key found in request" error (status 401) in net._http_response.
-- Safe to run more than once. Paste into Supabase > SQL Editor and Run (after upgrade-8.sql).
-- Afterwards run ONE more line yourself (see push-key.sql) to save your public (anon) key.

alter table private.push_config add column if not exists anon_key text;

create or replace function private.push_headers(cfg private.push_config) returns jsonb
language sql immutable as $$
  select jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', cfg.secret)
         || case when cfg.anon_key is not null and cfg.anon_key not like 'PASTE%'
                 then jsonb_build_object('apikey', cfg.anon_key, 'Authorization', 'Bearer ' || cfg.anon_key)
                 else '{}'::jsonb end;
$$;

create or replace function private.notify_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg private.push_config;
begin
  begin
    select * into cfg from private.push_config where id = 1;
    if cfg.url is not null and cfg.url not like 'PASTE%' then
      perform net.http_post(
        url := cfg.url,
        body := jsonb_build_object('plan_id', new.id,
                  'kind', case when tg_op = 'INSERT' then 'new' else 'updated' end),
        headers := private.push_headers(cfg));
    end if;
  exception when others then
    null;
  end;
  return new;
end $$;

create or replace function private.send_due_reminders() returns void
language plpgsql security definer set search_path = public as $$
declare cfg private.push_config; r record;
begin
  select * into cfg from private.push_config where id = 1;
  for r in
    select plan_id, parent_id, remind_at from leave_reminders
     where sent_at is null and remind_at <= now()
     for update skip locked
  loop
    begin
      if cfg.url is not null and cfg.url not like 'PASTE%' and r.remind_at > now() - interval '30 minutes' then
        perform net.http_post(
          url := cfg.url,
          body := jsonb_build_object('kind', 'leave', 'plan_id', r.plan_id, 'parent_id', r.parent_id),
          headers := private.push_headers(cfg));
      end if;
    exception when others then
      null;
    end;
    update leave_reminders set sent_at = now() where plan_id = r.plan_id and parent_id = r.parent_id;
  end loop;
end $$;

revoke all on function private.push_headers(private.push_config) from public, anon, authenticated;
revoke all on function private.send_due_reminders() from public, anon, authenticated;
