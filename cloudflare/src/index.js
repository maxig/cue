// Cue share Worker — the Cloudflare port of server/index.js.
//
//   Bindings (see wrangler.toml):
//     env.DB     D1 database   (metadata, replaces db.json)
//     env.MEDIA  R2 bucket     (the recorded video bytes)
//     env.AI     Workers AI    (Whisper transcription + Llama summaries)
//
// The HTTP API is identical to the Node server so the macOS app can point at
// either one. The app uploads the video straight to R2 over the S3 API (SigV4);
// this Worker never receives the bytes, it only registers metadata and serves
// the player page + (optionally) streams the object back.

import { renderPlayer, renderIndex, renderDisabled, renderLanding, renderApp, renderAppLocked } from "./views.js";
import { AwsClient } from "aws4fetch";
import { jwtVerify, createRemoteJWKSet } from "jose";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

// Largest object we'll pull fully into the Worker for in-line transcription.
const MAX_TRANSCRIBE_BYTES = 100 * 1024 * 1024;

// Default R2 storage cap (override with the MAX_BYTES var). 9 GB stays under the
// 10 GB free tier with headroom.
const DEFAULT_MAX_BYTES = 9_000_000_000;

// Default lifetime of a presigned media URL (override with MEDIA_URL_TTL).
const DEFAULT_MEDIA_TTL = 1800; // 30 minutes

// Workers AI text model for summaries (override with the SUMMARY_MODEL var).
// 70B "fast" fp8 gives good summaries; switch to @cf/meta/llama-3.1-8b-instruct-fp8
// to use fewer daily Neurons.
const DEFAULT_SUMMARY_MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";

function json(data, init = {}) {
  return new Response(JSON.stringify(data), {
    status: init.status || 200,
    headers: { "content-type": "application/json; charset=utf-8", ...CORS, ...(init.headers || {}) },
  });
}

function html(markup, status = 200) {
  return new Response(markup, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", ...CORS },
  });
}

// D1 row (snake_case) -> API shape (camelCase), matching the Node server.
function rowToVideo(row) {
  return {
    id: row.id,
    title: row.title,
    durationSeconds: row.duration_seconds,
    objectKey: row.object_key,
    audioKey: row.audio_key || null,
    bytes: row.bytes || 0,
    width: row.width,
    height: row.height,
    captureMode: row.capture_mode,
    createdAt: row.created_at,
    disabled: !!row.disabled,
    transcript: row.transcript || null,
    summary: row.summary || null,
  };
}

function baseURL(request, env) {
  if (env.PUBLIC_BASE) return env.PUBLIC_BASE.replace(/\/$/, "");
  return new URL(request.url).origin;
}

// Where the raw video bytes are served from. Prefer a custom domain bound to
// the R2 bucket (cacheable at the edge); otherwise fall back to streaming
// through this Worker at /file/<key>.
function mediaURL(request, env, video) {
  let mediaBase = (env.MEDIA_PUBLIC_BASE || "").replace(/\/$/, "");
  if (mediaBase) {
    if (!/^https?:\/\//i.test(mediaBase)) mediaBase = `https://${mediaBase}`;
    return `${mediaBase}/${video.objectKey}`;
  }
  return `${baseURL(request, env)}/file/${video.objectKey}`;
}

// Presigned-URL config. Present only when R2 S3 credentials are set, which opts
// the deployment into serving media from the PRIVATE bucket via short-lived
// signed URLs (so a disabled link can't be fetched once existing URLs expire).
function presignConfig(env) {
  const accountId = env.R2_ACCOUNT_ID;
  const accessKeyId = env.R2_ACCESS_KEY_ID;
  const secretAccessKey = env.R2_SECRET_ACCESS_KEY;
  if (!accountId || !accessKeyId || !secretAccessKey) return null;
  return {
    accountId,
    accessKeyId,
    secretAccessKey,
    bucket: env.R2_BUCKET || "cue",
    ttl: Number(env.MEDIA_URL_TTL) || DEFAULT_MEDIA_TTL,
  };
}

async function presignedURL(cfg, key) {
  const client = new AwsClient({
    accessKeyId: cfg.accessKeyId,
    secretAccessKey: cfg.secretAccessKey,
    service: "s3",
    region: "auto",
  });
  const u = new URL(`https://${cfg.accountId}.r2.cloudflarestorage.com/${cfg.bucket}/${key}`);
  u.searchParams.set("X-Amz-Expires", String(cfg.ttl));
  const signed = await client.sign(u.toString(), { method: "GET", aws: { signQuery: true } });
  return signed.url;
}

// Freshest-security-first media URL: presigned (private bucket) → public custom
// domain → Worker proxy. Mints a new short-lived URL per call when presigning.
async function resolveMediaURL(request, env, video) {
  const cfg = presignConfig(env);
  if (cfg) return await presignedURL(cfg, video.objectKey);
  return mediaURL(request, env, video);
}

function decorate(request, env, v) {
  return {
    ...v,
    mediaURL: mediaURL(request, env, v),
    shareURL: `${baseURL(request, env)}/v/${v.id}`,
  };
}

// Constant-time string compare so a wrong token can't be recovered byte-by-byte
// from response timing. Bails on a length mismatch (the token length isn't secret).
function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  if (ab.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

// Cloudflare Access (Zero Trust) — lets the owner open the /app dashboard in a
// browser after logging in with their Cloudflare identity, instead of pasting
// the owner token. When ACCESS_TEAM_DOMAIN + ACCESS_AUD are set, a request that
// carries a valid Access token (the header Cloudflare injects, or the
// CF_Authorization cookie) counts as the owner. The signing keys (JWKS) are
// fetched from the team's cert endpoint and cached across requests.
let _jwks = null;
let _jwksTeam = null;
function accessJWKS(team) {
  if (!_jwks || _jwksTeam !== team) {
    _jwks = createRemoteJWKSet(new URL(`https://${team}/cdn-cgi/access/certs`));
    _jwksTeam = team;
  }
  return _jwks;
}

function accessToken(request) {
  const header = request.headers.get("cf-access-jwt-assertion");
  if (header) return header;
  const m = (request.headers.get("cookie") || "").match(/(?:^|;\s*)CF_Authorization=([^;]+)/);
  return m ? m[1] : null;
}

async function verifyAccess(request, env) {
  const team = (env.ACCESS_TEAM_DOMAIN || "").trim();
  const aud = (env.ACCESS_AUD || "").trim();
  if (!team || !aud) return null; // Access not configured → no browser owner.
  const token = accessToken(request);
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, accessJWKS(team), {
      issuer: `https://${team}`,
      audience: aud,
    });
    return payload; // includes the authenticated user's email.
  } catch {
    return null;
  }
}

// Owner guard for the whole /api surface and the /app dashboard. Fail-closed:
// stays locked until an owner credential is configured, then accepts EITHER the
// `Authorization: Bearer <OWNER_TOKEN>` (native app) OR a verified Cloudflare
// Access login (browser). Public viewing (/v/:id, /file) is separate.
async function ownerError(request, env) {
  const expected = env.OWNER_TOKEN;
  const got = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (expected && got && timingSafeEqual(got, expected)) return null;
  if (await verifyAccess(request, env)) return null;
  const accessConfigured = !!(env.ACCESS_TEAM_DOMAIN && env.ACCESS_AUD);
  if (!expected && !accessConfigured) {
    return json({ error: "server not configured: set OWNER_TOKEN (and/or Cloudflare Access)" }, { status: 503 });
  }
  return json({ error: "unauthorized" }, { status: 401 });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const { pathname } = url;
    const method = request.method;

    if (method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });

    try {
      // Health -------------------------------------------------------------
      if (pathname === "/healthz") return json({ ok: true, service: "cue-worker" });

      // Register a freshly uploaded recording -----------------------------
      if (pathname === "/api/videos" && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const body = await request.json().catch(() => ({}));
        const { id, title, durationSeconds, objectKey, audioKey, bytes, width, height, captureMode, createdAt } = body || {};
        if (!id || !objectKey) return json({ error: "id and objectKey are required" }, { status: 400 });

        await env.DB.prepare(
          `INSERT INTO videos (id, title, duration_seconds, object_key, audio_key, bytes, width, height, capture_mode, created_at, disabled)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1)
           ON CONFLICT(id) DO UPDATE SET
             title=excluded.title, duration_seconds=excluded.duration_seconds,
             object_key=excluded.object_key, audio_key=excluded.audio_key, bytes=excluded.bytes,
             width=excluded.width, height=excluded.height,
             capture_mode=excluded.capture_mode, created_at=excluded.created_at, disabled=1`
        ).bind(
          id,
          title || "Untitled Cue",
          Number(durationSeconds) || 0,
          objectKey,
          audioKey || null,
          Number(bytes) || 0,
          Number(width) || 0,
          Number(height) || 0,
          captureMode || "screen",
          createdAt || new Date().toISOString()
        ).run();

        // Evict oldest recordings from R2 if this upload pushed usage over the
        // cap. Local copies remain in the app library and can be re-uploaded.
        await enforceStorageCap(env, id);

        return json({ id, url: `${baseURL(request, env)}/v/${id}` });
      }

      // List --------------------------------------------------------------
      if (pathname === "/api/videos" && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const { results } = await env.DB.prepare(
          "SELECT * FROM videos ORDER BY created_at DESC"
        ).all();
        return json({ videos: (results || []).map((r) => decorate(request, env, rowToVideo(r))) });
      }

      // Transcribe one recording (Workers AI / Whisper) -------------------
      const txMatch = pathname.match(/^\/api\/videos\/([^/]+)\/transcribe$/);
      if (txMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        return await transcribeHTTP(decodeURIComponent(txMatch[1]), url, env);
      }

      // Summarize one recording (Workers AI / Llama) ----------------------
      const sumMatch = pathname.match(/^\/api\/videos\/([^/]+)\/summarize$/);
      if (sumMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        return await summarizeHTTP(decodeURIComponent(sumMatch[1]), env);
      }

      // Owner: disable / enable a share link ------------------------------
      const toggleMatch = pathname.match(/^\/api\/videos\/([^/]+)\/(disable|enable)$/);
      if (toggleMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const id = decodeURIComponent(toggleMatch[1]);
        const disabled = toggleMatch[2] === "disable";
        const ok = await setDisabled(env, id, disabled);
        if (!ok) return json({ error: "not found" }, { status: 404 });
        return json({ id, disabled });
      }

      // Fetch one ---------------------------------------------------------
      const oneMatch = pathname.match(/^\/api\/videos\/([^/]+)$/);
      if (oneMatch && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?")
          .bind(decodeURIComponent(oneMatch[1])).first();
        if (!row) return json({ error: "not found" }, { status: 404 });
        const v = rowToVideo(row);
        const dv = decorate(request, env, v);
        dv.mediaURL = await resolveMediaURL(request, env, v);
        return json(dv);
      }

      // Owner: delete a recording (R2 objects + metadata) -----------------
      if (oneMatch && method === "DELETE") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const id = decodeURIComponent(oneMatch[1]);
        const ok = await deleteVideo(env, id);
        if (!ok) return json({ error: "not found" }, { status: 404 });
        return json({ deleted: id });
      }

      // Owner dashboard (browser) — lists every recording with controls. Gated
      // by Cloudflare Access (log in with your Cloudflare identity) or the
      // bearer token. Never public: fail-closed if neither is satisfied.
      if (pathname === "/app" && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const { results } = await env.DB.prepare(
          "SELECT * FROM videos ORDER BY created_at DESC"
        ).all();
        const videos = (results || []).map((r) => decorate(request, env, rowToVideo(r)));
        return html(renderApp(videos, {
          base: baseURL(request, env),
          flash: url.searchParams.get("flash") || "",
          error: url.searchParams.get("error") || "",
        }));
      }

      // Owner dashboard actions (enable/disable/transcribe/summarize/delete)
      // via same-origin form POSTs — same Access/bearer gate, plus an origin
      // check to block CSRF. Reports the outcome back via a ?flash / ?error.
      if (pathname === "/app" && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const base = baseURL(request, env);
        const origin = request.headers.get("origin");
        if (origin && origin.replace(/\/$/, "") !== base) {
          return html(renderAppLocked("Request blocked (bad origin)."), 403);
        }
        const form = await request.formData();
        const id = String(form.get("id") || "");
        const action = String(form.get("action") || "");
        let flash = "", error = "";
        try {
          if (!id) throw new Error("missing id");
          if (action === "enable" || action === "disable") {
            const ok = await setDisabled(env, id, action === "disable");
            flash = ok ? `Link ${action === "disable" ? "disabled" : "enabled"}.` : "Recording not found.";
          } else if (action === "delete") {
            flash = (await deleteVideo(env, id)) ? "Recording deleted." : "Recording not found.";
          } else if (action === "transcribe" || action === "summarize") {
            const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
            if (!row) throw new Error("Recording not found.");
            if (action === "transcribe") {
              const { text } = await transcribeVideo(env, row, {});
              flash = `Transcribed (${wordCount(text)} words).`;
            } else {
              await summarizeVideo(env, row);
              flash = "Summary generated.";
            }
          }
        } catch (e) {
          error = String((e && e.message) || e);
        }
        const q = error ? `?error=${encodeURIComponent(error)}` : (flash ? `?flash=${encodeURIComponent(flash)}` : "");
        return Response.redirect(`${base}/app${q}`, 303);
      }

      // Web player page ---------------------------------------------------
      const vMatch = pathname.match(/^\/v\/([^/]+)$/);
      if (vMatch && method === "GET") {
        const sid = decodeURIComponent(vMatch[1]);
        const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(sid).first();
        if (!row) return html(renderIndex([], { notFound: sid }), 404);
        if (row.disabled) return html(renderDisabled(), 410);
        const v = rowToVideo(row);
        const dv = decorate(request, env, v);
        dv.mediaURL = await resolveMediaURL(request, env, v);
        return html(renderPlayer(dv));
      }

      // Media passthrough (Range-aware) — used when MEDIA_PUBLIC_BASE is unset
      if (pathname.startsWith("/file/") && (method === "GET" || method === "HEAD")) {
        return await serveFile(decodeURIComponent(pathname.slice("/file/".length)), request, env);
      }

      // Landing page — never lists the catalog (this is a private server).
      if (pathname === "/" && method === "GET") {
        return html(renderLanding());
      }

      return json({ error: "not found" }, { status: 404 });
    } catch (err) {
      return json({ error: String((err && err.message) || err) }, { status: 500 });
    }
  },
};

// --- R2 streaming with HTTP Range (so the <video> tag can seek) --------------

async function serveFile(key, request, env) {
  if (!key) return new Response("missing key", { status: 400, headers: CORS });

  // Fail closed: only serve bytes that belong to a known recording whose share
  // link is enabled. An unknown key (no row) or a disabled link is refused, so
  // the bucket is never a public file server even if an object key is guessed.
  // (A bucket custom domain would bypass the Worker — delete to fully revoke.)
  const owner = await env.DB.prepare(
    "SELECT disabled FROM videos WHERE object_key = ?1 OR audio_key = ?1"
  ).bind(key).first();
  if (!owner) return new Response("not found", { status: 404, headers: CORS });
  if (owner.disabled) return new Response("disabled", { status: 410, headers: CORS });

  if (request.method === "HEAD") {
    const head = await env.MEDIA.head(key);
    if (!head) return new Response(null, { status: 404, headers: CORS });
    const h = new Headers(CORS);
    head.writeHttpMetadata(h);
    h.set("etag", head.httpEtag);
    h.set("accept-ranges", "bytes");
    h.set("content-length", String(head.size));
    h.set("cache-control", "private, max-age=0, must-revalidate");
    return new Response(null, { status: 200, headers: h });
  }

  const range = request.headers.get("range");
  let object;
  if (range) {
    const m = /bytes=(\d*)-(\d*)/.exec(range);
    const start = m && m[1] !== "" ? Number(m[1]) : undefined;
    const end = m && m[2] !== "" ? Number(m[2]) : undefined;
    let opts;
    if (start !== undefined && end !== undefined) opts = { range: { offset: start, length: end - start + 1 } };
    else if (start !== undefined) opts = { range: { offset: start } };
    else if (end !== undefined) opts = { range: { suffix: end } };
    object = await env.MEDIA.get(key, opts);
  } else {
    object = await env.MEDIA.get(key);
  }

  if (!object) return new Response("not found", { status: 404, headers: CORS });

  const headers = new Headers(CORS);
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  // Access-controlled media: keep it out of any shared/CDN cache and force the
  // browser to revalidate, so a disabled link stops resolving on the next request.
  headers.set("cache-control", "private, max-age=0, must-revalidate");

  if (object.range && typeof object.size === "number") {
    const offset = object.range.offset ?? 0;
    const length = object.range.length ?? object.size - offset;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    return new Response(object.body, { status: 206, headers });
  }

  headers.set("content-length", String(object.size));
  return new Response(object.body, { status: 200, headers });
}

// --- Transcription (Workers AI: Whisper Large v3 Turbo) ---------------------

function wordCount(text) {
  return text && text.trim() ? text.trim().split(/\s+/).length : 0;
}

// Run Whisper over an R2 object and return { text, vtt }. Throws on a missing or
// too-large object.
async function runWhisper(env, key, lang) {
  const head = await env.MEDIA.head(key);
  if (!head) throw new Error(`object not found: ${key}`);
  if (head.size > MAX_TRANSCRIBE_BYTES) {
    throw new Error(`audio is ${(head.size / 1e6).toFixed(0)} MB; too large to transcribe in-Worker (limit 100 MB).`);
  }
  const object = await env.MEDIA.get(key);
  const audio = arrayBufferToBase64(await object.arrayBuffer());
  const input = { audio };
  if (lang) input.language = lang;
  const result = await env.AI.run("@cf/openai/whisper-large-v3-turbo", input);
  const text = result?.text || "";
  const vtt = Array.isArray(result?.segments)
    ? result.segments.map((s) => s.vtt).filter(Boolean).join("\n") || null
    : null;
  return { text, vtt };
}

// Transcribe a recording's audio sidecar (or ?key=) and persist the result.
async function transcribeVideo(env, row, { key, lang } = {}) {
  const objKey = key || row.audio_key || row.object_key;
  const { text, vtt } = await runWhisper(env, objKey, lang);
  await env.DB.prepare("UPDATE videos SET transcript = ?, transcript_vtt = ? WHERE id = ?")
    .bind(text, vtt, row.id).run();
  return { text, vtt };
}

// HTTP wrapper for POST /api/videos/:id/transcribe.
async function transcribeHTTP(id, url, env) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404 });
  try {
    const { text, vtt } = await transcribeVideo(env, row, {
      key: url.searchParams.get("key") || undefined,
      lang: url.searchParams.get("lang") || undefined,
    });
    return json({ id, text, word_count: wordCount(text), vtt });
  } catch (e) {
    return json({ error: String((e && e.message) || e) }, { status: 500 });
  }
}

// --- Summary (Workers AI: Llama) --------------------------------------------

// Summarize a recording. Auto-transcribes first if no transcript exists yet,
// then asks the text model for a short overview + key points. Persists `summary`.
async function summarizeVideo(env, row) {
  let transcript = row.transcript;
  if (!transcript) {
    const { text } = await transcribeVideo(env, row, {});
    transcript = text;
  }
  if (!transcript || !transcript.trim()) {
    throw new Error("nothing to summarize — no transcript (is there audio in this recording?).");
  }
  const model = env.SUMMARY_MODEL || DEFAULT_SUMMARY_MODEL;
  const result = await env.AI.run(model, {
    messages: [
      {
        role: "system",
        content:
          "You summarize screen-recording transcripts for a video sharing page. " +
          "Reply in plain text: first a 2-3 sentence overview, then a blank line, then " +
          "'Key points:' followed by 3-5 short bullets each starting with '- '. " +
          "Be concise and factual; never invent anything that isn't in the transcript.",
      },
      { role: "user", content: `Transcript:\n\n${transcript.slice(0, 12000)}` },
    ],
    max_tokens: 512,
  });
  const summary = (result?.response || "").trim();
  if (!summary) throw new Error("the summary model returned nothing.");
  await env.DB.prepare("UPDATE videos SET summary = ? WHERE id = ?").bind(summary, row.id).run();
  return summary;
}

// HTTP wrapper for POST /api/videos/:id/summarize.
async function summarizeHTTP(id, env) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404 });
  try {
    const summary = await summarizeVideo(env, row);
    return json({ id, summary });
  } catch (e) {
    return json({ error: String((e && e.message) || e) }, { status: 500 });
  }
}

// --- Owner actions / storage cap --------------------------------------------

// Flip a share link off/on. Returns false if no recording matched the id.
async function setDisabled(env, id, disabled) {
  const res = await env.DB.prepare("UPDATE videos SET disabled = ? WHERE id = ?")
    .bind(disabled ? 1 : 0, id).run();
  return !!res.meta.changes;
}

// Delete a recording everywhere (R2 objects + metadata). Returns false if the
// id didn't exist.
async function deleteVideo(env, id) {
  const row = await env.DB.prepare(
    "SELECT object_key, audio_key FROM videos WHERE id = ?"
  ).bind(id).first();
  if (!row) return false;
  await deleteObjects(env, row);
  await env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(id).run();
  return true;
}

async function deleteObjects(env, row) {
  const keys = [row.object_key, row.audio_key].filter(Boolean);
  if (keys.length) await env.MEDIA.delete(keys);
}

// Evict oldest recordings until total R2 usage is back under the cap. Never
// evicts `keepId` (the recording that was just uploaded).
async function enforceStorageCap(env, keepId) {
  const cap = Number(env.MAX_BYTES) || DEFAULT_MAX_BYTES;
  const agg = await env.DB.prepare("SELECT COALESCE(SUM(bytes), 0) AS total FROM videos").first();
  let total = Number(agg?.total || 0);
  if (total <= cap) return;

  const { results } = await env.DB.prepare(
    "SELECT id, object_key, audio_key, bytes FROM videos WHERE id != ? ORDER BY created_at ASC"
  ).bind(keepId).all();

  for (const row of results || []) {
    if (total <= cap) break;
    await deleteObjects(env, row);
    await env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(row.id).run();
    total -= Number(row.bytes || 0);
  }
}

function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunk = 0x8000; // avoid arg-count limits on String.fromCharCode
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
