// Lutron Home — api-router Worker.
//
// Phase 0: just GET /api/health, gated by Cloudflare Access. This exists to
// verify that the account, DNS, Access app, and JWT verification plumbing
// all work end-to-end before any integration code lands.
//
// Later phases mount routes per integration (alarm, garage, lutron, …).

import { Hono } from 'hono';
import { accessAuth, type AccessIdentity, type AccessEnv } from './auth.js';

// Re-export DO classes so wrangler can find them
export { AlarmDO } from '../durable-objects/AlarmDO.js';
export { Broadcaster } from '../durable-objects/Broadcaster.js';

interface Env extends AccessEnv {
  ALARM_DO: DurableObjectNamespace;
  BROADCASTER: DurableObjectNamespace;
}

type Variables = { identity: AccessIdentity };

const app = new Hono<{ Bindings: Env; Variables: Variables }>();

// Every /api/* route requires a valid Cloudflare Access identity.
app.use('/api/*', accessAuth());

app.get('/api/health', (c) => {
  const identity = c.get('identity');
  return c.json({
    ok: true,
    phase: 0,
    identity: {
      sub: identity.sub,
      email: identity.email ?? null,
      commonName: identity.commonName ?? null,
    },
    timestamp: new Date().toISOString(),
  });
});

// ── OAuth relays (public, no Access auth) ────────────────────────────────────
// Sonos requires a publicly routable redirect URI. This route receives the
// OAuth callback from Sonos and redirects to the app's custom URL scheme
// so ASWebAuthenticationSession can intercept it.

app.get('/oauth/sonos/callback', (c) => {
  const url = new URL(c.req.url);
  const params = url.searchParams.toString();
  return c.redirect(`lutronhome://oauth/sonos?${params}`, 302);
});

// Unauthenticated liveness probe — useful for tunnel/DNS checks without
// needing an Access token. Returns nothing sensitive.
app.get('/ping', (c) => c.text('pong'));

app.notFound((c) => c.json({ error: 'not_found' }, 404));

app.onError((err, c) => {
  console.error('api-router error:', err);
  return c.json({ error: 'internal_error', detail: err.message }, 500);
});

export default app;
