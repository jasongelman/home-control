// Cloudflare Access JWT verification.
//
// Every request that reaches the api-router must carry proof of a Cloudflare
// Access identity. There are two flavours:
//
//   1. Human browser session. Access injects a signed JWT into the
//      `Cf-Access-Jwt-Assertion` header (also available as a cookie of the
//      same name). We verify it against the Access JWKS for our team.
//
//   2. Machine caller (MCP server, local LEAP bridge, cron jobs). They use
//      Access service tokens, which arrive as `CF-Access-Client-Id` +
//      `CF-Access-Client-Secret`. Cloudflare Access validates these at its
//      edge before the request reaches us AND mints an equivalent JWT in
//      `Cf-Access-Jwt-Assertion`, so on the Worker side we only ever need
//      to verify the JWT.
//
// In both cases, a valid JWT is the gate. No JWT → 401.

import { createRemoteJWKSet, jwtVerify, type JWTPayload } from 'jose';
import type { Context, MiddlewareHandler } from 'hono';

export interface AccessIdentity {
  // `email` is set for human users, `common_name` for service tokens.
  // We expose both so downstream handlers can audit-log the caller.
  sub: string;
  email?: string;
  commonName?: string;
  raw: JWTPayload;
}

export interface AccessEnv {
  CF_ACCESS_TEAM_DOMAIN: string;
  CF_ACCESS_AUD: string;
}

// Cache the JWKS per team domain for the lifetime of the isolate.
// jose's createRemoteJWKSet handles its own caching/revalidation.
const jwksCache = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

// Accept both "jasongelman" and "jasongelman.cloudflareaccess.com" in the
// CF_ACCESS_TEAM_DOMAIN var — whichever form the user happens to paste from
// the dashboard.
function teamDomainHost(raw: string): string {
  const trimmed = raw.trim().replace(/^https?:\/\//, '').replace(/\/$/, '');
  return trimmed.endsWith('.cloudflareaccess.com')
    ? trimmed
    : `${trimmed}.cloudflareaccess.com`;
}

function getJwks(teamDomain: string): ReturnType<typeof createRemoteJWKSet> {
  const host = teamDomainHost(teamDomain);
  let jwks = jwksCache.get(host);
  if (!jwks) {
    const url = new URL(`https://${host}/cdn-cgi/access/certs`);
    jwks = createRemoteJWKSet(url);
    jwksCache.set(host, jwks);
  }
  return jwks;
}

export async function verifyAccessJwt(
  request: Request,
  env: AccessEnv,
): Promise<AccessIdentity> {
  if (!env.CF_ACCESS_TEAM_DOMAIN || !env.CF_ACCESS_AUD) {
    throw new Error('Access misconfigured: CF_ACCESS_TEAM_DOMAIN and CF_ACCESS_AUD must be set');
  }

  const token =
    request.headers.get('Cf-Access-Jwt-Assertion') ??
    extractCookie(request.headers.get('Cookie'), 'CF_Authorization');

  if (!token) throw new Error('Missing Cf-Access-Jwt-Assertion');

  const jwks = getJwks(env.CF_ACCESS_TEAM_DOMAIN);
  const { payload } = await jwtVerify(token, jwks, {
    issuer: `https://${teamDomainHost(env.CF_ACCESS_TEAM_DOMAIN)}`,
    audience: env.CF_ACCESS_AUD,
  });

  return {
    sub: String(payload.sub ?? ''),
    email: typeof payload.email === 'string' ? payload.email : undefined,
    commonName: typeof payload.common_name === 'string' ? payload.common_name : undefined,
    raw: payload,
  };
}

function extractCookie(header: string | null, name: string): string | null {
  if (!header) return null;
  for (const part of header.split(';')) {
    const [k, ...rest] = part.trim().split('=');
    if (k === name) return rest.join('=');
  }
  return null;
}

// Hono middleware wrapper. Attaches the identity to c.var.identity on success;
// responds 401 on failure.
export function accessAuth(): MiddlewareHandler<{
  Bindings: AccessEnv;
  Variables: { identity: AccessIdentity };
}> {
  return async (c: Context, next) => {
    try {
      const identity = await verifyAccessJwt(c.req.raw, c.env as AccessEnv);
      c.set('identity', identity);
      await next();
    } catch (err) {
      const message = err instanceof Error ? err.message : 'unauthorized';
      return c.json({ error: 'unauthorized', detail: message }, 401);
    }
  };
}
