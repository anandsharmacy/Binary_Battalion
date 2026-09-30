import { useState, useEffect, useMemo, useRef } from 'react';
import { MlTopAlertsPanel } from '@/components/MlRisk';
import MapViz, { type MapLayer } from '@/components/MapViz';
import Modal from '@/components/Modal';
import { SeverityBadge, StatusBadge, AccessibilityBadge } from '@/components/StatusBadge';
import type { Severity } from '@/data/demo';
import { getIncidents, subscribeToIncidents, type StoredIncident } from '@/lib/incidentStore';
import { getTasks, subscribeToTasks } from '@/lib/taskStore';
import { Card, CardHeader, BORDER, SURFACE_2, TEAL, GOLD } from '../fo/ui';

/* ────────────────────────────────────────────────────────────────
   Regional Control Center — Command Center dashboard.
   Distinct three-zone command layout (map anchor + critical panel +
   regional intelligence) using the exact shared design system.
──────────────────────────────────────────────────────────────── */

const MAP_LAYERS: { key: MapLayer; label: string; dot: string }[] = [
  { key: 'risk', label: 'Risk', dot: '#D97A1F' },
  { key: 'incidents', label: 'Incidents', dot: '#B3261E' },
  { key: 'routes', label: 'Routes', dot: '#2E9B63' },
  { key: 'logistics', label: 'Logistics', dot: '#9FB4CC' },
  { key: 'ml', label: 'ML risk', dot: '#B3261E' },
  { key: 'flood', label: 'Flood', dot: '#9FB4CC' },
  { key: 'landslide', label: 'Landslides', dot: '#D97A1F' },
];

const CC_NAVY = '#0E2A47';
const CC_RED = '#B3261E';
const CC_ORANGE = '#D97A1F';
const CC_MUTED = '#5B6472';
const CC_LINE = 'rgba(91,100,114,.24)';
const SEV_STYLE: Record<Severity, { label: string; icon: string; fg: string; bg: string; bd: string }> = {
  CRITICAL: { label: 'Critical', icon: '●', fg: CC_RED, bg: 'rgba(179,38,30,.08)', bd: 'rgba(179,38,30,.4)' },
  HIGH: { label: 'High', icon: '▲', fg: '#B0601A', bg: 'rgba(217,122,31,.1)', bd: 'rgba(217,122,31,.45)' },
  MODERATE: { label: 'Moderate', icon: '▲', fg: '#B0601A', bg: 'rgba(217,122,31,.1)', bd: 'rgba(217,122,31,.45)' },
  LOW: { label: 'Low', icon: '●', fg: '#1E6B45', bg: 'rgba(30,107,69,.08)', bd: 'rgba(30,107,69,.35)' },
};
const prettyStatus = (s?: string) => (s || '—').replace(/_/g, ' ').toLowerCase().replace(/^./, c => c.toUpperCase());

function riskColor(s: number) {
  return s > 75 ? '#BE2424' : s > 60 ? '#C25A1A' : s > 40 ? '#C4861A' : '#2D6B4F';
}

export default function CommandCenter({ setPage }: { setPage?: (p: string) => void }) {
  const [incidents, setIncidents] = useState(() => getIncidents());
  const [tasks, setTasks] = useState(() => getTasks());
  const [overall, setOverall] = useState(72);
  const [analyzing, setAnalyzing] = useState(false);
  const [refresh, setRefresh] = useState<'idle' | 'busy' | 'done'>('idle');
  const [updatedTick, setUpdatedTick] = useState('just now');
  const [mapLayers, setMapLayers] = useState<Record<MapLayer, boolean>>({ risk: true, incidents: true, routes: true, logistics: true, ml: false, flood: false, landslide: false });
  const [reviewIncident, setReviewIncident] = useState<StoredIncident | null>(null);
  const mapBoxRef = useRef<HTMLElement>(null);
  const [fullscreen, setFullscreen] = useState(false);
  const [mapFsHeight, setMapFsHeight] = useState(0);

  useEffect(() => {
    const sync = () => {
      const on = document.fullscreenElement === mapBoxRef.current;
      setFullscreen(on);
      if (on) setMapFsHeight(window.innerHeight - 47);
    };
    document.addEventListener('fullscreenchange', sync);
    window.addEventListener('resize', sync);
    return () => { document.removeEventListener('fullscreenchange', sync); window.removeEventListener('resize', sync); };
  }, []);

  const toggleFullscreen = () => {
    if (document.fullscreenElement) void document.exitFullscreen();
    else void mapBoxRef.current?.requestFullscreen();
  };

  useEffect(() => subscribeToIncidents(stored => setIncidents(stored)), []);
  useEffect(() => subscribeToTasks(stored => setTasks(stored)), []);

  const liveRoutes = useMemo(() => {
    const grouped = new Map<string, { id: string; name: string; risk: number; accessibility: number; incidents: number; status: string; weather: string; eta: string; distance: string; delay: string; lastUpdated: string; floodRisk: Severity; landslideRisk: Severity }>();

    incidents.forEach(incident => {
      const existing = grouped.get(incident.route) ?? {
        id: incident.route,
        name: incident.route,
        risk: 0,
        accessibility: 100,
        incidents: 0,
        status: 'Open',
        weather: 'Monitoring',
        eta: 'Pending',
        distance: 'N/A',
        delay: 'None',
        lastUpdated: incident.reportedTime,
        floodRisk: 'LOW',
        landslideRisk: 'LOW',
      };
      const nextRisk = Math.max(existing.risk, incident.riskScore);
      const nextAccessibility = Math.max(20, Math.min(100, existing.accessibility - (incident.severity === 'CRITICAL' ? 30 : incident.severity === 'HIGH' ? 20 : incident.severity === 'MODERATE' ? 12 : 6)));
      grouped.set(incident.route, {
        ...existing,
        risk: nextRisk,
        accessibility: nextAccessibility,
        incidents: existing.incidents + 1,
        status: incident.status === 'RESOLVED' ? 'Open' : incident.status === 'ESCALATED' ? 'Restricted' : incident.status === 'PENDING_VERIFICATION' ? 'Restricted' : 'Open',
        weather: incident.severity === 'CRITICAL' ? 'Severe' : incident.severity === 'HIGH' ? 'Heavy Rain' : 'Monitoring',
        eta: incident.estimatedDisruption,
        floodRisk: incident.severity === 'LOW' ? 'LOW' : incident.severity === 'MODERATE' ? 'MODERATE' : incident.severity === 'HIGH' ? 'HIGH' : 'CRITICAL',
        landslideRisk: incident.severity === 'CRITICAL' ? 'CRITICAL' : incident.severity === 'HIGH' ? 'HIGH' : 'MODERATE',
      });
    });

    return Array.from(grouped.values()).slice(0, 6);
  }, [incidents]);

  const liveVehicles = useMemo(() => {
    return tasks.slice(0, 5).map(task => ({
      id: task.id,
      cargo: task.title,
      origin: 'Regional HQ',
      destination: task.location,
      currentLocation: task.location,
      route: task.relatedIncident ?? task.location,
      eta: task.deadline,
      delay: task.status === 'Escalated' ? 'High' : task.status === 'In Progress' ? '+30m' : 'None',
      risk: task.priority,
      status: task.status === 'Escalated' ? 'At Risk' : task.status === 'In Progress' ? 'Delayed' : 'On Time',
    }));
  }, [tasks]);

  const activeIncidents = useMemo(
    () => incidents.filter(incident => !['RESOLVED', 'CLOSED'].includes(incident.status)),
    [incidents]
  );

  const criticalIncidents = useMemo(
    () => activeIncidents.filter(incident => incident.severity === 'CRITICAL' || incident.status === 'ESCALATED').slice(0, 5),
    [activeIncidents]
  );

  const affectedRoutes = useMemo(
    () => Array.from(new Set(activeIncidents.map(incident => incident.route))).filter(Boolean),
    [activeIncidents]
  );

  const atRiskLogistics = useMemo(
    () => tasks.filter(task => ['New', 'In Progress', 'Escalated'].includes(task.status)).length + activeIncidents.filter(incident => incident.affectedLogistics > 0).length,
    [tasks, activeIncidents]
  );

  const districtsOnAlert = useMemo(
    () => Array.from(new Set(activeIncidents.map(incident => incident.location.split(',').pop()?.trim() || incident.location))).filter(Boolean).length,
    [activeIncidents]
  );

  const regionalAccessibility = useMemo(() => {
    if (!activeIncidents.length) return 76;
    const averageRisk = activeIncidents.reduce((sum, incident) => sum + incident.riskScore, 0) / activeIncidents.length;
    return Math.max(20, Math.min(100, Math.round(100 - averageRisk * 0.5)));
  }, [activeIncidents]);

  const criticalList = useMemo(() => criticalIncidents.map(incident => ({
    incident,
    sev: incident.severity,
    title: incident.status === 'ESCALATED' ? `Escalated: ${incident.type}` : `${incident.type} — ${incident.location}`,
    meta: [
      ['Route', incident.route ?? '—'],
      ['Status', incident.status ?? '—'],
      ['Reported', incident.reportedTime ?? '—'],
    ],
    time: incident.reportedTime ?? '—',
    btn: 'Review Incident',
  })), [criticalIncidents]);

  const riskList = useMemo(() => {
    const routeMap = new Map<string, { score: number; level: Severity; label: string; trend: string }>();

    activeIncidents.forEach(incident => {
      const current = routeMap.get(incident.route) ?? { score: 0, level: incident.severity, label: incident.route, trend: 'Watchlist' };
      routeMap.set(incident.route, {
        score: Math.max(current.score, incident.riskScore),
        level: incident.severity,
        label: incident.route,
        trend: current.trend,
      });
    });

    return Array.from(routeMap.values()).slice(0, 5).map(item => ({
      label: item.label,
      score: item.score,
      level: item.level,
      trend: item.score >= 75 ? 'Escalating' : 'Monitoring',
    }));
  }, [activeIncidents]);

  const districtRows = useMemo(() => {
    const grouped = new Map<string, { name: string; risk: Severity; acc: number; inc: number; alerts: number; routes: Set<string>; impact: string; status: string }>();

    activeIncidents.forEach(incident => {
      const key = incident.location.split(',').slice(-2).join(', ') || incident.location;
      const existing = grouped.get(key) ?? {
        name: key,
        risk: 'LOW',
        acc: 100,
        inc: 0,
        alerts: 0,
        routes: new Set<string>(),
        impact: 'Monitoring',
        status: 'Active',
      };

      const currentRisk = incident.severity === 'CRITICAL' ? 4 : incident.severity === 'HIGH' ? 3 : incident.severity === 'MODERATE' ? 2 : 1;
      const maxRiskIndex = { LOW: 1, MODERATE: 2, HIGH: 3, CRITICAL: 4 };
      const nextRisk = maxRiskIndex[existing.risk] >= currentRisk ? existing.risk : incident.severity;
      existing.risk = nextRisk;
      existing.acc = Math.max(20, Math.min(100, 100 - Math.round((incident.riskScore + existing.inc * 8) / (existing.inc + 1))));
      existing.inc += 1;
      existing.alerts += incident.severity === 'CRITICAL' || incident.severity === 'HIGH' ? 1 : 0;
      existing.routes.add(incident.route);
      existing.impact = incident.estimatedDisruption || 'Monitoring';
      existing.status = incident.status === 'ESCALATED' ? 'Escalated' : 'Active';
      grouped.set(key, existing);
    });

    return Array.from(grouped.values()).slice(0, 5).map(entry => ({
      name: entry.name,
      risk: entry.risk,
      acc: entry.acc,
      inc: String(entry.inc),
      alerts: String(entry.alerts),
      routes: String(entry.routes.size),
      impact: entry.impact,
      status: entry.status,
    }));
  }, [activeIncidents]);

  const predictionRows = useMemo(() => {
    return activeIncidents.slice(0, 3).map((incident, index) => ({
      title: `${incident.type} risk watch`,
      rows: [
        ['Route', incident.route],
        ['Likelihood', `${Math.min(98, incident.riskScore + (index * 6))}%`],
        ['Window', index === 0 ? 'Next 3 hrs' : index === 1 ? 'Next 6 hrs' : 'Next 12 hrs'],
      ],
      confidence: Math.min(98, incident.riskScore + (index * 4)),
    }));
  }, [activeIncidents]);

  const priorityActions = useMemo(() => {
    const actionMap: Array<{ sev: Severity; label: string; loc: string; time: string }> = [];

    activeIncidents.slice(0, 4).forEach(incident => {
      actionMap.push({
        sev: incident.severity,
        label: `${incident.type} at ${incident.location}`,
        loc: incident.route,
        time: incident.reportedTime,
      });
    });

    tasks.filter(task => ['New', 'In Progress', 'Escalated'].includes(task.status)).slice(0, 2).forEach(task => {
      actionMap.push({
        sev: task.priority,
        label: task.title,
        loc: task.location,
        time: task.created,
      });
    });

    return actionMap.slice(0, 5);
  }, [activeIncidents, tasks]);

  const alertSummary = useMemo(() => [
    { label: 'Critical', value: activeIncidents.filter(incident => incident.severity === 'CRITICAL').length, sev: 'CRITICAL' as Severity },
    { label: 'High', value: activeIncidents.filter(incident => incident.severity === 'HIGH').length, sev: 'HIGH' as Severity },
    { label: 'Moderate', value: activeIncidents.filter(incident => incident.severity === 'MODERATE').length, sev: 'MODERATE' as Severity },
    { label: 'Low', value: activeIncidents.filter(incident => incident.severity === 'LOW').length, sev: 'LOW' as Severity },
  ], [activeIncidents]);

  useEffect(() => {
    const t1 = setTimeout(() => setAnalyzing(true), 1200);
    const t2 = setTimeout(() => {
      setOverall(regionalAccessibility);
      setAnalyzing(false);
    }, 2400);
    return () => { clearTimeout(t1); clearTimeout(t2); };
  }, [regionalAccessibility]);

  const doRefresh = () => {
    setRefresh('busy');
    setTimeout(() => { setRefresh('done'); setUpdatedTick('just now'); }, 1200);
  };

  return (
    <div className="space-y-5 max-w-screen-2xl">

      {/* Header */}
      <div className="flex items-baseline gap-3.5 flex-wrap">
        <h1 className="text-[20px] font-extrabold" style={{ color: CC_NAVY }}>Regional Control Center</h1>
        <span className="text-[12.5px]" style={{ color: CC_MUTED }}>North Eastern Region · live situational awareness</span>
        <div className="ml-auto flex items-center gap-2 self-center">
          <span className="inline-flex items-center gap-1.5 text-[11.5px] font-semibold px-2.5 py-1 rounded border"
            style={{ color: '#1E6B45', borderColor: 'rgba(30,107,69,.35)' }}>
            <span className="w-[7px] h-[7px] rounded-full" style={{ background: '#1E6B45' }} />System operational
          </span>
          <button onClick={doRefresh} disabled={refresh === 'busy'}
            className="text-[11.5px] font-semibold px-2.5 py-1 rounded border disabled:opacity-70 hover:bg-[#EEF1F4]"
            style={{ color: '#1B3F63', borderColor: CC_LINE, background: '#FBFBF9' }}>
            {refresh === 'busy' ? '↻ Updating…' : refresh === 'done' ? `✓ Updated ${updatedTick}` : '↻ Refresh'}
          </button>
        </div>
      </div>

      {/* KPI strip */}
      <div className="flex flex-wrap rounded-[5px] border overflow-hidden" style={{ background: '#FBFBF9', borderColor: CC_LINE }}>
        {[
          { v: activeIncidents.length, l: ['Active', 'incidents'], c: CC_NAVY },
          { v: criticalIncidents.length, l: ['Critical', criticalIncidents.length === 1 ? 'incident' : 'incidents'], c: CC_RED, hot: criticalIncidents.length > 0 },
          { v: affectedRoutes.length, l: ['Affected', affectedRoutes.length === 1 ? 'route' : 'routes'], c: CC_ORANGE },
          { v: atRiskLogistics, l: ['At-risk', 'logistics'], c: '#1E6B45' },
          { v: districtsOnAlert, l: ['District', 'on alert'], c: CC_NAVY },
        ].map(k => (
          <div key={k.l[0]} className="flex-1 min-w-[140px] flex items-center gap-2.5 px-4 py-2.5 border-r"
            style={{ borderColor: 'rgba(91,100,114,.16)', background: k.hot ? 'rgba(179,38,30,.05)' : undefined }}>
            <span className="text-[20px] font-extrabold tabular-nums" style={{ color: k.c }}>{k.v}</span>
            <span className="text-xs leading-tight" style={{ color: k.hot ? CC_RED : '#3A4048', fontWeight: k.hot ? 600 : 400 }}>{k.l[0]}<br />{k.l[1]}</span>
          </div>
        ))}
        <div className="flex-[1.4] min-w-[200px] flex items-center gap-3 px-4 py-2.5">
          <span className="text-[20px] font-extrabold tabular-nums" style={{ color: CC_NAVY }}>{regionalAccessibility}<span className="text-xs font-semibold" style={{ color: CC_MUTED }}>/100</span></span>
          <div className="flex-1 flex flex-col gap-1.5">
            <span className="text-xs" style={{ color: '#3A4048' }}>Regional accessibility</span>
            <div className="h-[5px] rounded-sm overflow-hidden" style={{ background: 'rgba(91,100,114,.16)' }}>
              <div className="h-full" style={{ width: `${regionalAccessibility}%`, background: regionalAccessibility >= 70 ? '#1E6B45' : regionalAccessibility >= 45 ? CC_ORANGE : CC_RED }} />
            </div>
          </div>
        </div>
      </div>

      {/* Map + critical situation */}
      <div className="grid grid-cols-1 xl:grid-cols-[minmax(0,1fr)_332px] gap-3.5">
        <section ref={mapBoxRef} className="flex flex-col rounded-[5px] border overflow-hidden" style={{ background: '#FBFBF9', borderColor: CC_LINE }}>
          <div className="min-h-[46px] flex items-center gap-3 px-3.5 py-2 border-b" style={{ borderColor: CC_LINE }}>
            <h2 className="text-sm font-bold whitespace-nowrap" style={{ color: CC_NAVY }}>Regional Situation Map</h2>
            <div className="w-px h-[22px] flex-none" style={{ background: CC_LINE }} />
            <div className="flex gap-1 flex-wrap flex-1 min-w-0">
              {MAP_LAYERS.map(({ key, label, dot }) => {
                const on = mapLayers[key];
                return (
                  <button key={key} onClick={() => setMapLayers(prev => ({ ...prev, [key]: !prev[key] }))} aria-pressed={on}
                    className="text-[11.5px] font-semibold px-2 py-1 rounded border flex items-center gap-1.5 whitespace-nowrap"
                    style={{ borderColor: on ? CC_NAVY : 'rgba(91,100,114,.3)', background: on ? CC_NAVY : 'transparent', color: on ? '#fff' : CC_MUTED }}>
                    <span className="w-[7px] h-[7px] rounded-sm" style={{ background: on ? dot : 'rgba(91,100,114,.35)' }} />{label}
                  </button>
                );
              })}
            </div>
            <button onClick={toggleFullscreen} aria-label={fullscreen ? 'Exit full screen' : 'Full screen map'} title={fullscreen ? 'Exit full screen (Esc)' : 'Full screen'}
              className="flex-none w-8 h-8 grid place-items-center rounded border hover:bg-[#EEF1F4]"
              style={{ borderColor: 'rgba(91,100,114,.3)', color: CC_NAVY }}>
              <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                <path d={fullscreen ? 'M9 3v6H3M15 3v6h6M9 21v-6H3M15 21v-6h6' : 'M3 9V3h6M21 9V3h-6M3 15v6h6M21 15v6h-6'} />
              </svg>
            </button>
          </div>
          <div className={fullscreen ? 'flex-1 min-h-0' : ''}>
            <MapViz incidents={incidents} routes={liveRoutes} vehicles={liveVehicles} height={fullscreen ? mapFsHeight : 560} showLegend layers={mapLayers} rounded="0" />
          </div>
        </section>

        <aside className="flex flex-col rounded-[5px] border overflow-hidden xl:max-h-[607px]" style={{ background: '#FBFBF9', borderColor: CC_LINE }}>
          <div className="px-4 py-3 flex items-baseline gap-2" style={{ borderBottom: `1.5px solid ${CC_NAVY}` }}>
            <h2 className="text-sm font-bold" style={{ color: CC_NAVY }}>Critical Situation</h2>
            <span className="text-[11.5px]" style={{ color: CC_MUTED }}>highest-priority events</span>
          </div>
          <div className="flex-1 overflow-y-auto min-h-0">
            {criticalList.length === 0 && (
              <div className="px-4 py-8 text-center text-xs" style={{ color: CC_MUTED }}>No critical or escalated incidents right now.</div>
            )}
            {criticalList.map((c, i) => {
              const st = SEV_STYLE[c.sev];
              return (
                <button key={`${c.incident.id}-${i}`} onClick={() => setReviewIncident(c.incident)}
                  className="w-full text-left px-4 py-3 flex flex-col gap-1.5 border-b hover:bg-[rgba(14,42,71,.035)]"
                  style={{ borderColor: 'rgba(91,100,114,.14)' }}>
                  <div className="flex items-center gap-2">
                    <span className="inline-flex items-center gap-1.5 text-[11px] font-bold px-1.5 py-0.5 rounded-[3px] border"
                      style={{ color: st.fg, background: st.bg, borderColor: st.bd }}>
                      {st.icon} {st.label}
                    </span>
                    <span className="ml-auto text-[11px] tabular-nums" style={{ color: CC_MUTED }}>{c.time}</span>
                  </div>
                  <div className="text-[13.5px] font-bold" style={{ color: '#1A2230' }}>{c.title}</div>
                  <div className="grid grid-cols-[62px_1fr] gap-x-2 gap-y-0.5 text-[11.5px]">
                    <span style={{ color: CC_MUTED }}>Route</span><span style={{ color: '#1A2230' }}>{c.incident.route || 'Not provided'}</span>
                    <span style={{ color: CC_MUTED }}>Status</span><span className="font-semibold" style={{ color: '#1A2230' }}>{prettyStatus(c.incident.status)}</span>
                  </div>
                  <span className="text-xs font-semibold" style={{ color: '#1B3F63' }}>Review incident →</span>
                </button>
              );
            })}
          </div>
          <div className="p-3 px-4 border-t" style={{ borderColor: CC_LINE }}>
            <button onClick={() => setPage?.('incidents')}
              className="w-full h-[38px] rounded text-[13px] font-semibold text-white hover:bg-[#1B3F63]"
              style={{ background: CC_NAVY }}>View all critical events</button>
          </div>
        </aside>
      </div>

      {/* Regional Risk Intelligence */}
      <Card>
        <CardHeader title="Regional Risk Intelligence"
          action={<span className="text-xs px-1.5 py-0.5 rounded" style={{ background: '#F0EFED', color: '#5A6670' }}>Rule-based · from reported incidents</span>} />
        <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3 p-4">
          {riskList.map((r, i) => {
            const score = i === 0 ? overall : r.score;
            return (
              <div key={r.label} className="rounded-lg border p-3" style={{ background: SURFACE_2, borderColor: BORDER }}>
                <div className="text-xs font-medium mb-1" style={{ color: '#5A6670' }}>{r.label}</div>
                <div className="flex items-baseline gap-1 mb-1.5">
                  {i === 0 && analyzing
                    ? <span className="text-sm animate-pulse" style={{ color: GOLD }}>✦ Analyzing…</span>
                    : <><span className="text-2xl font-bold transition-all" style={{ color: riskColor(score) }}>{score}</span>
                        <span className="text-xs" style={{ color: 'var(--text-muted)' }}>/100</span></>}
                </div>
                <div className="flex items-center justify-between">
                  <SeverityBadge severity={r.level} />
                  {i === 0 && !analyzing && <span className="text-xs font-semibold" style={{ color: '#BE2424' }}>+6</span>}
                </div>
                {r.trend && <div className="text-xs mt-1.5" style={{ color: '#BE2424' }}>{r.trend}</div>}
                <div className="mt-2 h-1.5 rounded-full overflow-hidden" style={{ background: BORDER }}>
                  <div className="h-full rounded-full transition-all duration-700" style={{ width: `${score}%`, background: riskColor(score) }} />
                </div>
              </div>
            );
          })}
        </div>
      </Card>

      {/* Road disruption risk — live model output; raising an alert is always an officer's decision (ML-006) */}
      <Card>
        <CardHeader title="Road Disruption Risk" sub="Model output · highest-risk corridor segments today" />
        <div className="p-4">
          <MlTopAlertsPanel canPromote />
        </div>
      </Card>

      {/* District status + Live logistics */}
      <div className="grid grid-cols-1 xl:grid-cols-3 gap-5">
        <Card className="xl:col-span-2">
          <CardHeader title="District Situation" sub="Regional comparison"
            action={<button onClick={() => setPage?.('analytics')} className="text-xs font-medium px-3 py-1.5 rounded border" style={{ borderColor: BORDER, color: TEAL }}>View All Districts →</button>} />
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr style={{ background: SURFACE_2 }}>
                  {['District', 'Risk', 'Access.', 'Incidents', 'Alerts', 'Routes', 'Logistics', 'Status'].map(h => (
                    <th key={h} scope="col" className="text-left px-3 py-2.5 text-xs font-semibold uppercase tracking-wider" style={{ color: '#5A6670' }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {districtRows.map((d, i) => (
                  <tr key={d.name} className="transition-colors cursor-pointer hover:bg-black/[0.02]"
                    style={{ background: i % 2 === 0 ? 'transparent' : 'rgba(243,235,220,0.4)' }}>
                    <td className="px-3 py-2.5 text-xs font-medium" style={{ color: '#17212B' }}>{d.name}</td>
                    <td className="px-3 py-2.5"><SeverityBadge severity={d.risk} /></td>
                    <td className="px-3 py-2.5"><AccessibilityBadge score={d.acc} /></td>
                    <td className="px-3 py-2.5 text-xs" style={{ color: '#17212B' }}>{d.inc}</td>
                    <td className="px-3 py-2.5 text-xs" style={{ color: '#17212B' }}>{d.alerts}</td>
                    <td className="px-3 py-2.5 text-xs" style={{ color: '#17212B' }}>{d.routes}</td>
                    <td className="px-3 py-2.5 text-xs" style={{ color: '#5A6670' }}>{d.impact}</td>
                    <td className="px-3 py-2.5"><StatusBadge status={d.status} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>

        {/* Live logistics */}
        <Card className="flex flex-col">
          <CardHeader title="Live Logistics"
            action={<span className="inline-flex items-center gap-1 text-xs" style={{ color: '#BE2424' }}><span className="w-1.5 h-1.5 rounded-full inline-block animate-pulse" style={{ background: '#BE2424' }} />LIVE</span>} />
          <div className="flex-1 divide-y" style={{ borderColor: SURFACE_2 }}>
            {liveVehicles.slice(0, 5).map(v => (
              <div key={v.id} className="px-4 py-2.5 flex items-center gap-3">
                <div className="flex-1 min-w-0">
                  <div className="text-xs font-mono font-semibold" style={{ color: TEAL }}>{v.id}</div>
                  <div className="text-xs" style={{ color: 'var(--text-muted)' }}>{v.route} → {v.destination}</div>
                </div>
                <StatusBadge status={v.status} />
                <SeverityBadge severity={v.risk} />
                <span className="text-xs w-10 text-right" style={{ color: '#5A6670' }}>{v.delay === 'None' ? 'ETA' : v.delay}</span>
              </div>
            ))}
          </div>
          <div className="px-4 py-2 border-t flex items-center justify-end" style={{ borderColor: BORDER }}>
            <button onClick={() => setPage?.('logistics')} className="text-xs font-medium" style={{ color: TEAL }}>View Live Logistics →</button>
          </div>
        </Card>
      </div>

      {/* AI predictions + Priority actions + side column */}
      <div className="grid grid-cols-1 xl:grid-cols-3 gap-5">
        {/* AI predictions */}
        <Card>
          <CardHeader title="Incident Risk Watch"
            action={<span className="text-xs" style={{ color: 'var(--text-muted)' }}>Rule-based</span>} />
          <div className="p-4 space-y-3">
            {predictionRows.map(p => (
              <div key={p.title} className="rounded-lg border p-3" style={{ background: SURFACE_2, borderColor: BORDER }}>
                <div className="flex items-center justify-between mb-1.5">
                  <span className="text-xs font-semibold" style={{ color: '#17212B' }}>{p.title}</span>
                  <span className="text-xs font-bold" style={{ color: '#2D6B4F' }}>{p.confidence}%</span>
                </div>
                <div className="flex flex-wrap gap-x-3 gap-y-0.5">
                  {p.rows.map(([k, v]) => (
                    <span key={k} className="text-xs" style={{ color: '#5A6670' }}><span style={{ color: 'var(--text-muted)' }}>{k}: </span>{v}</span>
                  ))}
                </div>
                <div className="flex items-center gap-1 mt-1.5">
                  <span className="text-xs" style={{ color: 'var(--text-muted)' }}>Rule-based estimate from reported incidents — not model output</span></div>
              </div>
            ))}
            <button onClick={() => setPage?.('ai')} className="w-full text-xs font-medium px-3 py-2 rounded border" style={{ borderColor: BORDER, color: TEAL }}>View All Predictions →</button>
          </div>
        </Card>

        {/* Priority actions */}
        <Card>
          <CardHeader title="Priority Actions" sub="Recommended next steps" />
          <div className="divide-y" style={{ borderColor: SURFACE_2 }}>
            {priorityActions.map((a, i) => (
              <div key={`${a.label}-${i}`} className="px-4 py-3 flex items-center gap-3">
                <SeverityBadge severity={a.sev} />
                <div className="flex-1 min-w-0">
                  <div className="text-xs font-medium" style={{ color: '#17212B' }}>{a.label}</div>
                  <div className="text-xs" style={{ color: 'var(--text-muted)' }}>{a.loc} · {a.time}</div>
                </div>
                <button className="text-xs font-medium px-2.5 py-1 rounded border" style={{ borderColor: BORDER, color: TEAL, minHeight: 32 }}>Review</button>
              </div>
            ))}
          </div>
        </Card>

        {/* Right column: alert summary + regional accessibility */}
        <div className="space-y-5">
          <Card>
            <CardHeader title="Alert Summary"
              action={<button onClick={() => setPage?.('alerts')} className="text-xs font-medium" style={{ color: TEAL }}>View Alerts →</button>} />
            <div className="grid grid-cols-2 gap-3 p-4">
              {alertSummary.map(a => (
                <div key={a.label} className="rounded-lg border p-3" style={{ background: SURFACE_2, borderColor: BORDER }}>
                  <div className="text-2xl font-bold leading-none mb-1" style={{ color: '#17212B' }}>{String(a.value).padStart(2, '0')}</div>
                  <SeverityBadge severity={a.sev} />
                </div>
              ))}
            </div>
          </Card>

          <Card>
            <CardHeader title="Regional Accessibility" />
            <div className="p-4">
              <div className="flex items-end justify-between mb-2">
                <div className="text-3xl font-bold leading-none" style={{ color: '#C25A1A' }}>{regionalAccessibility}<span className="text-sm" style={{ color: 'var(--text-muted)' }}>/100</span></div>
                <SeverityBadge severity={regionalAccessibility >= 75 ? 'MODERATE' : 'HIGH'} />
              </div>
              <div className="h-2 rounded-full overflow-hidden mb-3" style={{ background: BORDER }}>
                <div className="h-full rounded-full" style={{ width: `${regionalAccessibility}%`, background: '#C25A1A' }} />
              </div>
              {[
                ['Fully Accessible', Math.max(20, regionalAccessibility), '#2D6B4F'],
                ['Partially Accessible', Math.max(18, Math.round((100 - regionalAccessibility) * 0.6)), '#C4861A'],
                ['Restricted', Math.max(10, 100 - Math.max(20, regionalAccessibility) - Math.max(18, Math.round((100 - regionalAccessibility) * 0.6))), '#BE2424'],
              ].map(([l, v, c]) => (
                <div key={l as string} className="flex items-center justify-between text-xs py-1" style={{ color: '#5A6670' }}>
                  <span className="flex items-center gap-1.5"><span className="w-2 h-2 rounded-full inline-block" style={{ background: c as string }} />{l}</span>
                  <span className="font-medium" style={{ color: '#17212B' }}>{v}%</span>
                </div>
              ))}
            </div>
          </Card>
        </div>
      </div>

      {/* Incident Review Slide-over / Modal */}
      {reviewIncident && (
        <Modal open onClose={() => setReviewIncident(null)} labelledBy="review-title" side="right">
          <div className="ui-glass h-full w-[42rem] max-w-full overflow-y-auto shadow-2xl p-6 flex flex-col gap-5"
            style={{ borderLeft: '1px solid rgba(180,162,136,0.55)' }}>
            <div className="flex items-start justify-between border-b pb-4" style={{ borderColor: 'rgba(180,162,136,0.4)' }}>
              <div>
                <div className="font-mono text-xs mb-1" style={{ color: 'var(--text-muted)' }}>Incident ID: {reviewIncident.id}</div>
                <h2 id="review-title" className="font-semibold text-xl" style={{ color: '#17212B' }}>
                  {reviewIncident.type ?? 'Incident'} — {reviewIncident.location ?? 'Unknown Location'}
                </h2>
                <div className="flex items-center gap-2 mt-2">
                  <SeverityBadge severity={reviewIncident.severity ?? 'MODERATE'} />
                  <StatusBadge status={reviewIncident.status ?? 'ACTIVE'} />
                </div>
              </div>
              <button
                type="button"
                onClick={() => setReviewIncident(null)}
                aria-label="Close details"
                className="text-lg font-bold px-2 py-1 rounded hover:bg-black/10 transition-colors min-h-[28px] min-w-[28px] pointer-coarse:min-h-11 pointer-coarse:min-w-11"
                style={{ color: '#5A6670' }}>
                ✕
              </button>
            </div>

            {/* Details Table */}
            <div className="rounded-xl border overflow-hidden" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
              {[
                ['Incident ID', reviewIncident.id],
                ['Incident Type', reviewIncident.type ?? '—'],
                ['Severity Level', reviewIncident.severity ?? '—'],
                ['Workflow Status', reviewIncident.status ?? '—'],
                ['Location', reviewIncident.location ?? '—'],
                ['Corridor / Route', reviewIncident.route ?? '—'],
                ['Reported Date & Time', reviewIncident.reportedTime ?? '—'],
                ['Reporting Officer / Source', reviewIncident.reportedBy ?? 'Field Officer'],
                ['Assigned Officer', reviewIncident.assignedOfficer ?? '— Unassigned'],
                ['GPS Coordinates', reviewIncident.gpsCoords ?? 'Not specified'],
                ['Verification Status', reviewIncident.verification ?? 'Pending'],
                ['Nearby Landmark', reviewIncident.landmark || '—'],
                ['Road Condition', reviewIncident.roadCondition ?? 'Not assessed'],
                ['Vehicles Affected', String(reviewIncident.affectedLogistics ?? 0)],
                ['Estimated Blockage', reviewIncident.estimatedDisruption ?? 'Not estimated'],
              ].map(([label, val], idx) => (
                <div key={label} className="flex items-center px-4 py-2.5 text-xs border-b last:border-b-0"
                  style={{ background: idx % 2 === 0 ? 'rgba(250,247,240,0.82)' : 'rgba(238,228,210,0.55)', borderColor: 'rgba(180,162,136,0.3)' }}>
                  <span className="w-44 font-medium flex-shrink-0" style={{ color: '#5A6670' }}>{label}</span>
                  <span className="font-semibold" style={{ color: '#17212B' }}>{val}</span>
                </div>
              ))}
            </div>

            {/* Description */}
            <div className="rounded-xl border p-4" style={{ background: 'rgba(238,228,210,0.6)', borderColor: 'rgba(180,162,136,0.55)' }}>
              <div className="text-xs font-semibold uppercase tracking-wider mb-1" style={{ color: '#5A6670' }}>Incident Description</div>
              <p className="text-xs leading-relaxed" style={{ color: '#17212B' }}>
                {reviewIncident.description || 'No detailed description provided.'}
              </p>
            </div>

            {/* Map Preview */}
            <div>
              <div className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Incident Map Location</div>
              <div className="rounded-xl border overflow-hidden" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
                <MapViz incidents={[reviewIncident]} height={220} showLegend={false} rounded="0" />
              </div>
            </div>

            {/* Evidence if any */}
            {reviewIncident.evidence && reviewIncident.evidence.length > 0 && (
              <div>
                <div className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Supporting Evidence</div>
                <div className="grid grid-cols-2 gap-3">
                  {reviewIncident.evidence.map((file, fIdx) => (
                    <div key={fIdx} className="rounded-lg border p-2 text-xs" style={{ background: 'white', borderColor: 'rgba(180,162,136,0.55)' }}>
                      {file.type?.startsWith('image/') ? (
                        <img src={file.dataUrl} alt={file.name} className="h-28 w-full object-cover rounded mb-1" />
                      ) : (
                        <div className="h-28 flex items-center justify-center rounded bg-slate-100 mb-1" style={{ color: '#17324D' }}>
                          Video / Media File
                        </div>
                      )}
                      <div className="truncate font-medium" style={{ color: '#17212B' }}>{file.name}</div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Action buttons */}
            <div className="flex items-center justify-end gap-3 pt-2">
              <button
                onClick={() => setReviewIncident(null)}
                className="text-xs font-medium px-4 py-2 rounded border transition-colors cursor-pointer"
                style={{ borderColor: 'rgba(180,162,136,0.6)', color: '#5A6670', background: 'transparent' }}>
                Close
              </button>
              <button
                onClick={() => {
                  setPage?.('incidents');
                  setReviewIncident(null);
                }}
                className="text-xs font-semibold px-4 py-2 rounded transition-all cursor-pointer"
                style={{ background: '#17324D', color: 'white' }}>
                Open in Incidents Dashboard →
              </button>
            </div>
          </div>
        </Modal>
      )}

      <style>{`@keyframes fadeIn{from{opacity:0;transform:translateY(-4px)}to{opacity:1;transform:none}}`}</style>
    </div>
  );
}
