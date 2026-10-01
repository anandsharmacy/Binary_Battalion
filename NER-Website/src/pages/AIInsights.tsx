import { LoadingRows, MlCaveat, MlNotice, MlRouteSummary, MlTopAlertsPanel } from '@/components/MlRisk';
import {
  districtsAtRisk, fetchRecentRuns, fetchRoutesSummary, fetchTopAlerts, formatMlDate, TIER_LABEL, tierTrend,
  topShare, useMlQuery,
} from '@/lib/ml';
import { profileService } from '@/lib/profileService';
import { SURFACE, SURFACE_2, BORDER as border } from './fo/ui';

const card = { background: SURFACE, borderColor: border };
const cardHead = { borderColor: border, background: SURFACE_2 };

function Empty({ text }: { text: string }) {
  return (
    <div className="text-xs rounded-lg border px-3 py-2" style={{ color: '#5A6670', borderColor: border }}>{text}</div>
  );
}

export default function AIInsights() {
  const routes = useMlQuery(fetchRoutesSummary);
  // Both re-run when a new batch lands (useMlQuery subscribes to ml_batch_runs).
  const runs = useMlQuery(fetchRecentRuns);
  const top = useMlQuery(() => fetchTopAlerts('alert'));
  const districts = top.data ? districtsAtRisk(top.data.rows ?? []) : [];
  // The database enforces this too; the button only appears where it can succeed.
  const role = profileService.getCurrentRole();
  const canPromote = role === 'control' || role === 'district';

  return (
    <div className="space-y-6 max-w-screen-2xl">
      <div className="flex items-start justify-between">
        <div>
          <div className="flex items-center gap-2">
            <span style={{ color: '#D7A73A' }}>✦</span>
            <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>AI Insights</h1>
          </div>
          <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>
            Model predictions, refreshed when a new run is published
          </p>
        </div>
        <div className="text-xs px-3 py-1.5 rounded border" style={{ background: '#FEF8E6', borderColor: '#F5DFA8', color: '#C4861A' }}>
          ✦ AI-generated estimates · Confidence varies
        </div>
      </div>

      {/* Disclaimer */}
      <div className="rounded-xl border p-3 flex items-center gap-2"
        style={{ background: 'rgba(238,228,210,0.88)', borderColor: 'rgba(180,162,136,0.55)' }}>
        <span className="text-lg" style={{ color: '#D7A73A' }}>✦</span>
        <p className="text-xs" style={{ color: '#5A6670' }}>
          <strong>Road Disruption Risk</strong> is the NER model's daily ranking of every road segment it covers by
          rainfall-triggered disruption risk. Every panel here is derived from that model's published runs. All of it is advisory, not confirmed
          fact — District Officer discretion required.
        </p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">

        {/* Road disruption risk — live model output (sih-ml) */}
        <div className="rounded-xl border shadow-sm lg:col-span-2" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
          <div className="px-4 py-3 border-b" style={{ borderColor: 'rgba(180,162,136,0.55)', background: 'rgba(238,228,210,0.88)' }}>
            <h2 className="font-semibold text-base" style={{ color: '#17212B' }}>Road Disruption Risk</h2>
            <p className="text-xs" style={{ color: 'var(--text-muted)' }}>Model output · rainfall-triggered landslide ranking per covered road segment; floods are not modelled</p>
          </div>
          <div className="p-4 grid grid-cols-1 xl:grid-cols-2 gap-6">
            <section className="space-y-2">
              <h3 className="text-sm font-semibold" style={{ color: '#17212B' }}>Highest-risk segments today</h3>
              <MlTopAlertsPanel canPromote={canPromote} />
            </section>
            <section className="space-y-2">
              <h3 className="text-sm font-semibold" style={{ color: '#17212B' }}>Risk on planned routes</h3>
              <MlNotice signedOut={routes.signedOut} error={routes.error} />
              {routes.loading && !routes.data && !routes.signedOut && (
                <LoadingRows label="Loading routes…" />
              )}
              {routes.data && routes.data.state !== 'unavailable' && (routes.data.routes ?? []).length === 0 && (
                <Empty text="No planned routes are loaded yet, so there is no per-route risk to show." />
              )}
              <div className="space-y-3">
                {(routes.data?.routes ?? []).map((r) => (
                  <div key={r.route_id} className="rounded-lg border p-3" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
                    <div className="font-semibold text-sm mb-2" style={{ color: '#17212B' }}>{r.name}</div>
                    <MlRouteSummary meta={routes.data} summary={r.summary} coverage={r.coverage_fraction} lengthM={r.route_length_m} />
                  </div>
                ))}
              </div>
            </section>
          </div>
        </div>

        {/* Trend vs previous published batch (ml_batch_runs) */}
        <div className="rounded-xl border shadow-sm" style={card}>
          <div className="px-4 py-3 border-b" style={cardHead}>
            <h2 className="font-semibold text-base" style={{ color: '#17212B' }}>Risk Trend</h2>
            <p className="text-xs" style={{ color: 'var(--text-muted)' }}>Model output · latest published run vs the one before</p>
          </div>
          <div className="p-4 space-y-3">
            <MlNotice signedOut={runs.signedOut} error={runs.error} />
            {runs.loading && !runs.data && !runs.signedOut && <LoadingRows label="Loading runs…" />}
            {runs.data && runs.data.length === 0 && <Empty text="No ML run has been published yet." />}
            {runs.data && runs.data.length > 0 && (
              <>
                <p className="text-xs" style={{ color: 'var(--text-muted)' }}>
                  {runs.data[0].mode === 'replay' ? 'Replay' : 'Live'} run for {formatMlDate(runs.data[0].score_date)}
                  {runs.data[1] ? ` vs ${runs.data[1].mode} run for ${formatMlDate(runs.data[1].score_date)}` : ' · no earlier run to compare'}
                </p>
                {tierTrend(runs.data).map((t) => (
                  <div key={t.tier} className="rounded-lg border p-3 flex items-center justify-between" style={{ borderColor: border }}>
                    <span className="text-sm" style={{ color: '#17212B' }}>{TIER_LABEL[t.tier]}</span>
                    <span className="text-sm font-semibold tabular-nums" style={{ color: '#17212B' }}>
                      {t.now.toLocaleString('en-IN')} segments
                      {t.delta != null && (
                        <span className="ml-2 text-xs" style={{ color: t.delta > 0 ? '#BE2424' : t.delta < 0 ? '#2D6B4F' : '#5A6670' }}>
                          {t.delta > 0 ? '▲' : t.delta < 0 ? '▼' : '='} {Math.abs(t.delta).toLocaleString('en-IN')}
                        </span>
                      )}
                    </span>
                  </div>
                ))}
              </>
            )}
          </div>
        </div>

        {/* Where to send field verification first: top alert segments grouped by district */}
        <div className="rounded-xl border shadow-sm" style={card}>
          <div className="px-4 py-3 border-b" style={cardHead}>
            <h2 className="font-semibold text-base" style={{ color: '#17212B' }}>Districts to Verify First</h2>
            <p className="text-xs" style={{ color: 'var(--text-muted)' }}>Model output · today's highest-risk segments by nearest district</p>
          </div>
          <div className="p-4 space-y-3">
            <MlNotice signedOut={top.signedOut} error={top.error} meta={top.data} />
            {top.loading && !top.data && !top.signedOut && <LoadingRows label="Loading districts…" />}
            {top.data && top.data.state !== 'unavailable' && districts.length === 0 && (
              <Empty text="No high-risk segments in today's run." />
            )}
            {districts.map((d) => (
              <div key={d.district} className="rounded-lg border p-3" style={{ borderColor: border }}>
                <div className="flex items-center justify-between">
                  <span className="font-semibold text-sm" style={{ color: '#17212B' }}>
                    {d.district}{d.state ? `, ${d.state}` : ''}
                  </span>
                  <span className="text-xs" style={{ color: '#BE2424' }}>{topShare(d.max_percentile)}</span>
                </div>
                <p className="text-xs mt-1" style={{ color: '#5A6670' }}>
                  {d.n_segments} of today's top {top.data?.rows.length} alert segments. Send a field check before rerouting.
                </p>
              </div>
            ))}
            <MlCaveat meta={top.data} />
          </div>
        </div>
      </div>
    </div>
  );
}
