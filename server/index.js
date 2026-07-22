import express from "express";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderPlayer, renderIndex, renderLanding, renderUploading, renderUploadFailed, renderDisabled } from "./views.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = process.env.PORT || 8787;
// Public base of THIS service (used to build share links).
const PUBLIC_BASE = (process.env.CUE_PUBLIC_BASE || `http://localhost:${PORT}`).replace(/\/$/, "");
// Public base where MinIO objects are served from (bucket included).
const MINIO_PUBLIC_BASE = (process.env.MINIO_PUBLIC_BASE || "http://localhost:9000/cue").replace(/\/$/, "");

const DB_PATH = path.join(__dirname, "db.json");
const DB_BACKUP_PATH = path.join(__dirname, "db.backup.json");

// --- tiny JSON store -------------------------------------------------------

function loadDB() {
  for (const candidate of [DB_PATH, DB_BACKUP_PATH]) {
    try {
      const db = JSON.parse(fs.readFileSync(candidate, "utf8"));
      if (!db || typeof db !== "object" || !db.videos || typeof db.videos !== "object") continue;
      if (candidate === DB_BACKUP_PATH) {
        fs.copyFileSync(DB_BACKUP_PATH, DB_PATH);
        console.warn("Cue server restored db.json from its backup");
      }
      return db;
    } catch {}
  }
  return { videos: {} };
}
function saveDB(db) {
  const temporary = `${DB_PATH}.${process.pid}.tmp`;
  const handle = fs.openSync(temporary, "w", 0o600);
  try {
    fs.writeFileSync(handle, JSON.stringify(db, null, 2));
    fs.fsyncSync(handle);
  } finally {
    fs.closeSync(handle);
  }
  if (fs.existsSync(DB_PATH)) fs.copyFileSync(DB_PATH, DB_BACKUP_PATH);
  fs.renameSync(temporary, DB_PATH);
}

function mediaURL(video) {
  return `${MINIO_PUBLIC_BASE}/${video.objectKey}`;
}

function normalizedTimestamp(value, fallback = null) {
  const milliseconds = Date.parse(String(value || ""));
  if (Number.isFinite(milliseconds)) return new Date(milliseconds).toISOString();
  return fallback;
}

function apiVideo(video) {
  return {
    ...video,
    disabled: !!video.disabled,
    titleUpdatedAt: video.titleUpdatedAt || video.createdAt || null,
    transcriptUpdatedAt: video.transcript == null ? null : (video.transcriptUpdatedAt || video.createdAt || null),
    summaryUpdatedAt: video.summary == null ? null : (video.summaryUpdatedAt || video.createdAt || null),
    uploadStatus: video.uploadStatus || "ready",
    uploadUpdatedAt: video.uploadUpdatedAt || video.createdAt || null,
    mediaURL: mediaURL(video),
    shareURL: `${PUBLIC_BASE}/v/${video.id}`,
  };
}

// --- app -------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: "5mb" }));
app.use(express.urlencoded({ extended: false, limit: "32kb" }));

// Permissive CORS for the desktop app + the player page.
app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
  res.setHeader("Content-Security-Policy", "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data: https:; media-src 'self' blob: http: https:");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.get("/healthz", (_req, res) => res.json({ ok: true, service: "cue-server" }));

// Register a freshly uploaded recording. Returns the canonical share URL.
app.post("/api/videos", (req, res) => {
  const { id, title, durationSeconds, objectKey, audioKey, bytes, width, height, captureMode, createdAt } = req.body || {};
  if (!id || !objectKey) {
    return res.status(400).json({ error: "id and objectKey are required" });
  }
  const db = loadDB();
  const existing = db.videos[id];
  const created = normalizedTimestamp(createdAt, new Date().toISOString());
  const incomingTitleAt = normalizedTimestamp(req.body?.titleUpdatedAt, created);
  const existingTitleAt = normalizedTimestamp(existing?.titleUpdatedAt, existing?.createdAt || "");
  const useIncomingTitle = !existing || !existingTitleAt || incomingTitleAt >= existingTitleAt;
  const uploadStatus = ["uploading", "ready", "failed"].includes(req.body?.uploadStatus)
    ? req.body.uploadStatus : "ready";
  db.videos[id] = {
    ...existing,
    id,
    title: useIncomingTitle ? (title || "Untitled Cue") : existing.title,
    titleUpdatedAt: useIncomingTitle ? incomingTitleAt : existingTitleAt,
    durationSeconds: Number(durationSeconds) || 0,
    objectKey,
    audioKey: audioKey || null,
    bytes: Number(bytes) || 0,
    width: Number(width) || 0,
    height: Number(height) || 0,
    captureMode: captureMode || "screen",
    createdAt: created,
    uploadStatus,
    uploadUpdatedAt: new Date().toISOString(),
    // A retry/finalization must not re-enable a link the owner disabled while
    // an upload was running. Visibility is chosen only when the entity is born.
    disabled: existing ? !!existing.disabled : req.body?.disabled !== false,
  };
  saveDB(db);
  res.json({ id, url: `${PUBLIC_BASE}/v/${id}` });
});

app.get("/api/videos", (_req, res) => {
  const db = loadDB();
  const videos = Object.values(db.videos)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map(apiVideo);
  res.json({ videos });
});

app.get("/api/videos/:id", (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) return res.status(404).json({ error: "not found" });
  res.json(apiVideo(video));
});

app.get("/api/public/videos/:id/status", (req, res) => {
  const video = loadDB().videos[req.params.id];
  if (!video) return res.status(404).set("cache-control", "no-store").json({ error: "not found" });
  res.set("cache-control", "no-store").json({
    status: video.uploadStatus || "ready",
    disabled: !!video.disabled,
  });
});

app.post("/api/videos/:id/:action(enable|disable)", (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) return res.status(404).json({ error: "not found" });
  video.disabled = req.params.action === "disable";
  saveDB(db);
  res.json({ id: video.id, disabled: video.disabled });
});

app.delete("/api/videos/:id", (req, res) => {
  const db = loadDB();
  if (!db.videos[req.params.id]) return res.status(404).json({ error: "not found" });
  delete db.videos[req.params.id];
  saveDB(db);
  res.json({ deleted: req.params.id });
});

function cleanTitle(value) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, 100).trim();
}

function renameVideo(id, proposedTitle, proposedUpdatedAt) {
  const title = cleanTitle(proposedTitle);
  if (!title) return { error: "title is required", status: 400 };
  const db = loadDB();
  if (!db.videos[id]) return { error: "not found", status: 404 };
  const video = db.videos[id];
  const updatedAt = normalizedTimestamp(proposedUpdatedAt, new Date().toISOString());
  const currentUpdatedAt = normalizedTimestamp(video.titleUpdatedAt, video.createdAt || "");
  if (!currentUpdatedAt || updatedAt > currentUpdatedAt) {
    video.title = title;
    video.titleUpdatedAt = updatedAt;
    saveDB(db);
  }
  return { id, title: video.title, titleUpdatedAt: video.titleUpdatedAt || video.createdAt || null };
}

// Same title endpoint as the Cloudflare Worker, used by the native Library.
app.post("/api/videos/:id/title", (req, res) => {
  const result = renameVideo(req.params.id, req.body?.title, req.body?.titleUpdatedAt);
  if (result.error) return res.status(result.status).json({ error: result.error });
  res.json(result);
});

// Same conditional per-field merge contract as the Cloudflare Worker.
app.post("/api/videos/:id/sync", (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) return res.status(404).json({ error: "not found" });
  const body = req.body || {};
  let changed = false;

  if (Object.hasOwn(body, "title")) {
    const title = cleanTitle(body.title);
    const updatedAt = normalizedTimestamp(body.titleUpdatedAt);
    if (!title || !updatedAt) return res.status(400).json({ error: "title and titleUpdatedAt are required" });
    const current = normalizedTimestamp(video.titleUpdatedAt, video.createdAt || "");
    if (!current || updatedAt > current) {
      video.title = title;
      video.titleUpdatedAt = updatedAt;
      changed = true;
    }
  }
  if (Object.hasOwn(body, "transcript")) {
    const updatedAt = normalizedTimestamp(body.transcriptUpdatedAt);
    if (!updatedAt) return res.status(400).json({ error: "transcriptUpdatedAt is required" });
    const current = normalizedTimestamp(video.transcriptUpdatedAt);
    if (!current || updatedAt > current) {
      video.transcript = body.transcript == null ? null : String(body.transcript);
      video.transcriptVtt = body.transcriptVtt == null ? null : String(body.transcriptVtt);
      video.transcriptUpdatedAt = updatedAt;
      changed = true;
    }
  }
  if (Object.hasOwn(body, "summary")) {
    const updatedAt = normalizedTimestamp(body.summaryUpdatedAt);
    if (!updatedAt) return res.status(400).json({ error: "summaryUpdatedAt is required" });
    const current = normalizedTimestamp(video.summaryUpdatedAt);
    if (!current || updatedAt > current) {
      video.summary = body.summary == null ? null : String(body.summary);
      video.summaryUpdatedAt = updatedAt;
      changed = true;
    }
  }
  if (changed) saveDB(db);
  res.json(apiVideo(video));
});

// Local web-player form counterpart. The development server has no owner auth,
// so anyone who can reach this explicitly local service can edit its metadata.
app.post("/videos/:id/title", (req, res) => {
  const result = renameVideo(req.params.id, req.body?.title);
  if (result.error) return res.status(result.status).send(result.error);
  res.redirect(303, `/v/${encodeURIComponent(req.params.id)}`);
});

// The web player page.
app.get("/v/:id", (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) {
    return res.status(404).send(renderIndex([], { notFound: req.params.id }));
  }
  if (video.disabled) return res.status(410).set("cache-control", "no-store").send(renderDisabled());
  if (video.uploadStatus === "failed") {
    return res.status(503).set("cache-control", "no-store").send(renderUploadFailed(apiVideo(video)));
  }
  if ((video.uploadStatus || "ready") !== "ready") {
    return res.set("cache-control", "no-store").send(renderUploading(apiVideo(video)));
  }
  res.send(renderPlayer(
    apiVideo(video),
    { editable: false }
  ));
});

// Public product landing. Keep the local catalog at /library for development.
app.get("/", (_req, res) => {
  res.send(renderLanding());
});

app.get("/download", (_req, res) => {
  res.redirect(302, "https://github.com/maxig/cue/releases/latest/download/Cue.dmg");
});

app.get("/library", (_req, res) => {
  const db = loadDB();
  const videos = Object.values(db.videos)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map((v) => ({ ...v, shareURL: `${PUBLIC_BASE}/v/${v.id}` }));
  res.send(renderIndex(videos, {}));
});

app.listen(PORT, () => {
  console.log(`Cue server on ${PUBLIC_BASE}`);
  console.log(`Streaming media from ${MINIO_PUBLIC_BASE}`);
});
