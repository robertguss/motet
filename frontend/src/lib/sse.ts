import { getStoredToken } from './api';

export interface SseEventFrame {
  id: string | null;
  event: string;
  data: string;
}

export interface SubscribeSseOptions {
  lastEventId?: string | null;
  onOpen?: () => void;
  onEvent: (ev: SseEventFrame) => void;
  onStatus?: (connected: boolean) => void;
  onError?: (err: Error) => void;
}

export interface StreamPostSseOptions {
  signal?: AbortSignal;
  onStart?: (meta: Record<string, unknown>) => void;
  onToken: (delta: string, fullText: string) => void;
  onDone?: (meta: Record<string, unknown>, fullText: string) => void;
  onError?: (err: string) => void;
}

function authHeaders(extra: Record<string, string> = {}): Record<string, string> {
  const headers: Record<string, string> = { ...extra };
  const tok = getStoredToken();
  if (tok) headers['Authorization'] = `Bearer ${tok}`;
  return headers;
}

async function consumeSseBody(
  body: ReadableStream<Uint8Array>,
  onFrame: (ev: SseEventFrame) => boolean | void
): Promise<void> {
  const reader = body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  let evName = 'message';
  let evId: string | null = null;
  let dataLines: string[] = [];
  let stopRequested = false;

  const dispatch = () => {
    if (dataLines.length === 0 && evId === null) {
      evName = 'message';
      return;
    }
    const frame: SseEventFrame = {
      id: evId,
      event: evName || 'message',
      data: dataLines.join('\n'),
    };
    evName = 'message';
    evId = null;
    dataLines = [];
    if (onFrame(frame) === false) {
      stopRequested = true;
    }
  };

  try {
    while (!stopRequested) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split(/\r\n|\n|\r/);
      buf = lines.pop() ?? '';
      for (const line of lines) {
        if (line === '') {
          dispatch();
          if (stopRequested) break;
        } else if (line.startsWith(':')) {
          // keepalive comment
        } else {
          const colon = line.indexOf(':');
          const field = colon >= 0 ? line.slice(0, colon) : line;
          const rawVal = colon >= 0 ? line.slice(colon + 1) : '';
          const val = rawVal.startsWith(' ') ? rawVal.slice(1) : rawVal;
          if (field === 'event') evName = val || 'message';
          else if (field === 'id') evId = val;
          else if (field === 'data') dataLines.push(val);
        }
      }
    }
    if (!stopRequested) dispatch();
  } finally {
    try {
      await reader.cancel();
    } catch {
      // ignore cancel failures on already-closed streams
    }
  }
}

export function subscribeSse(path: string, opts: SubscribeSseOptions): () => void {
  let stopped = false;
  let controller: AbortController | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let lastId = opts.lastEventId ?? null;
  let backoffMs = 1000;

  const run = async () => {
    while (!stopped) {
      controller = new AbortController();
      try {
        const headers = authHeaders({ Accept: 'text/event-stream' });
        if (lastId) headers['Last-Event-ID'] = lastId;
        const res = await fetch(path, {
          method: 'GET',
          headers,
          signal: controller.signal,
        });
        if (!res.ok || !res.body) {
          const txt = await res.text().catch(() => '');
          throw new Error(txt || `SSE HTTP ${res.status}`);
        }
        backoffMs = 1000;
        opts.onStatus?.(true);
        opts.onOpen?.();
        await consumeSseBody(res.body, (ev) => {
          if (stopped) return false;
          if (ev.id !== null) lastId = ev.id;
          opts.onEvent(ev);
        });
      } catch (err) {
        if (!stopped) {
          opts.onError?.(err instanceof Error ? err : new Error(String(err)));
        }
      }
      if (stopped) break;
      opts.onStatus?.(false);
      await new Promise<void>((resolve) => {
        timer = setTimeout(resolve, backoffMs);
      });
      backoffMs = Math.min(15000, Math.round(backoffMs * 1.7));
    }
  };

  void run();

  return () => {
    stopped = true;
    opts.onStatus?.(false);
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    controller?.abort();
  };
}

export function extractStreamTextDelta(ev: SseEventFrame): string {
  const raw = ev.data.trim();
  if (!raw || raw === '[DONE]') return '';
  try {
    const obj = JSON.parse(raw) as Record<string, unknown>;
    if (typeof obj.delta === 'string') return obj.delta;
    if (Array.isArray(obj.candidates)) {
      const c0 = obj.candidates[0] as Record<string, unknown> | undefined;
      const content = c0?.content as Record<string, unknown> | undefined;
      const parts = Array.isArray(content?.parts) ? content.parts : [];
      return parts
        .map((p) =>
          p && typeof p === 'object' && typeof (p as Record<string, unknown>).text === 'string'
            ? ((p as Record<string, unknown>).text as string)
            : ''
        )
        .join('');
    }
    if (Array.isArray(obj.choices)) {
      const c0 = obj.choices[0] as Record<string, unknown> | undefined;
      const d = c0?.delta as Record<string, unknown> | undefined;
      if (typeof d?.content === 'string') return d.content;
    }
    const deltaObj = obj.delta as Record<string, unknown> | undefined;
    if (deltaObj && typeof deltaObj.text === 'string') return deltaObj.text;
  } catch {
    if (ev.event === 'ai.token') return ev.data;
  }
  return '';
}

export async function streamPostSse<TBody>(
  path: string,
  body: TBody,
  opts: StreamPostSseOptions
): Promise<string> {
  const headers = authHeaders({
    'Content-Type': 'application/json',
    Accept: 'text/event-stream',
  });
  const res = await fetch(path, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
    signal: opts.signal,
  });
  if (!res.ok || !res.body) {
    const txt = await res.text().catch(() => '');
    let msg = txt || `HTTP ${res.status}`;
    try {
      const parsed = JSON.parse(txt) as Record<string, unknown>;
      msg = String(parsed?.message || parsed?.error || msg);
    } catch {
      // keep raw
    }
    throw new Error(msg);
  }

  let fullText = '';
  let streamErr: string | null = null;
  await consumeSseBody(res.body, (ev) => {
    if (ev.event === 'ai.start') {
      try {
        opts.onStart?.(JSON.parse(ev.data || '{}') as Record<string, unknown>);
      } catch {
        opts.onStart?.({});
      }
      return;
    }
    if (ev.event === 'ai.error') {
      let msg = ev.data || 'Streaming error';
      try {
        const parsed = JSON.parse(ev.data) as Record<string, unknown>;
        msg = String(parsed.message || parsed.error || msg);
      } catch {
        // keep raw
      }
      streamErr = msg;
      opts.onError?.(msg);
      return false;
    }
    if (ev.event === 'ai.done') {
      try {
        opts.onDone?.(JSON.parse(ev.data || '{}') as Record<string, unknown>, fullText);
      } catch {
        opts.onDone?.({}, fullText);
      }
      return false;
    }
    const delta = extractStreamTextDelta(ev);
    if (delta) {
      fullText += delta;
      opts.onToken(delta, fullText);
    }
  });

  if (streamErr) {
    throw new Error(streamErr);
  }
  return fullText;
}
