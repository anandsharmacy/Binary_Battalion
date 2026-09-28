-- ML road-disruption risk storage + the publisher contract used by sih-ml/src/sih_ml/serve/publish.py
-- (design: ML_INTEGRATION_PLAN.md section 5). Scores live in ml_private (never exposed through the API);
-- clients read them only through the SECURITY DEFINER RPCs in the next migration.

create schema if not exists ml_private;

-- The publish job connects as a LOGIN user that is a member of this role (never the service-role key).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'ml_publisher') then
    create role ml_publisher nologin;
  end if;
end $$;

create table public.ml_model_versions (
  id              bigint generated always as identity primary key,
  version         text not null,
  bundle_hash     text not null unique,
  uri             text,
  manifest        jsonb not null,
  policy          jsonb not null,
  registry_status text not null default 'candidate' check (registry_status in ('candidate', 'approved', 'retired')),
  approved_by     uuid references auth.users (id),
  approved_at     timestamptz,
  created_at      timestamptz not null default now()
);

create table public.ml_batch_runs (
  id                         bigint generated always as identity primary key,
  score_date                 date not null,
  mode                       text not null check (mode in ('live', 'replay')),
  model_version_id           bigint references public.ml_model_versions (id),
  bundle_version             text,
  bundle_hash                text not null,
  featurestore_schema_sha256 text,
  n_segments                 integer,
  tier_counts                jsonb not null default '{}',
  drift                      jsonb,
  data_quality               jsonb,
  run                        jsonb not null,                -- the batch's run.json, verbatim
  status                     text not null default 'staging' check (status in ('staging', 'published')),
  is_current                 boolean not null default false,
  published_at               timestamptz,
  expires_at                 timestamptz,                   -- live batches go stale after this; replay never does
  scores_pruned_at           timestamptz,
  unique (score_date, bundle_hash)
);
create unique index ml_batch_runs_one_current on public.ml_batch_runs ((true)) where is_current;

create table public.ml_coverage (
  id         smallint primary key check (id = 1),
  geom       extensions.geography(MultiPolygon, 4326) not null,
  n_cells    integer not null,
  updated_at timestamptz not null default now()
);

create table public.ml_segments (
  segment_id text primary key,
  geom       extensions.geography(Point, 4326) not null,
  slope_deg  real,
  steep      boolean not null default false,
  cell_index integer not null
);
create index ml_segments_geom_idx on public.ml_segments using gist (geom);

-- One partition per published run (created by ml_begin_run, attached by ml_finish_run).
create table ml_private.segment_scores (
  run_id          bigint  not null,
  segment_id      text    not null,
  raw_score       real    not null,
  p_calibrated    real    not null,
  risk_percentile real    not null,
  steep           boolean not null,
  tier            text    not null check (tier in ('none', 'alert', 'human_review')),
  tier_rank       integer not null,
  primary key (run_id, segment_id)
) partition by list (run_id);
create index segment_scores_tier_idx on ml_private.segment_scores (run_id, tier, tier_rank);

-- Audit record of what a user was shown (ML-006 / ML-007).
create table public.ml_route_risk_snapshots (
  id          bigint generated always as identity primary key,
  client_id   text not null unique,
  user_id     uuid not null references auth.users (id),
  context     text not null,
  run_id      bigint,
  route_id    text,
  shipment_id text,
  route_hash  text,
  summary     jsonb not null,
  created_at  timestamptz not null default now()
);

alter table public.ml_model_versions       enable row level security;
alter table public.ml_batch_runs           enable row level security;
alter table public.ml_coverage             enable row level security;
alter table public.ml_segments             enable row level security;
alter table public.ml_route_risk_snapshots enable row level security;

-- Run metadata is harmless and lets every client refresh over Realtime when a new day lands.
create policy ml_runs_read     on public.ml_batch_runs     for select to authenticated using (public.is_active_user());
create policy ml_versions_read on public.ml_model_versions for select to authenticated using (public.is_officer());
create policy ml_coverage_read on public.ml_coverage       for select to authenticated using (public.is_officer());
create policy ml_segments_read on public.ml_segments       for select to authenticated using (public.is_officer());
create policy ml_snapshots_own on public.ml_route_risk_snapshots for select to authenticated
  using (user_id = auth.uid() or public.is_officer());

alter publication supabase_realtime add table public.ml_batch_runs;

-- Publisher functions ---------------------------------------------------------------------------

-- Registers a run and creates its staging table. Returns NULL when (date, bundle) is already published.
create function public.ml_begin_run(p_run jsonb, p_mode text, p_model jsonb) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_date  date := (p_run->>'date')::date;
  v_hash  text := p_run->>'bundle_hash';
  v_model bigint;
  v_id    bigint;
begin
  if p_mode not in ('live', 'replay') then
    raise exception 'mode must be live or replay' using errcode = '22023';
  end if;
  if v_date is null or v_hash is null then
    raise exception 'run.json needs date and bundle_hash' using errcode = '22023';
  end if;
  if exists (select 1 from public.ml_batch_runs where score_date = v_date and bundle_hash = v_hash and status = 'published') then
    return null;
  end if;

  insert into public.ml_model_versions (version, bundle_hash, uri, manifest, policy)
  values (coalesce(p_run->>'bundle_version', p_model->'manifest'->>'version', v_hash), v_hash,
          p_model->>'uri', p_model->'manifest', p_model->'policy')
  on conflict (bundle_hash) do update set manifest = excluded.manifest, policy = excluded.policy, uri = excluded.uri
  returning id into v_model;

  delete from public.ml_batch_runs where score_date = v_date and bundle_hash = v_hash and status = 'staging';
  insert into public.ml_batch_runs
    (score_date, mode, model_version_id, bundle_version, bundle_hash, featurestore_schema_sha256, n_segments,
     tier_counts, drift, data_quality, run, expires_at)
  values (v_date, p_mode, v_model, p_run->>'bundle_version', v_hash, p_run->>'featurestore_schema_sha256',
          (p_run->>'n_segments')::int, coalesce(p_run->'tiers', '{}'), p_run->'drift', p_run->'data_quality', p_run,
          case when p_mode = 'live' then ((v_date + 2)::timestamp at time zone 'Asia/Kolkata') end)
  returning id into v_id;

  execute format('drop table if exists ml_private.scores_r%s', v_id);
  execute format('create table ml_private.scores_r%s (like ml_private.segment_scores including constraints)', v_id);
  execute format('grant insert on ml_private.scores_r%s to ml_publisher', v_id);
  return v_id;
end $$;

-- Validates the loaded rows against run.json, attaches the partition and (optionally) makes it current.
create function public.ml_finish_run(p_run_id bigint, p_set_current boolean default true) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r      public.ml_batch_runs;
  v_rows bigint;
  v_tiers jsonb;
  old    record;
begin
  select * into r from public.ml_batch_runs where id = p_run_id and status = 'staging';
  if not found then
    raise exception 'run % is not staging', p_run_id using errcode = 'P0002';
  end if;

  execute format('select count(*) from ml_private.scores_r%s', p_run_id) into v_rows;
  execute format('select coalesce(jsonb_object_agg(tier, n), ''{}''::jsonb) '
                 'from (select tier, count(*) n from ml_private.scores_r%s group by tier) t', p_run_id) into v_tiers;

  if r.n_segments is not null and v_rows <> r.n_segments then
    raise exception 'run %: % rows loaded but run.json says %', p_run_id, v_rows, r.n_segments using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_each_text(r.tier_counts) k where (v_tiers->>k.key)::bigint is distinct from k.value::bigint) then
    raise exception 'run %: tier counts % differ from run.json %', p_run_id, v_tiers, r.tier_counts using errcode = '22023';
  end if;

  execute format('alter table ml_private.segment_scores attach partition ml_private.scores_r%s for values in (%s)',
                 p_run_id, p_run_id);
  update public.ml_batch_runs set status = 'published', published_at = now(), tier_counts = v_tiers where id = p_run_id;
  if p_set_current then perform public.ml_set_current(p_run_id); end if;

  -- 30-day retention for live days; replay days are kept until replaced.
  for old in select id from public.ml_batch_runs
             where mode = 'live' and status = 'published' and not is_current and scores_pruned_at is null
               and score_date < current_date - 30 loop
    execute format('drop table if exists ml_private.scores_r%s', old.id);
    update public.ml_batch_runs set scores_pruned_at = now() where id = old.id;
  end loop;

  return jsonb_build_object('run_id', p_run_id, 'rows', v_rows, 'tiers', v_tiers, 'current', p_set_current);
end $$;

create function public.ml_set_current(p_run_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.ml_batch_runs where id = p_run_id and status = 'published' and scores_pruned_at is null) then
    raise exception 'run % is not a published run with scores', p_run_id using errcode = 'P0002';
  end if;
  update public.ml_batch_runs set is_current = false where is_current and id <> p_run_id;
  update public.ml_batch_runs set is_current = true where id = p_run_id;
end $$;

-- What the publisher itself needs beyond the functions above.
grant usage on schema public, extensions, ml_private to ml_publisher;
grant select on public.ml_batch_runs to ml_publisher;
grant select, insert, update, truncate on public.ml_segments to ml_publisher;
grant select, insert, update on public.ml_coverage to ml_publisher;
grant execute on function public.ml_begin_run(jsonb, text, jsonb), public.ml_finish_run(bigint, boolean),
                          public.ml_set_current(bigint) to ml_publisher;
