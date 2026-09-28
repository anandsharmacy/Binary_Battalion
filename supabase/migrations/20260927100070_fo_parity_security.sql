-- Field-officer form parity (web ReportIncident == Flutter ReportScreen) and two security fixes.
--   * road_incidents gains the report fields both forms now send: landmark, road_condition,
--     vehicles_affected, estimated_blockage.
--   * A report whose reporter has no district falls back to the nearest district by GPS, so the
--     district officer sees it (previously district_id stayed null and only the control room saw it).
--   * Field officers can no longer insert a report that is already verified/active: an unreviewed
--     report could otherwise mark a corridor blocked (get_corridor_accessibility).
--   * Self-registered control_room accounts start inactive and need approval, like every officer role.

alter table public.road_incidents
  add column landmark           text,
  add column road_condition     text check (road_condition in ('fully_blocked', 'partially_accessible', 'passable_with_caution')),
  add column vehicles_affected  integer check (vehicles_affected >= 0),
  add column estimated_blockage text;

create or replace function public.road_incidents_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    -- Only reviewers may create a report that skips review.
    if coalesce(public.my_role() not in ('district_officer', 'control_room'), true) then
      new.status := 'reported';
      new.verification := 'pending';
    end if;
  end if;
  if new.lat is not null and new.lng is not null then
    new.location := extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography;
  end if;
  if tg_op = 'INSERT' then
    new.district_id := coalesce(new.district_id, public.my_district_id(),
      (select l.id from public.locations l
       where new.location is not null and l.kind = 'district' and l.geom is not null
       order by l.geom operator(extensions.<->) new.location limit 1));
  end if;
  if new.verification is distinct from 'pending'
     and (tg_op = 'INSERT' or new.verification is distinct from old.verification) then
    new.verified_by := auth.uid();
  end if;
  return new;
end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  m        jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_role   public.user_role_enum;
  v_loc    uuid;
begin
  v_role := case m->>'requested_role'
    when 'rider'            then 'rider'
    when 'district_officer' then 'district_officer'
    when 'control_room'     then 'control_room'
    else 'field_officer'
  end::public.user_role_enum;

  select l.id into v_loc from public.locations l
  where nullif(trim(m->>'district'), '') is not null
    and lower(l.name) = lower(trim(m->>'district'))
    and (nullif(trim(m->>'state'), '') is null or lower(l.state) = lower(trim(m->>'state')))
  order by l.kind = 'district' desc limit 1;

  insert into public.profiles (id, full_name, officer_id, phone, region)
  values (new.id, nullif(trim(m->>'full_name'), ''), nullif(trim(m->>'officer_id'), ''),
          nullif(trim(m->>'phone'), ''), nullif(trim(coalesce(m->>'district', m->>'state', '')), ''));

  -- Riders only are active immediately. The very first control_room account is switched on by hand:
  --   update public.user_roles set is_active = true where user_id = '<uuid>';
  insert into public.user_roles (user_id, role, district_id, is_active)
  values (new.id, v_role, v_loc, v_role = 'rider');

  if v_role = 'rider' then
    insert into public.rider_profiles (user_id, phone, vehicle_registration)
    values (new.id, nullif(trim(m->>'phone'), ''), nullif(upper(trim(m->>'vehicle_registration')), ''));
  end if;
  return new;
end $$;

revoke execute on function public.road_incidents_fill(), public.handle_new_user() from public, anon, authenticated;
