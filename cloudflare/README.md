# Cue on Cloudflare — a step-by-step self-hosting guide

This folder turns Cue's **sharing backend** into a small, always-on service on
Cloudflare's **free tier**. Once it's up, your share links work for anyone on the
internet — no server to babysit, no bandwidth bill.

It's a drop-in replacement for the local Node server in [`../server`](../server):
both speak the **same HTTP API**, so the macOS app can point at either.

| Piece | Local dev (`../server`) | Cloudflare (this folder) |
| --- | --- | --- |
| Video bytes | MinIO (Docker) | **R2** bucket |
| Metadata | `db.json` | **D1** (SQLite) |
| API + web player | Node / Express | **Worker** |
| Transcription | — | **Workers AI** (Whisper) |

> **New to Cloudflare?** That's fine — this guide assumes no prior knowledge.
> Follow the numbered steps in order. Each command is copy-pasteable. The whole
> thing runs on the free tier.

---

## How it fits together

```
                  SigV4 PUT (S3 API)              register metadata
   Cue.app ───────────────────────────▶  R2   ───────────────────▶ Worker ──▶ D1
      │                                   ▲                            │
      │ (owner token)                     │ stream bytes               │ serves /v/<id>
      └──────────────  viewer's browser  ◀┴──────────  Worker /file proxy (private)
```

The app uploads the video **straight to R2** over the S3 API. The Worker never
touches the bytes — it stores metadata, serves the player page, and (in the
default setup) proxies the video back out while a link is enabled.

**Why Cloudflare?** R2 charges **$0 for egress** — and egress (streaming video to
viewers) is what makes "free" video hosting expensive everywhere else.

| Service | Free tier | Used for |
| --- | --- | --- |
| R2 | 10 GB storage, **unlimited egress**, 1M writes + 10M reads/mo | video files |
| D1 | 5 GB, 5M row-reads/day | metadata |
| Workers | 100k requests/day | API + player |
| Workers AI | 10k Neurons/day | Whisper transcription |

---

## Zero-setup from the app (recommended)

You don't need any of the manual steps below to get started: in Cue choose
**Settings → Sharing → Cue server → Set up automatically…**. The app opens a
Cloudflare page with a ready-made API token template; you click **Create
Token**, paste the one string back into Cue, and the app provisions everything
itself — R2 bucket, D1 database + schema, the Worker (bundled into the app),
its secrets, and the `workers.dev` share link. The S3 upload keys are derived
from the same token (access key = token id, secret = SHA-256 of the token), so
nothing else is ever typed.

Notes:

- **Account creation can't be automated** — Cloudflare has no signup API
  (browser check + ToS + email verification), so the app sends you to the
  signup page first if needed.
- **R2 needs a one-time free activation** with a card on file; setup detects
  this, deep-links you to the R2 plan page, and resumes on Retry.
- The app deploys a prebuilt copy of this Worker
  (`Cue/Upload/CloudflareProvisioning/CueWorker.js` + `CueSchema.sql`). After
  changing `src/` or `schema.sql`, regenerate them with
  `npm run sync:app-resources`.
- **Run setup again** in the app re-deploys that bundled Worker over the
  existing one — that's the upgrade path for app-managed deployments. When the
  Worker already exists (including wrangler-managed deploys), the app uploads
  with `keep_bindings`, so vars and secrets it doesn't manage — Cloudflare
  Access settings, `MEDIA_PUBLIC_BASE`, extra secrets — survive; custom-domain
  routes are separate config and are never touched.

The manual path below remains fully supported and is what you want for custom
domains, Cloudflare Access, and self-hosted tweaks.

---

## Before you start

- A **Cloudflare account** (free) — sign up at [dash.cloudflare.com](https://dash.cloudflare.com).
- **Node 18+** and `npx` (Wrangler, Cloudflare's CLI, comes via `npm install`).
- *(Recommended)* a **domain on Cloudflare**, for clean links + edge caching.
  Without one you'll get a free `https://cue.<you>.workers.dev` URL instead.

```sh
cd cloudflare
npm install          # pulls in Wrangler + dependencies
npx wrangler login   # opens a browser to authorize the CLI
```

`wrangler.toml` is your config file. Copy the example and edit as you go:

```sh
cp wrangler.toml.example wrangler.toml
```

---

## Step 1 — Create the R2 bucket (pick your region now)

R2 is where the video files live. Create the bucket **with a location** close to
you or your viewers:

```sh
npx wrangler r2 bucket create cue --location weur
```

Location hints: `wnam` (West US), `enam` (East US), `weur` (**West EU**),
`eeur` (**East EU**), `apac` (Asia-Pacific), `oc` (Oceania).

> ⚠️ **A bucket's location is fixed at creation and can't be changed later.** To
> move regions you'd create a new bucket and copy objects over. Pick now.
>
> **Need a hard EU data-residency guarantee?** Create it in the EU *jurisdiction*
> instead: `npx wrangler r2 bucket create cue --jurisdiction eu`. That pins data
> to the EU — but note the S3 endpoint then becomes
> `https://<ACCOUNT_ID>.eu.r2.cloudflarestorage.com` (use that in the app, Step 5).

Keep the bucket **private** — that's the default, and Cue relies on it (see
[Security model](#security-model)). The bucket name (`cue`) must match
`bucket_name` in `wrangler.toml`.

---

## Step 2 — Create the D1 database

D1 is the SQLite database that stores each recording's metadata (title, keys,
on/off flag). Create it and copy the printed `database_id` into `wrangler.toml`:

```sh
npx wrangler d1 create cue
```

```toml
# wrangler.toml
[[d1_databases]]
binding = "DB"
database_name = "cue"
database_id = "paste-the-id-here"
```

Load the table schema:

```sh
npm run db:schema          # the deployed (remote) database
npm run db:schema:local    # the local `wrangler dev` simulator
```

> **Upgrading a database created before these features?** Add the new columns:
> ```sh
> npx wrangler d1 execute cue --remote --command "ALTER TABLE videos ADD COLUMN audio_key TEXT; ALTER TABLE videos ADD COLUMN bytes INTEGER NOT NULL DEFAULT 0; ALTER TABLE videos ADD COLUMN disabled INTEGER NOT NULL DEFAULT 1; ALTER TABLE videos ADD COLUMN transcript TEXT; ALTER TABLE videos ADD COLUMN transcript_vtt TEXT;"
> ```
> **Adding reactions & comments** ([below](#reactions--comments))? They live in new
> tables, so just re-run the schema — it's idempotent (`CREATE TABLE IF NOT EXISTS`
> leaves `videos` untouched): `npm run db:schema` (remote) / `npm run db:schema:local`.
>
> **Enabling native/web Library sync on an existing database?** Apply the
> one-time metadata-clock migration before deploying the matching Worker:
> ```sh
> npm run db:migrate:metadata-sync
> ```
>
> **Enabling resumable uploads and early share links on an existing database?**
> Apply the upload-lifecycle migration before deploying the matching Worker:
> ```sh
> npm run db:migrate:upload-status
> ```
> Fresh databases created from `schema.sql` already include all of these columns.

---

## Step 3 — Set the owner token (required)

The **owner token** is the master key. The macOS app sends it on every request
that registers, lists, deletes, or toggles a recording. Pick a long random value
and store it as a **secret** (never in `wrangler.toml`):

```sh
# generate a strong token, then paste it when prompted:
openssl rand -hex 32
npx wrangler secret put OWNER_TOKEN
```

The guard is **fail-closed**: until `OWNER_TOKEN` is set, the entire `/api`
surface returns `503`; with it set, a missing or wrong token gets `401`. You'll
paste the same value into the app in Step 5.

---

## Step 4 — Deploy

```sh
npm run deploy
```

Wrangler prints your Worker URL, e.g. `https://cue.<you>.workers.dev`. Check it:

```sh
curl https://cue.<you>.workers.dev/healthz
# {"ok":true,"service":"cue-worker"}
```

**Custom domain (recommended):** in the dashboard go to **Workers & Pages → cue
→ Settings → Domains & Routes → Add custom domain** (e.g. `cue.example.com`).
Cloudflare provisions the certificate automatically.

---

## Step 5 — Point the macOS app at Cloudflare

Open **Cue → Settings → Sharing** and fill in two groups of fields.

**R2 / S3 upload** — create the keys first: **R2 → Manage R2 API Tokens → Create
API token**, scope it to **Object Read & Write** on the **`cue` bucket only**
(not account-wide). That yields an Access Key ID + Secret and shows your endpoint.

| Field | Value |
| --- | --- |
| Endpoint | `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` (or the `.eu.` host for an EU-jurisdiction bucket) |
| Region | `auto` ← **required for R2** |
| Bucket | `cue` |
| Access Key ID / Secret | from the R2 API token above |
| Addressing | **path-style** |

**Share server (this Worker)**

| Field | Value |
| --- | --- |
| Server base | `https://cue.<you>.workers.dev` (or your custom domain) |
| Owner token | the same value you set in Step 3 |

> R2 gotchas: region **must** be `auto`, use **path-style** addressing, and the
> endpoint is your account-ID host. The app's existing SigV4 signer works as-is.

### Test it end to end

1. Record something and click **Upload to Cloud** in the app.
2. The app PUTs `…/final.mp4` (+ a small `audio.m4a`) to R2, then registers metadata.
3. The link starts **off** — click **Enable link** in the Library to publish.
4. Open the `…/v/<id>` link in a browser — the video should stream.

```sh
# Confirm the metadata landed (the list is owner-only, so send the token):
curl -H "Authorization: Bearer <OWNER_TOKEN>" \
  https://cue.<you>.workers.dev/api/videos
```

---

## Step 6 (recommended) — Owner dashboard via Cloudflare Access

Want a **private web page that lists all your recordings** (with Enable / Disable
/ Delete buttons), without typing the owner token into a browser? Put the `/app`
route behind **Cloudflare Access** — Cloudflare logs you in with your identity
(email code, Google, GitHub…), and the dashboard appears.

> The macOS app keeps using the owner token. **Don't** put `/api` behind Access —
> the app is a native client with no browser login and would get blocked. Protect
> only `/app`.

**6.1 Turn on Zero Trust (one time).** In the dashboard open **Zero Trust**. If
it's your first visit, pick a **team name** — that becomes your team domain,
`yourteam.cloudflareaccess.com`. The free plan covers up to 50 users.

**6.2 Add an Access application.** Zero Trust → **Access → Applications → Add an
application → Self-hosted**:

- **Application name:** `Cue dashboard`
- **Session duration:** e.g. `24 hours`
- **Public hostname:** subdomain `cue`, domain `yourdomain.com`, **path** `app`
  (this protects `https://cue.yourdomain.com/app` and nothing else)

**6.3 Choose how you log in.** Under login methods, the simplest is **One-time
PIN** (Cloudflare emails you a code — no identity provider to set up). Google,
GitHub, etc. also work.

**6.4 Add a policy.** Add a policy with **Action: Allow** and an **Include** rule
of **Emails → your email address**. Now only you can get in.

**6.5 Copy the AUD tag.** Open the application's settings and copy its
**Application Audience (AUD) Tag** — a long hex string.

**6.6 Wire it into the Worker.** In `wrangler.toml` set:

```toml
[vars]
ACCESS_TEAM_DOMAIN = "yourteam.cloudflareaccess.com"
ACCESS_AUD = "the-long-aud-tag-you-copied"
```

Then redeploy:

```sh
npm run deploy
```

**6.7 Open it.** Visit `https://cue.yourdomain.com/app`. Cloudflare asks you to
log in; afterwards the dashboard loads. ✅ The dashboard has a **search box** that
filters your library by title or transcript text (with a highlighted snippet of
the match) — most useful once recordings have been transcribed.

**How it stays safe:** the Worker independently **verifies** the Access token on
every `/app` request (it checks the signature against your team's public keys and
the AUD). So even on the `*.workers.dev` hostname — which the Access app doesn't
cover — `/app` stays locked (no valid token there). Until you set both vars,
`/app` returns a "Sign in" page and never the catalog (fail-closed).

---

## How the video bytes are served (3 modes)

Pick by how private you need the raw files to be. The default (do nothing) is the
most private.

| Mode | Configure | Bucket | "Disable link" revokes bytes? |
| --- | --- | --- | --- |
| **Worker proxy** *(default)* | nothing | private | ✅ instantly |
| **Presigned** | R2 S3 creds (below) | private | ✅ once the URL expires (≤ `MEDIA_URL_TTL`) |
| **Custom domain** | `MEDIA_PUBLIC_BASE` | **public** | ❌ never (see warning) |

- **Worker proxy (default).** Set nothing. The Worker streams objects at
  `/file/<key>` (HTTP Range supported) and checks the on/off flag on every
  request, so disabling cuts access *instantly*. It refuses any key that isn't a
  known, enabled recording. Responses are `private, must-revalidate` (no CDN
  copy). Egress is still free.
- **Presigned (most private for direct links).** Keep the bucket private and set
  R2 S3 credentials; the Worker mints a fresh **short-lived signed URL** per play,
  only while the link is enabled:
  ```toml
  R2_ACCOUNT_ID = "your-account-id"
  R2_BUCKET = "cue"
  MEDIA_URL_TTL = "1800"   # seconds (default 30 min)
  ```
  ```sh
  npx wrangler secret put R2_ACCESS_KEY_ID
  npx wrangler secret put R2_SECRET_ACCESS_KEY
  ```
  Presigning takes precedence whenever these creds are set.
- **Custom domain (fastest, public).** Connect a domain under **R2 → cue →
  Settings → Public access** and set `MEDIA_PUBLIC_BASE`.
  > ⚠️ This makes the bucket's objects **publicly readable** over that hostname —
  > anyone with an object URL can fetch it, and *"disable link" can't revoke those
  > bytes*. Only for non-private content; **Remove from Cloud / Delete** to revoke.

### CORS (only if a browser uploads directly)

The macOS app is native, so its uploads **don't** need CORS. Add a CORS policy
(**R2 → cue → Settings → CORS policy**) only if a browser ever PUTs/`fetch()`es R2
directly.

---

## Owner controls

An explicit Cue-server share allocates an unguessable capability URL immediately.
While multipart upload is running, that URL shows a waiting page; it becomes a live
player as soon as R2 completion succeeds. Private uploads created only for native AI
insights remain disabled. Any live link can be disabled again at any time.

From the app's Library (right-click a row, or the detail pane) — or from the
[Access dashboard](#step-6-recommended--owner-dashboard-via-cloudflare-access):

- **Disable / Enable link** — flips a flag so `/v/:id` returns *"link disabled"*
  (HTTP 410) without deleting anything; reversible anytime.
- **Remove from Cloud** — deletes the R2 objects + metadata, keeps the local file.
- **Rename** — edits the title from either the macOS Library or private web view;
  both update the same server metadata. The native app also reconciles titles,
  transcripts, summaries, and link state on launch, whenever the Library opens,
  and every 30 seconds while it runs. Newer per-field edits win, including edits
  made while the Mac was offline.
- **Delete** — removes it everywhere (local + cloud).

> Disable gates the Worker. If you serve media through an R2 **custom domain**, its
> CDN may still return cached bytes to someone who saved the direct URL — use
> **Remove from Cloud** to hard-revoke.

### Per-video owner view (`/app/v/:id`)

Every recording has a private management page at **`/app/v/<id>`** — the same player
your viewers see, plus an action bar (Enable/Disable link, Transcribe, Summarize,
Rename, Delete), the inline transcript/summary, and **comment moderation**. Open it from the
[dashboard](#step-6-recommended--owner-dashboard-via-cloudflare-access) (click a
recording's title or its **Manage** button). It plays a recording even while the
link is disabled, so you can review before publishing.

**No extra Zero Trust setup.** A Cloudflare Access self-hosted app scoped to the
`/app` *path* protects that path **and every subpath**, so the Access app from
Step 6 already covers `/app/v/:id` (and `/app/file/...`) — nothing new to configure.
The Worker also re-verifies the Access token (or owner bearer) on these routes, so
they stay fail-closed even on the `*.workers.dev` host. (If you ever set the Access
app to *exclude* subpaths, add an `/app/*` include — but subpath inclusion is the
default.)

---

## Reactions & comments

The player page (`/v/:id`) is interactive for **anyone with the link** — no login:

- **Reactions** — tap an emoji (👍 🎉 😂 ❤️ 👀 🔥); counts are aggregate and a viewer
  can toggle their own back off.
- **Comments** — post with an optional name (defaults to *Anonymous*), **pinned to the
  current spot in the video**; the timestamp is clickable and seeks the player. A
  commenter can delete their own comment; **you** can delete any from `/app/v/:id`.

Both work only while a link is **enabled** (a disabled/410 recording accepts neither).
Reactions and comments live in D1 (`reactions`, `comments` tables) and are removed
automatically when a recording is deleted or evicted.

> **Spam hardening (optional).** The public write endpoints (`/api/public/*`) are open
> by design and guarded by input validation (emoji allowlist, length caps, enabled-
> link-only, `no-store`). For a heavily public deployment add a Cloudflare **WAF
> rate-limiting rule** on `/api/public/*`, and/or a **Turnstile** challenge on the
> comment box — neither needs app changes.

---

## Security model

What's reachable, and by whom:

| Surface | Who can reach it |
| --- | --- |
| `GET /v/:id`, `GET /file/:key` | **anyone** — but only while that specific link is **enabled** (else 410/404) |
| `POST /api/public/videos/:id/{reactions,comments}` | **anyone** — but only for an **enabled** link (validated: emoji allowlist, length caps, `no-store`) |
| `GET /healthz`, `GET /` | anyone — a health check and a landing page that **never lists** anything |
| `GET/POST/DELETE /api/*` (except `/api/public/*`) | **owner token only** (`Authorization: Bearer …`) — fail-closed |
| `GET/POST /app`, `/app/v/:id`, `/app/file/*` | **owner token OR a verified Cloudflare Access login** — fail-closed |
| R2 bucket (list / upload / download) | **only your R2 API keys** — the bucket is private, no public URL, no CORS |
| D1 database | **only the Worker** — never exposed to the internet |

Consequences: nobody can list your catalog, fetch a disabled link's bytes, guess
their way into the bucket, or flip share flags without your token or a Cloudflare
login. Object keys are random UUIDs, so share links are unguessable capability
URLs. Verify the lockdown yourself:

```sh
curl -s -o /dev/null -w "%{http_code}\n" https://cue.<you>.workers.dev/api/videos   # 401
curl -s -o /dev/null -w "%{http_code}\n" https://cue.<you>.workers.dev/app          # 401 (until Access is set)
```

---

## Transcription (Workers AI · Whisper)

Cloudflare can transcribe audio on the free tier via Workers AI's Whisper model
(`@cf/openai/whisper-large-v3-turbo`). It's owner-only and runs on demand:

```sh
curl -X POST -H "Authorization: Bearer <OWNER_TOKEN>" \
  https://cue.<you>.workers.dev/api/videos/<id>/transcribe
```

- **Transcribes the audio-only sidecar by default.** The app exports a small
  `audio.m4a` next to each recording and registers it as `audioKey`, so Whisper
  never ingests the full video.
- Stores plain text in `videos.transcript` (+ WebVTT timing in `transcript_vtt`),
  which then shows up in the player's **Transcript** tab.
- Override the source with `?key=<object-key>`; force a language with `?lang=en`.
- **Caveats:** the Worker pulls the object into memory, so it's capped at 100 MB
  (`MAX_TRANSCRIBE_BYTES`); free tier is 10k Neurons/day.
- **Remove fillers (declutter).** `POST /api/videos/:id/declutter` — or the **Remove
  fillers** button on the dashboard / per-video view — strips "um/uh/er…" plus a couple
  of filler phrases from the stored transcript **and** its VTT, in place (no Workers AI
  / Neurons used). Re-transcribe to restore the raw text.

### Summaries, names, and smart chapters

**Summarize** uses one structured Workers AI response to create a concise overview,
key points, a meaningful title (maximum eight words), and timestamped chapters from
the stored WebVTT. Fresh date-based titles are replaced automatically; a title you
edited yourself is preserved. Chapters appear as seek buttons in the public and owner
players, and the generated title syncs back to the native Library.

---

## Storage cap & retention

R2 usage is kept under **`MAX_BYTES`** (default 9 GB, in `wrangler.toml`). When a
new upload pushes the total over the cap, the Worker evicts the **oldest**
recordings from R2 (objects + rows) until it's back under. Eviction removes only
the **cloud** copy — originals stay in your app library (`~/Movies/Cue`); hit
**Re-upload** to bring one back. R2 becomes a rolling cache in front of your local
archive.

---

## HTTP API

| Method | Path | Access | Purpose |
| --- | --- | --- | --- |
| `GET` | `/healthz` | public | health check |
| `POST` | `/api/videos` | **owner** | create/finalize an upload (`uploadStatus`, `objectKey`, optional `audioKey`, `bytes`) → stable `{ id, url }` |
| `GET` | `/api/videos` | **owner** | list all recordings |
| `GET` | `/api/videos/search?q=` | **owner** | search titles + transcripts → matches with snippets |
| `GET` | `/api/videos/:id` | **owner** | fetch one recording |
| `DELETE` | `/api/videos/:id` | **owner** | delete R2 objects + metadata |
| `POST` | `/api/videos/:id/disable` · `/enable` | **owner** | turn the share link off / on |
| `POST` | `/api/videos/:id/title` | **owner** | rename a recording (`{ title }`) |
| `POST` | `/api/videos/:id/sync` | **owner** | conditionally merge newer title/transcript/summary fields from the native Library |
| `POST` | `/api/videos/:id/transcribe` · `/summarize` | **owner** | transcribe / summarize (Workers AI) |
| `POST` | `/api/videos/:id/declutter` | **owner** | strip filler words (um/uh…) from the transcript |
| `GET` · `POST` | `/app` | **owner / Access** | private dashboard (list + Enable/Disable/Delete) |
| `GET` · `POST` | `/app/v/:id` | **owner / Access** | per-video owner view + actions + comment moderation |
| `GET` | `/app/file/:key` | **owner / Access** | stream bytes for the owner (plays even while disabled) |
| `GET` | `/v/:id` | public | web player page (410 if disabled) |
| `GET` | `/file/:key` | public | stream bytes for an *enabled* recording (Range-aware; 404/410 otherwise) |
| `POST` | `/api/public/videos/:id/reactions` | public\* | toggle an emoji reaction · *\*enabled links only* |
| `POST` | `/api/public/videos/:id/comments` | public\* | post a timestamped comment · *\*enabled links only* |
| `DELETE` | `/api/public/videos/:id/comments/:cid` | author / owner | delete a comment (author via viewer id, or owner) |
| `GET` | `/api/public/videos/:id/engagement` | public\* | reactions + comments JSON · *\*enabled links only* |
| `GET` | `/api/public/videos/:id/status` | capability link | minimal `uploading` / `ready` / `failed` state for the waiting page |
| `GET` | `/` | public | Cue landing and install instructions (never lists the catalog) |
| `GET` | `/download` | public | redirect to the latest signed `Cue.dmg` GitHub release asset |

---

## Local development

```sh
npm run db:schema:local    # once, to create the local D1 tables
npm run dev                # http://localhost:8787, local R2 + D1 simulators
```

`wrangler dev` simulates R2/D1 locally. To exercise the **real** remote bindings,
run `npx wrangler dev --remote`. Tail production logs with `npm run tail`.

---

## Troubleshooting

- **Everything under `/api` returns 401.** The app's owner token doesn't match the
  Worker's `OWNER_TOKEN` secret. Re-set it (Step 3) and re-paste it in the app.
- **`/api` returns 503.** `OWNER_TOKEN` isn't set yet — run `wrangler secret put OWNER_TOKEN`.
- **`/app` shows "Sign in" even after logging in.** `ACCESS_AUD` / `ACCESS_TEAM_DOMAIN`
  are missing or wrong, or you opened the `*.workers.dev` host (Access only covers
  the custom domain). Re-copy the AUD tag and redeploy.
- **Upload fails from the app.** Check region is `auto`, addressing is **path-style**,
  and the R2 API token has **Object Read & Write** on the `cue` bucket.
- **Video won't play but the page loads.** The link is disabled — click **Enable link**.

---

## Costs & when to upgrade

Everything above fits the free tier. You start paying when you exceed: R2 storage
> 10 GB ($0.015/GB·mo, egress stays free); Workers > 100k req/day or D1 > 5M
row-reads/day (Workers Paid, $5/mo); Workers AI > 10k Neurons/day. Because the
usual budget-killer — egress — is free, you can serve a lot of views first.
