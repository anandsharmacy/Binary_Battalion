import { useLayoutEffect, useRef } from 'react';
import { Toaster } from '@/lib/notify';

interface ModalProps {
  open: boolean;
  onClose: () => void;
  labelledBy: string;
  side?: 'center' | 'right';
  className?: string;
  children: React.ReactNode;
}

/** Native <dialog>: focus trap, Esc, top layer and inert background come from the browser. */
export default function Modal({ open, onClose, labelledBy, side = 'center', className = '', children }: ModalProps) {
  const ref = useRef<HTMLDialogElement>(null);

  // Layout effect, not effect: the dialog must be shown before children's effects run,
  // or a Leaflet map inside measures a 0×0 container.
  useLayoutEffect(() => {
    const dialog = ref.current;
    if (!open || !dialog) return;
    const opener = document.activeElement as HTMLElement | null;
    dialog.showModal();
    return () => {
      dialog.close();
      opener?.focus?.();
    };
  }, [open]);

  if (!open) return null;
  // Nested dialogs: React propagates cancel/click through the component tree, so act only on our own dialog.
  return (
    <dialog
      ref={ref}
      aria-labelledby={labelledBy}
      className={`ui-dialog ${side === 'right' ? 'is-right' : ''} ${className}`}
      onCancel={e => { if (e.target !== e.currentTarget) return; e.preventDefault(); onClose(); }}
      onClick={e => { if (e.target === e.currentTarget) onClose(); }}
    >
      {children}
      <Toaster />
    </dialog>
  );
}
