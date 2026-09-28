-- Alert pipeline (DELIVERY_GAP_PLAN 3.3): acknowledge/resolve RPC, per-user notification
-- preferences, FCM device tokens, and high-severity road incidents raising alerts.
-- The delivery webhook (alerts INSERT -> notify edge function) is NOT here: it needs the
-- project URL and a shared secret in Vault. See supabase/functions/notify/webhook.sql.

-- Alerts: who resolved it ----------------------------------------------------------------------
alter table public.alerts
  add column resolved_by uuid references auth.users (id),
  add column resolved_at timestamptz;
create index alerts_created_idx on public.alerts (created_at desc);

-- Officers see alerts for their own district plus district-less ones (ML, statewide); the control
-- room sees all. Mirrors the road_incidents scoping in 20260927100060 (inline: that helper is created later).
create function public.alert_in_my_scope(p_district uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.has_role('control_room')
      or (public.is_officer() and (p_district is null or p_district =
            (select ur.district_id from public.user_roles ur where ur.user_id = auth.uid())))
$$;
drop policy alerts_read on public.alerts;
drop policy alerts_update on public.alerts;
create policy alerts_read on public.alerts for select to authenticated using (public.alert_in_my_scope(district_id));
create policy alerts_update on public.alerts for update to authenticated
  using (public.alert_in_my_scope(district_id)) with check (public.alert_in_my_scope(district_id));

-- Acknowledge / resolve. The actor is always auth.uid(); clients can't claim someone else did it.
create function public.set_alert_status(p_alert_id uuid, p_status text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_officer() then raise exception 'officers only' using errcode = '42501'; end if;
  if p_status not in ('acknowledged', 'resolved') then
    raise exception 'status must be acknowledged or resolved' using errcode = '22023';
  end if;
  update public.alerts a set
    status          = case when a.status = 'resolved' then a.status else p_status end,
    acknowledged_by = coalesce(a.acknowledged_by, auth.uid()),
    acknowledged_at = coalesce(a.acknowledged_at, now()),
    resolved_by     = case when p_status = 'resolved' then coalesce(a.resolved_by, auth.uid()) else a.resolved_by end,
    resolved_at     = case when p_status = 'resolved' then coalesce(a.resolved_at, now()) else a.resolved_at end
  where a.id = p_alert_id and public.alert_in_my_scope(a.district_id);
  if not found then raise exception 'alert not found' using errcode = 'P0002'; end if;
  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), 'alert_' || p_status, 'alerts', p_alert_id::text, null);
end $$;

-- Notification preferences: one row per user; a missing row means the defaults below. ----------
create table public.notification_prefs (
  user_id    uuid primary key references auth.users (id) on delete cascade default auth.uid(),
  push       boolean not null default true,
  email      boolean not null default true,
  sms        boolean not null default false,
  updated_at timestamptz not null default now()
);
create trigger notification_prefs_touch before update on public.notification_prefs
  for each row execute function public.touch_updated_at();

alter table public.notification_prefs enable row level security;
create policy notification_prefs_own on public.notification_prefs for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.notification_prefs to authenticated;

-- FCM registration tokens. Written through register_device_token so a phone that changes hands
-- moves its token to the new user (a plain upsert would hit the old owner's row under RLS).
create table public.device_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  platform   text not null check (platform in ('android', 'ios', 'web')),
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;
create policy device_tokens_own_read   on public.device_tokens for select to authenticated using (user_id = auth.uid());
create policy device_tokens_own_delete on public.device_tokens for delete to authenticated using (user_id = auth.uid());
grant select, delete on public.device_tokens to authenticated;

create function public.register_device_token(p_token text, p_platform text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;
  if coalesce(length(p_token), 0) not between 20 and 4096 then
    raise exception 'invalid token' using errcode = '22023';
  end if;
  insert into public.device_tokens (token, user_id, platform, updated_at)
  values (p_token, auth.uid(), p_platform, now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end $$;

revoke execute on function public.set_alert_status(uuid, text), public.register_device_token(text, text), public.alert_in_my_scope(uuid) from public, anon;
grant execute on function public.set_alert_status(uuid, text), public.register_device_token(text, text), public.alert_in_my_scope(uuid) to authenticated;

-- High/critical road incidents raise an alert --------------------------------------------------
-- plpgsql + to_jsonb(new): reads Agent 6's optional title/location_text when that migration has
-- run, without depending on those columns at CREATE time.
create function public.raise_alert_from_incident()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  j       jsonb := to_jsonb(new);
  v_label text  := initcap(replace(new.incident_type, '_', ' '));
begin
  insert into public.alerts (title, description, severity, source, district_id, route_id, incident_id, created_by)
  values (
    coalesce(nullif(j->>'title', ''), v_label || ' reported')
      || coalesce(' · ' || nullif(j->>'location_text', ''), ''),
    new.description,
    new.severity,
    'rule',
    new.district_id,
    new.route_id,
    new.id,
    new.reporter_id
  );
  return new;
end $$;

create trigger road_incidents_raise_alert after insert on public.road_incidents
  for each row when (new.severity in ('critical', 'high'))
  execute function public.raise_alert_from_incident();
revoke execute on function public.raise_alert_from_incident() from public, anon, authenticated;  -- Agent 7: trigger-only
