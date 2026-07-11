import express from "express";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { renderPlayer, renderIndex, renderDisabled, renderLanding } from "./views.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = process.env.PORT || 8787;
// Public base of THIS service (used to build share links).
const PUBLIC_BASE = (process.env.CUE_PUBLIC_BASE || `http://localhost:${PORT}`).replace(/\/$/, "");
// Public base where MinIO objects are served from (bucket included).
const MINIO_PUBLIC_BASE = (process.env.MINIO_PUBLIC_BASE || "http://localhost:9000/cue").replace(/\/$/, "");
// Owner token for the privileged /api surface + dashboard. Fail-closed: the API
// is 503 until this is set, exactly like the Cloudflare Worker. Put the same
// value in the app under Settings ▸ Sharing ▸ Owner token.
const OWNER_TOKEN = process.env.OWNER_TOKEN || "";

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

// API shape sent to clients — mirrors the Worker's rowToVideo.
function decorate(video) {
  return {
    ...video,
    disabled: !!video.disabled,
    mediaURL: mediaURL(video),
    shareURL: `${PUBLIC_BASE}/v/${video.id}`,
  };
}

// --- owner auth (fail-closed, constant-time) --------------------------------

// Constant-time compare so a wrong token can't be recovered from timing.
function tokenOK(got) {
  if (!OWNER_TOKEN || !got) return false;
  const a = Buffer.from(got);
  const b = Buffer.from(OWNER_TOKEN);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

// Express middleware guarding the whole /api surface. Fail-closed: 503 until a
// token is configured, then 401 without a valid `Authorization: Bearer <token>`.
function requireOwner(req, res, next) {
  if (!OWNER_TOKEN) {
    return res.status(503).json({ error: "server not configured: set OWNER_TOKEN" });
  }
  const got = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");
  if (!tokenOK(got)) return res.status(401).json({ error: "unauthorized" });
  next();
}

// --- app -------------------------------------------------------------------

const app = express();
app.use(express.json({ limit: "1mb" }));

// Permissive CORS for the desktop app + the player page.
app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.get("/healthz", (_req, res) => res.json({ ok: true, service: "cue-server" }));

// Register a freshly uploaded recording. Returns the canonical share URL.
// New recordings are created with the share link DISABLED (links off by
// default); a re-upload of an existing recording preserves its current state.
app.post("/api/videos", requireOwner, (req, res) => {
  const { id, title, durationSeconds, objectKey, audioKey, bytes, width, height, captureMode, createdAt } = req.body || {};
  if (!id || !objectKey) {
    return res.status(400).json({ error: "id and objectKey are required" });
  }
  const db = loadDB();
  const existing = db.videos[id];
  db.videos[id] = {
    id,
    title: title || "Untitled Cue",
    durationSeconds: Number(durationSeconds) || 0,
    objectKey,
    audioKey: audioKey || null,
    bytes: Number(bytes) || 0,
    width: Number(width) || 0,
    height: Number(height) || 0,
    captureMode: captureMode || "screen",
    createdAt: createdAt || existing?.createdAt || new Date().toISOString(),
    // Preserve an existing link's enabled/disabled state on re-upload; default
    // new recordings to disabled so nothing is viewable until the owner opts in.
    disabled: existing ? !!existing.disabled : true,
  };
  saveDB(db);
  res.json({ id, url: `${PUBLIC_BASE}/v/${id}`, disabled: db.videos[id].disabled });
});

app.get("/api/videos", requireOwner, (_req, res) => {
  const db = loadDB();
  const videos = Object.values(db.videos)
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt))
    .map(decorate);
  res.json({ videos });
});

app.get("/api/videos/:id", requireOwner, (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) return res.status(404).json({ error: "not found" });
  res.json(decorate(video));
});

// Owner: rename a recording (updates the share page title).
app.patch("/api/videos/:id", requireOwner, (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) return res.status(404).json({ error: "not found" });
  const { title } = req.body || {};
  if (typeof title === "string" && title.trim()) video.title = title.trim();
  saveDB(db);
  res.json(decorate(video));
});

// Owner: enable / disable the public share link.
for (const action of ["enable", "disable"]) {
  app.post(`/api/videos/:id/${action}`, requireOwner, (req, res) => {
    const db = loadDB();
    const video = db.videos[req.params.id];
    if (!video) return res.status(404).json({ error: "not found" });
    video.disabled = action === "disable";
    saveDB(db);
    res.json({ id: video.id, disabled: video.disabled });
  });
}

// Owner: delete a recording's metadata. (The MinIO object itself is removed by
// the app via the S3 API; local dev serves the bucket publicly.)
app.delete("/api/videos/:id", requireOwner, (req, res) => {
  const db = loadDB();
  if (!db.videos[req.params.id]) return res.status(404).json({ error: "not found" });
  delete db.videos[req.params.id];
  saveDB(db);
  res.json({ deleted: req.params.id });
});

// The web player page. Disabled links return 410 (like the Worker).
app.get("/v/:id", (req, res) => {
  const db = loadDB();
  const video = db.videos[req.params.id];
  if (!video) {
    return res.status(404).send(renderIndex([], { notFound: req.params.id }));
  }
  if (video.disabled) return res.status(410).send(renderDisabled());
  res.send(renderPlayer(decorate(video)));
});

// Landing page — never lists the catalog (this is a private server).
app.get("/", (_req, res) => res.send(renderLanding()));

app.listen(PORT, () => {
  console.log(`Cue server on ${PUBLIC_BASE}`);
  console.log(`Streaming media from ${MINIO_PUBLIC_BASE}`);
  if (!OWNER_TOKEN) {
    console.warn("⚠  OWNER_TOKEN is not set — the /api surface is disabled (503).");
    console.warn("   Set OWNER_TOKEN and paste the same value into the app to enable sharing.");
  }
});
