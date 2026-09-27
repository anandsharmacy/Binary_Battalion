import { useEffect, useState } from 'react';

type Toast = { id: number; message: string; tone: 'success' | 'error'; action?: { label: string; run: () => void } };

// Only the most recently mounted Toaster shows toasts: Modal mounts one inside its <dialog>,
// because content outside an open modal dialog is inert and under the scrim.
// The toast itself lives here, not in a Toaster, so closing a drawer hands it (and its Undo) back to the page.
const listeners: ((toast: Toast | null) => void)[] = [];
let current: Toast | null = null;
let seq = 0;

function show(toast: Toast | null) {
  current = toast;
  listeners[listeners.length - 1]?.(toast);
}

/** Show a short, non-blocking result message (HIG feedback: show the results, offer Undo). */
export function notify(message: string, opts: { tone?: Toast['tone']; action?: Toast['action'] } = {}) {
  show({ id: ++seq, message, tone: opts.tone ?? 'success', action: opts.action });
}

/** Rendered by Shell and by each Modal. One toast at a time; auto-dismiss after 5 s, paused while hovered or focused. */
export function Toaster() {
  const [toast, setToast] = useState<Toast | null>(null);
  const [paused, setPaused] = useState(false);

  useEffect(() => {
    listeners[listeners.length - 1]?.(null);
    listeners.push(setToast);
    setToast(current);
    return () => {
      listeners.splice(listeners.indexOf(setToast), 1);
      listeners[listeners.length - 1]?.(current);
    };
  }, []);

  useEffect(() => {
    if (!toast || paused) return;
    const timer = setTimeout(() => show(null), 5000);
    return () => clearTimeout(timer);
  }, [toast, paused]);

  return (
    <div role="status" aria-live="polite"
      className="fixed bottom-20 sm:bottom-5 left-1/2 -translate-x-1/2 z-[60] max-w-[calc(100vw-32px)]"
      onMouseEnter={() => setPaused(true)} onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)} onBlur={() => setPaused(false)}>
      {toast && (
        <div key={toast.id} data-surface="dark" className="ui-toast flex items-center gap-3 rounded-lg px-4 py-2.5 text-sm shadow-xl"
          style={{ background: toast.tone === 'error' ? '#7A1B1B' : '#17324D', color: 'white' }}>
          <span>{toast.message}</span>
          {toast.action && (
            <button type="button"
              onClick={() => { toast.action!.run(); show(null); }}
              className="ui-press font-semibold underline underline-offset-2 min-h-[28px] pointer-coarse:min-h-11"
              style={{ color: '#F3D58A' }}>
              {toast.action.label}
            </button>
          )}
          <button type="button" aria-label="Dismiss" onClick={() => show(null)}
            className="ui-press opacity-80 hover:opacity-100 min-h-[28px] min-w-[28px] pointer-coarse:min-h-11 pointer-coarse:min-w-11">✕</button>
        </div>
      )}
    </div>
  );
}

/** Show the result of an Undo (HIG undo-and-redo): scroll the row marked data-row-id into view and flash it once. */
export function useRowFlash() {
  const [flashId, setFlashId] = useState<string | null>(null);
  useEffect(() => {
    if (!flashId) return;
    document.querySelector(`[data-row-id="${CSS.escape(flashId)}"]`)?.scrollIntoView({ block: 'nearest' });
    const timer = setTimeout(() => setFlashId(null), 700);
    return () => clearTimeout(timer);
  }, [flashId]);
  return [flashId, setFlashId] as const;
}
