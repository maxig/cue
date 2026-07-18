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
  disabled: 0,
  transcript: "Um, hello, you know, world.",
  transcript_vtt: "WEBVTT\n\n00:01.250 --> 00:03.000\nUm\n\n00:03.000 --> 00:05.000\nHello world.\n",
  summary: "A friendly demo.",
};

function mockEnvironment(row = sampleRow) {
  const writes = [];
  const DB = {
    prepare(sql) {
      return {
        bind(...values) {
          return {
            async first() {
              if (sql.includes("SELECT * FROM videos WHERE id")) return { ...row };
              if (sql.includes("SELECT disabled FROM videos")) return { disabled: row.disabled };
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
