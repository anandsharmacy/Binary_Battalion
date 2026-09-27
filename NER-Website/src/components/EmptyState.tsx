import { Icon } from '@/auth/Icons';

interface EmptyStateProps {
  icon?: React.ReactNode;
  title: string;
  message?: string;
  action?: { label: string; run: () => void };
}

const DEFAULT_ICON = <Icon name="inbox" size={22} />;

export default function EmptyState({ icon = DEFAULT_ICON, title, message, action }: EmptyStateProps) {
  return (
    <div className="flex flex-col items-center text-center py-10 px-4" style={{ gap: 'var(--space-1)' }}>
      <span aria-hidden="true" className="flex" style={{ color: 'var(--text-muted)' }}>{icon}</span>
      <div className="font-semibold" style={{ color: '#17212B', fontSize: 'var(--fs-body)' }}>{title}</div>
      {message && <div className="max-w-sm" style={{ color: 'var(--text-muted)', fontSize: 'var(--fs-caption)' }}>{message}</div>}
      {action && (
        <button type="button" onClick={action.run}
          className="ui-press mt-2 rounded px-3 py-1.5 font-medium min-h-[28px] pointer-coarse:min-h-11"
          style={{ background: '#17324D', color: 'white', fontSize: 'var(--fs-caption)' }}>
          {action.label}
        </button>
      )}
    </div>
  );
}
