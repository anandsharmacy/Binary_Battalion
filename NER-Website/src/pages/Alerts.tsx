import { useState } from 'react';
import { SeverityBadge } from '@/components/StatusBadge';
import EmptyState from '@/components/EmptyState';
import { useAlerts, setAlertStatus, type AlertRow, type AlertSeverity } from '@/lib/alerts';
import { notify } from '@/lib/notify';
import type { Severity } from '@/data/demo';

const FILTERS = ['Open', 'Critical', 'High', 'Moderate', 'Info', 'Resolved', 'All'] as const;
type Filter = typeof FILTERS[number];

const BADGE: Record<AlertSeverity, Severity> = { critical: 'CRITICAL', high: 'HIGH', moderate: 'MODERATE', info: 'LOW' };
const EDGE: Record<AlertSeverity, string> = { critical: '#BE2424', high: '#E07840', moderate: '#C4861A', info: '#2D6B4F' };
const SOURCE: Record<AlertRow['source'], string> = { human: 'Officer', rule: 'Field report', feed: 'Feed', ml: 'ML model' };

function matches(a: AlertRow, f: Filter) {
  if (f === 'All') return true;
  if (f === 'Resolved') return a.status === 'resolved';
  if (a.status === 'resolved') return false;
  return f === 'Open' || a.severity === f.toLowerCase();
}

const when = (iso: string) => new Date(iso).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' });

export default function Alerts() {
  const { alerts, loading, error } = useAlerts();
  const [filter, setFilter] = useState<Filter>('Open');
  const [busy, setBusy] = useState<string | null>(null);

  const act = async (id: string, status: 'acknowledged' | 'resolved') => {
    setBusy(id);
    try {
      await setAlertStatus(id, status);
      notify(status === 'resolved' ? 'Alert resolved' : 'Alert acknowledged');
    } catch (e) {
      notify(`Could not update alert: ${(e as Error).message}`, { tone: 'error' });
    } finally {
      setBusy(null);
    }
  };

  const filtered = alerts.filter(a => matches(a, filter));
  const unacknowledged = alerts.filter(a => a.status === 'active').length;

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div>
        <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Alerts</h1>
        <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>
          Live operational alerts — {unacknowledged} unacknowledged
        </p>
      </div>

      <div className="flex flex-wrap gap-1" role="tablist" aria-label="Filter alerts">
        {FILTERS.map(f => (
          <button key={f} role="tab" aria-selected={filter === f} onClick={() => setFilter(f)}
            className="text-xs px-3 py-1.5 rounded-full border transition-colors min-h-[28px] pointer-coarse:min-h-11"
            style={{
              background: filter === f ? '#17324D' : 'rgba(250,247,240,0.82)',
              color: filter === f ? 'white' : '#5A6670',
              borderColor: filter === f ? '#17324D' : 'rgba(180,162,136,0.55)',
            }}>
            {f}
          </button>
        ))}
      </div>

      {error && (
        <div role="alert" className="rounded-lg border p-3 text-sm" style={{ borderColor: '#F5B8B8', background: '#FEE9E9', color: '#7A1B1B' }}>
          Could not load alerts: {error}
        </div>
      )}

      {loading ? (
        <p className="text-sm" style={{ color: 'var(--text-muted)' }}>Loading alerts…</p>
      ) : filtered.length === 0 && !error ? (
        <EmptyState title="No alerts" message="New alerts appear here as soon as they are raised." />
      ) : (
        <div className="space-y-3">
          {filtered.map(a => {
            const done = a.status !== 'active';
            return (
              <div key={a.id} className="rounded-xl border shadow-sm p-4"
                style={{
                  background: done ? 'rgba(243,235,220,0.55)' : 'rgba(250,247,240,0.82)',
                  borderColor: 'rgba(180,162,136,0.55)',
                  borderLeftWidth: 3,
                  borderLeftColor: EDGE[a.severity],
                }}>
                <div className="flex items-start gap-3">
                  <div className="flex-shrink-0 mt-0.5"><SeverityBadge severity={BADGE[a.severity]} /></div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-start justify-between gap-2 flex-wrap">
                      <h3 className="font-semibold text-sm" style={{ color: '#17212B' }}>{a.title}</h3>
                      <span className="text-xs" style={{ color: 'var(--text-muted)' }}>{when(a.created_at)}</span>
                    </div>
                    <div className="flex items-center gap-3 text-xs mt-0.5 mb-2 flex-wrap" style={{ color: 'var(--text-muted)' }}>
                      <span>◉ {a.district?.name ?? 'All districts'}</span>
                      <span>· Source: {SOURCE[a.source]}</span>
                    </div>
                    {a.description && <p className="text-xs leading-relaxed" style={{ color: '#5A6670' }}>{a.description}</p>}
                    {a.status === 'acknowledged' && (
                      <p className="text-xs mt-2" style={{ color: 'var(--text-muted)' }}>
                        Acknowledged by {a.acknowledgedByName ?? 'an officer'}{a.acknowledged_at ? ` · ${when(a.acknowledged_at)}` : ''}
                      </p>
                    )}
                    {a.status === 'resolved' && (
                      <p className="text-xs mt-2" style={{ color: 'var(--text-muted)' }}>
                        Resolved by {a.resolvedByName ?? 'an officer'}{a.resolved_at ? ` · ${when(a.resolved_at)}` : ''}
                      </p>
                    )}
                    {a.status !== 'resolved' && (
                      <div className="flex gap-2 mt-3 flex-wrap">
                        {!done && (
                          <button onClick={() => act(a.id, 'acknowledged')} disabled={busy === a.id}
                            className="text-xs font-medium px-3 py-1.5 rounded border min-h-[28px] pointer-coarse:min-h-11"
                            style={{ background: '#17324D', color: 'white', borderColor: '#17324D' }}>
                            Acknowledge
                          </button>
                        )}
                        <button onClick={() => act(a.id, 'resolved')} disabled={busy === a.id}
                          className="text-xs font-medium px-3 py-1.5 rounded border min-h-[28px] pointer-coarse:min-h-11"
                          style={{ borderColor: 'rgba(180,162,136,0.55)', color: '#5A6670' }}>
                          Resolve
                        </button>
                      </div>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
