-- ML read RPCs shared by the website (src/lib/ml.ts) and the Flutter app (ml_repository.dart).
-- All SECURITY DEFINER: the database decides what each role sees. Riders never read ml_* tables;
-- they get only their assigned routes or a line they planned themselves.

create function public.ml_pick_run(p_date date default null) returns public.ml_batch_runs
language sql stable security definer set search_path = '' as $$
  select r.* from public.ml_batch_runs r
  where r.status = 'published' and r.scores_pruned_at is null
    and case when p_date is null then r.is_current else r.score_date = p_date end
  order by r.published_at desc limit 1
$$;

-- Every ML answer carries this, so clients can label live / replay / stale / unavailable (ML-008).
create function public.ml_meta(r public.ml_batch_runs) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when r.id is null then jsonb_build_object('state', 'unavailable') else jsonb_build_object(
    'state', case when r.mode = 'replay' then 'replay'
                  when r.expires_at is not null and r.expires_at < now() then 'stale' else 'live' end,
    'run_id', r.id, 'score_date', r.score_date, 'mode', r.mode,
    'model_version', r.bundle_version, 'bundle_hash', r.bundle_hash,
    'published_at', r.published_at, 'expires_at', r.expires_at,
    'caveat', (select mv.policy->>'probability_caveat' from public.ml_model_versions mv where mv.id = r.model_version_id)
  ) end
$$;

-- Risk along one line: matches segments within p_buffer metres, summarises them and lists the
-- alert / review segments in order along the line. Internal; called by the RPCs below.
create function public.ml_route_risk(p_line extensions.geography, p_run public.ml_batch_runs, p_buffer integer)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_geom  extensions.geometry := p_line::extensions.geometry;
  v_len   double precision := extensions.st_length(p_line);
  v_cov   double precision;
  v_n     integer; v_alert integer; v_review integer; v_max real;
  v_worst jsonb; v_segs jsonb; v_band text;
begin
  select extensions.st_length(extensions.st_intersection(v_geom, c.geom::extensions.geometry)::extensions.geography)
         / nullif(v_len, 0)
    into v_cov from public.ml_coverage c where c.id = 1;
  v_cov := coalesce(v_cov, 0);

  with m as (
    select s.segment_id, sc.risk_percentile, sc.tier, sc.tier_rank, s.steep,
           extensions.st_y(s.geom::extensions.geometry) as lat,
           extensions.st_x(s.geom::extensions.geometry) as lon,
           round((extensions.st_linelocatepoint(v_geom, s.geom::extensions.geometry) * v_len)::numeric) as along_m
    from public.ml_segments s
    join ml_private.segment_scores sc on sc.run_id = p_run.id and sc.segment_id = s.segment_id
    where extensions.st_dwithin(s.geom, p_line, p_buffer)
  )
  select count(*), count(*) filter (where tier = 'alert'), count(*) filter (where tier = 'human_review'),
         max(risk_percentile),
         (select to_jsonb(w) from (select segment_id, along_m, lat, lon, risk_percentile, tier, steep
                                   from m order by risk_percentile desc limit 1) w),
         coalesce((select jsonb_agg(to_jsonb(x) order by x.along_m)
                   from (select segment_id, along_m, lat, lon, risk_percentile, tier, steep
                         from m where tier <> 'none' order by tier_rank limit 500) x), '[]'::jsonb)
    into v_n, v_alert, v_review, v_max, v_worst, v_segs
    from m;

  v_band := case when v_cov = 0 then 'no_coverage' when v_alert > 0 then 'high'
                 when v_review > 0 then 'review' else 'low' end;
  return jsonb_build_object(
    'route_length_m', round(v_len::numeric), 'buffer_m', p_buffer,
    'coverage_fraction', round(v_cov::numeric, 3),
    'summary', jsonb_build_object('n_matched', v_n, 'n_alert', v_alert, 'n_human_review', v_review,
                                  'max_percentile', v_max, 'band', v_band, 'worst', v_worst),
    'segments', v_segs);
end $$;

create function public.ml_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs;
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;
  v_run := public.ml_pick_run(null);
  if v_run.id is null then return public.ml_meta(v_run); end if;
  return public.ml_meta(v_run) || jsonb_build_object(
    'tier_counts', v_run.tier_counts,
    'alert_capacity', 20,   -- N shown per day is a policy decision with MDoNER (plan B5)
    'coverage_bbox', (select jsonb_build_array(extensions.st_xmin(g::extensions.box3d), extensions.st_ymin(g::extensions.box3d),
                                               extensions.st_xmax(g::extensions.box3d), extensions.st_ymax(g::extensions.box3d))
                      from (select c.geom::extensions.geometry as g from public.ml_coverage c where c.id = 1) q));
end $$;

-- Route by id / route_number (riders: only their own open shipment's route) or a GeoJSON LineString
-- the app planned (any signed-in role).
create function public.get_route_ml_risk(
  p_route_id text default null, p_geojson jsonb default null, p_date date default null, p_buffer_m integer default 100
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_run   public.ml_batch_runs;
  v_route public.routes;
  v_line  extensions.geography;
  v_g     extensions.geometry;
  v_buf   integer := least(greatest(coalesce(p_buffer_m, 100), 10), 1000);
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;

  if p_route_id is not null then
    select * into v_route from public.routes r where r.id::text = p_route_id or r.route_number = p_route_id limit 1;
    if v_route.id is null or v_route.geom is null then
      raise exception 'unknown route or route has no geometry' using errcode = 'P0002';
    end if;
    if public.my_role() = 'rider' and not exists (
         select 1 from public.shipments s where s.rider_id = auth.uid() and s.route_id = v_route.id
           and s.status not in ('arrived', 'completed', 'cancelled')) then
      raise exception 'route is not assigned to you' using errcode = '42501';
    end if;
    v_line := v_route.geom;
  elsif p_geojson is not null then
    v_g := extensions.st_setsrid(extensions.st_geomfromgeojson(p_geojson::text), 4326);
    if extensions.geometrytype(v_g) <> 'LINESTRING' or extensions.st_npoints(v_g) > 5000 then
      raise exception 'p_geojson must be a LineString with at most 5000 points' using errcode = '22023';
    end if;
    v_line := v_g::extensions.geography;
  else
    raise exception 'give p_route_id or p_geojson' using errcode = '22023';
  end if;

  v_run := public.ml_pick_run(p_date);
  if v_run.id is null then
    return public.ml_meta(v_run) || jsonb_build_object('route_id', v_route.id::text);
  end if;
  return public.ml_meta(v_run) || jsonb_build_object('route_id', v_route.id::text)
         || public.ml_route_risk(v_line, v_run, v_buf);
end $$;

-- Officers: every stored route with geometry.
create function public.get_routes_ml_summary() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs;
begin
  if not public.is_officer() then raise exception 'officers only' using errcode = '42501'; end if;
  v_run := public.ml_pick_run(null);
  return public.ml_meta(v_run) || jsonb_build_object('routes', case when v_run.id is null then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('route_id', r.id, 'route_number', r.route_number, 'name', r.name)
                     || public.ml_route_risk(r.geom, v_run, 100) order by r.route_number)
    from public.routes r where r.geom is not null), '[]'::jsonb) end);
end $$;

-- Riders: the route of each open shipment assigned to them.
create function public.get_my_routes_ml_risk() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs;
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;
  v_run := public.ml_pick_run(null);
  return public.ml_meta(v_run) || jsonb_build_object('routes', case when v_run.id is null then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('shipment_id', s.id, 'shipment_number', s.shipment_number,
                                        'shipment_status', s.status, 'route_id', r.id,
                                        'route_number', r.route_number, 'name', r.name)
                     || public.ml_route_risk(r.geom, v_run, 100) order by s.created_at)
    from public.shipments s join public.routes r on r.id = s.route_id
    where s.rider_id = auth.uid() and r.geom is not null
      and s.status not in ('arrived', 'completed', 'cancelled')), '[]'::jsonb) end);
end $$;

-- Officers: top-N segments of a tier by tier_rank, with the nearest place (needs locations.geom).
create function public.get_ml_top_alerts(
  p_date date default null, p_tier text default 'alert', p_limit integer default 20, p_district text default null
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs; v_n bigint; v_rows jsonb;
begin
  if not public.is_officer() then raise exception 'officers only' using errcode = '42501'; end if;
  if p_tier not in ('alert', 'human_review') then raise exception 'tier must be alert or human_review' using errcode = '22023'; end if;
  v_run := public.ml_pick_run(p_date);
  if v_run.id is null then
    return public.ml_meta(v_run) || jsonb_build_object('tier', p_tier, 'scope', 'region', 'capacity', 0, 'n_in_tier', 0, 'rows', '[]'::jsonb);
  end if;

  select count(*) into v_n from ml_private.segment_scores where run_id = v_run.id and tier = p_tier;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.tier_rank), '[]'::jsonb) into v_rows from (
    select sc.tier_rank, s.segment_id,
           extensions.st_y(s.geom::extensions.geometry) as lat, extensions.st_x(s.geom::extensions.geometry) as lon,
           sc.risk_percentile, sc.tier, sc.steep,
           near.name as near_place, near.district as near_district, near.state as near_state,
           round(near.km::numeric, 1) as near_km, a.id::text as promoted_alert_id
    from ml_private.segment_scores sc
    join public.ml_segments s on s.segment_id = sc.segment_id
    left join lateral (
      select l.name, l.district, l.state, extensions.st_distance(l.geom, s.geom) / 1000 as km
      from public.locations l where l.geom is not null
      order by l.geom operator(extensions.<->) s.geom limit 1) near on true
    left join public.alerts a on a.source = 'ml' and a.ml_segment_id = sc.segment_id and a.ml_run_id = v_run.id
    where sc.run_id = v_run.id and sc.tier = p_tier and (p_district is null or near.district = p_district)
    order by sc.tier_rank
    limit least(greatest(p_limit, 1), 200)) t;

  return public.ml_meta(v_run) || jsonb_build_object(
    'tier', p_tier, 'scope', coalesce('district:' || p_district, 'region'),
    'capacity', least(greatest(p_limit, 1), 200), 'n_in_tier', v_n, 'rows', v_rows);
end $$;

-- Officers: map points for the ML layer inside a bounding box.
create function public.get_ml_segments_in_bbox(
  p_west double precision, p_south double precision, p_east double precision, p_north double precision,
  p_min_tier text default 'human_review', p_limit integer default 1000
) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_run public.ml_batch_runs;
begin
  if not public.is_officer() then raise exception 'officers only' using errcode = '42501'; end if;
  v_run := public.ml_pick_run(null);
  if v_run.id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'segment_id', s.segment_id, 'lat', extensions.st_y(s.geom::extensions.geometry),
             'lon', extensions.st_x(s.geom::extensions.geometry),
             'risk_percentile', sc.risk_percentile, 'tier', sc.tier, 'steep', sc.steep) order by sc.tier_rank)
    from (select * from ml_private.segment_scores x
          where x.run_id = v_run.id and (x.tier = 'alert' or (p_min_tier = 'human_review' and x.tier = 'human_review'))
          order by x.tier_rank limit 50000) sc
    join public.ml_segments s on s.segment_id = sc.segment_id
    where s.geom operator(extensions.&&) extensions.st_makeenvelope(p_west, p_south, p_east, p_north, 4326)::extensions.geography
    limit least(greatest(p_limit, 1), 5000)), '[]'::jsonb);
end $$;

-- Control room / district officers turn one segment into an operational alert (never automatic, B5).
create function public.promote_ml_alert(p_segment_id text, p_run_id bigint default null, p_note text default null)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_run public.ml_batch_runs;
  v_tier text; v_pct real; v_id uuid;
begin
  if public.my_role() not in ('control_room', 'district_officer') then
    raise exception 'only the control room or district officers can promote ML alerts' using errcode = '42501';
  end if;
  if p_run_id is null then v_run := public.ml_pick_run(null);
  else select * into v_run from public.ml_batch_runs r where r.id = p_run_id and r.status = 'published' and r.scores_pruned_at is null;
  end if;
  if v_run.id is null then raise exception 'no published ML run' using errcode = 'P0002'; end if;

  select sc.tier, sc.risk_percentile into v_tier, v_pct
  from ml_private.segment_scores sc where sc.run_id = v_run.id and sc.segment_id = p_segment_id;
  if v_tier is null or v_tier = 'none' then
    raise exception 'segment % is not in an alert tier for run %', p_segment_id, v_run.id using errcode = '22023';
  end if;

  insert into public.alerts (title, description, severity, source, ml_segment_id, ml_run_id, promoted_by, created_by)
  values ('ML road-disruption risk: segment ' || p_segment_id,
          format('Model %s, scores of %s (%s). Risk percentile %s.%s', v_run.bundle_version, v_run.score_date, v_run.mode,
                 round(v_pct::numeric, 2), coalesce(' Note: ' || p_note, '')),
          case v_tier when 'alert' then 'high' else 'moderate' end, 'ml', p_segment_id, v_run.id, auth.uid(), auth.uid())
  on conflict (ml_segment_id, ml_run_id) where source = 'ml' do nothing
  returning id into v_id;

  if v_id is null then
    select a.id into v_id from public.alerts a where a.source = 'ml' and a.ml_segment_id = p_segment_id and a.ml_run_id = v_run.id;
  else
    insert into public.audit_log (actor_id, action, entity, entity_id, detail)
    values (auth.uid(), 'ml_alert_promoted', 'alerts', v_id::text,
            jsonb_build_object('segment_id', p_segment_id, 'run_id', v_run.id, 'tier', v_tier, 'note', p_note));
  end if;
  return v_id::text;
end $$;

-- Audit record of what a rider or officer was shown (ML-006 / ML-007). Idempotent on p_client_id.
create function public.record_route_risk_snapshot(
  p_client_id text, p_context text, p_summary jsonb,
  p_run_id bigint default null, p_route_id text default null, p_shipment_id text default null,
  p_route_hash text default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_active_user() then raise exception 'sign in required' using errcode = '42501'; end if;
  insert into public.ml_route_risk_snapshots (client_id, user_id, context, run_id, route_id, shipment_id, route_hash, summary)
  values (p_client_id, auth.uid(), p_context, p_run_id, p_route_id, p_shipment_id, p_route_hash, p_summary)
  on conflict (client_id) do nothing;
end $$;
