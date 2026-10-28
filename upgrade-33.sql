-- Upgrade 33: an optional "area" for each circle, used only to choose which local sponsors its members see.
-- * The organiser can type a town or postcode start (for example "Milton Keynes" or "MK7"), up to 40 characters.
-- * It is shown to members of that circle, but NOT to people who only have the invite code.
-- * It is never shown to sponsors. Sponsors only see counts of views, taps and hides.
-- * Never put a street address in it. It goes through the same swearing and web-link filter as the circle name.
-- Safe to run more than once. Run it BEFORE uploading the new index.html.
-- If Supabase offers "Run and enable RLS", either choice is fine: this script creates no tables.

alter table circles add column if not exists area text;

do $$ begin
  alter table circles add constraint circles_area_len
    check (area is null or char_length(area) between 1 and 40);
exception when duplicate_object then null; end $$;

drop trigger if exists rude_circles on public.circles;
create trigger rude_circles before insert or update on public.circles
  for each row execute function private.rude_check('name','description','area');

create or replace function set_circle_area(p_circle uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare a text := nullif(trim(coalesce(p_text, '')), '');
begin
  if not is_organiser(p_circle) then raise exception 'Only an organiser can do that'; end if;
  if a is not null and char_length(a) > 40 then
    raise exception 'Keep the area to 40 characters or fewer.';
  end if;
  update circles set area = a where id = p_circle;
end $$;

revoke all on function set_circle_area(uuid, text) from public, anon;
grant execute on function set_circle_area(uuid, text) to authenticated;
