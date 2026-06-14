-- Cue metadata store (D1 / SQLite). Mirrors the shape of server/db.json so the
-- Worker and the Node server expose an identical API.

CREATE TABLE IF NOT EXISTS videos (
  id               TEXT    PRIMARY KEY,
  title            TEXT    NOT NULL DEFAULT 'Untitled Cue',
  duration_seconds REAL    NOT NULL DEFAULT 0,
  object_key       TEXT    NOT NULL,
  audio_key        TEXT,             -- audio-only sidecar (audio.m4a) for transcription
  bytes            INTEGER NOT NULL DEFAULT 0,   -- R2 footprint (video + audio), drives the storage cap
  width            INTEGER NOT NULL DEFAULT 0,
  height           INTEGER NOT NULL DEFAULT 0,
  capture_mode     TEXT    NOT NULL DEFAULT 'screen',
  created_at       TEXT    NOT NULL,
  disabled         INTEGER NOT NULL DEFAULT 1,   -- share link OFF by default; owner enables it
  transcript       TEXT,             -- plain text, populated on demand by Whisper
  transcript_vtt   TEXT              -- WebVTT with segment timing, optional
);

CREATE INDEX IF NOT EXISTS idx_videos_created_at ON videos (created_at DESC);
