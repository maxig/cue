import express from "express";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderPlayer, renderIndex } from "./views.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = process.env.PORT || 8787;
// Public base of THIS service (used to build share links).
const PUBLIC_BASE = (process.env.CUE_PUBLIC_BASE || `http://localhost:${PORT}`).replace(/\/$/, "");
// Public base where MinIO objects are served from (bucket included).
const MINIO_PUBLIC_BASE = (process.env.MINIO_PUBLIC_BASE || "http://localhost:9000/cue").replace(/\/$/, "");

const DB_PATH = path.join(__dirname, "db.json");

// --- tiny JSON store -------------------------------------------------------

function loadDB() {
  try {
    return JSON.parse(fs.readFileSync(DB_PATH, "utf8"));
  } catch {
    return { videos: {} };
  }
}
function saveDB(db) {
  fs.writeFileSync(DB_PATH, JSON.stringify(db, null, 2));
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
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
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
    disabled: existing?.disabled ?? false,
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
  res.send(renderPlayer(
    apiVideo(video),
    { editable: true }
  ));
});

// A simple library index.
app.get("/", (_req, res) => {
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
