import { useState, useEffect } from 'react';
import { SeverityBadge, StatusBadge } from '@/components/StatusBadge';
import type { Severity, TaskStatus } from '@/data/demo';
import { Card, PageHeader, BORDER, SURFACE, SURFACE_2, TEAL } from './ui';
import { profileService } from '@/lib/profileService';
import { getTasks, requestTaskVerification, subscribeToTasks, updateTask } from '@/lib/taskStore';
import { myUserId } from '@/lib/liveTable';

const toStatus = (life: Life): TaskStatus => (life === 'Assigned' ? 'New' : life);
import { notify } from '@/lib/notify';
import EmptyState from '@/components/EmptyState';
import { Icon } from '@/auth/Icons';

type Life = 'Assigned' | 'In Progress' | 'Completed' | 'Awaiting Verification' | 'Verified' | 'Rejected';

interface FOTask {
  id: string; title: string; location: string; priority: Severity;
  assigned: string; due: string; status: Life; note?: string;
}

const TABS = ['All', 'Pending', 'In Progress', 'Completed', 'Overdue'] as const;
// Completed → request District Officer verification; only the District Officer can move it to Verified/Rejected.
const NEXT: Record<Life, Life | null> = { Assigned: 'In Progress', 'In Progress': 'Completed', Completed: 'Awaiting Verification', 'Awaiting Verification': null, Verified: null, Rejected: null };
const ACTION_LABEL: Record<Life, string> = { Assigned: 'Start Task', 'In Progress': 'Complete Task', Completed: 'Awaiting Verification', 'Awaiting Verification': 'Awaiting District Officer Verification', Verified: 'Verified', Rejected: 'Rejected by District Officer' };
const DONE: Life[] = ['Completed', 'Awaiting Verification', 'Verified'];
const DONE_MESSAGE: Partial<Record<Life, string>> = { Assigned: 'Task started.', 'In Progress': 'Task completed.', Completed: 'Marked complete. Awaiting District Officer review.' };

function toFieldTask(task: ReturnType<typeof getTasks>[number]): FOTask {
  return {
    id: task.id,
    title: task.title,
    location: task.location,
    priority: task.priority,
    assigned: task.created,
    due: task.deadline,
    status: task.status === 'New' ? 'Assigned' : task.status as Life,
    note: task.verificationNote,
  };
}

export default function MyTasks() {
  const [tab, setTab] = useState<typeof TABS[number]>('All');
  const [tasks, setTasks] = useState<FOTask[]>(() => getTasks().filter(task => task.assignedTo === myUserId()).map(toFieldTask));
  const [busy, setBusy] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [profile, setProfile] = useState(() => {
    try {
      return profileService.getProfile();
    } catch (error) {
      console.error('Error loading profile in MyTasks:', error);
      // Return a safe fallback
      return {
        label: 'Field Officer',
        profileName: 'Field Officer',
        profileInitials: 'FO',
        officerId: 'UNKNOWN',
        department: 'Field Operations',
        region: 'Unknown District',
        phone: '',
        email: '',
        lastLogin: 'Unknown',
        status: 'Active',
      };
    }
  });

  // Subscribe to profile changes
  useEffect(() => {
    const unsubscribe = profileService.subscribe((updatedProfile) => {
      try {
        setProfile(updatedProfile);
      } catch (error) {
        console.error('Error updating profile in MyTasks:', error);
      }
    });
    return unsubscribe;
  }, []);

  useEffect(() => subscribeToTasks(stored => setTasks(stored.filter(task => task.assignedTo === myUserId()).map(toFieldTask))), []);

  const advance = (id: string) => {
    const t = tasks.find(x => x.id === id);
    if (!t || !NEXT[t.status]) return;
    setBusy(id);
    setTimeout(() => {
      setTasks(ts => ts.map(x => x.id === id ? { ...x, status: NEXT[x.status]! } : x));
      if (t.status === 'Completed') requestTaskVerification(id);
      else updateTask(id, { status: toStatus(NEXT[t.status]!) });
      setBusy(null);
      const prev = t.status;
      notify(DONE_MESSAGE[prev] ?? 'Task updated.', {
        action: {
          label: 'Undo',
          run: () => {
            setTasks(ts => ts.map(x => x.id === id ? { ...x, status: prev } : x));
            updateTask(id, { status: toStatus(prev) });
            notify('Change undone.');
          },
        },
      });
    }, 800);
  };

  const needle = query.trim().toLowerCase();
  const clearFilters = () => { setTab('All'); setQuery(''); };
  const filtered = tasks.filter(t => {
    if (needle && ![t.id, t.title].some(v => v.toLowerCase().includes(needle))) return false;
    if (tab === 'All') return true;
    if (tab === 'Pending') return t.status === 'Assigned';
    if (tab === 'In Progress') return t.status === 'In Progress';
    if (tab === 'Completed') return DONE.includes(t.status);
    if (tab === 'Overdue') return t.due.startsWith('Yesterday') && !DONE.includes(t.status);
    return true;
  });

  return (
    <div className="space-y-6 max-w-screen-2xl">
      <PageHeader title="My Tasks" sub={`Field tasks assigned to you · ${profile.profileName} · ${profile.region}`} />

      {/* Tabs */}
      <div className="flex gap-1 border-b overflow-x-auto" style={{ borderColor: BORDER }}>
        {TABS.map(t => {
          const active = tab === t;
          const count = t === 'All' ? tasks.length : tasks.filter(x =>
            t === 'Pending' ? x.status === 'Assigned' :
            t === 'In Progress' ? x.status === 'In Progress' :
            t === 'Completed' ? DONE.includes(x.status) :
            x.due.startsWith('Yesterday') && !DONE.includes(x.status)
          ).length;
          return (
            <button key={t} onClick={() => setTab(t)}
              className="px-4 py-2 text-sm font-medium transition-all whitespace-nowrap"
              style={{
                color: active ? '#17212B' : 'var(--text-muted)',
                borderBottom: `2px solid ${active ? TEAL : 'transparent'}`,
                marginBottom: -1,
              }}>
              {t} <span className="text-xs" style={{ color: 'var(--text-muted)' }}>({count})</span>
            </button>
          );
        })}
      </div>

      <Card>
        <div className="px-4 py-3 border-b flex flex-wrap items-center justify-between gap-2" style={{ borderColor: BORDER }}>
          <span className="text-sm font-medium" style={{ color: '#17212B' }}>
            {filtered.length} task{filtered.length !== 1 ? 's' : ''}
          </span>
          <input type="search" value={query} onChange={e => setQuery(e.target.value)}
            onKeyDown={e => { if (e.key === 'Escape' && query) { e.preventDefault(); setQuery(''); } }}
            aria-label="Search my tasks" placeholder="Search task ID or title"
            className="text-xs px-2 py-1.5 rounded border w-full sm:w-52" style={{ borderColor: BORDER, background: SURFACE }} />
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ background: SURFACE_2 }}>
                {['Task ID', 'Task', 'Location', 'Priority', 'Assigned', 'Due', 'Status', 'Action'].map(h => (
                  <th key={h} scope="col" className="text-left px-4 py-2.5 text-xs font-semibold uppercase tracking-wider" style={{ color: '#5A6670' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {filtered.map((t, i) => (
                <tr key={t.id} className="transition-colors" style={{ background: i % 2 === 0 ? SURFACE : 'rgba(243,235,220,0.55)' }}>
                  <td className="px-4 py-2.5 font-mono text-xs" style={{ color: TEAL }}>#{t.id}</td>
                  <td className="px-4 py-2.5 text-xs font-medium" style={{ color: '#17212B' }}>{t.title}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{t.location}</td>
                  <td className="px-4 py-2.5"><SeverityBadge severity={t.priority} /></td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: 'var(--text-muted)' }}>{t.assigned}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: 'var(--text-muted)' }}>{t.due}</td>
                  <td className="px-4 py-2.5"><StatusBadge status={t.status} /></td>
                  <td className="px-4 py-2.5">
                    {NEXT[t.status] ? (
                      <button onClick={() => advance(t.id)} disabled={busy === t.id}
                        className="text-xs font-medium px-2.5 py-1 rounded border transition-all disabled:opacity-60"
                        style={{ borderColor: BORDER, color: TEAL, minHeight: 32 }}>
                        {busy === t.id ? 'Updating…' : ACTION_LABEL[t.status]}
                      </button>
                    ) : t.status === 'Verified' ? (
                      <span className="text-xs" style={{ color: '#2D6B4F' }}>✓ {ACTION_LABEL[t.status]}</span>
                    ) : t.status === 'Rejected' ? (
                      <span className="text-xs" style={{ color: '#BE2424' }}>✕ {ACTION_LABEL[t.status]}{t.note ? ` — ${t.note}` : ''}</span>
                    ) : (
                      <span className="text-xs" style={{ color: '#C4861A' }}>◷ {ACTION_LABEL[t.status]}</span>
                    )}
                  </td>
                </tr>
              ))}
              {filtered.length === 0 && (
                <tr><td colSpan={8}>{query
                  ? <EmptyState icon={<Icon name="search" size={22} />} title="No matches" message={`No tasks match “${query.trim()}”.`} action={{ label: 'Clear search', run: clearFilters }} />
                  : tab === 'All'
                  ? <EmptyState icon={<Icon name="tasks" size={22} />} title="No tasks assigned to you" message="Tasks your District Officer assigns will appear here." />
                  : <EmptyState icon={<Icon name="tasks" size={22} />} title="No tasks in this view" action={{ label: 'Show all tasks', run: () => setTab('All') }} />}</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>
    </div>
  );
}
