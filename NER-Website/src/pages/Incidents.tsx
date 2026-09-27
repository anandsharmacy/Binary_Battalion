import { useEffect, useMemo, useState } from 'react';
import MapViz from '@/components/MapViz';
import Modal from '@/components/Modal';
import EmptyState from '@/components/EmptyState';
import { notify, useRowFlash } from '@/lib/notify';
import { SeverityBadge, StatusBadge } from '@/components/StatusBadge';
import { incidents as initialIncidents } from '@/data/demo';
import type { Incident, IncidentStatus } from '@/data/demo';
import { getIncidents, subscribeToIncidents, updateIncident } from '@/lib/incidentStore';
import { createTaskFromIncident } from '@/lib/taskStore';
import { Icon } from '@/auth/Icons';

const tabs: { key: string; label: string; filter: (i: Incident) => boolean }[] = [
  { key: 'all', label: 'All', filter: () => true },
  { key: 'pending', label: 'Pending Verification', filter: i => i.status === 'PENDING_VERIFICATION' || i.status === 'UNDER_REVIEW' },
  { key: 'active', label: 'Active', filter: i => i.status === 'ACTIVE' },
  { key: 'escalated', label: 'Escalated', filter: i => i.status === 'ESCALATED' },
  { key: 'resolved', label: 'Resolved', filter: i => i.status === 'RESOLVED' },
];

const timeline = ['Reported', 'Verified', 'Assigned', 'Response in Progress', 'Resolved'];

function getTimelineStep(status: IncidentStatus) {
  if (status === 'PENDING_VERIFICATION' || status === 'UNDER_REVIEW') return 0;
  if (status === 'ACTIVE') return 3;
  if (status === 'ESCALATED') return 3;
  if (status === 'RESOLVED') return 4;
  return 0;
}

function IncidentDetail({ inc, onClose, onVerify, onAssign, onStatusChange, onCreateTask }: {
  inc: Incident; onClose: () => void;
  onVerify: (id: string) => void; onAssign: (id: string) => void;
  onStatusChange: (id: string, status: IncidentStatus) => void;
  onCreateTask: (id: string) => void;
}) {
  const step = getTimelineStep(inc.status);
  const [preview, setPreview] = useState<{ name: string; type: string; dataUrl: string } | null>(null);
  const mapIncidents = useMemo(() => [inc], [inc]);
        return (
          <Modal open onClose={onClose} labelledBy="incident-title" side="right">
            <div className="h-full w-[42rem] max-w-full overflow-y-auto shadow-2xl"
        style={{ background: 'rgba(250,247,240,0.82)', borderLeft: '1px solid rgba(180,162,136,0.55)' }}>
        <div className="px-5 py-4 border-b flex items-start justify-between"
                style={{ borderColor: 'rgba(180,162,136,0.55)', background: 'rgba(238,228,210,0.96)' }}>
          <div>
            <div className="font-mono text-xs mb-1" style={{ color: '#5A6670' }}>{inc.id}</div>
            <h2 id="incident-title" className="font-semibold text-lg" style={{ color: '#17212B' }}>{inc.type} — {inc.location}</h2>
            <div className="flex gap-2 mt-1">
              <SeverityBadge severity={inc.severity} />
              <StatusBadge status={inc.status} />
            </div>
          </div>
          <button type="button" onClick={onClose} aria-label="Close details"
            className="text-xl flex items-center justify-center rounded min-h-[28px] min-w-[28px] pointer-coarse:min-h-11 pointer-coarse:min-w-11"
            style={{ color: 'var(--text-muted)' }}>✕</button>
        </div>

        <div className="px-5 py-4 space-y-5">
          <div className="rounded-lg border p-3 flex flex-wrap items-center justify-between gap-3" style={{ background: 'rgba(238,228,210,0.88)', borderColor: 'rgba(180,162,136,0.55)' }}>
            <div>
              <div className="text-xs uppercase tracking-wider" style={{ color: 'var(--text-muted)' }}>Current workflow state</div>
              <div className="mt-1"><StatusBadge status={inc.status} /></div>
            </div>
            <div className="flex flex-wrap gap-2">
              {inc.verification === 'Pending' && <button onClick={() => { onVerify(inc.id); }} className="text-xs font-medium px-3 py-2 rounded" style={{ background: '#17324D', color: 'white' }}>Verify</button>}
              {inc.status !== 'ESCALATED' && inc.status !== 'RESOLVED' && <button onClick={() => { onStatusChange(inc.id, 'ESCALATED'); }} className="text-xs font-medium px-3 py-2 rounded border" style={{ color: '#BE2424', borderColor: '#F5B8B8', background: '#FEE9E9' }}>Escalate</button>}
              {inc.status === 'ACTIVE' && <button onClick={() => { onStatusChange(inc.id, 'RESOLVED'); }} className="text-xs font-medium px-3 py-2 rounded border" style={{ color: '#2D6B4F', borderColor: '#A8D4B8', background: '#EAF4EE' }}>Resolve</button>}
            </div>
          </div>
          {/* Timeline */}
          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-3" style={{ color: '#5A6670' }}>Response Timeline</h3>
            <div className="flex items-center gap-0">
              {timeline.map((t, i) => (
                <div key={t} className="flex items-center flex-1">
                  <div className="flex flex-col items-center">
                    <div className="w-5 h-5 rounded-full border-2 flex items-center justify-center text-xs font-bold"
                      style={{
                        background: i <= step ? '#17324D' : 'rgba(238,228,210,0.88)',
                        borderColor: i <= step ? '#17324D' : 'rgba(180,162,136,0.55)',
                        color: i <= step ? 'white' : 'var(--text-muted)',
                      }}>
                      {i < step ? '✓' : i + 1}
                    </div>
                    <span className="text-xs text-center mt-1 leading-tight w-16" style={{ color: i <= step ? '#17212B' : 'var(--text-muted)', fontSize: 11 }}>
                      {t}
                    </span>
                  </div>
                  {i < timeline.length - 1 && (
                    <div className="flex-1 h-0.5 mx-1" style={{ background: i < step ? '#17324D' : 'rgba(180,162,136,0.55)' }} />
                  )}
                </div>
              ))}
            </div>
          </div>

          {/* Info */}
          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Incident Information</h3>
            <div className="rounded-lg border" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
              {[
                { label: 'Type', value: inc.type },
                { label: 'Location', value: inc.location },
                { label: 'Route', value: inc.route },
                { label: 'Reported By', value: inc.reportedBy },
                { label: 'Reported Time', value: inc.reportedTime },
                { label: 'GPS Coordinates', value: inc.gpsCoords },
                { label: 'Verification', value: inc.verification },
                { label: 'Assigned Officer', value: inc.assignedOfficer ?? '— Not Assigned' },
              ].map((row, i) => (
                <div key={row.label} className="flex px-3 py-2" style={{ background: i % 2 === 0 ? 'rgba(250,247,240,0.82)' : 'rgba(243,235,220,0.55)' }}>
                  <span className="w-36 flex-shrink-0 text-xs" style={{ color: 'var(--text-muted)' }}>{row.label}</span>
                  <span className="text-xs font-medium" style={{ color: '#17212B' }}>{row.value}</span>
                </div>
              ))}
            </div>
          </div>

          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Location Map</h3>
            <div className="rounded-lg border overflow-hidden" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
              <MapViz incidents={mapIncidents} height={220} rounded="0" showLegend={false} />
            </div>
          </div>

          {/* Description */}
          <div className="rounded-lg p-3 border" style={{ background: 'rgba(238,228,210,0.88)', borderColor: 'rgba(180,162,136,0.55)' }}>
            <p className="text-xs leading-relaxed" style={{ color: '#5A6670' }}>{inc.description}</p>
          </div>

          {inc.evidence && inc.evidence.length > 0 && (
            <div>
              <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Evidence</h3>
              <div className="grid grid-cols-2 gap-3">
                {inc.evidence.map(file => (
                  <button type="button" key={`${inc.id}-${file.name}`} onClick={() => setPreview(file)}
                    className="rounded-lg border overflow-hidden text-left" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
                    {file.type.startsWith('image/') ? (
                      <img src={file.dataUrl} alt={file.name} className="h-32 w-full object-cover" />
                    ) : (
                      <div className="h-32 flex items-center justify-center" style={{ background: 'rgba(238,228,210,0.88)', color: '#17324D' }}>Video evidence</div>
                    )}
                    <div className="px-2 py-1.5 text-xs truncate" style={{ color: '#2F6F7E' }}>{file.name}</div>
                  </button>
                ))}
              </div>
            </div>
          )}

          {preview && (
            <Modal open onClose={() => setPreview(null)} labelledBy="evidence-title">
              <div className="relative max-w-4xl max-h-[90vh] rounded-lg overflow-hidden" style={{ background: '#17212B' }}>
                <h2 id="evidence-title" className="sr-only">Evidence: {preview.name}</h2>
                <button type="button" onClick={() => setPreview(null)} className="absolute top-2 right-2 z-10 rounded-full px-2 py-1 text-lg min-h-[28px] min-w-[28px] pointer-coarse:min-h-11 pointer-coarse:min-w-11" aria-label="Close evidence preview" style={{ background: 'rgba(0,0,0,0.65)', color: 'white' }}>✕</button>
                {preview.type.startsWith('image/') ? <img src={preview.dataUrl} alt={preview.name} className="max-h-[85vh] max-w-[90vw] object-contain" /> : <video src={preview.dataUrl} controls className="max-h-[85vh] max-w-[90vw]" />}
              </div>
            </Modal>
          )}

          {/* AI Risk */}
          <div className="rounded-lg border p-3" style={{ background: '#FEF8E6', borderColor: '#F5DFA8' }}>
            <div className="flex items-center gap-1.5 mb-2">
              <span style={{ color: '#D7A73A' }}>✦</span>
              <h3 className="text-xs font-semibold uppercase tracking-wider" style={{ color: '#5A6670' }}>AI Risk Assessment</h3>
            </div>
            <div className="flex items-center gap-3 mb-2">
              <div className="text-3xl font-bold" style={{ color: '#17212B' }}>{inc.riskScore}</div>
              <div>
                <div className="text-xs" style={{ color: '#5A6670' }}>Risk Score / 100</div>
                <SeverityBadge severity={inc.riskScore > 75 ? 'CRITICAL' : inc.riskScore > 50 ? 'HIGH' : inc.riskScore > 25 ? 'MODERATE' : 'LOW'} />
              </div>
              <div className="flex-1 ml-2">
                <div className="h-2 rounded-full overflow-hidden" style={{ background: 'rgba(180,162,136,0.55)' }}>
                  <div style={{ width: `${inc.riskScore}%`, background: inc.riskScore > 75 ? '#BE2424' : '#E07840' }} className="h-full rounded-full" />
                </div>
              </div>
            </div>
            <p className="text-xs" style={{ color: 'var(--text-muted)' }}>AI-generated estimate · Affected logistics: {inc.affectedLogistics} convoys · {inc.estimatedDisruption}</p>
          </div>

          {/* Actions */}
          <div>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Actions</h3>
            <div className="flex flex-wrap gap-2">
              {inc.verification === 'Pending' && (
                <button onClick={() => { onVerify(inc.id); }}
                  className="text-xs font-medium px-3 py-2 rounded border"
                  style={{ background: '#17324D', color: 'white', borderColor: '#17324D' }}>
                  ✓ Verify Incident
                </button>
              )}
              <button onClick={() => { onAssign(inc.id); }}
                className="text-xs font-medium px-3 py-2 rounded border"
                style={{ background: '#2F6F7E', color: 'white', borderColor: '#2F6F7E' }}>
                Assign Officer
              </button>
              <button onClick={() => { onCreateTask(inc.id); }} className="text-xs font-medium px-3 py-2 rounded border"
                style={{ borderColor: 'rgba(180,162,136,0.55)', color: '#5A6670' }}>
                Create Task
              </button>
              <button onClick={() => { onStatusChange(inc.id, 'ESCALATED'); }} className="text-xs font-medium px-3 py-2 rounded border"
                style={{ borderColor: '#F5B8B8', color: '#BE2424', background: '#FEE9E9' }}>
                Escalate
              </button>
              {inc.status === 'ACTIVE' && (
                <button onClick={() => { onStatusChange(inc.id, 'RESOLVED'); }} className="text-xs font-medium px-3 py-2 rounded border"
                  style={{ borderColor: '#A8D4B8', color: '#2D6B4F', background: '#EAF4EE' }}>
                  ✓ Resolve Incident
                </button>
              )}
            </div>
          </div>
        </div>
      </div>
    </Modal>
  );
}

export default function Incidents() {
  const [tab, setTab] = useState('all');
  const [severityFilter, setSeverityFilter] = useState('All Severity');
  const [typeFilter, setTypeFilter] = useState('All Types');
  const [selected, setSelected] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [incList, setIncList] = useState<Incident[]>(() => [...initialIncidents, ...getIncidents()]);
  const [flashId, setFlashId] = useRowFlash();

  useEffect(() => subscribeToIncidents(stored => setIncList([...initialIncidents, ...stored])), []);

  const current = tabs.find(t => t.key === tab)!;
  const needle = query.trim().toLowerCase();
  const filtered = incList.filter(current.filter).filter(incident =>
    (severityFilter === 'All Severity' || incident.severity === severityFilter.toUpperCase()) &&
    (typeFilter === 'All Types' || incident.type === typeFilter) &&
    (!needle || [incident.id, incident.location, incident.route].some(v => v.toLowerCase().includes(needle)))
  );
  const filtersActive = tab !== 'all' || severityFilter !== 'All Severity' || typeFilter !== 'All Types' || query !== '';
  const clearFilters = () => { setTab('all'); setSeverityFilter('All Severity'); setTypeFilter('All Types'); setQuery(''); };
  const selectedInc = incList.find(i => i.id === selected);

  type Patch = Parameters<typeof updateIncident>[1];
  const apply = (id: string, patch: Patch) => {
    updateIncident(id, patch);
    setIncList(prev => prev.map(i => i.id === id ? { ...i, ...patch } : i));
  };
  // Apply a change and offer Undo that restores exactly the fields it touched.
  const change = (id: string, patch: Patch, message: string) => {
    const before = incList.find(i => i.id === id);
    if (!before) return;
    const undo: Patch = Object.fromEntries(Object.keys(patch).map(k => [k, before[k as keyof Patch]]));
    apply(id, patch);
    notify(message, { action: { label: 'Undo', run: () => { apply(id, undo); setFlashId(id); notify('Change undone.'); } } });
  };
  const handleVerify = (id: string) => change(id, { verification: 'Verified', status: 'ACTIVE' }, 'Incident verified and marked Active.');
  const handleAssign = (id: string) => change(id, { assignedOfficer: 'FO-101', status: 'ACTIVE' }, 'Assigned to FO-101.');
  const handleStatusChange = (id: string, status: IncidentStatus) => change(id, { status },
    status === 'ESCALATED' ? 'Incident marked Escalated.' : status === 'RESOLVED' ? 'Incident marked Resolved.' : `Status set to ${status}.`);
  const handleCreateTask = (id: string) => {
    const incident = incList.find(item => item.id === id);
    if (!incident) return;
    createTaskFromIncident({
      incidentId: incident.id,
      title: `Follow up: ${incident.type} at ${incident.location}`,
      location: incident.location,
      priority: incident.severity,
      description: incident.description,
    });
    setIncList(prev => prev.map(i => i.id === id ? { ...i, status: i.status === 'PENDING_VERIFICATION' ? 'ACTIVE' : i.status } : i));
    updateIncident(id, { status: 'ACTIVE' });
    notify('Task created from this incident.');
  };

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div>
        <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Incidents</h1>
        <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>Manage and verify incident reports across the district</p>
      </div>

      {/* Summary stats */}
      <div className="grid grid-cols-3 sm:grid-cols-5 gap-3">
        {tabs.map(t => {
          const count = incList.filter(t.filter).length;
          return (
            <button key={t.key} onClick={() => setTab(t.key)} aria-pressed={tab === t.key}
              className="ui-card rounded-xl border p-3 text-left transition-all"
              style={{
                background: tab === t.key ? '#17324D' : 'rgba(250,247,240,0.82)',
                borderColor: tab === t.key ? '#17324D' : 'rgba(180,162,136,0.55)',
              }}>
              <div className="text-2xl font-bold" style={{ color: tab === t.key ? 'white' : '#17212B' }}>{count}</div>
              <div className="text-xs mt-0.5" style={{ color: tab === t.key ? '#8AAFC8' : '#5A6670' }}>{t.label}</div>
            </button>
          );
        })}
      </div>

      {/* Tabs */}
      <div className="flex gap-0 border-b overflow-x-auto" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
        {tabs.map(t => (
          <button key={t.key} onClick={() => setTab(t.key)}
            className="px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors"
            style={{
              borderBottomColor: tab === t.key ? '#17324D' : 'transparent',
              color: tab === t.key ? '#17324D' : '#5A6670',
            }}>
            {t.label}
            <span className="ml-1.5 text-xs px-1.5 py-0.5 rounded-full"
              style={{ background: 'rgba(238,228,210,0.88)', color: '#5A6670' }}>
              {incList.filter(t.filter).length}
            </span>
          </button>
        ))}
      </div>

      {/* Table */}
      <div className="rounded-xl border shadow-sm overflow-hidden"
        style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>

        {/* Table header with actions */}
        <div className="px-4 py-3 border-b flex flex-wrap items-center justify-between gap-2"
          style={{ borderColor: 'rgba(180,162,136,0.55)', background: 'rgba(238,228,210,0.88)' }}>
          <span className="text-sm font-medium" style={{ color: '#17212B' }}>
            {filtered.length} incident{filtered.length !== 1 ? 's' : ''}
          </span>
          <div className="flex flex-wrap gap-2 w-full sm:w-auto">
            <input type="search" value={query} onChange={e => setQuery(e.target.value)}
              onKeyDown={e => { if (e.key === 'Escape' && query) { e.preventDefault(); setQuery(''); } }}
              aria-label="Search incidents" placeholder="Search ID, location or route"
              className="text-xs px-2 py-1.5 rounded border w-full sm:w-52"
              style={{ borderColor: 'rgba(180,162,136,0.55)', background: 'rgba(250,247,240,0.82)' }} />
            <select aria-label="Filter by severity" value={severityFilter} onChange={event => setSeverityFilter(event.target.value)} className="text-xs px-2 py-1.5 rounded border flex-1 sm:flex-none"
              style={{ borderColor: 'rgba(180,162,136,0.55)', background: 'rgba(250,247,240,0.82)' }}>
              <option>All Severity</option>
              <option>Critical</option>
              <option>High</option>
              <option>Moderate</option>
            </select>
            <select aria-label="Filter by type" value={typeFilter} onChange={event => setTypeFilter(event.target.value)} className="text-xs px-2 py-1.5 rounded border flex-1 sm:flex-none"
              style={{ borderColor: 'rgba(180,162,136,0.55)', background: 'rgba(250,247,240,0.82)' }}>
              <option>All Types</option>
              <option>Flood</option>
              <option>Landslide</option>
              <option>Road Blockage</option>
              <option>Accident</option>
              <option>Infrastructure Damage</option>
            </select>
          </div>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ background: 'rgba(243,235,220,0.55)' }}>
                {['Incident ID', 'Type', 'Location', 'Route', 'Severity', 'Reported By', 'Time', 'Verification', 'Assigned', 'Status', 'Actions'].map(h => (
                  <th key={h} scope="col" className="text-left px-4 py-2.5 text-xs font-semibold uppercase tracking-wider whitespace-nowrap"
                    style={{ color: '#5A6670' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filtered.map((inc, i) => (
                <tr key={inc.id} data-row-id={inc.id}
                  className={`cursor-pointer ${flashId === inc.id ? 'ui-flash' : ''}`}
                  style={{ background: i % 2 === 0 ? 'rgba(250,247,240,0.82)' : 'rgba(243,235,220,0.55)' }}
                  onClick={() => setSelected(inc.id)}>
                  <td className="px-4 py-2.5 font-mono text-xs font-medium" style={{ color: '#2F6F7E' }}>{inc.id}</td>
                  <td className="px-4 py-2.5 text-xs whitespace-nowrap" style={{ color: '#17212B' }}>{inc.type}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670', maxWidth: 160 }}>{inc.location}</td>
                  <td className="px-4 py-2.5 font-mono text-xs" style={{ color: '#2F6F7E' }}>{inc.route}</td>
                  <td className="px-4 py-2.5"><SeverityBadge severity={inc.severity} /></td>
                  <td className="px-4 py-2.5 font-mono text-xs" style={{ color: '#5A6670' }}>{inc.reportedBy}</td>
                  <td className="px-4 py-2.5 text-xs whitespace-nowrap" style={{ color: 'var(--text-muted)' }}>{inc.reportedTime}</td>
                  <td className="px-4 py-2.5"><StatusBadge status={inc.verification} /></td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: inc.assignedOfficer ? '#17212B' : 'var(--text-muted)' }}>
                    {inc.assignedOfficer ?? '—'}
                  </td>
                  <td className="px-4 py-2.5"><StatusBadge status={inc.status} /></td>
                  <td className="px-4 py-2.5">
                    <div className="flex gap-1" onClick={e => e.stopPropagation()}>
                      <button onClick={() => setSelected(inc.id)}
                        className="text-xs px-2 py-1 rounded border min-h-[28px] min-w-[28px] pointer-coarse:min-h-11 pointer-coarse:min-w-11"
                        style={{ borderColor: 'rgba(180,162,136,0.55)', color: '#2F6F7E' }}>View</button>
                      {inc.verification === 'Pending' && (
                        <button onClick={() => handleVerify(inc.id)}
                          className="text-xs px-2 py-1 rounded border min-h-[28px] min-w-[28px] pointer-coarse:min-h-11 pointer-coarse:min-w-11"
                          style={{ borderColor: '#A8D4B8', color: '#2D6B4F' }}>Verify</button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {filtered.length === 0 && (filtersActive
            ? <EmptyState icon={<Icon name="search" size={22} />} title="No incidents match this view" message="Try another tab, filter or search term." action={{ label: 'Clear filters', run: clearFilters }} />
            : <EmptyState icon={<Icon name="incident" size={22} />} title="No incidents yet" message="Reports from field officers will appear here." />)}
        </div>
      </div>

      {selectedInc && (
        <IncidentDetail
          inc={selectedInc}
          onClose={() => setSelected(null)}
          onVerify={handleVerify}
          onAssign={handleAssign}
          onStatusChange={handleStatusChange}
          onCreateTask={handleCreateTask}
        />
      )}
    </div>
  );
}
