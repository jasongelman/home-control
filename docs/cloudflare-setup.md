# Cloudflare setup — Lutron Home cloud API

One-time dashboard steps for Phase 0 of the cloud refactor. Everything after
this is automated via `wrangler`.

Prerequisites:
- A Cloudflare account with a registered domain (referred to below as
  `<domain>`).
- Cloudflare Zero Trust (Access) enabled on that account. Free tier up to
  50 users is sufficient.
- `wrangler` CLI installed locally (`npm i -g wrangler` or use
  `npx wrangler`).

All of the steps below happen in the Cloudflare dashboard. Nothing here
touches this repo — the values you collect get pasted into
`workers/wrangler.toml` and/or stored with `wrangler secret put`.

## 1. Pick hostnames

Decide on two hostnames on your domain:

| Purpose | Example |
|---|---|
| Public API Worker | `lutron-api.<domain>` |
| On-prem LEAP bridge (Phase 3) | `lutron-bridge.<domain>` |

Only the first one is needed for Phase 0.

## 2. Create the api-router Worker placeholder

1. Cloudflare dashboard → **Workers & Pages** → **Create application** →
   **Create Worker**.
2. Name it `lutron-home-api`. Use the default "Hello World" template.
3. Deploy once so the Worker exists. You will overwrite it via `wrangler
   deploy` from this repo shortly.
4. Under the new Worker's **Settings** → **Triggers** → **Custom Domains**,
   add `lutron-api.<domain>`.

> The Custom Domain step provisions the DNS record and TLS cert
> automatically. Do **not** use a route pattern instead — custom domains
> play nicer with Cloudflare Access.

## 3. Create the Cloudflare Access application

1. Zero Trust dashboard → **Access** → **Applications** → **Add an
   application** → **Self-hosted**.
2. Application name: `Lutron Home API`.
3. Session duration: `24 hours` (taste).
4. Application domain: `lutron-api.<domain>`.
5. **Identity providers**: pick whichever you use (Google, GitHub,
   one-time PIN via email, etc.). At least one human identity provider
   and the built-in "Service Auth" option must both be enabled.
6. **Policies** — create two:
   - **Policy 1: Humans** — action `Allow`, include rule
     `Emails` = your email address.
   - **Policy 2: Machines** — action `Service Auth`, include rule
     `Service Token` = (you'll create this in the next step, then come
     back and attach it here).
7. Save the application. On the details page, copy:
   - **AUD** (Application Audience tag). Hex string. Put it in
     `workers/wrangler.toml` as `CF_ACCESS_AUD`.
   - **Team domain**. Looks like `yourteam.cloudflareaccess.com`. The
     prefix (`yourteam`) goes into `wrangler.toml` as
     `CF_ACCESS_TEAM_DOMAIN`.

## 4. Create a service token for the MCP server

This token is how the future MCP server Worker will authenticate to
the api-router. It is also handy for Phase 0 `curl` smoke-testing from
a terminal.

1. Zero Trust → **Access** → **Service Auth** → **Service Tokens** →
   **Create Service Token**.
2. Name: `lutron-mcp`. Duration: `Non-expiring` (rotate manually).
3. Copy the **Client ID** and **Client Secret** (shown once). Store them
   somewhere safe — for Phase 0, a password manager is fine; later
   phases will store them as Worker secrets via `wrangler secret put`.
4. Go back to the Access application's **Policies** → "Machines"
   policy → add this service token to the include rule.

## 5. Put the config values into wrangler.toml

Edit `workers/wrangler.toml` and fill in:

```toml
[vars]
CF_ACCESS_TEAM_DOMAIN = "yourteam"   # no .cloudflareaccess.com suffix
CF_ACCESS_AUD = "abc123…"            # the AUD tag from step 3
```

Commit this — these are not secrets.

## 6. First deploy + smoke test

From the repo root:

```bash
cd workers
npm install
npx wrangler login        # one-time, opens a browser
npx wrangler deploy
```

Then verify:

```bash
# Unauthenticated liveness probe — should print "pong"
curl https://lutron-api.<domain>/ping

# /api/health without auth — should return 401
curl -i https://lutron-api.<domain>/api/health

# /api/health with service token — should return {ok: true, …}
curl -i https://lutron-api.<domain>/api/health \
  -H "CF-Access-Client-Id: <CLIENT_ID>" \
  -H "CF-Access-Client-Secret: <CLIENT_SECRET>"

# /api/health from a browser — after SSO, should return {ok: true, …}
open https://lutron-api.<domain>/api/health
```

If all four checks pass, Phase 0 is done.

## What Phase 0 does NOT set up

These are deferred until the phase that needs them:

- **KV namespace `STATE`** — Phase 2 (cold-load cache for `GET /api/state`)
- **D1 database `lutron_home`** — Phase 4 (scenes, automations, audit log)
- **Durable Object classes** — Phase 1 onward (one per integration +
  broadcaster)
- **Cloudflare Tunnel for the LEAP bridge** — Phase 3
- **Cloudflare Pages deployment for the web client** — Phase 6
- **Worker secrets** (`ANTHROPIC_API_KEY`, vendor OAuth client secrets,
  bridge service token) — added via `wrangler secret put` in the phase
  that introduces each integration.

Instructions for each land in this document as those phases ship.
