-- Adds the durable early-link upload lifecycle. Existing rows already have
-- complete objects, so they migrate directly to `ready`.
ALTER TABLE videos ADD COLUMN upload_status TEXT NOT NULL DEFAULT 'ready';
ALTER TABLE videos ADD COLUMN upload_updated_at TEXT NOT NULL DEFAULT '';

UPDATE videos
SET upload_status = 'ready', upload_updated_at = created_at
WHERE upload_updated_at = '';
