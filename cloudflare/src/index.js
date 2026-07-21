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

// Emoji reactions a viewer may post. Anything outside this allowlist is rejected,
// so the public reactions endpoint can never store arbitrary strings.
const REACTIONS = ["👍", "🎉", "😂", "❤️", "👀", "🔥"];

// Public engagement responses are per-viewer and must never be cached.
const NO_STORE = { "cache-control": "no-store" };

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
    transcriptVtt: row.transcript_vtt || null,
    summary: row.summary || null,
    chapters: parseStoredChapters(row.summary),
  };
}

function cleanTitle(value, maxLength = 100) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, maxLength).trim();
}

function generatedTitle(value, fallback) {
  let title = cleanTitle(value, 60).replace(/^["'“”‘’]+|["'“”‘’.:;,-]+$/g, "").trim();
  title = title.split(/\s+/).slice(0, 8).join(" ");
  return title || cleanTitle(fallback, 60) || "Untitled Cue";
}

// Preserve a title the owner has already chosen. Fresh native recordings use
// "Cue · <date>", while older clients and direct API uploads may use Untitled.
function hasDefaultTitle(title) {
  const value = cleanTitle(title);
  return !value || /^Untitled Cue$/i.test(value) || /^Cue\s*[·-]/i.test(value);
}

function parseStoredChapters(summary) {
  const marker = /(?:^|\n)Chapters:\s*\n/i;
  const match = marker.exec(String(summary || ""));
  if (!match) return [];
  return String(summary).slice(match.index + match[0].length).split(/\r?\n/).map((line) => {
    const m = /^-\s*(?:(\d+):)?(\d{1,2}):(\d{2})\s+[—-]\s+(.+)$/.exec(line.trim());
    if (!m) return null;
    const seconds = (Number(m[1]) || 0) * 3600 + Number(m[2]) * 60 + Number(m[3]);
    const title = cleanTitle(m[4], 80);
    return title ? { startSeconds: seconds, title } : null;
  }).filter(Boolean).slice(0, 8);
}

function formatChapterTime(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  return hours
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`
    : `${minutes}:${String(secs).padStart(2, "0")}`;
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

// Hash to a fixed length, then use the runtime's constant-time comparison so
// neither token contents nor token length affect the comparison path.
async function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const [ah, bh] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  return crypto.subtle.timingSafeEqual(ah, bh);
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
  if (expected && got && await timingSafeEqual(got, expected)) return null;
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

      // Search titles + transcripts (owner). Exact-path check sits before the
      // /api/videos/:id matcher so "search" isn't mistaken for a recording id.
      if (pathname === "/api/videos/search" && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const q = (url.searchParams.get("q") || "").trim();
        if (!q) return json({ q: "", videos: [] });
        const rows = await searchVideos(env, q);
        return json({
          q,
          videos: rows.map((r) => {
            const dv = decorate(request, env, rowToVideo(r));
            dv.snippet = transcriptSnippet(r.transcript, q);
            return dv;
          }),
        });
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

      // Rename one recording. Used by the native Library and kept separate from
      // registration so a title edit never touches media metadata or link state.
      const titleMatch = pathname.match(/^\/api\/videos\/([^/]+)\/title$/);
      if (titleMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const body = await request.json().catch(() => ({}));
        const title = cleanTitle(body?.title);
        if (!title) return json({ error: "title is required" }, { status: 400 });
        const id = decodeURIComponent(titleMatch[1]);
        const ok = await updateTitle(env, id, title);
        if (!ok) return json({ error: "not found" }, { status: 404 });
        return json({ id, title });
      }

      // Remove filler words from one recording's transcript (Workers AI-free) --
      const declMatch = pathname.match(/^\/api\/videos\/([^/]+)\/declutter$/);
      if (declMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        return await declutterHTTP(decodeURIComponent(declMatch[1]), env);
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

      // Owner per-video view (browser) — the share page plus owner actions and
      // comment moderation. Lives under /app so the existing Cloudflare Access
      // app (which protects /app and all its subpaths) already covers it; the
      // Worker re-verifies via ownerError so it's fail-closed everywhere.
      const appVideoMatch = pathname.match(/^\/app\/v\/([^/]+)$/);
      if (appVideoMatch && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const id = decodeURIComponent(appVideoMatch[1]);
        const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
        if (!row) return html(renderAppLocked("Recording not found."), 404);
        const v = rowToVideo(row);
        const dv = decorate(request, env, v);
        dv.mediaURL = await ownerMediaURL(request, env, v); // plays even while disabled
        const [counts, comments] = await Promise.all([reactionCounts(env, id), listComments(env, id)]);
        return html(renderPlayer(dv, {
          owner: true,
          counts,
          comments,
          flash: url.searchParams.get("flash") || "",
          error: url.searchParams.get("error") || "",
        }));
      }

      // Owner per-video actions (enable/disable/transcribe/summarize/delete +
      // comment moderation) via same-origin form POSTs — same Access/bearer gate
      // as /app plus an Origin check to block CSRF. Redirects back with a flash.
      if (appVideoMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const base = baseURL(request, env);
        const origin = request.headers.get("origin");
        if (origin && origin.replace(/\/$/, "") !== base) {
          return html(renderAppLocked("Request blocked (bad origin)."), 403);
        }
        const id = decodeURIComponent(appVideoMatch[1]);
        const form = await request.formData();
        const action = String(form.get("action") || "");
        let flash = "", error = "", gone = false;
        try {
          const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
          if (!row) throw new Error("Recording not found.");
          if (action === "enable" || action === "disable") {
            await setDisabled(env, id, action === "disable");
            flash = `Link ${action === "disable" ? "disabled" : "enabled"}.`;
          } else if (action === "delete") {
            await deleteVideo(env, id);
            gone = true;
            flash = "Recording deleted.";
          } else if (action === "delete-comment") {
            const ok = await deleteComment(env, id, String(form.get("commentId") || ""));
            flash = ok ? "Comment deleted." : "Comment not found.";
          } else if (action === "transcribe") {
            const { text } = await transcribeVideo(env, row, {});
            flash = `Transcribed (${wordCount(text)} words).`;
          } else if (action === "summarize") {
            const insight = await summarizeVideo(env, row);
            flash = `Summary generated${insight.title !== row.title ? ` and named “${insight.title}”` : ""}.`;
          } else if (action === "rename") {
            const title = cleanTitle(form.get("title"));
            if (!title) throw new Error("A title is required.");
            await updateTitle(env, id, title);
            flash = "Title updated.";
          } else if (action === "declutter") {
            await declutterVideo(env, row);
            flash = "Filler words removed.";
          } else {
            throw new Error("unknown action");
          }
        } catch (e) {
          error = String((e && e.message) || e);
        }
        const q = error ? `?error=${encodeURIComponent(error)}` : (flash ? `?flash=${encodeURIComponent(flash)}` : "");
        // After a delete the video is gone → send the owner back to the library.
        const dest = gone ? `${base}/app${q}` : `${base}/app/v/${encodeURIComponent(id)}${q}`;
        return Response.redirect(dest, 303);
      }

      // Owner media passthrough — like /file, but serves a known object even
      // while its link is disabled, so the owner can preview from /app/v/:id.
      if (pathname.startsWith("/app/file/") && (method === "GET" || method === "HEAD")) {
        const denied = await ownerError(request, env);
        if (denied) return new Response("unauthorized", { status: denied.status, headers: CORS });
        return await serveFile(decodeURIComponent(pathname.slice("/app/file/".length)), request, env, { ownerView: true });
      }

      // Owner dashboard (browser) — lists every recording with controls. Gated
      // by Cloudflare Access (log in with your Cloudflare identity) or the
      // bearer token. Never public: fail-closed if neither is satisfied.
      if (pathname === "/app" && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const q = (url.searchParams.get("q") || "").trim();
        const rows = q
          ? await searchVideos(env, q)
          : ((await env.DB.prepare("SELECT * FROM videos ORDER BY created_at DESC").all()).results || []);
        const videos = rows.map((r) => {
          const dv = decorate(request, env, rowToVideo(r));
          if (q) dv.snippet = transcriptSnippet(r.transcript, q);
          return dv;
        });
        return html(renderApp(videos, {
          base: baseURL(request, env),
          flash: url.searchParams.get("flash") || "",
          error: url.searchParams.get("error") || "",
          q,
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
              const insight = await summarizeVideo(env, row);
              flash = `Summary generated${insight.title !== row.title ? ` and named “${insight.title}”` : ""}.`;
            }
          } else if (action === "rename") {
            const title = cleanTitle(form.get("title"));
            if (!title) throw new Error("A title is required.");
            const ok = await updateTitle(env, id, title);
            flash = ok ? "Title updated." : "Recording not found.";
          } else if (action === "declutter") {
            const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
            if (!row) throw new Error("Recording not found.");
            await declutterVideo(env, row);
            flash = "Filler words removed.";
          }
        } catch (e) {
          error = String((e && e.message) || e);
        }
        const q = error ? `?error=${encodeURIComponent(error)}` : (flash ? `?flash=${encodeURIComponent(flash)}` : "");
        return Response.redirect(`${base}/app${q}`, 303);
      }

      // Public engagement (reactions + comments) — open by design (anyone with
      // the link), but only for a known, ENABLED recording. No auth, no cookies.
      const reactMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/reactions$/);
      if (reactMatch && method === "POST") {
        return await handleReaction(decodeURIComponent(reactMatch[1]), request, env);
      }
      const addCommentMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/comments$/);
      if (addCommentMatch && method === "POST") {
        return await handleAddComment(decodeURIComponent(addCommentMatch[1]), request, env);
      }
      const delCommentMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/comments\/([^/]+)$/);
      if (delCommentMatch && method === "DELETE") {
        return await handleDeleteComment(
          decodeURIComponent(delCommentMatch[1]),
          decodeURIComponent(delCommentMatch[2]),
          request,
          env
        );
      }
      const engageMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/engagement$/);
      if (engageMatch && method === "GET") {
        return await handleEngagement(decodeURIComponent(engageMatch[1]), url, request, env);
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
        const [counts, comments] = await Promise.all([reactionCounts(env, sid), listComments(env, sid)]);
        return html(renderPlayer(dv, { counts, comments }));
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

async function serveFile(key, request, env, opts = {}) {
  if (!key) return new Response("missing key", { status: 400, headers: CORS });

  // Fail closed: only serve bytes that belong to a known recording whose share
  // link is enabled. An unknown key (no row) or a disabled link is refused, so
  // the bucket is never a public file server even if an object key is guessed.
  // (A bucket custom domain would bypass the Worker — delete to fully revoke.)
  // The owner preview path (opts.ownerView, behind ownerError) skips the
  // disabled gate so the owner can still watch their own paused recordings.
  const owner = await env.DB.prepare(
    "SELECT disabled FROM videos WHERE object_key = ?1 OR audio_key = ?1"
  ).bind(key).first();
  if (!owner) return new Response("not found", { status: 404, headers: CORS });
  if (!opts.ownerView && owner.disabled) return new Response("disabled", { status: 410, headers: CORS });

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

const SUMMARY_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    overview: { type: "string" },
    keyPoints: { type: "array", items: { type: "string" }, minItems: 2, maxItems: 5 },
    chapters: {
      type: "array",
      items: {
        type: "object",
        properties: {
          startSeconds: { type: "number", minimum: 0 },
          title: { type: "string" },
        },
        required: ["startSeconds", "title"],
      },
      maxItems: 8,
    },
  },
  required: ["title", "overview", "keyPoints", "chapters"],
};

function structuredResponse(result) {
  const response = result?.response;
  if (response && typeof response === "object") return response;
  if (typeof response !== "string") return null;
  try { return JSON.parse(response); } catch { return null; }
}

function cleanChapters(items, durationSeconds, fallbackTitle) {
  const duration = Math.max(0, Number(durationSeconds) || 0);
  const chapters = (Array.isArray(items) ? items : []).map((chapter) => ({
    startSeconds: Math.max(0, Math.round(Number(chapter?.startSeconds) || 0)),
    title: cleanTitle(chapter?.title, 80),
  })).filter((chapter) => chapter.title && (!duration || chapter.startSeconds < duration))
    .sort((a, b) => a.startSeconds - b.startSeconds)
    .filter((chapter, index, all) => index === 0 || chapter.startSeconds - all[index - 1].startSeconds >= 5)
    .slice(0, 8);
  if (!chapters.length || chapters[0].startSeconds > 5) {
    chapters.unshift({ startSeconds: 0, title: cleanTitle(fallbackTitle, 80) || "Overview" });
  } else {
    chapters[0].startSeconds = 0;
  }
  return chapters;
}

function formatInsightSummary(insight) {
  const parts = [cleanTitle(insight.overview, 900)];
  const points = (Array.isArray(insight.keyPoints) ? insight.keyPoints : [])
    .map((point) => cleanTitle(point, 220)).filter(Boolean).slice(0, 5);
  if (points.length) parts.push(`Key points:\n${points.map((point) => `- ${point}`).join("\n")}`);
  if (insight.chapters.length) {
    parts.push(`Chapters:\n${insight.chapters.map((chapter) =>
      `- ${formatChapterTime(chapter.startSeconds)} — ${chapter.title}`).join("\n")}`);
  }
  return parts.filter(Boolean).join("\n\n");
}

// Summarize a recording. Auto-transcribes first if no transcript exists, then
// generates a concise title, overview, key points, and timestamped chapters in a
// single structured inference. A manually chosen title is never overwritten.
async function summarizeVideo(env, row) {
  let transcript = row.transcript;
  let transcriptVtt = row.transcript_vtt;
  if (!transcript) {
    const { text, vtt } = await transcribeVideo(env, row, {});
    transcript = text;
    transcriptVtt = vtt;
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
          "Create useful metadata for a screen-recording transcript. " +
          "The title must be meaningful, specific, at most 8 words, and must not include quotes or generic labels like 'Video' or 'Recording'. " +
          "Write a concise 2-3 sentence overview, 2-5 short key points, and 2-8 chapters. " +
          "Chapter startSeconds must come from the supplied WebVTT timestamps; begin the first chapter at 0. " +
          "If no timestamps are supplied, return one chapter at 0. Be factual and never invent details.",
      },
      {
        role: "user",
        content: transcriptVtt
          ? `Timestamped transcript (WebVTT):\n\n${transcriptVtt.slice(0, 16000)}`
          : `Transcript:\n\n${transcript.slice(0, 12000)}`,
      },
    ],
    response_format: { type: "json_schema", json_schema: SUMMARY_SCHEMA },
    max_tokens: 768,
  });
  const value = structuredResponse(result);
  if (!value) throw new Error("the summary model returned invalid structured data.");

  const suggestedTitle = generatedTitle(value.title, row.title);
  const title = hasDefaultTitle(row.title) ? suggestedTitle : cleanTitle(row.title);
  const chapters = cleanChapters(value.chapters, row.duration_seconds, suggestedTitle);
  const summary = formatInsightSummary({
    overview: value.overview,
    keyPoints: value.keyPoints,
    chapters,
  });
  if (!summary) throw new Error("the summary model returned no usable summary.");
  await env.DB.prepare("UPDATE videos SET title = ?, summary = ? WHERE id = ?")
    .bind(title, summary, row.id).run();
  return { title, summary, chapters };
}

// HTTP wrapper for POST /api/videos/:id/summarize.
async function summarizeHTTP(id, env) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404 });
  try {
    const insight = await summarizeVideo(env, row);
    return json({ id, ...insight });
  } catch (e) {
    return json({ error: String((e && e.message) || e) }, { status: 500 });
  }
}

// --- Filler-word removal (transcript-level "declutter") ---------------------

// Strip vocal disfluencies ("um", "uh", "er"…) and a couple of common filler
// phrases from a line of transcript, tidying leftover spacing/punctuation.
// Conservative by design: it deletes known fillers only, never rewrites wording.
function removeFillers(text) {
  if (!text || !text.trim()) return text;
  let t = ` ${text} `;
  t = t.replace(/\s+\b(?:um+|uh+|uhm|erm|er+|ah+|hmm+|hm|mhm|mm+)\b\s*,?/gi, " ");
  t = t.replace(/\s+\b(?:you know|i mean)\b\s*,?/gi, " ");
  t = t.replace(/\s{2,}/g, " ")
       .replace(/\s+([,.!?;:])/g, "$1")   // no space before punctuation
       .replace(/,\s*([.!?;:])/g, "$1")   // comma swallowed by following punctuation
       .replace(/,\s*,/g, ",")            // collapse doubled commas
       .replace(/^[\s,;:]+/, "")          // drop a stray leading comma left by a removed opener
       .trim();
  return t;
}

// Clean every cue's text in a WebVTT blob, leaving timestamp lines intact so the
// timestamped transcript stays aligned.
function cleanVttFillers(vtt) {
  if (!vtt) return vtt;
  return String(vtt).split(/\r?\n/).map((line) => {
    const t = line.trim();
    if (!t || t === "WEBVTT" || t.includes("-->") || /^NOTE\b/.test(t)) return line;
    return removeFillers(line);
  }).join("\n");
}

// Owner action: remove filler words from a recording's transcript (and its VTT),
// transcribing first if needed. Edits in place — re-transcribe restores the raw
// text. Returns the cleaned transcript.
async function declutterVideo(env, row) {
  let transcript = row.transcript;
  let vtt = row.transcript_vtt;
  if (!transcript) {
    const r = await transcribeVideo(env, row, {});
    transcript = r.text;
    vtt = r.vtt;
  }
  if (!transcript || !transcript.trim()) {
    throw new Error("nothing to declutter — no transcript (is there audio in this recording?).");
  }
  const cleanText = removeFillers(transcript);
  const cleanVtt = cleanVttFillers(vtt);
  await env.DB.prepare("UPDATE videos SET transcript = ?, transcript_vtt = ? WHERE id = ?")
    .bind(cleanText, cleanVtt, row.id).run();
  return cleanText;
}

// HTTP wrapper for POST /api/videos/:id/declutter.
async function declutterHTTP(id, env) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404 });
  try {
    const text = await declutterVideo(env, row);
    return json({ id, text, word_count: wordCount(text) });
  } catch (e) {
    return json({ error: String((e && e.message) || e) }, { status: 500 });
  }
}

// --- Owner actions / storage cap --------------------------------------------

async function updateTitle(env, id, title) {
  const res = await env.DB.prepare("UPDATE videos SET title = ? WHERE id = ?")
    .bind(title, id).run();
  return !!res.meta.changes;
}

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
  await deleteEngagement(env, id);
  return true;
}

async function deleteObjects(env, row) {
  const keys = [row.object_key, row.audio_key].filter(Boolean);
  if (keys.length) await env.MEDIA.delete(keys);
}

// Remove a recording's comments + reactions (D1 has no enforced cascade).
async function deleteEngagement(env, id) {
  await env.DB.prepare("DELETE FROM comments WHERE video_id = ?").bind(id).run();
  await env.DB.prepare("DELETE FROM reactions WHERE video_id = ?").bind(id).run();
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
    await deleteEngagement(env, row.id);
    total -= Number(row.bytes || 0);
  }
}

// --- Engagement: reactions + comments ---------------------------------------

// Owner preview media URL — presigned (private bucket) if configured, else the
// owner-gated /app/file proxy, which (unlike /file) serves a disabled recording.
async function ownerMediaURL(request, env, video) {
  const cfg = presignConfig(env);
  if (cfg) return await presignedURL(cfg, video.objectKey);
  return `${baseURL(request, env)}/app/file/${video.objectKey}`;
}

// Public-engagement guard: returns an error Response unless the recording exists
// and its share link is enabled (so viewers can only engage with live videos).
async function enabledVideoError(env, id) {
  const row = await env.DB.prepare("SELECT disabled FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404, headers: NO_STORE });
  if (row.disabled) return json({ error: "link disabled" }, { status: 410, headers: NO_STORE });
  return null;
}

// Anonymous browser id from the client (localStorage). Constrained so it can't
// carry markup or unbounded data into the DB. Returns null if malformed.
function cleanViewerId(v) {
  const s = String(v || "").trim();
  return /^[A-Za-z0-9_-]{1,64}$/.test(s) ? s : null;
}

async function reactionCounts(env, id) {
  const { results } = await env.DB.prepare(
    "SELECT emoji, COUNT(*) AS n FROM reactions WHERE video_id = ? GROUP BY emoji"
  ).bind(id).all();
  const counts = {};
  for (const r of results || []) counts[r.emoji] = Number(r.n) || 0;
  return counts;
}

async function viewerReactions(env, id, viewerId) {
  if (!viewerId) return [];
  const { results } = await env.DB.prepare(
    "SELECT emoji FROM reactions WHERE video_id = ? AND viewer_id = ?"
  ).bind(id, viewerId).all();
  return (results || []).map((r) => r.emoji);
}

// Public comment shape. Deliberately omits viewer_id: it's a stable pseudonymous
// id that would let anyone correlate/spoof comments if exposed in the page. The
// "delete my own" affordance is tracked client-side (localStorage id set); the
// server reads the stored viewer_id directly when authorizing a delete.
async function listComments(env, id, limit = 500) {
  const { results } = await env.DB.prepare(
    "SELECT id, author, body, ts_seconds, created_at FROM comments WHERE video_id = ? ORDER BY created_at ASC LIMIT ?"
  ).bind(id, limit).all();
  return (results || []).map((r) => ({
    id: r.id,
    author: r.author,
    body: r.body,
    tsSeconds: r.ts_seconds == null ? null : Number(r.ts_seconds),
    createdAt: r.created_at,
  }));
}

// POST /api/public/videos/:id/reactions { emoji, viewerId } — toggles one emoji.
async function handleReaction(id, request, env) {
  const err = await enabledVideoError(env, id);
  if (err) return err;
  const body = await request.json().catch(() => ({}));
  const emoji = String(body.emoji || "");
  const viewerId = cleanViewerId(body.viewerId);
  if (!REACTIONS.includes(emoji)) return json({ error: "unsupported reaction" }, { status: 400, headers: NO_STORE });
  if (!viewerId) return json({ error: "missing viewerId" }, { status: 400, headers: NO_STORE });

  const existing = await env.DB.prepare(
    "SELECT id FROM reactions WHERE video_id = ? AND emoji = ? AND viewer_id = ?"
  ).bind(id, emoji, viewerId).first();
  if (existing) {
    await env.DB.prepare("DELETE FROM reactions WHERE id = ?").bind(existing.id).run();
  } else {
    await env.DB.prepare(
      "INSERT INTO reactions (id, video_id, emoji, viewer_id, created_at) VALUES (?, ?, ?, ?, ?)"
    ).bind(crypto.randomUUID(), id, emoji, viewerId, new Date().toISOString()).run();
  }
  const [counts, mine] = await Promise.all([reactionCounts(env, id), viewerReactions(env, id, viewerId)]);
  return json({ counts, mine }, { headers: NO_STORE });
}

// POST /api/public/videos/:id/comments { author, body, viewerId, tsSeconds }.
async function handleAddComment(id, request, env) {
  const err = await enabledVideoError(env, id);
  if (err) return err;
  const b = await request.json().catch(() => ({}));
  const author = String(b.author || "").trim().slice(0, 60) || "Anonymous";
  const text = String(b.body || "").trim().slice(0, 2000);
  const viewerId = cleanViewerId(b.viewerId);
  let ts = Number(b.tsSeconds);
  ts = Number.isFinite(ts) && ts >= 0 ? ts : null;
  if (!text) return json({ error: "empty comment" }, { status: 400, headers: NO_STORE });

  const comment = {
    id: crypto.randomUUID(),
    author,
    body: text,
    tsSeconds: ts,
    createdAt: new Date().toISOString(),
  };
  await env.DB.prepare(
    "INSERT INTO comments (id, video_id, author, body, viewer_id, ts_seconds, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
  ).bind(comment.id, id, author, text, viewerId, ts, comment.createdAt).run();
  return json({ comment }, { headers: NO_STORE }); // viewerId intentionally not echoed
}

// DELETE /api/public/videos/:id/comments/:cid?viewer=... — the comment's author
// (matching viewerId) or the owner (bearer/Access) may remove it.
async function handleDeleteComment(id, cid, request, env) {
  const url = new URL(request.url);
  const viewerId = cleanViewerId(url.searchParams.get("viewer"));
  const row = await env.DB.prepare("SELECT viewer_id FROM comments WHERE id = ? AND video_id = ?")
    .bind(cid, id).first();
  if (!row) return json({ error: "not found" }, { status: 404, headers: NO_STORE });
  const isOwner = !(await ownerError(request, env));
  const isAuthor = !!(viewerId && row.viewer_id && await timingSafeEqual(viewerId, row.viewer_id));
  if (!isOwner && !isAuthor) return json({ error: "forbidden" }, { status: 403, headers: NO_STORE });
  await env.DB.prepare("DELETE FROM comments WHERE id = ?").bind(cid).run();
  return json({ deleted: cid }, { headers: NO_STORE });
}

// GET /api/public/videos/:id/engagement?viewer=... — counts + this viewer's
// reactions + the comment list (for clients that refresh without a reload).
async function handleEngagement(id, url, request, env) {
  const err = await enabledVideoError(env, id);
  if (err) return err;
  const viewerId = cleanViewerId(url.searchParams.get("viewer"));
  const [counts, mine, comments] = await Promise.all([
    reactionCounts(env, id),
    viewerReactions(env, id, viewerId),
    listComments(env, id),
  ]);
  return json({ counts, mine, comments }, { headers: NO_STORE });
}

// Owner moderation: delete a single comment that belongs to a video.
async function deleteComment(env, id, cid) {
  if (!cid) return false;
  const res = await env.DB.prepare("DELETE FROM comments WHERE id = ? AND video_id = ?")
    .bind(cid, id).run();
  return !!res.meta.changes;
}

// --- Transcript search (owner) ----------------------------------------------

// Search titles, transcripts and summaries with a LIKE scan — plenty at a
// self-hosted scale, and no FTS table/triggers to keep in sync. % and _ in the
// query are escaped so they match literally rather than as wildcards.
async function searchVideos(env, q) {
  const like = `%${q.replace(/[\\%_]/g, "\\$&")}%`;
  const { results } = await env.DB.prepare(
    `SELECT * FROM videos
       WHERE title LIKE ?1 ESCAPE '\\'
          OR transcript LIKE ?1 ESCAPE '\\'
          OR summary LIKE ?1 ESCAPE '\\'
       ORDER BY created_at DESC`
  ).bind(like).all();
  return results || [];
}

// A short transcript excerpt around the first match of q (for dashboard search
// results), or "" when the match was only in the title/summary.
function transcriptSnippet(transcript, q, radius = 80) {
  if (!transcript) return "";
  const i = transcript.toLowerCase().indexOf(q.toLowerCase());
  if (i === -1) return "";
  const start = Math.max(0, i - radius);
  const end = Math.min(transcript.length, i + q.length + radius);
  return (start > 0 ? "…" : "") + transcript.slice(start, end).trim() + (end < transcript.length ? "…" : "");
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
