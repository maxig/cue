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

// --- app -------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: "1mb" }));

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
  const { id, title, durationSeconds, objectKey, width, height, captureMode, createdAt } = req.body || {};
  if (!id || !objectKey) {
    return res.status(400).json({ error: "id and objectKey are required" });
  }
  const db = loadDB();
  db.videos[id] = {
    id,
    title: title || "Untitled Cue",
    durationSeconds: Number(durationSeconds) || 0,
    objectKey,
    width: Number(width) || 0,
    height: Number(height) || 0,
    captureMode: captureMode || "screen",
    createdAt: createdAt || new Date().toISOString(),
  };
  saveDB(db);
  res.json({ id, url: `${PUBLIC_BASE}/v/${id}` });
});

app.get("/api/videos", (_req, res) => {
  const db = loadDB();
  const videos = Object.values(db.videos)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map((v) => ({ ...v, mediaURL: mediaURL(v), shareURL: `${PUBLIC_BASE}/v/${v.id}` }));
  res.json({ videos });
});

app.get("/api/videos/:id", (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) return res.status(404).json({ error: "not found" });
  res.json({ ...video, mediaURL: mediaURL(video), shareURL: `${PUBLIC_BASE}/v/${video.id}` });
});

// The web player page.
app.get("/v/:id", (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) {
    return res.status(404).send(renderIndex([], { notFound: req.params.id }));
  }
  res.send(renderPlayer({ ...video, mediaURL: mediaURL(video), shareURL: `${PUBLIC_BASE}/v/${video.id}` }));
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
