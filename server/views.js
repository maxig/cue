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

export function renderPlayer(v) {
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
        <h1 class="title">${esc(v.title)}</h1>
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
        <div data-tab="summary">An AI summary and smart chapters will appear here. <span class="soon">Phase 2</span></div>
        <div data-tab="transcript" hidden>A searchable, word-level transcript will appear here. <span class="soon">Phase 2</span></div>
        <div data-tab="activity" hidden>Views, reactions, and comments will appear here. <span class="soon">Phase 2</span></div>
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
