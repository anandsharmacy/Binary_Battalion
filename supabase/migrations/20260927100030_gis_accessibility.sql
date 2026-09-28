-- Agent 3: server-side corridor accessibility (checklist 2: GIS accessibility dashboard).
--
-- get_corridor_accessibility(p_district) returns, per stored route:
--   status          open | restricted | blocked
--   open_length_pct    share of the route length not affected by open incidents
--                      (blocked stretch counts 0, restricted stretch counts 0.5); null without geometry
--   accessibility_pct  0 when blocked, else open_length_pct
--   incidents       open incidents on the route (route_id match, or within 1 km of its line)
--   ml              mean / max risk percentile of ML segments within 100 m (latest published run)
--
-- Incident scope mirrors road_incidents RLS: control room sees every district (optionally narrowed by
-- p_district, a district name); district / field officers see only their own district. Riders are refused.
--
-- plpgsql on purpose: the body is resolved at call time, so this applies before Agent 6's
-- 20260927100060_field_reporting.sql and uses only road_incidents columns from the core schema.

create or replace function public.get_corridor_accessibility(p_district text default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_role   text := public.my_role();
  v_scope  uuid;
  v_all    boolean;
  v_run    public.ml_batch_runs;
  v_routes jsonb;
begin
  if not public.is_officer() then raise exception 'officers only' using errcode = '42501'; end if;

  if v_role = 'control_room' then
    v_all := nullif(trim(p_district), '') is null;
    if not v_all then
      select l.id into v_scope from public.locations l
       where l.kind = 'district' and lower(l.district) = lower(trim(p_district)) limit 1;
    end if;
  else
    select ur.district_id into v_scope from public.user_roles ur where ur.user_id = auth.uid() and ur.is_active;
    v_all := false;
  end if;

  v_run := public.ml_pick_run(null);

  with inc as (
    select i.id, i.incident_type, i.severity, i.status, i.route_id, i.district_id, i.location, i.created_at,
           (select l.district from public.locations l where l.id = i.district_id) as district,
           -- blocking needs a confirmed report; an unconfirmed critical one only restricts
           (i.status in ('verified', 'active', 'assigned', 'escalated')
             and (i.severity = 'critical' or (i.incident_type in ('road_blockage', 'landslide', 'flood') and i.severity = 'high')))
             as blocks
    from public.road_incidents i
    where i.status not in ('resolved', 'rejected')
      and (v_all or i.district_id = v_scope)
  ),
  per_route as (
    select r.id, r.route_number, r.name, r.origin, r.destination, r.geom,
           extensions.st_length(r.geom) as len_m,
           coalesce((select jsonb_agg(jsonb_build_object(
                       'id', x.id, 'incident_type', x.incident_type, 'severity', x.severity,
                       'status', x.status, 'blocks', x.blocks, 'created_at', x.created_at, 'district', x.district,
                       'lat', extensions.st_y(x.location::extensions.geometry),
                       'lon', extensions.st_x(x.location::extensions.geometry)) order by x.blocks desc, x.created_at desc)
                     from inc x
                     where x.route_id = r.id
                        or (r.geom is not null and x.location is not null and extensions.st_dwithin(x.location, r.geom, 1000))),
                    '[]'::jsonb) as incidents
    from public.routes r
  ),
  scored as (
    select p.*,
           case when exists (select 1 from jsonb_array_elements(p.incidents) e where (e->>'blocks')::boolean) then 'blocked'
                when jsonb_array_length(p.incidents) > 0 then 'restricted'
                else 'open' end as status,
           -- length of the line within 1 km of blocking / other open incidents
           (select extensions.st_length(extensions.st_intersection(p.geom::extensions.geometry,
                     extensions.st_union(extensions.st_buffer(x.location, 1000)::extensions.geometry))::extensions.geography)
              from inc x where x.blocks and x.location is not null and p.geom is not null
               and extensions.st_dwithin(x.location, p.geom, 1000)) as blocked_m,
           (select extensions.st_length(extensions.st_intersection(p.geom::extensions.geometry,
                     extensions.st_union(extensions.st_buffer(x.location, 1000)::extensions.geometry))::extensions.geography)
              from inc x where not x.blocks and x.location is not null and p.geom is not null
               and extensions.st_dwithin(x.location, p.geom, 1000)) as restricted_m,
           (select jsonb_build_object('n_segments', count(*), 'n_alert', count(*) filter (where sc.tier = 'alert'),
                                      'mean_percentile', round(avg(sc.risk_percentile)::numeric, 1),
                                      'max_percentile', max(sc.risk_percentile))
              from public.ml_segments s
              join ml_private.segment_scores sc on sc.run_id = v_run.id and sc.segment_id = s.segment_id
             where v_run.id is not null and p.geom is not null and extensions.st_dwithin(s.geom, p.geom, 100)) as ml
    from per_route p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'route_id', s.id, 'route_number', s.route_number, 'name', s.name,
           'origin', s.origin, 'destination', s.destination,
           'status', s.status,
           'has_geometry', s.geom is not null,
           'length_m', round(s.len_m::numeric),
           'open_length_pct', s.open_pct,
           -- a blocked corridor is cut for through traffic, whatever share of it is still clear
           'accessibility_pct', case when s.status = 'blocked' then 0 else s.open_pct end,
           'blocking_incidents', (select count(*) from jsonb_array_elements(s.incidents) e where (e->>'blocks')::boolean),
           'open_incidents', jsonb_array_length(s.incidents),
           'incidents', s.incidents,
           'ml', case when v_run.id is null or s.geom is null then null else s.ml end,
           'geojson', case when s.geom is null then null
                           else extensions.st_asgeojson(extensions.st_simplify(s.geom::extensions.geometry, 0.0005), 5)::jsonb end
         ) order by s.route_number), '[]'::jsonb)
    into v_routes
    from (select sc.*, case when sc.len_m > 0 then greatest(0, round((100 * (1
                 - (coalesce(sc.blocked_m, 0) + 0.5 * greatest(coalesce(sc.restricted_m, 0) - coalesce(sc.blocked_m, 0), 0)) / sc.len_m))::numeric, 1))
               end as open_pct
          from scored sc) s;

  return jsonb_build_object(
    'generated_at', now(),
    'scope', case when v_all then 'region' else coalesce(v_scope::text, 'none') end,
    'ml', public.ml_meta(v_run),
    'routes', v_routes);
end $$;

revoke execute on function public.get_corridor_accessibility(text) from public, anon;
grant execute on function public.get_corridor_accessibility(text) to authenticated;
