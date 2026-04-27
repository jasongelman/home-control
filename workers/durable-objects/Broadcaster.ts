// Broadcaster — Durable Object that fans out state-change events as SSE.
//
// Integration DOs (AlarmDO, etc.) POST to /broadcast with a JSON event body.
// Web clients subscribe via GET /events (SSE). One global singleton
// (idFromName('global')).

export class Broadcaster {
  private clients: Set<WritableStreamDefaultWriter<Uint8Array>> = new Set();
  private encoder = new TextEncoder();

  constructor(_state: DurableObjectState, _env: unknown) {
    // No stored state needed — connections are ephemeral
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/events') {
      return this.acceptSSE();
    }

    if (request.method === 'POST' && url.pathname === '/broadcast') {
      const event = await request.json() as { integration: string; state: unknown };
      await this.broadcast(event);
      return Response.json({ ok: true, clients: this.clients.size });
    }

    return Response.json({ error: 'not_found' }, { status: 404 });
  }

  private acceptSSE(): Response {
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const writer = writable.getWriter();

    this.clients.add(writer);

    // Send an initial comment to confirm the stream is alive
    const hello = this.encoder.encode(': connected\n\n');
    writer.write(hello).catch(() => {
      this.clients.delete(writer);
    });

    // Clean up when the client disconnects
    writer.closed.then(
      () => this.clients.delete(writer),
      () => this.clients.delete(writer),
    );

    return new Response(readable, {
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'Access-Control-Allow-Origin': '*',
      },
    });
  }

  private async broadcast(event: { integration: string; state: unknown }): Promise<void> {
    const data = JSON.stringify(event);
    const payload = this.encoder.encode(`event: stateChange\ndata: ${data}\n\n`);

    const dead: WritableStreamDefaultWriter<Uint8Array>[] = [];

    for (const writer of this.clients) {
      try {
        await writer.write(payload);
      } catch {
        dead.push(writer);
      }
    }

    for (const w of dead) {
      this.clients.delete(w);
      try { w.close().catch(() => {}); } catch { /* already closed */ }
    }
  }
}
