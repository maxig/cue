import assert from "node:assert/strict";
import { test } from "node:test";
import worker from "../src/index.js";

// Cloudflare exposes timingSafeEqual on SubtleCrypto. Node's Web Crypto may not
// yet include that extension, so provide an equivalent test-only implementation.
if (typeof crypto.subtle.timingSafeEqual !== "function") {
  Object.defineProperty(crypto.subtle, "timingSafeEqual", {
    value(a, b) {
      const left = new Uint8Array(a.buffer || a, a.byteOffset || 0, a.byteLength);
      const right = new Uint8Array(b.buffer || b, b.byteOffset || 0, b.byteLength);
      if (left.byteLength !== right.byteLength) return false;
      let difference = 0;
      for (let i = 0; i < left.byteLength; i += 1) difference |= left[i] ^ right[i];
      return difference === 0;
    },
  });
}

const sampleRow = {
  id: "video-1",
  title: "Hello demo",
  duration_seconds: 42,
  object_key: "video-1/final.mp4",
  audio_key: "video-1/audio.m4a",
  bytes: 1234,
  width: 1920,
  height: 1080,
  capture_mode: "screen",
  created_at: "2026-07-18T12:00:00.000Z",
  upload_status: "ready",
  upload_updated_at: "2026-07-18T12:00:00.000Z",
  disabled: 0,
  transcript: "Um, hello, you know, world.",
  transcript_vtt: "WEBVTT\n\n00:01.250 --> 00:03.000\nUm\n\n00:03.000 --> 00:05.000\nHello world.\n",
  summary: "A friendly demo.",
  title_updated_at: "2026-07-18T12:00:00.000Z",
  transcript_updated_at: "2026-07-18T12:01:00.000Z",
  summary_updated_at: "2026-07-18T12:02:00.000Z",
};

function mockEnvironment(row = sampleRow) {
  const writes = [];
  const DB = {
    withSession() { return DB; },
    prepare(sql) {
      return {
        bind(...values) {
          return {
            async first() {
              if (sql.includes("SELECT * FROM videos WHERE id")) return { ...row };
              if (sql.includes("SELECT upload_status, disabled")) {
                return { upload_status: row.upload_status || "ready", disabled: row.disabled };
              }
              if (sql.includes("SELECT disabled") && sql.includes("FROM videos")) {
                return { disabled: row.disabled, upload_status: row.upload_status || "ready" };
              }
              return null;
            },
            async all() {
              if (sql.includes("WHERE title LIKE")) return { results: [{ ...row }] };
              return { results: [] };
            },
            async run() {
              writes.push({ sql, values });
              return { meta: { changes: 1 } };
            },
          };
        },
      };
    },
  };
  return { env: { DB, OWNER_TOKEN: "test-owner" }, writes };
}

function ownerRequest(url, init = {}) {
  return new Request(url, {
    ...init,
    headers: { authorization: "Bearer test-owner", ...(init.headers || {}) },
  });
}

test("owner search returns transcript snippets and renders highlighted dashboard results", async () => {
  const { env } = mockEnvironment();
  const apiResponse = await worker.fetch(ownerRequest("https://cue.test/api/videos/search?q=hello"), env);
  assert.equal(apiResponse.status, 200);
  const payload = await apiResponse.json();
  assert.equal(payload.videos.length, 1);
  assert.match(payload.videos[0].snippet, /hello/i);

  const appResponse = await worker.fetch(ownerRequest("https://cue.test/app?q=hello"), env);
  assert.equal(appResponse.status, 200);
  const markup = await appResponse.text();
  assert.match(markup, /<mark>hello<\/mark>/i);
  assert.match(markup, /Remove fillers/);
});

test("declutter removes fillers from plain text and WebVTT cues", async () => {
  const { env, writes } = mockEnvironment();
  const response = await worker.fetch(ownerRequest("https://cue.test/api/videos/video-1/declutter", {
    method: "POST",
  }), env);
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.text, "hello, world.");

  const update = writes.find(({ sql }) => sql.includes("UPDATE videos SET transcript"));
  assert.ok(update, "expected transcript update");
  assert.equal(update.values[0], "hello, world.");
  assert.doesNotMatch(update.values[1], /\nUm\n/i);
  assert.match(update.values[1], /00:01\.250 --> 00:03\.000/);
});

test("public player renders stored VTT as clickable timestamped transcript lines", async () => {
  const { env } = mockEnvironment();
  const response = await worker.fetch(new Request("https://cue.test/v/video-1"), env);
  assert.equal(response.status, 200);
  const markup = await response.text();
  assert.match(markup, /class="ts-transcript"/);
  assert.match(markup, /onclick="seekTo\(1\.25\)"/);
  assert.match(markup, /Hello world\./);
});

test("an early upload entity has a stable loading page and public status", async () => {
  const row = { ...sampleRow, upload_status: "uploading", disabled: 0 };
  const { env } = mockEnvironment(row);
  const page = await worker.fetch(new Request("https://cue.test/v/video-1"), env);
  assert.equal(page.status, 200);
  const markup = await page.text();
  assert.match(markup, /Your recording is on its way/);
  assert.doesNotMatch(markup, /<video/);
  assert.equal(page.headers.get("cache-control"), "no-store");

  const status = await worker.fetch(new Request("https://cue.test/api/public/videos/video-1/status"), env);
  assert.equal(status.status, 200);
  assert.deepEqual(await status.json(), { status: "uploading", disabled: false });
});

test("registration persists upload lifecycle and requested public visibility", async () => {
  const { env, writes } = mockEnvironment();
  const response = await worker.fetch(ownerRequest("https://cue.test/api/videos", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      id: "new-video",
      title: "Fresh upload",
      objectKey: "new-video/final.mp4",
      uploadStatus: "uploading",
      disabled: false,
    }),
  }), env);
  assert.equal(response.status, 200);
  const insert = writes.find(({ sql }) => sql.includes("INSERT INTO videos"));
  assert.ok(insert);
  assert.equal(insert.values[10], "uploading");
  assert.equal(insert.values[12], 0);
  assert.doesNotMatch(insert.sql, /disabled=excluded\.disabled/);
});

test("a disabled link stays private while its upload is incomplete", async () => {
  const row = { ...sampleRow, upload_status: "uploading", disabled: 1 };
  const { env } = mockEnvironment(row);
  const page = await worker.fetch(new Request("https://cue.test/v/video-1"), env);
  assert.equal(page.status, 410);
  assert.match(await page.text(), /disabled by its owner/);
});

test("landing page links to GitHub and the stable DMG download route", async () => {
  const { env } = mockEnvironment();
  const page = await worker.fetch(new Request("https://cue.test/"), env);
  const markup = await page.text();
  assert.match(markup, /github\.com\/maxig\/cue/);
  assert.match(markup, /href="\/download"/);

  const download = await worker.fetch(new Request("https://cue.test/download"), env);
  assert.equal(download.status, 302);
  assert.equal(download.headers.get("location"), "https://github.com/maxig/cue/releases/latest/download/Cue.dmg");
});

test("summary generation creates a concise title and timestamped smart chapters", async () => {
  const row = {
    ...sampleRow,
    title: "Cue · Jul 21, 2:30 PM",
    transcript_vtt: "WEBVTT\n\n00:00.000 --> 00:08.000\nProject introduction.\n\n00:08.000 --> 00:30.000\nLive product demo.\n",
  };
  const { env, writes } = mockEnvironment(row);
  env.AI = {
    async run() {
      return {
        response: {
          title: "Shipping the New Search Experience",
          overview: "A walkthrough of the new search experience and its rollout plan.",
          keyPoints: ["Search is faster", "The rollout starts next week"],
          chapters: [
            { startSeconds: 0, title: "Introduction" },
            { startSeconds: 8, title: "Product demo" },
          ],
        },
      };
    },
  };

  const response = await worker.fetch(ownerRequest("https://cue.test/api/videos/video-1/summarize", {
    method: "POST",
  }), env);
  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.title, "Shipping the New Search Experience");
  assert.deepEqual(payload.chapters, [
    { startSeconds: 0, title: "Introduction" },
    { startSeconds: 8, title: "Product demo" },
  ]);
  assert.match(payload.summary, /Chapters:\n- 0:00 — Introduction/);

  const update = writes.find(({ sql }) => sql.includes("UPDATE videos SET title"));
  assert.ok(update, "expected title and summary update");
  assert.equal(update.values[0], "Shipping the New Search Experience");
});

test("owner can rename a video through the API and web management form", async () => {
  const { env, writes } = mockEnvironment();
  const apiResponse = await worker.fetch(ownerRequest("https://cue.test/api/videos/video-1/title", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ title: "  Quarterly   planning  " }),
  }), env);
  assert.equal(apiResponse.status, 200);
  assert.equal((await apiResponse.json()).title, "Quarterly planning");

  const formResponse = await worker.fetch(ownerRequest("https://cue.test/app/v/video-1", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", origin: "https://cue.test" },
    body: new URLSearchParams({ action: "rename", title: "Launch review" }),
  }), env);
  assert.equal(formResponse.status, 303);
  assert.ok(writes.some(({ sql, values }) => sql.includes("UPDATE videos SET title") && values[0] === "Launch review"));
});

test("native metadata sync uses independent conditional clocks and returns settled fields", async () => {
  const { env, writes } = mockEnvironment();
  const response = await worker.fetch(ownerRequest("https://cue.test/api/videos/video-1/sync", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      title: "Synced native title",
      titleUpdatedAt: "2026-07-21T10:00:00.000Z",
      transcript: "A newer local transcript.",
      transcriptVtt: null,
      transcriptUpdatedAt: "2026-07-21T10:01:00.000Z",
      summary: "A newer local summary.",
      summaryUpdatedAt: "2026-07-21T10:02:00.000Z",
    }),
  }), env);

  assert.equal(response.status, 200);
  assert.ok(writes.some(({ sql, values }) =>
    sql.includes("COALESCE(title_updated_at") && values[0] === "Synced native title"));
  assert.ok(writes.some(({ sql, values }) =>
    sql.includes("COALESCE(transcript_updated_at") && values[0] === "A newer local transcript."));
  assert.ok(writes.some(({ sql, values }) =>
    sql.includes("COALESCE(summary_updated_at") && values[0] === "A newer local summary."));
});

test("public player renders stored smart chapters as seek controls", async () => {
  const row = {
    ...sampleRow,
    summary: "A concise overview.\n\nKey points:\n- One\n\nChapters:\n- 0:00 — Introduction\n- 0:12 — Demo",
  };
  const { env } = mockEnvironment(row);
  const response = await worker.fetch(new Request("https://cue.test/v/video-1"), env);
  assert.equal(response.status, 200);
  const markup = await response.text();
  assert.match(markup, /class="chapter" onclick="seekTo\(12\)"/);
  assert.match(markup, />Demo<\/span>/);
  assert.doesNotMatch(markup, /Chapters:\s*- 0:00/);
});
