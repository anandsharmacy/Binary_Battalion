import { useState } from 'react';
import { SeverityBadge, StatusBadge, AccessibilityBadge } from '@/components/StatusBadge';
import { routes } from '@/data/demo';
import { MlRoutesBoard } from '@/components/MlRisk';
import Modal from '@/components/Modal';
import EmptyState from '@/components/EmptyState';
import { Icon } from '@/auth/Icons';
import type { Route } from '@/data/demo';

function RouteDetail({ route, onClose }: { route: Route; onClose: () => void }) {
  return (
    <Modal open onClose={onClose} labelledBy="route-title" side="right">
      <div className="h-full w-[32rem] max-w-full overflow-y-auto shadow-2xl"
        style={{ background: 'rgba(250,247,240,0.82)', borderLeft: '1px solid rgba(180,162,136,0.55)' }}>
        <div className="px-5 py-4 border-b" style={{ borderColor: 'rgba(180,162,136,0.55)', background: 'rgba(238,228,210,0.88)' }}>
          <div className="flex items-start justify-between">
            <div>
              <h2 id="route-title" className="font-semibold text-lg" style={{ color: '#17212B' }}>Route {route.id}</h2>
              <p className="text-xs" style={{ color: '#5A6670' }}>{route.name} · {route.distance}</p>
            </div>
            <button type="button" onClick={onClose} aria-label="Close details"
              className="text-xl flex items-center justify-center rounded min-h-[28px] min-w-[28px] pointer-coarse:min-h-11 pointer-coarse:min-w-11"
              style={{ color: 'var(--text-muted)' }}>✕</button>
          </div>
          <div className="flex gap-2 mt-2">
            <StatusBadge status={route.status} />
            <SeverityBadge severity={route.riskScore > 75 ? 'CRITICAL' : route.riskScore > 50 ? 'HIGH' : route.riskScore > 25 ? 'MODERATE' : 'LOW'} />
          </div>
        </div>

        <div className="px-5 py-4 space-y-5">
          {/* Score overview */}
          <div className="grid grid-cols-2 gap-3">
            <div className="rounded-lg p-3 border" style={{ background: 'rgba(238,228,210,0.88)', borderColor: 'rgba(180,162,136,0.55)' }}>
              <div className="text-xs mb-1" style={{ color: 'var(--text-muted)' }}>Accessibility Score</div>
              <AccessibilityBadge score={route.accessibilityScore} />
            </div>
            <div className="rounded-lg p-3 border" style={{ background: 'rgba(238,228,210,0.88)', borderColor: 'rgba(180,162,136,0.55)' }}>
              <div className="text-xs mb-1" style={{ color: 'var(--text-muted)' }}>Risk Score</div>
              <div className="font-bold text-lg" style={{ color: '#17212B' }}>{route.riskScore}/100</div>
            </div>
          </div>

          {/* Route details */}
          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Route Details</h3>
            <div className="rounded-lg border overflow-hidden" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
              {[
                { label: 'Weather', value: route.weather },
                { label: 'Flood Risk', value: <SeverityBadge severity={route.floodRisk} /> },
                { label: 'Landslide Risk', value: <SeverityBadge severity={route.landslideRisk} /> },
                { label: 'ETA', value: route.eta },
                { label: 'Expected Delay', value: route.delay },
                { label: 'Active Incidents', value: `${route.incidents}` },
                { label: 'Last Updated', value: route.lastUpdated },
              ].map((row, i) => (
                <div key={row.label} className="flex items-center px-3 py-2" style={{ background: i % 2 === 0 ? 'rgba(250,247,240,0.82)' : 'rgba(243,235,220,0.55)' }}>
                  <span className="w-36 flex-shrink-0 text-xs" style={{ color: 'var(--text-muted)' }}>{row.label}</span>
                  <span className="text-xs font-medium" style={{ color: '#17212B' }}>
                    {typeof row.value === 'string' ? row.value : row.value}
                  </span>
                </div>
              ))}
            </div>
          </div>

          {/* Alternative route comparison */}
          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Route Comparison</h3>
            <div className="grid grid-cols-2 gap-3">
              <div className="rounded-lg border p-3" style={{ background: '#FEF1E6', borderColor: '#F5CDA8' }}>
                <div className="text-xs font-semibold mb-2" style={{ color: '#C25A1A' }}>▲ Current Route</div>
                <div className="space-y-1">
                  <div className="flex justify-between text-xs"><span style={{ color: 'var(--text-muted)' }}>Distance</span><span style={{ color: '#17212B' }} className="font-medium">{route.distance}</span></div>
                  <div className="flex justify-between text-xs"><span style={{ color: 'var(--text-muted)' }}>ETA</span><span style={{ color: '#17212B' }} className="font-medium">{route.eta}</span></div>
                  <div className="flex justify-between text-xs"><span style={{ color: 'var(--text-muted)' }}>Risk</span><span style={{ color: '#BE2424' }} className="font-bold">{route.riskScore}</span></div>
                </div>
              </div>
              {/* No routing engine computes alternatives yet, so none is shown (no invented numbers). */}
              <div className="rounded-lg border p-3 flex items-center justify-center text-center text-xs" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)', color: 'var(--text-muted)' }}>
                No alternative computed
              </div>
            </div>
          </div>

          {/* Interim until product decides (V2 audit section 7, #4): these actions have no backend yet. */}
          <div>
            <div className="flex gap-2">
              <button type="button" disabled aria-describedby="route-actions-note"
                className="text-xs font-medium px-3 py-2 rounded border disabled:opacity-60 disabled:cursor-not-allowed"
                style={{ background: '#17324D', color: 'white', borderColor: '#17324D' }}>
                Apply Rerouting
              </button>
              <button type="button" disabled aria-describedby="route-actions-note"
                className="text-xs font-medium px-3 py-2 rounded border disabled:opacity-60 disabled:cursor-not-allowed"
                style={{ borderColor: 'rgba(180,162,136,0.55)', color: '#5A6670' }}>
                Request Inspection
              </button>
            </div>
            <p id="route-actions-note" className="text-xs mt-1.5" style={{ color: 'var(--text-muted)' }}>Not available yet</p>
          </div>
        </div>
      </div>
    </Modal>
  );
}

export default function Routes() {
  const [selected, setSelected] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState('All Status');
  const selectedRoute = routes.find(r => r.id === selected);
  const visible = routes.filter(r => statusFilter === 'All Status' || r.status === statusFilter);

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div className="flex items-start justify-between flex-wrap gap-3">
        <div>
          <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Routes</h1>
          <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>Route intelligence and accessibility monitoring</p>
        </div>
        <div className="flex gap-2">
          <select aria-label="Filter by status" value={statusFilter} onChange={e => setStatusFilter(e.target.value)} className="text-xs px-3 py-1.5 rounded border" style={{ borderColor: 'rgba(180,162,136,0.55)', background: 'rgba(250,247,240,0.82)' }}>
            <option>All Status</option>
            <option>Open</option>
            <option>Restricted</option>
            <option>Blocked</option>
            <option>Closed</option>
          </select>
        </div>
      </div>

      {/* Route summary KPIs */}
      <div className="grid grid-cols-4 gap-3">
        {[
          { label: 'Open Routes', value: routes.filter(r => r.status === 'Open').length, color: '#2D6B4F', bg: '#EAF4EE' },
          { label: 'Restricted', value: routes.filter(r => r.status === 'Restricted').length, color: '#C4861A', bg: '#FEF8E6' },
          { label: 'Blocked', value: routes.filter(r => r.status === 'Blocked').length, color: '#C25A1A', bg: '#FEF1E6' },
          { label: 'Closed', value: routes.filter(r => r.status === 'Closed').length, color: '#BE2424', bg: '#FEE9E9' },
        ].map(item => (
          <div key={item.label} className="rounded-xl border p-4 shadow-sm"
            style={{ background: item.bg, borderColor: 'rgba(180,162,136,0.55)' }}>
            <div className="text-3xl font-bold" style={{ color: item.color }}>{item.value}</div>
            <div className="text-xs font-medium mt-1" style={{ color: item.color }}>{item.label}</div>
          </div>
        ))}
      </div>

      <MlRoutesBoard />

      <div className="rounded-xl border shadow-sm overflow-hidden" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ background: 'rgba(238,228,210,0.88)' }}>
                {['Route ID', 'Name', 'Distance', 'Accessibility', 'Risk', 'Status', 'Weather', 'ETA', 'Delay', 'Updated', 'Actions'].map(h => (
                  <th key={h} scope="col" className="text-left px-4 py-3 text-xs font-semibold uppercase tracking-wider whitespace-nowrap"
                    style={{ color: '#5A6670' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {visible.map((route, i) => (
                <tr key={route.id} className="hover:opacity-80 transition-opacity cursor-pointer"
                  style={{ background: i % 2 === 0 ? 'rgba(250,247,240,0.82)' : 'rgba(243,235,220,0.55)' }}
                  onClick={() => setSelected(route.id)}>
                  <td className="px-4 py-3 font-mono text-xs font-semibold" style={{ color: '#2F6F7E' }}>{route.id}</td>
                  <td className="px-4 py-3 text-xs font-medium" style={{ color: '#17212B' }}>{route.name}</td>
                  <td className="px-4 py-3 text-xs" style={{ color: '#5A6670' }}>{route.distance}</td>
                  <td className="px-4 py-3"><AccessibilityBadge score={route.accessibilityScore} /></td>
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-2">
                      <div className="w-12 h-1.5 rounded-full overflow-hidden" style={{ background: 'rgba(180,162,136,0.55)' }}>
                        <div style={{ width: `${route.riskScore}%`, background: route.riskScore > 75 ? '#BE2424' : route.riskScore > 50 ? '#E07840' : '#C4861A' }} className="h-full" />
                      </div>
                      <span className="text-xs font-medium" style={{ color: '#17212B' }}>{route.riskScore}</span>
                    </div>
                  </td>
                  <td className="px-4 py-3"><StatusBadge status={route.status} /></td>
                  <td className="px-4 py-3 text-xs" style={{ color: '#5A6670' }}>{route.weather}</td>
                  <td className="px-4 py-3 text-xs font-medium" style={{ color: '#17212B' }}>{route.eta}</td>
                  <td className="px-4 py-3 text-xs" style={{ color: route.delay === 'None' ? '#2D6B4F' : '#C25A1A', fontWeight: 600 }}>{route.delay}</td>
                  <td className="px-4 py-3 text-xs" style={{ color: 'var(--text-muted)' }}>{route.lastUpdated}</td>
                  <td className="px-4 py-3">
                    <button type="button" onClick={() => setSelected(route.id)} className="text-xs font-medium px-2 py-1 rounded border"
                      style={{ borderColor: 'rgba(180,162,136,0.55)', color: '#2F6F7E' }}>
                      Detail →
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {visible.length === 0 && (statusFilter !== 'All Status'
            ? <EmptyState icon={<Icon name="search" size={22} />} title={`No ${statusFilter.toLowerCase()} routes`} action={{ label: 'Show all routes', run: () => setStatusFilter('All Status') }} />
            : <EmptyState icon={<Icon name="route" size={22} />} title="No routes yet" message="Monitored routes will appear here." />)}
        </div>
      </div>

      {selectedRoute && (
        <RouteDetail route={selectedRoute} onClose={() => setSelected(null)} />
      )}
    </div>
  );
}
