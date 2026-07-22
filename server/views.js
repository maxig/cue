// Server-rendered HTML for the Cue web player and index.

function esc(s = "") {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtDuration(seconds = 0) {
  const total = Math.round(seconds);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

function fmtDate(iso) {
  try {
    return new Date(iso).toLocaleString(undefined, {
      month: "short", day: "numeric", year: "numeric", hour: "numeric", minute: "2-digit",
    });
  } catch {
    return iso || "";
  }
}

const BASE_CSS = `
  :root {
    --bg: #0b0d12;
    --panel: rgba(255,255,255,0.05);
    --panel-border: rgba(255,255,255,0.10);
    --text: #f4f6fb;
    --muted: #9aa3b2;
    --accent: #0a84ff;
    --teal: #00b8bd;
    --radius: 18px;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body {
    background:
      radial-gradient(1200px 600px at 80% -10%, rgba(10,132,255,0.18), transparent 60%),
      radial-gradient(900px 500px at -10% 10%, rgba(0,184,189,0.12), transparent 55%),
      var(--bg);
    color: var(--text);
    font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", system-ui, sans-serif;
    min-height: 100vh;
  }
  a { color: var(--accent); text-decoration: none; }
  .wrap { max-width: 1100px; margin: 0 auto; padding: 24px; }
  .topbar { display: flex; align-items: center; gap: 12px; margin-bottom: 22px; }
  .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 18px; }
  .logo {
    width: 26px; height: 26px; border-radius: 50%;
    background: linear-gradient(135deg, var(--accent), var(--teal));
    display: grid; place-items: center; box-shadow: 0 4px 14px rgba(10,132,255,.45);
  }
  .logo::after { content: ""; width: 9px; height: 9px; border-radius: 50%; background: #fff; }
  .spacer { flex: 1; }
  .linkpill {
    display: flex; align-items: center; gap: 8px;
    background: var(--panel); border: 1px solid var(--panel-border);
    border-radius: 999px; padding: 7px 8px 7px 14px; backdrop-filter: blur(20px);
  }
  .linkpill code { color: var(--muted); font-size: 12px; max-width: 320px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  button.copy {
    border: none; cursor: pointer; color: #fff; font-weight: 600; font-size: 12px;
    background: var(--accent); border-radius: 999px; padding: 6px 12px;
  }
  button.copy:active { transform: scale(0.97); }
  .layout { display: grid; grid-template-columns: 1fr 340px; gap: 18px; align-items: start; }
  @media (max-width: 860px) { .layout { grid-template-columns: 1fr; } }
  .card {
    background: var(--panel); border: 1px solid var(--panel-border);
    border-radius: var(--radius); backdrop-filter: blur(24px);
  }
  .videoframe { overflow: hidden; padding: 0; background: #000; }
  video { width: 100%; display: block; aspect-ratio: 16/10; background: #000; }
  .meta { padding: 16px 18px; }
  .title { font-size: 22px; font-weight: 700; margin: 0 0 6px; }
  .title-form { display: flex; gap: 7px; align-items: center; margin: 0 0 8px; }
  .title-input { width: 100%; min-width: 0; background: rgba(255,255,255,.05); border: 1px solid var(--panel-border);
                 color: var(--text); border-radius: 10px; padding: 8px 10px; font-family: inherit; font-size: 17px;
                 line-height: 1.2; font-weight: 700; }
  .title-input:focus { outline: none; border-color: rgba(10,132,255,.65); }
  .save-title { border: none; cursor: pointer; color: #fff; font-weight: 600; font-size: 12px;
                background: var(--accent); border-radius: 10px; padding: 8px 12px; }
  .submeta { color: var(--muted); font-size: 13px; display: flex; gap: 14px; flex-wrap: wrap; }
  .submeta span { display: inline-flex; gap: 6px; align-items: center; }
  .reactions { display: flex; gap: 8px; padding: 12px 18px 0; }
  .reactions button {
    border: 1px solid var(--panel-border); background: rgba(255,255,255,0.04);
    border-radius: 999px; padding: 6px 10px; font-size: 16px; cursor: pointer;
  }
  .reactions button:hover { background: rgba(255,255,255,0.10); }
  .tabs { display: flex; gap: 4px; padding: 6px; }
  .tabs button {
    flex: 1; border: none; cursor: pointer; color: var(--muted); font-weight: 600; font-size: 13px;
    background: transparent; border-radius: 12px; padding: 8px;
  }
  .tabs button.active { color: var(--text); background: rgba(255,255,255,0.08); }
  .tabbody { padding: 0 18px 18px; color: var(--muted); font-size: 13.5px; }
  .soon {
    display: inline-block; margin-top: 8px; font-size: 11px; font-weight: 700; color: var(--accent);
    background: rgba(10,132,255,0.14); padding: 3px 9px; border-radius: 999px;
  }
  .empty { text-align: center; padding: 80px 20px; color: var(--muted); }
  .list { display: grid; gap: 10px; }
  .row { display: flex; gap: 12px; padding: 12px 14px; align-items: center; }
  .row .t { font-weight: 600; color: var(--text); }
  footer { color: var(--muted); font-size: 12px; text-align: center; margin-top: 28px; }
`;

const SITE_CSS = `
  .site { max-width: 900px; margin: 0 auto; padding: 28px 24px 56px; }
  .site .topbar { margin-bottom: 64px; }
  .site .brand { color: var(--text); }
  .github { color: var(--text); border: 1px solid var(--panel-border); background: var(--panel);
            border-radius: 999px; padding: 7px 12px; font-size: 13px; }
  .hero { max-width: 730px; text-align: center; margin: 0 auto; }
  .hero h1 { font-size: clamp(42px, 8vw, 72px); letter-spacing: -.05em; line-height: 1; margin: 0 0 20px; }
  .hero p { color: var(--muted); font-size: 19px; margin: 0 auto; max-width: 640px; }
  .ctas { display: flex; justify-content: center; gap: 12px; flex-wrap: wrap; margin: 32px 0 64px; }
  .cta { color: #fff; font-weight: 700; border-radius: 14px; padding: 13px 20px; background: var(--accent); }
  .cta.secondary { color: var(--text); background: var(--panel); border: 1px solid var(--panel-border); }
  .steps { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
  .step { padding: 20px; }
  .step b { color: var(--accent); }
  .step h2 { font-size: 16px; margin: 12px 0 5px; }
  .step p { color: var(--muted); font-size: 13px; margin: 0; }
  .contribute { margin-top: 14px; padding: 22px; text-align: center; color: var(--muted); }
  .waiting { max-width: 580px; margin: 80px auto; padding: 44px 30px; text-align: center; }
  .waiting p { color: var(--muted); }
  .spinner { width: 42px; height: 42px; margin: 0 auto 22px; border-radius: 50%; border: 3px solid rgba(255,255,255,.12);
             border-top-color: var(--accent); animation: spin .9s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  @media (max-width: 700px) { .steps { grid-template-columns: 1fr; } }
`;

export function renderPlayer(v, { editable = false } = {}) {
  const share = esc(v.shareURL);
  const media = esc(v.mediaURL);
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(v.title)} · Cue</title>
<style>${BASE_CSS}</style>
</head><body>
<div class="wrap">
  <div class="topbar">
    <div class="brand"><div class="logo"></div> Cue</div>
    <div class="spacer"></div>
    <div class="linkpill">
      <code id="share">${share}</code>
      <button class="copy" onclick="navigator.clipboard.writeText('${share}');this.textContent='Copied'">Copy link</button>
    </div>
  </div>

  <div class="layout">
    <div>
      <div class="card videoframe">
        <video controls autoplay playsinline preload="metadata" src="${media}"></video>
      </div>
      <div class="reactions" aria-hidden="true">
        <button>👍</button><button>🎉</button><button>😂</button><button>❤️</button><button>👀</button><button>🔥</button>
      </div>
    </div>

    <div class="card">
      <div class="meta">
        ${editable
          ? `<form class="title-form" method="post" action="/videos/${esc(v.id)}/title">
              <input class="title-input" name="title" value="${esc(v.title)}" maxlength="100" aria-label="Video title" required />
              <button class="save-title" type="submit">Save</button>
            </form>`
          : `<h1 class="title">${esc(v.title)}</h1>`}
        <div class="submeta">
          <span>📅 ${esc(fmtDate(v.createdAt))}</span>
          <span>⏱ ${esc(fmtDuration(v.durationSeconds))}</span>
          <span>🖥 ${esc(v.captureMode)}</span>
        </div>
      </div>
      <div class="tabs">
        <button class="active" onclick="tab(this,'summary')">Summary</button>
        <button onclick="tab(this,'transcript')">Transcript</button>
        <button onclick="tab(this,'activity')">Activity</button>
      </div>
      <div class="tabbody">
        <div data-tab="summary">AI summaries are available when Cue is connected to the Cloudflare backend.</div>
        <div data-tab="transcript" hidden>AI transcripts are available when Cue is connected to the Cloudflare backend.</div>
        <div data-tab="activity" hidden>Reactions and comments are available on the Cloudflare player.</div>
      </div>
    </div>
  </div>

  <footer>Shared with Cue · self-hosted</footer>
</div>
<script>
  function tab(btn, name){
    document.querySelectorAll('.tabs button').forEach(b=>b.classList.remove('active'));
    btn.classList.add('active');
    document.querySelectorAll('.tabbody [data-tab]').forEach(d=>d.hidden = d.dataset.tab!==name);
  }
</script>
</body></html>`;
}

export function renderLanding() {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="description" content="Cue is an open-source native macOS screen recorder with self-hosted sharing." />
  <title>Cue · Native screen recording for macOS</title><style>${BASE_CSS}${SITE_CSS}</style></head><body>
  <div class="site"><div class="topbar"><a class="brand" href="/"><div class="logo"></div> Cue</a><div class="spacer"></div>
  <a class="github" href="https://github.com/maxig/cue" target="_blank" rel="noopener">⌘ Open source · GitHub ↗</a></div>
  <main><section class="hero"><h1>Record your Mac.<br />Share in a moment.</h1>
  <p>A lightweight, open-source Loom alternative that keeps recordings on your Mac and storage you control.</p>
  <div class="ctas"><a class="cta" href="/download">↓ Download Cue for macOS</a>
  <a class="cta secondary" href="https://github.com/maxig/cue" target="_blank" rel="noopener">View source</a></div></section>
  <section class="steps"><article class="card step"><b>1</b><h2>Download the DMG</h2><p>Get the latest signed build directly from GitHub.</p></article>
  <article class="card step"><b>2</b><h2>Move it to Applications</h2><p>Open the disk image and drag Cue to Applications.</p></article>
  <article class="card step"><b>3</b><h2>Grant capture access</h2><p>Screen Recording is required. Camera and microphone are optional.</p></article></section>
  <section class="card contribute">Want to help? <a href="https://github.com/maxig/cue#contributing" target="_blank" rel="noopener">Report an issue or contribute on GitHub ↗</a></section></main>
  <footer>MIT licensed · recordings stay yours</footer></div></body></html>`;
}

export function renderUploading(v) {
  const id = JSON.stringify(String(v.id)).replace(/</g, "\\u003c");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" /><meta name="robots" content="noindex" />
  <title>Uploading ${esc(v.title)} · Cue</title><style>${BASE_CSS}${SITE_CSS}</style></head><body><div class="wrap">
  <div class="topbar"><a class="brand" href="/"><div class="logo"></div> Cue</a></div>
  <main class="card waiting"><div class="spinner"></div><h1>Your recording is on its way</h1>
  <p id="msg">${esc(v.title)} is still uploading. This page will be ready automatically.</p></main></div>
  <script>const id=${id};async function check(){try{const r=await fetch('/api/public/videos/'+encodeURIComponent(id)+'/status',{cache:'no-store'});if(r.ok){const s=await r.json();if(s.disabled||s.status==='ready'){location.reload();return;}if(s.status==='failed'){document.querySelector('.spinner').style.display='none';document.getElementById('msg').textContent='The upload paused. The owner can resume it from Cue.';return;}}}catch(e){}setTimeout(check,2000)}setTimeout(check,1200)</script>
  </body></html>`;
}

export function renderUploadFailed(v) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" /><meta name="robots" content="noindex" />
  <title>Upload paused · Cue</title><style>${BASE_CSS}${SITE_CSS}</style></head><body><div class="wrap">
  <div class="topbar"><a class="brand" href="/"><div class="logo"></div> Cue</a></div>
  <main class="card waiting"><h1>Upload paused</h1><p>${esc(v.title)} is safe on the owner's Mac. They can resume this upload from Cue.</p></main>
  </div></body></html>`;
}

export function renderDisabled() {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Link disabled · Cue</title><style>${BASE_CSS}</style></head><body><div class="wrap">
  <div class="topbar"><a class="brand" href="/"><div class="logo"></div> Cue</a></div>
  <div class="empty">This share link has been disabled by its owner.</div></div></body></html>`;
}

export function renderIndex(videos, { notFound } = {}) {
  const rows = videos.map((v) => `
    <a class="card row" href="/v/${esc(v.id)}">
      <div>
        <div class="t">${esc(v.title)}</div>
        <div class="submeta"><span>${esc(fmtDate(v.createdAt))}</span> <span>${esc(fmtDuration(v.durationSeconds))}</span></div>
      </div>
    </a>`).join("");

  const body = notFound
    ? `<div class="empty">No video found for <code>${esc(notFound)}</code>.</div>`
    : (videos.length ? `<div class="list">${rows}</div>` : `<div class="empty">No recordings shared yet.</div>`);

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Cue</title><style>${BASE_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar"><div class="brand"><div class="logo"></div> Cue</div></div>
  ${body}
  <footer>Cue · self-hosted</footer>
</div></body></html>`;
}
