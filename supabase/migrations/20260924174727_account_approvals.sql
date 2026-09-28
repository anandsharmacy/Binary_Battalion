-- Account approvals.
--   field officer    -> starts inactive; approved by a district officer of the same district, or the control room
--   district officer -> starts inactive; approved by the control room
--   control room     -> active immediately (sign-up left open for now; close it by removing
--                       'control_room' from the is_active list in handle_new_user)
--   rider            -> active immediately (unchanged)
-- Rejecting an account deactivates its profile, so my_role() stays null and it can't sign in.

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

  insert into public.user_roles (user_id, role, district_id, is_active)
  values (new.id, v_role, v_loc, v_role in ('rider', 'control_room'));

  if v_role = 'rider' then
    insert into public.rider_profiles (user_id, phone, vehicle_registration)
    values (new.id, nullif(trim(m->>'phone'), ''), nullif(upper(trim(m->>'vehicle_registration')), ''));
  end if;
  return new;
end $$;

-- Can the signed-in user review this pending account? Control room: any non-rider account.
-- District officer: field officers of their own district.
create or replace function public.can_review_account(p_role public.user_role_enum, p_district uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (public.has_role('control_room') and p_role <> 'rider')
    or (public.has_role('district_officer') and p_role = 'field_officer'
        and p_district = (select ur.district_id from public.user_roles ur where ur.user_id = auth.uid())),
    false)
$$;

-- Pending sign-ups the caller may review, oldest first.
create or replace function public.pending_accounts()
returns table (user_id uuid, full_name text, email text, role text, district text, state text, requested_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select ur.user_id, p.full_name, u.email::text, ur.role::text, l.name, l.state, ur.created_at
  from public.user_roles ur
  join public.profiles p on p.id = ur.user_id
  join auth.users u on u.id = ur.user_id
  left join public.locations l on l.id = ur.district_id
  where not ur.is_active and p.is_active
    and public.can_review_account(ur.role, ur.district_id)
  order by ur.created_at
$$;

-- Approve (activate the role) or reject (deactivate the profile) one pending sign-up.
create or replace function public.review_account(p_user_id uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.user_roles%rowtype;
begin
  select ur.* into r from public.user_roles ur
  join public.profiles p on p.id = ur.user_id
  where ur.user_id = p_user_id and not ur.is_active and p.is_active;
  if not found then
    raise exception 'This account has no pending request.' using errcode = 'P0002';
  end if;
  if not public.can_review_account(r.role, r.district_id) then
    raise exception 'You are not allowed to review this account.' using errcode = '42501';
  end if;

  if p_approve then
    update public.user_roles set is_active = true where user_id = p_user_id;
  else
    update public.profiles set is_active = false where id = p_user_id;
  end if;

  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), case when p_approve then 'account_approved' else 'account_rejected' end,
          'user_roles', p_user_id::text, jsonb_build_object('role', r.role));
end $$;

-- Signed-in users only (every new function is executable by PUBLIC by default).
revoke execute on function public.can_review_account(public.user_role_enum, uuid), public.pending_accounts(),
  public.review_account(uuid, boolean) from public, anon;
grant execute on function public.pending_accounts(), public.review_account(uuid, boolean) to authenticated;
