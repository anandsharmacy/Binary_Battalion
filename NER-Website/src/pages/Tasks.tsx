import { useEffect, useState } from 'react';
import { SeverityBadge, StatusBadge } from '@/components/StatusBadge';
import { getTasks, reviewTask, subscribeToTasks, updateTask } from '@/lib/taskStore';
import { notify, useRowFlash } from '@/lib/notify';
import Modal from '@/components/Modal';
import EmptyState from '@/components/EmptyState';
import { Icon } from '@/auth/Icons';

const BORDER = 'rgba(180,162,136,0.55)';
const SURFACE = 'rgba(250,247,240,0.82)';

const tabKeys = ['All', 'New', 'In Progress', 'Completed', 'Escalated'];

export default function Tasks() {
  const [tab, setTab] = useState('All');
  const [tasks, setTasks] = useState<ReturnType<typeof getTasks>>(() => getTasks());
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [rejecting, setRejecting] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const [flashId, setFlashId] = useRowFlash();

  useEffect(() => subscribeToTasks(stored => setTasks(stored)), []);

  const needle = query.trim().toLowerCase();
  const filtered = tasks.filter(t => (tab === 'All' || t.status === tab) &&
    (!needle || [t.id, t.title, t.location].some(v => v?.toLowerCase().includes(needle))));
  const clearFilters = () => { setTab('All'); setQuery(''); };
  const selectedTask = tasks.find(task => task.id === selectedTaskId) ?? null;
  const pendingReview = tasks.filter(task => task.status === 'Awaiting Verification');

  // reviewTask is role-gated and may no-op, so report what actually happened.
  const review = (id: string, approve: boolean, reason = '') => {
    reviewTask(id, approve, reason);
    const done = getTasks().find(task => task.id === id)?.status === (approve ? 'Verified' : 'Rejected');
    if (!done) { notify('Only a District Officer can review this task.', { tone: 'error' }); return; }
    notify(approve ? `Task ${id} verified.` : `Task ${id} rejected.`, {
      action: { label: 'Undo', run: () => { updateTask(id, { status: 'Awaiting Verification' }); setFlashId(id); notify('Review undone.'); } },
    });
  };
  const reject = (id: string) => { setReason(''); setRejecting(id); };

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div className="flex items-start justify-between flex-wrap gap-3">
        <div>
          <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Tasks</h1>
          <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>Field task management and assignment</p>
        </div>
        {/* Interim until product decides: no create-task flow exists yet (V2 audit section 7, #4). */}
        <div className="flex flex-col items-end gap-1">
          <button type="button" disabled aria-describedby="create-task-note"
            className="text-xs font-medium px-3 py-2 rounded border disabled:opacity-60 disabled:cursor-not-allowed"
            style={{ background: '#17324D', color: 'white', borderColor: '#17324D' }}>
            + Create Task
          </button>
          <span id="create-task-note" className="text-xs" style={{ color: 'var(--text-muted)' }}>Not available yet</span>
        </div>
      </div>

      {pendingReview.length > 0 && (
        <div className="rounded-xl border px-4 py-3 text-xs" style={{ background: '#FEF8E6', borderColor: '#F5DFA8', color: '#7A6D2A' }}>
          <span className="font-semibold">Verification required:</span> {pendingReview.map(task => task.id).join(', ')}
        </div>
      )}

      {/* Summary */}
      <div className="grid grid-cols-3 sm:grid-cols-5 gap-3">
        {tabKeys.map(t => {
          const count = t === 'All' ? tasks.length : tasks.filter(task => task.status === t).length;
          return (
            <button key={t} onClick={() => setTab(t)} aria-pressed={tab === t}
              className="ui-card rounded-xl border p-3 text-left transition-all"
              style={{ background: tab === t ? '#17324D' : 'rgba(250,247,240,0.82)', borderColor: tab === t ? '#17324D' : 'rgba(180,162,136,0.55)' }}>
              <div className="text-2xl font-bold" style={{ color: tab === t ? 'white' : '#17212B' }}>{count}</div>
              <div className="text-xs mt-0.5" style={{ color: tab === t ? '#8AAFC8' : '#5A6670' }}>{t}</div>
            </button>
          );
        })}
      </div>

      <div className="flex gap-0 border-b overflow-x-auto" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
        {tabKeys.map(t => (
          <button key={t} onClick={() => setTab(t)}
            className="px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors"
            style={{ borderBottomColor: tab === t ? '#17324D' : 'transparent', color: tab === t ? '#17324D' : '#5A6670' }}>
            {t}
          </button>
        ))}
      </div>

      <div className="rounded-xl border shadow-sm overflow-hidden" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
        <div className="px-4 py-3 border-b flex flex-wrap items-center justify-between gap-2" style={{ borderColor: BORDER, background: 'rgba(238,228,210,0.88)' }}>
          <span className="text-sm font-medium" style={{ color: '#17212B' }}>
            {filtered.length} task{filtered.length !== 1 ? 's' : ''}
          </span>
          <input type="search" value={query} onChange={e => setQuery(e.target.value)}
            onKeyDown={e => { if (e.key === 'Escape' && query) { e.preventDefault(); setQuery(''); } }}
            aria-label="Search tasks" placeholder="Search ID, title or location"
            className="text-xs px-2 py-1.5 rounded border w-full sm:w-52" style={{ borderColor: BORDER, background: SURFACE }} />
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ background: 'rgba(238,228,210,0.88)' }}>
                {['Task ID', 'Title', 'Location', 'Priority', 'Assigned Officer', 'Created', 'Deadline', 'Status', 'Actions'].map(h => (
                  <th key={h} scope="col" className="text-left px-4 py-2.5 text-xs font-semibold uppercase tracking-wider whitespace-nowrap"
                    style={{ color: '#5A6670' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filtered.map((task, i) => (
                <tr key={task.id} data-row-id={task.id} className={flashId === task.id ? 'ui-flash' : undefined} style={{ background: i % 2 === 0 ? 'rgba(250,247,240,0.82)' : 'rgba(243,235,220,0.55)' }}>
                  <td className="px-4 py-2.5 font-mono text-xs font-semibold" style={{ color: '#2F6F7E' }}>{task.id}</td>
                  <td className="px-4 py-2.5">
                    <div className="text-xs font-medium" style={{ color: '#17212B' }}>{task.title}</div>
                    {task.relatedIncident && (
                      <div className="text-xs mt-0.5" style={{ color: 'var(--text-muted)' }}>↳ {task.relatedIncident}</div>
                    )}
                  </td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{task.location}</td>
                  <td className="px-4 py-2.5"><SeverityBadge severity={task.priority} /></td>
                  <td className="px-4 py-2.5 font-mono text-xs" style={{ color: task.assignedOfficer ? '#17212B' : 'var(--text-muted)' }}>
                    {task.assignedOfficer ?? '— Unassigned'}
                  </td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: 'var(--text-muted)' }}>{task.created}</td>
                  <td className="px-4 py-2.5 text-xs font-medium" style={{ color: '#17212B' }}>{task.deadline}</td>
                  <td className="px-4 py-2.5"><StatusBadge status={task.status} /></td>
                  <td className="px-4 py-2.5">
                    <button
                      onClick={() => setSelectedTaskId(selectedTaskId === task.id ? null : task.id)}
                      aria-expanded={selectedTaskId === task.id}
                      className="text-xs px-2 py-1 rounded border"
                      style={{ borderColor: 'rgba(180,162,136,0.55)', color: selectedTaskId === task.id ? '#17324D' : '#2F6F7E' }}>
                      {selectedTaskId === task.id ? 'Hide' : 'View'}
                    </button>
                    {task.status === 'Awaiting Verification' && (
                      <span className="ml-2 inline-flex gap-1">
                        <button onClick={() => review(task.id, true)} className="text-xs px-2 py-1 rounded border"
                          style={{ borderColor: '#A8D4B8', background: '#EAF4EE', color: '#2D6B4F' }}>Verify</button>
                        <button onClick={() => reject(task.id)} className="text-xs px-2 py-1 rounded border"
                          style={{ borderColor: '#F5B8B8', background: '#FEE9E9', color: '#BE2424' }}>Reject</button>
                      </span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {filtered.length === 0 && (tab !== 'All' || query
            ? <EmptyState icon={<Icon name="search" size={22} />} title="No tasks match this view" message="Try another tab or search term."
                action={{ label: query ? 'Clear search' : 'Show all tasks', run: clearFilters }} />
            : <EmptyState icon={<Icon name="tasks" size={22} />} title="No tasks yet" message="Tasks created from incidents will appear here." />)}
        </div>
      </div>

      {selectedTask && (
        <div className="rounded-xl border p-4" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
          <div className="flex items-start justify-between gap-4">
            <div>
              <div className="text-xs uppercase tracking-wider" style={{ color: 'var(--text-muted)' }}>Task Details</div>
              <h3 className="mt-1 font-semibold text-base" style={{ color: '#17212B' }}>{selectedTask.title}</h3>
            </div>
            <button onClick={() => setSelectedTaskId(null)} className="text-xs font-medium px-2 py-1 rounded border" style={{ borderColor: 'rgba(180,162,136,0.55)', color: '#5A6670' }}>Close</button>
          </div>
          <div className="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3 text-xs" style={{ color: '#5A6670' }}>
            <div><span className="font-semibold" style={{ color: '#17212B' }}>Task ID:</span> {selectedTask.id}</div>
            <div><span className="font-semibold" style={{ color: '#17212B' }}>Priority:</span> <SeverityBadge severity={selectedTask.priority} /></div>
            <div><span className="font-semibold" style={{ color: '#17212B' }}>Location:</span> {selectedTask.location}</div>
            <div><span className="font-semibold" style={{ color: '#17212B' }}>Assigned:</span> {selectedTask.assignedOfficer ?? 'Unassigned'}</div>
            <div><span className="font-semibold" style={{ color: '#17212B' }}>Created:</span> {selectedTask.created}</div>
            <div><span className="font-semibold" style={{ color: '#17212B' }}>Deadline:</span> {selectedTask.deadline}</div>
            <div className="md:col-span-2"><span className="font-semibold" style={{ color: '#17212B' }}>Description:</span> {selectedTask.description}</div>
            {selectedTask.verificationNote && (
              <div className="md:col-span-2"><span className="font-semibold" style={{ color: '#17212B' }}>Rejection reason:</span> {selectedTask.verificationNote}</div>
            )}
          </div>
        </div>
      )}

      <Modal open={rejecting !== null} onClose={() => setRejecting(null)} labelledBy="task-reject-title">
        <form className="w-[26rem] max-w-full rounded-xl border p-5 shadow-2xl" style={{ background: '#FFFDF9', borderColor: BORDER }}
          onSubmit={e => { e.preventDefault(); const id = rejecting!; setRejecting(null); review(id, false, reason.trim()); }}>
          <h2 id="task-reject-title" className="font-semibold text-base" style={{ color: '#17212B' }}>Reject task {rejecting}?</h2>
          <p className="text-sm mt-1.5" style={{ color: '#5A6670' }}>The task is marked Rejected. You can undo this right after.</p>
          <label htmlFor="task-reject-reason" className="block text-xs font-medium mt-4 mb-1" style={{ color: '#5A6670' }}>Reason (optional)</label>
          <textarea id="task-reject-reason" rows={3} value={reason} onChange={e => setReason(e.target.value)}
            className="w-full rounded border px-3 py-2 text-sm" style={{ borderColor: BORDER, background: 'white', color: '#17212B' }} />
          <div className="mt-5 flex justify-end gap-2">
            <button type="button" autoFocus onClick={() => setRejecting(null)}
              className="ui-press text-sm font-medium px-4 py-2 rounded border" style={{ borderColor: BORDER, color: '#17212B', background: SURFACE }}>Cancel</button>
            <button type="submit"
              className="ui-press text-sm font-semibold px-4 py-2 rounded" style={{ background: '#BE2424', color: 'white' }}>Reject</button>
          </div>
        </form>
      </Modal>
    </div>
  );
}
