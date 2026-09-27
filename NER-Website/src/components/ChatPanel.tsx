import { useEffect, useRef, useState } from 'react';
import { MlNotice, MlStatePill } from '@/components/MlRisk';
import { useChat } from '@/lib/chat';
import { useLanguage } from '@/lib/i18n';
import type { MlMeta } from '@/lib/ml';

const STARTERS = [
  'Which route is riskiest today?',
  'Where is the risk on NH-10?',
  'Show the top high-risk segments',
];

/**
 * Floating advisory assistant. Mounted once in Shell so it survives page changes.
 * Labelled "advisory" on purpose (WEB-007): it must never read as an authoritative
 * system voice, and every answer it gives is grounded in the same RPCs the rest of
 * the app shows.
 */
export default function ChatPanel({ mlMeta }: { mlMeta: MlMeta | null }) {
  const { t, language } = useLanguage();
  const { messages, streaming, thinking, signedOut, error, send, stop, reset } = useChat(language);
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState('');
  const input = useRef<HTMLTextAreaElement>(null);
  const scroller = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (open) input.current?.focus();
  }, [open]);

  useEffect(() => {
    scroller.current?.scrollTo({ top: scroller.current.scrollHeight });
  }, [messages, thinking]);

  const submit = (text: string) => {
    if (!text.trim() || streaming) return;
    setDraft('');
    void send(text);
  };

  return (
    <>
      <button
        type="button"
        aria-expanded={open}
        aria-controls="ner-assistant-panel"
        onClick={() => setOpen((o) => !o)}
        className="fixed bottom-5 right-5 z-40 flex items-center gap-2 rounded-full px-4 py-3 text-sm font-semibold shadow-lg transition-transform hover:scale-[1.03] focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2"
        style={{ background: '#17324D', color: '#FAF7F0' }}
      >
        <span aria-hidden="true">✦</span>
        {t('Assistant')}
      </button>

      {open && (
        <div
          id="ner-assistant-panel"
          role="dialog"
          aria-modal="false"
          aria-label={t('Operations assistant')}
          onKeyDown={(e) => {
            if (e.key === 'Escape') setOpen(false);
          }}
          className="ui-glass fixed bottom-20 right-5 z-40 flex w-[min(24rem,calc(100vw-2.5rem))] flex-col overflow-hidden rounded-2xl border shadow-2xl"
          style={{ height: 'min(34rem, calc(100vh - 8rem))', '--glass-tint': '255,253,249', borderColor: 'rgba(180,162,136,0.5)' } as React.CSSProperties}
        >
          <header className="flex items-start justify-between gap-2 border-b px-4 py-3" style={{ borderColor: 'rgba(180,162,136,0.4)' }}>
            <div className="min-w-0">
              <div className="text-sm font-semibold" style={{ color: '#17212B' }}>
                {t('Assistant')} · {t('advisory')}
              </div>
              <div className="mt-1">
                <MlStatePill meta={mlMeta} signedOut={signedOut} />
              </div>
            </div>
            <div className="flex shrink-0 items-center gap-1 text-xs" style={{ color: '#5A6670' }}>
              {messages.length > 0 && (
                <button type="button" onClick={reset} className="rounded px-2 py-1 hover:bg-black/5">
                  {t('New chat')}
                </button>
              )}
              <button type="button" onClick={() => setOpen(false)} aria-label={t('Close')} className="rounded px-2 py-1 hover:bg-black/5">
                ✕
              </button>
            </div>
          </header>

          {/* aria-busy holds screen-reader announcements until the answer settles,
              rather than reading every streamed token. */}
          <div ref={scroller} className="flex-1 space-y-3 overflow-y-auto px-4 py-3 text-sm" aria-live="polite" aria-busy={streaming}>
            {signedOut ? (
              <MlNotice signedOut />
            ) : messages.length === 0 ? (
              <div className="space-y-2">
                <p style={{ color: '#5A6670' }}>
                  {t('Ask about route risk and operations. I can only read data — I cannot raise alerts or change anything.')}
                </p>
                <div className="flex flex-wrap gap-2">
                  {STARTERS.map((q) => (
                    <button
                      key={q}
                      type="button"
                      onClick={() => submit(q)}
                      className="rounded-full border px-3 py-1 text-xs hover:bg-black/5"
                      style={{ borderColor: 'rgba(180,162,136,0.6)', color: '#17324D' }}
                    >
                      {t(q)}
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              messages.map((m, i) => (
                <div key={i} className={m.role === 'user' ? 'flex justify-end' : 'flex justify-start'}>
                  <div
                    className="max-w-[85%] whitespace-pre-wrap rounded-2xl px-3 py-2"
                    style={
                      m.role === 'user'
                        ? { background: '#17324D', color: '#FAF7F0' }
                        : { background: 'rgba(240,239,237,0.9)', color: '#17212B', border: '1px solid rgba(180,162,136,0.4)' }
                    }
                  >
                    {m.content || (thinking && i === messages.length - 1 ? <span style={{ color: '#5A6670' }}>{t('Checking the data…')}</span> : null)}
                  </div>
                </div>
              ))
            )}
            {error && (
              <div role="alert" className="rounded-lg border px-3 py-2 text-xs" style={{ background: '#FEE9E9', borderColor: '#F5B8B8', color: '#BE2424' }}>
                {error}
              </div>
            )}
          </div>

          <form
            className="flex items-end gap-2 border-t p-3"
            style={{ borderColor: 'rgba(180,162,136,0.4)' }}
            onSubmit={(e) => {
              e.preventDefault();
              submit(draft);
            }}
          >
            <textarea
              ref={input}
              value={draft}
              rows={1}
              disabled={signedOut}
              maxLength={1000}
              aria-label={t('Ask the assistant')}
              placeholder={t('Ask a question…')}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                // Enter sends; Shift+Enter is a newline.
                if (e.key === 'Enter' && !e.shiftKey) {
                  e.preventDefault();
                  submit(draft);
                }
              }}
              className="max-h-24 min-h-[2.25rem] flex-1 resize-none rounded-lg border px-3 py-2 text-sm focus:outline-none focus-visible:ring-2"
              style={{ borderColor: 'rgba(180,162,136,0.6)', background: '#FFFFFF', color: '#17212B' }}
            />
            {streaming ? (
              <button type="button" onClick={stop} className="rounded-lg border px-3 py-2 text-sm font-semibold" style={{ borderColor: '#17324D', color: '#17324D' }}>
                {t('Stop')}
              </button>
            ) : (
              <button
                type="submit"
                disabled={!draft.trim() || signedOut}
                className="rounded-lg px-3 py-2 text-sm font-semibold disabled:opacity-40"
                style={{ background: '#17324D', color: '#FAF7F0' }}
              >
                {t('Send')}
              </button>
            )}
          </form>
        </div>
      )}
    </>
  );
}
