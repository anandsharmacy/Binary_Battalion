-- Role helpers, sign-up trigger, RLS and Realtime.

-- Helpers are SECURITY DEFINER so policies can call them without recursing into RLS.
create function public.my_role() returns text
language sql stable security definer set search_path = '' as $$
  select ur.role::text from public.user_roles ur
  join public.profiles p on p.id = ur.user_id
  where ur.user_id = auth.uid() and ur.is_active and p.is_active
$$;

create function public.has_role(p_role text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.my_role() = p_role
$$;

create function public.is_officer() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.my_role() in ('field_officer', 'district_officer', 'control_room'), false)
$$;

create function public.is_active_user() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.my_role() is not null
$$;

create function public.my_district_name() returns text
language sql stable security definer set search_path = '' as $$
  select l.name from public.user_roles ur
  join public.locations l on l.id = ur.district_id
  where ur.user_id = auth.uid() and ur.is_active
$$;

create function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger profiles_touch      before update on public.profiles       for each row execute function public.touch_updated_at();
create trigger shipments_touch     before update on public.shipments      for each row execute function public.touch_updated_at();
create trigger rider_profiles_touch before update on public.rider_profiles for each row execute function public.touch_updated_at();
create trigger road_incidents_touch before update on public.road_incidents for each row execute function public.touch_updated_at();

-- Sign-up: the clients send full_name, district, state, requested_role, phone, vehicle_registration
-- as auth metadata. Riders and field officers are active straight away. District officers and
-- the control room start INACTIVE until a control-room user activates them (user_roles update
-- policy below), so nobody can self-register into a privileged role.
create function public.handle_new_user() returns trigger
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

  insert into public.user_roles (user_id, role, district_id, is_active)
  values (new.id, v_role, v_loc, v_role in ('rider', 'field_officer'));

  if v_role = 'rider' then
    insert into public.rider_profiles (user_id, phone, vehicle_registration)
    values (new.id, nullif(trim(m->>'phone'), ''), nullif(upper(trim(m->>'vehicle_registration')), ''));
  end if;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- RLS ------------------------------------------------------------------------------------------
alter table public.locations               enable row level security;
alter table public.profiles                enable row level security;
alter table public.user_roles              enable row level security;
alter table public.routes                  enable row level security;
alter table public.shipments               enable row level security;
alter table public.road_incidents          enable row level security;
alter table public.alerts                  enable row level security;
alter table public.audit_log               enable row level security;
alter table public.rider_profiles          enable row level security;
alter table public.rider_locations         enable row level security;
alter table public.rider_location_history  enable row level security;

create policy locations_read on public.locations for select to authenticated using (true);

create policy profiles_read_own     on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_read_officer on public.profiles for select to authenticated using (public.is_officer());
create policy profiles_update_own   on public.profiles for update to authenticated
  using (id = auth.uid() and is_active) with check (id = auth.uid() and is_active);
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.has_role('control_room')) with check (public.has_role('control_room'));

create policy user_roles_read_own     on public.user_roles for select to authenticated using (user_id = auth.uid());
create policy user_roles_read_officer on public.user_roles for select to authenticated using (public.is_officer());
create policy user_roles_admin_update on public.user_roles for update to authenticated
  using (public.has_role('control_room')) with check (public.has_role('control_room'));

create policy routes_read  on public.routes for select to authenticated using (public.is_active_user());
create policy routes_write on public.routes for all to authenticated
  using (public.my_role() in ('control_room', 'district_officer'))
  with check (public.my_role() in ('control_room', 'district_officer'));

create policy shipments_officer on public.shipments for select to authenticated using (public.is_officer());
create policy shipments_rider   on public.shipments for select to authenticated
  using (rider_id = auth.uid() and public.has_role('rider'));
create policy shipments_write   on public.shipments for all to authenticated
  using (public.my_role() in ('control_room', 'district_officer'))
  with check (public.my_role() in ('control_room', 'district_officer'));
create policy shipments_rider_update on public.shipments for update to authenticated
  using (rider_id = auth.uid() and public.has_role('rider'))
  with check (rider_id = auth.uid() and public.has_role('rider'));

create policy incidents_read_officer on public.road_incidents for select to authenticated using (public.is_officer());
create policy incidents_read_own     on public.road_incidents for select to authenticated using (reporter_id = auth.uid());
create policy incidents_insert       on public.road_incidents for insert to authenticated
  with check (reporter_id = auth.uid() and public.is_active_user());
create policy incidents_officer_update on public.road_incidents for update to authenticated
  using (public.is_officer()) with check (public.is_officer());

create policy alerts_read   on public.alerts for select to authenticated using (public.is_officer());
create policy alerts_insert on public.alerts for insert to authenticated
  with check (public.is_officer() and created_by = auth.uid() and source = 'human');
create policy alerts_update on public.alerts for update to authenticated
  using (public.is_officer()) with check (public.is_officer());

create policy audit_read on public.audit_log for select to authenticated using (public.has_role('control_room'));

-- Riders: own rows only; officers read all rider rows. Writes go through the RPCs (no write policies).
create policy rider_profiles_own     on public.rider_profiles for select to authenticated using (user_id = auth.uid());
create policy rider_profiles_officer on public.rider_profiles for select to authenticated using (public.is_officer());
create policy rider_locations_own     on public.rider_locations for select to authenticated using (user_id = auth.uid());
create policy rider_locations_officer on public.rider_locations for select to authenticated using (public.is_officer());
create policy rider_history_own     on public.rider_location_history for select to authenticated using (user_id = auth.uid());
create policy rider_history_officer on public.rider_location_history for select to authenticated using (public.is_officer());

-- Realtime -------------------------------------------------------------------------------------
alter table public.rider_locations replica identity full;
alter table public.rider_profiles  replica identity full;
alter publication supabase_realtime add table
  public.rider_locations, public.rider_profiles, public.shipments, public.alerts, public.road_incidents;
