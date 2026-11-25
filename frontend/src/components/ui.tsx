import React from 'react';
import { X } from 'lucide-react';

export function cn(...parts: Array<string | false | null | undefined>): string {
  return parts.filter(Boolean).join(' ');
}

export const Card: React.FC<React.HTMLAttributes<HTMLDivElement>> = ({ className, ...props }) => (
  <div
    className={cn(
      'rounded-xl border border-[var(--border)] bg-[var(--card)] p-4 flex flex-col gap-3',
      className
    )}
    {...props}
  />
);

export const Badge: React.FC<{
  tone?: 'neutral' | 'accent' | 'ok' | 'warn' | 'bad' | 'info';
  className?: string;
  children: React.ReactNode;
}> = ({ tone = 'neutral', className, children }) => {
  const styles: Record<string, string> = {
    neutral: 'bg-[var(--card-2)] text-[var(--fg-muted)] border border-[var(--border)]',
    accent: 'bg-[var(--accent-soft)] text-[var(--accent-hover)] border border-transparent',
    ok: 'bg-[var(--ok-soft)] text-[var(--ok)] border border-transparent',
    warn: 'bg-[var(--warn-soft)] text-[var(--warn)] border border-transparent',
    bad: 'bg-[var(--bad-soft)] text-[var(--bad)] border border-transparent',
    info: 'bg-[var(--info-soft)] text-[var(--info)] border border-transparent',
  };
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-semibold whitespace-nowrap',
        styles[tone],
        className
      )}
    >
      {children}
    </span>
  );
};

export const Button: React.FC<
  React.ButtonHTMLAttributes<HTMLButtonElement> & {
    variant?: 'primary' | 'ghost' | 'ok' | 'bad' | 'warn';
    size?: 'sm' | 'md';
  }
> = ({ variant = 'primary', size = 'md', className, ...props }) => {
  const v: Record<string, string> = {
    primary: 'bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white border-transparent',
    ghost:
      'bg-[var(--card-2)] hover:bg-[var(--hover)] text-[var(--fg)] border-[var(--border)]',
    ok: 'bg-[var(--ok)] hover:brightness-110 text-slate-950 border-transparent',
    bad: 'bg-[var(--bad)] hover:brightness-110 text-white border-transparent',
    warn: 'bg-[var(--warn)] hover:brightness-110 text-slate-950 border-transparent',
  };
  const s = size === 'sm' ? 'px-2.5 py-1.5 text-xs min-h-[30px]' : 'px-3.5 py-2 text-sm min-h-[36px]';
  return (
    <button
      className={cn(
        'inline-flex items-center justify-center gap-1.5 rounded-lg border font-semibold cursor-pointer transition disabled:opacity-50 disabled:cursor-not-allowed whitespace-nowrap',
        v[variant],
        s,
        className
      )}
      {...props}
    />
  );
};

export const Field: React.FC<{
  label: string;
  hint?: string;
  className?: string;
  children: React.ReactNode;
}> = ({ label, hint, className, children }) => (
  <label className={cn('flex flex-col gap-1.5 flex-1 min-w-[140px]', className)}>
    <span className="text-xs font-semibold uppercase tracking-wider text-[var(--fg-muted)]">
      {label}
    </span>
    {children}
    {hint && <span className="text-xs text-[var(--fg-subtle)]">{hint}</span>}
  </label>
);

export const inputCls =
  'w-full rounded-lg border border-[var(--border)] bg-[var(--bg-elev)] px-3 py-2 text-sm text-[var(--fg)] placeholder:text-[var(--fg-subtle)] focus:outline-none focus:border-[var(--accent)]';

export const SectionHeader: React.FC<{
  title: string;
  subtitle?: string;
  actions?: React.ReactNode;
}> = ({ title, subtitle, actions }) => (
  <div className="flex items-start justify-between gap-3 flex-wrap">
    <div>
      <h1 className="text-lg font-bold tracking-tight text-[var(--fg)] m-0">{title}</h1>
      {subtitle && <p className="text-xs text-[var(--fg-muted)] mt-0.5 m-0">{subtitle}</p>}
    </div>
    {actions && <div className="flex items-center gap-2 flex-wrap">{actions}</div>}
  </div>
);

export const Modal: React.FC<{
  open: boolean;
  title: string;
  onClose: () => void;
  footer?: React.ReactNode;
  children: React.ReactNode;
}> = ({ open, title, onClose, footer, children }) => {
  if (!open) return null;
  return (
    <div
      className="fixed inset-0 z-50 bg-black/60 flex items-center justify-center p-4"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="w-full max-w-2xl max-h-[88dvh] rounded-2xl border border-[var(--border)] bg-[var(--card)] shadow-2xl flex flex-col overflow-hidden">
        <div className="px-5 py-3.5 border-b border-[var(--border)] flex items-center justify-between gap-3">
          <h2 className="text-base font-bold m-0">{title}</h2>
          <Button variant="ghost" size="sm" onClick={onClose} aria-label="Close">
            <X className="w-4 h-4" />
          </Button>
        </div>
        <div className="p-5 overflow-y-auto flex flex-col gap-3">{children}</div>
        {footer && (
          <div className="px-5 py-3 border-t border-[var(--border)] flex items-center justify-end gap-2">
            {footer}
          </div>
        )}
      </div>
    </div>
  );
};

export const EmptyState: React.FC<{
  title: string;
  description: string;
  action?: React.ReactNode;
}> = ({ title, description, action }) => (
  <Card className="items-center text-center py-8">
    <div className="text-sm font-semibold text-[var(--fg)]">{title}</div>
    <p className="text-xs text-[var(--fg-muted)] max-w-md m-0">{description}</p>
    {action}
  </Card>
);

/** Safe, lightweight Markdown renderer (no innerHTML XSS risk). */
export const MarkdownView: React.FC<{ content: string }> = ({ content }) => {
  const lines = (content || '').replace(/\r\n?/g, '\n').split('\n');
  const blocks: React.ReactNode[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();
    if (!trimmed) {
      i += 1;
      continue;
    }
    if (trimmed.startsWith('```')) {
      const lang = trimmed.slice(3).trim();
      const codeLines: string[] = [];
      i += 1;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        codeLines.push(lines[i]);
        i += 1;
      }
      i += 1;
      blocks.push(
        <div
          key={`cb-${i}`}
          className="rounded-lg border border-[var(--border)] bg-[var(--bg)] overflow-hidden"
        >
          {lang && (
            <div className="px-3 py-1 border-b border-[var(--border)] bg-[var(--card-2)] text-xs text-[var(--fg-muted)]">
              {lang}
            </div>
          )}
          <pre className="m-0 p-3 text-xs overflow-x-auto whitespace-pre">{codeLines.join('\n')}</pre>
        </div>
      );
      continue;
    }
    const hd = line.match(/^(#{1,4})\s+(.+)$/);
    if (hd) {
      const lvl = hd[1].length;
      const cls =
        lvl === 1
          ? 'text-base font-bold'
          : lvl === 2
            ? 'text-sm font-bold'
            : 'text-xs font-bold uppercase tracking-wide text-[var(--fg-muted)]';
      blocks.push(
        <div key={`h-${i}`} className={cls}>
          {hd[2]}
        </div>
      );
      i += 1;
      continue;
    }
    if (/^\s*[-*•]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*•]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*[-*•]\s+/, ''));
        i += 1;
      }
      blocks.push(
        <ul key={`ul-${i}`} className="m-0 pl-5 flex flex-col gap-1 list-disc">
          {items.map((it, idx) => (
            <li key={idx}>{it}</li>
          ))}
        </ul>
      );
      continue;
    }
    const para: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() &&
      !lines[i].trim().startsWith('```') &&
      !/^#{1,4}\s+/.test(lines[i]) &&
      !/^\s*[-*•]\s+/.test(lines[i])
    ) {
      para.push(lines[i]);
      i += 1;
    }
    blocks.push(
      <p key={`p-${i}`} className="m-0 whitespace-pre-wrap break-words">
        {para.join('\n')}
      </p>
    );
  }

  return <div className="flex flex-col gap-2 text-sm">{blocks}</div>;
};
