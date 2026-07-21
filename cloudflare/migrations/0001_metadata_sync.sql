-- Add per-field clocks used by Cue's bidirectional native/web Library sync.
-- Apply once to databases created before these columns were part of schema.sql.
ALTER TABLE videos ADD COLUMN title_updated_at TEXT;
ALTER TABLE videos ADD COLUMN transcript_updated_at TEXT;
ALTER TABLE videos ADD COLUMN summary_updated_at TEXT;

UPDATE videos
SET title_updated_at = created_at
WHERE title_updated_at IS NULL;

UPDATE videos
SET transcript_updated_at = created_at
WHERE transcript IS NOT NULL AND transcript_updated_at IS NULL;

UPDATE videos
SET summary_updated_at = created_at
WHERE summary IS NOT NULL AND summary_updated_at IS NULL;
