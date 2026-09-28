-- Fix: partitions need the parent's CHECK constraints to attach ("child table is missing constraint
-- segment_scores_tier_check"). LIKE copies NOT NULL but not CHECK unless asked.

create or replace function public.ml_begin_run(p_run jsonb, p_mode text, p_model jsonb) returns bigint
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
