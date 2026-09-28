/**
 * TEMPORARY bridge for sih_ml.serve.publish when the publishing machine can't
 * reach Postgres (ports 5432/6543 blocked) but can reach HTTPS. Edge Functions
 * run inside Supabase and get SUPABASE_DB_URL.
 *
 * Fixed operations only — never arbitrary SQL. Guarded by ML_PUBLISH_SECRET.
 * Not atomic across requests (publish.py's single transaction isn't possible
 * over HTTP); ml_finish_run still refuses to attach unless row and tier counts
 * match run.json, so a half-loaded day never becomes current.
 *
 * Delete after use: supabase functions delete ml-publish
 */

import postgres from 'npm:postgres@3';

const secret = Deno.env.get('ML_PUBLISH_SECRET') ?? '';
const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { prepare: false, max: 1 });

function sameSecret(a: string, b: string): boolean {
  if (!b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const ok = (body: unknown) => new Response(JSON.stringify(body), { headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST' || !sameSecret(req.headers.get('x-publish-secret') ?? '', secret)) {
    return new Response('forbidden', { status: 403 });
  }
  const b = await req.json();
  try {
    switch (b.op) {
      case 'segments_truncate':
        await sql`truncate public.ml_segments`;
        return ok({ truncated: true });

      case 'segments': {
        const r = await sql`
          insert into public.ml_segments (segment_id, geom, slope_deg, steep, cell_index)
          select r.segment_id,
                 extensions.st_setsrid(extensions.st_makepoint(r.lon, r.lat), 4326)::extensions.geography,
                 r.slope_deg, r.steep, r.cell_index
          from jsonb_to_recordset(${sql.json(b.rows)}) as r(
            segment_id text, lon float8, lat float8, slope_deg real, steep boolean, cell_index int)`;
        return ok({ inserted: r.count });
      }

      case 'coverage':
        await sql`
          insert into public.ml_coverage (id, geom, n_cells, updated_at)
          select 1, extensions.st_multi(extensions.st_union(array(
            select extensions.st_geomfromtext(w, 4326) from jsonb_array_elements_text(${sql.json(b.polygons)}) w
          )))::extensions.geography, ${b.n_cells}, now()
          on conflict (id) do update set geom = excluded.geom, n_cells = excluded.n_cells, updated_at = now()`;
        return ok({ coverage: true });

      case 'begin': {
        const [r] = await sql`select public.ml_begin_run(${sql.json(b.run)}, ${b.mode}, ${sql.json(b.model)}) as id`;
        return ok({ run_id: r.id });
      }

      case 'scores': {
        const id = Number(b.run_id);
        if (!Number.isInteger(id) || id <= 0) return new Response('bad run_id', { status: 400 });
        const r = await sql`
          insert into ml_private.${sql('scores_r' + id)}
            (run_id, segment_id, raw_score, p_calibrated, risk_percentile, steep, tier, tier_rank)
          select ${id}, r.segment_id, r.raw_score, r.p_calibrated, r.risk_percentile, r.steep, r.tier, r.tier_rank
          from jsonb_to_recordset(${sql.json(b.rows)}) as r(
            segment_id text, raw_score real, p_calibrated real, risk_percentile real,
            steep boolean, tier text, tier_rank int)`;
        return ok({ inserted: r.count });
      }

      case 'finish': {
        const [r] = await sql`select public.ml_finish_run(${Number(b.run_id)}, true) as out`;
        return ok(r.out);
      }

      default:
        return new Response('unknown op', { status: 400 });
    }
  } catch (e) {
    return new Response(JSON.stringify({ error: (e as Error).message }), { status: 500 });
  }
});
