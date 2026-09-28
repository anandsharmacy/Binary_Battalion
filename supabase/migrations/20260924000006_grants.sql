-- Data API grants. New Supabase projects do not auto-grant table or function access, so nothing
-- works until this runs. RLS (enabled on every table) stays the real boundary.

grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

-- Tables written only by RPCs / triggers / the publisher: clients get read access at most.
revoke insert, update, delete on
  public.ml_model_versions, public.ml_batch_runs, public.ml_coverage, public.ml_segments,
  public.ml_route_risk_snapshots, public.rider_locations, public.rider_location_history,
  public.rider_profiles, public.audit_log, public.locations
from authenticated;
revoke insert, delete on public.user_roles, public.profiles from authenticated;

-- Functions: closed by default, then open the client-facing ones to signed-in users only.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

grant execute on function
  public.my_role(), public.has_role(text), public.is_officer(), public.is_active_user(), public.my_district_name(),
  public.sync_rider_locations(jsonb), public.set_rider_duty(boolean, text, text), public.get_my_rider_context(),
  public.get_active_riders(integer), public.get_rider_trail(uuid, timestamptz, integer),
  public.ml_status(), public.get_route_ml_risk(text, jsonb, date, integer), public.get_routes_ml_summary(),
  public.get_my_routes_ml_risk(), public.get_ml_top_alerts(date, text, integer, text),
  public.get_ml_segments_in_bbox(double precision, double precision, double precision, double precision, text, integer),
  public.promote_ml_alert(text, bigint, text),
  public.record_route_risk_snapshot(text, text, jsonb, bigint, text, text, text)
to authenticated;

-- Guard: fail the migration if any public table was left without RLS.
do $$
declare t text;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity loop
    raise exception 'RLS is not enabled on public.%', t;
  end loop;
end $$;
