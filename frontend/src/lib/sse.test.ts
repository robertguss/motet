import { describe, expect, it, vi, afterEach } from 'vitest';
import { extractStreamTextDelta, streamPostSse, subscribeSse } from './sse';

function sseStreamResponse(chunks: string[], status = 200): Response {
  const enc = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const c of chunks) {
        controller.enqueue(enc.encode(c));
      }
      controller.close();
    },
  });
  return new Response(body, {
    status,
    headers: { 'Content-Type': 'text/event-stream' },
  });
}

describe('SSE client helpers', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('extracts deltas across OpenAI/Anthropic ai.token and Gemini raw frames', () => {
    expect(
      extractStreamTextDelta({ id: '1', event: 'ai.token', data: '{"delta":"Hello "}' })
    ).toBe('Hello ');
    expect(
      extractStreamTextDelta({
        id: '2',
        event: 'message',
        data: JSON.stringify({
          candidates: [{ content: { parts: [{ text: 'world' }, { text: '!' }] } }],
        }),
      })
    ).toBe('world!');
    expect(
      extractStreamTextDelta({
        id: '3',
        event: 'message',
        data: JSON.stringify({ choices: [{ delta: { content: 'chunk' } }] }),
      })
    ).toBe('chunk');
  });

  it('streams POST ai.start, split-chunk ai.token, and ai.done frames cleanly', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(
      sseStreamResponse([
        'retry: 2000\n\nevent: ai.start\ndata: {"session_id":"chief-main"}\n\n',
        'id: 10\nevent: ai.to',
        'ken\ndata: {"delta":"Hel',
        'lo"}\n\nid: 11\nevent: ai.token\ndata: {"delta":" world"}\n\n',
        'event: ai.done\ndata: {"done":true}\n\n',
      ])
    );

    const tokens: string[] = [];
    let sid = '';
    const out = await streamPostSse(
      '/v1/bots/chief/stream',
      { prompt: 'hi', session_id: null },
      {
        onStart: (m) => {
          sid = String(m.session_id || '');
        },
        onToken: (d) => tokens.push(d),
      }
    );

    expect(sid).toBe('chief-main');
    expect(tokens).toEqual(['Hello', ' world']);
    expect(out).toBe('Hello world');
  });

  it('subscribes to SSE with Last-Event-ID and cleans up cleanly', async () => {
    const seenHeaders: Array<Record<string, string>> = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (_input, init) => {
      seenHeaders.push((init?.headers as Record<string, string>) || {});
      return sseStreamResponse(['id: 42\nevent: feed.delta\ndata: {"txid":9}\n\n']);
    });

    const frames: Array<{ id: string | null; event: string; data: string }> = [];
    const unsub = subscribeSse('/v1/modb/feeds/f1/stream', {
      lastEventId: '41',
      onEvent: (ev) => {
        frames.push(ev);
        unsub();
      },
    });

    await vi.waitFor(() => expect(frames.length).toBe(1));
    expect(seenHeaders[0]['Last-Event-ID']).toBe('41');
    expect(frames[0]).toEqual({ id: '42', event: 'feed.delta', data: '{"txid":9}' });
  });
});
