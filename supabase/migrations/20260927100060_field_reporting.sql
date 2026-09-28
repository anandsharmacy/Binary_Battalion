-- Field reporting: persist incidents and tasks (DELIVERY_GAP_PLAN 3.2).
--   * road_incidents gains the fields the web/Flutter clients show, plus plain lat/lng.
--   * field_tasks: follow-up work created from an incident, with a verification step.
--   * Private Storage bucket incident-evidence for photos/videos.
--   * RLS scoped by role and district: control room sees everything, district and field officers
--     see their own district, reporters and assignees always see their own rows.

-- Helpers ---------------------------------------------------------------------------------------
create function public.my_district_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select ur.district_id from public.user_roles ur where ur.user_id = auth.uid() and ur.is_active
$$;

-- True when the caller may see/act on rows of this district (control room: every district).
create function public.in_my_scope(p_district uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    public.has_role('control_room')
    or (public.my_role() in ('district_officer', 'field_officer') and p_district = public.my_district_id()),
    false)
$$;

-- road_incidents ------------------------------------------------------------------------------
alter table public.road_incidents
  add column title          text,
  add column location_text  text,
  add column route_text     text,
  add column lat            double precision check (lat between -90 and 90),
  add column lng            double precision check (lng between -180 and 180),
  add column verification   text not null default 'pending' check (verification in ('pending', 'verified', 'rejected')),
  add column assigned_to    uuid references auth.users (id),
  add column evidence_paths text[] not null default '{}',
  alter column reporter_id set default auth.uid();

-- Web status values need two more states: under_review and active (verified, work under way).
alter table public.road_incidents drop constraint road_incidents_status_check;
alter table public.road_incidents add constraint road_incidents_status_check
  check (status in ('reported', 'under_review', 'verified', 'active', 'assigned', 'escalated', 'resolved', 'rejected'));

create index road_incidents_district_idx on public.road_incidents (district_id, created_at desc);
create index road_incidents_reporter_idx on public.road_incidents (reporter_id);
create index road_incidents_assigned_idx on public.road_incidents (assigned_to) where assigned_to is not null;
create index road_incidents_evidence_idx on public.road_incidents using gin (evidence_paths);

-- Fill district from the reporter, geography from lat/lng, and verified_by on verification.
create function public.road_incidents_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.district_id := coalesce(new.district_id, public.my_district_id());
  end if;
  if new.lat is not null and new.lng is not null then
    new.location := extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography;
  end if;
  if new.verification is distinct from 'pending'
     and (tg_op = 'INSERT' or new.verification is distinct from old.verification) then
    new.verified_by := auth.uid();
  end if;
  return new;
end $$;
create trigger road_incidents_fill before insert or update on public.road_incidents
  for each row execute function public.road_incidents_fill();

-- Replace the read-everything officer policies with district-scoped ones.
drop policy incidents_read_officer   on public.road_incidents;
drop policy incidents_officer_update on public.road_incidents;
create policy incidents_read_scope on public.road_incidents for select to authenticated
  using (public.in_my_scope(district_id) or assigned_to = auth.uid());
create policy incidents_update_scope on public.road_incidents for update to authenticated
  using (public.in_my_scope(district_id) or assigned_to = auth.uid())
  with check (public.in_my_scope(district_id) or assigned_to = auth.uid());
-- incidents_read_own and incidents_insert (reporter_id = auth.uid()) stay as they are.

-- field_tasks ---------------------------------------------------------------------------------
create table public.field_tasks (
  id                uuid primary key default gen_random_uuid(),
  client_id         text unique,
  incident_id       uuid references public.road_incidents (id) on delete set null,
  title             text not null,
  description       text,
  location_text     text,
  priority          text not null default 'moderate' check (priority in ('critical', 'high', 'moderate', 'info')),
  status            text not null default 'new'
    check (status in ('new', 'in_progress', 'completed', 'escalated', 'awaiting_verification', 'verified', 'rejected')),
  assigned_to       uuid references auth.users (id),
  district_id       uuid references public.locations (id),
  created_by        uuid default auth.uid() references auth.users (id),
  deadline          timestamptz,
  verification_note text,
  verified_by       uuid references auth.users (id),
  assigned_at       timestamptz,
  started_at        timestamptz,
  completed_at      timestamptz,
  verified_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index field_tasks_district_idx on public.field_tasks (district_id, created_at desc);
create index field_tasks_assigned_idx on public.field_tasks (assigned_to) where assigned_to is not null;
create index field_tasks_incident_idx on public.field_tasks (incident_id);

create trigger field_tasks_touch before update on public.field_tasks
  for each row execute function public.touch_updated_at();

-- Timestamps are set by the server so every client computes response time the same way.
-- Only district officers and the control room can decide a verification.
create function public.field_tasks_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_old_status text := case when tg_op = 'UPDATE' then old.status end;
  v_old_assignee uuid := case when tg_op = 'UPDATE' then old.assigned_to end;
begin
  if tg_op = 'INSERT' then
    new.district_id := coalesce(new.district_id,
      (select ri.district_id from public.road_incidents ri where ri.id = new.incident_id),
      public.my_district_id());
  end if;
  if new.assigned_to is not null and new.assigned_to is distinct from v_old_assignee then
    new.assigned_at := now();
  end if;
  if new.status is distinct from v_old_status then
    if (new.status in ('verified', 'rejected') or v_old_status = 'verified')
       and coalesce(public.my_role() not in ('district_officer', 'control_room'), true) then
      raise exception 'Only a district officer or the control room can review a task' using errcode = '42501';
    end if;
    if new.status in ('verified', 'rejected') then
      if v_old_status is distinct from 'awaiting_verification' then
        raise exception 'Only a task awaiting verification can be reviewed' using errcode = '22023';
      end if;
      new.verified_by := auth.uid();
      new.verified_at := now();
    elsif new.status = 'awaiting_verification' then
      -- from completed (field officer asks), or back from a decision (reviewer's undo / resubmission)
      if coalesce(v_old_status not in ('completed', 'verified', 'rejected'), true) then
        raise exception 'Only a completed task can be sent for verification' using errcode = '22023';
      end if;
      new.verified_by := null;
      new.verified_at := null;
    end if;
    if new.status = 'in_progress' and new.started_at is null then new.started_at := now(); end if;
    if new.status = 'completed' and new.completed_at is null then new.completed_at := now(); end if;
  end if;
  return new;
end $$;
create trigger field_tasks_fill before insert or update on public.field_tasks
  for each row execute function public.field_tasks_fill();

alter table public.field_tasks enable row level security;
create policy field_tasks_read on public.field_tasks for select to authenticated
  using (public.in_my_scope(district_id) or assigned_to = auth.uid() or created_by = auth.uid());
create policy field_tasks_insert on public.field_tasks for insert to authenticated
  with check (created_by = auth.uid()
    and public.my_role() in ('district_officer', 'control_room')
    and public.in_my_scope(district_id));
create policy field_tasks_update on public.field_tasks for update to authenticated
  using (public.in_my_scope(district_id) or assigned_to = auth.uid())
  with check (public.in_my_scope(district_id) or assigned_to = auth.uid());
create policy field_tasks_delete on public.field_tasks for delete to authenticated
  using (public.my_role() in ('district_officer', 'control_room') and public.in_my_scope(district_id));

grant select, insert, update, delete on public.field_tasks to authenticated;

-- Realtime ------------------------------------------------------------------------------------
-- road_incidents is already in the publication (20260924000002).
alter publication supabase_realtime add table public.field_tasks;

-- Storage: incident-evidence ------------------------------------------------------------------
-- Objects live under {uploader uid}/{client_id}/{file}. The uploader reads their own folder;
-- anyone who can see an incident (RLS on road_incidents applies inside the subquery) can read
-- the files listed in its evidence_paths.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('incident-evidence', 'incident-evidence', false, 20971520,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'video/mp4', 'video/quicktime', 'video/webm'])
on conflict (id) do nothing;

create policy evidence_insert_own on storage.objects for insert to authenticated
  with check (bucket_id = 'incident-evidence'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.is_active_user());
create policy evidence_update_own on storage.objects for update to authenticated
  using (bucket_id = 'incident-evidence' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'incident-evidence' and (storage.foldername(name))[1] = auth.uid()::text);
create policy evidence_read on storage.objects for select to authenticated
  using (bucket_id = 'incident-evidence' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.road_incidents ri where storage.objects.name = any (ri.evidence_paths))));

-- Grants ----------------------------------------------------------------------------------------
revoke execute on function public.my_district_id(), public.in_my_scope(uuid),
  public.road_incidents_fill(), public.field_tasks_fill() from public, anon, authenticated;
grant execute on function public.my_district_id(), public.in_my_scope(uuid) to authenticated;
