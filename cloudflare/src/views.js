// Server-rendered HTML for the Cue web player and index.
// Ported verbatim from server/views.js; the only change is that the Transcript
// tab renders a real transcript when one is present (see renderPlayer).

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
  .transcript { white-space: pre-wrap; line-height: 1.6; color: var(--text); max-height: 340px; overflow: auto; }
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
  const transcriptBody = v.transcript
    ? `<div class="transcript">${esc(v.transcript)}</div>`
    : `A searchable, word-level transcript will appear here. <span class="soon">Phase 2</span>`;
  const summaryBody = v.summary
    ? `<div class="transcript">${esc(v.summary)}</div>`
    : `An AI summary and smart chapters will appear here. <span class="soon">Phase 2</span>`;
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
        <div data-tab="summary">${summaryBody}</div>
        <div data-tab="transcript" hidden>${transcriptBody}</div>
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

export function renderDisabled() {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Link disabled · Cue</title><style>${BASE_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar"><div class="brand"><div class="logo"></div> Cue</div></div>
  <div class="empty">This share link has been disabled by its owner.</div>
  <footer>Cue · self-hosted</footer>
</div></body></html>`;
}

export function renderLanding() {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Cue</title><style>${BASE_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar"><div class="brand"><div class="logo"></div> Cue</div></div>
  <div class="empty">This is a private Cue server. Open a share link to view a recording.</div>
  <footer>Cue · self-hosted</footer>
</div></body></html>`;
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

// Extra styles for the owner dashboard (/app), layered on top of BASE_CSS.
const APP_CSS = `
  .approw { justify-content: space-between; gap: 16px; flex-wrap: wrap; }
  .approw .grow { min-width: 240px; flex: 1; }
  .sharerow { margin-top: 6px; font-size: 12px; }
  .sharerow a { color: var(--muted); word-break: break-all; }
  .badge { font-size: 11px; font-weight: 700; padding: 2px 8px; border-radius: 999px; }
  .badge.on { color: #2ec26b; background: rgba(46,194,107,0.16); }
  .badge.off { color: var(--muted); background: rgba(255,255,255,0.08); }
  .actions { display: flex; gap: 8px; align-items: center; }
  .actions form { margin: 0; }
  .btn { cursor: pointer; border: 1px solid var(--panel-border); background: rgba(255,255,255,0.06);
         color: var(--text); font-weight: 600; font-size: 12px; border-radius: 10px; padding: 7px 12px; }
  .btn:hover { background: rgba(255,255,255,0.12); }
  .btn.danger { color: #ff8a8a; border-color: rgba(255,90,90,0.35); }
  .btn.danger:hover { background: rgba(255,90,90,0.14); }
  .count { color: var(--muted); font-size: 13px; }
  .actions { flex-wrap: wrap; }
  .badge.ai { color: var(--accent); background: rgba(10,132,255,0.14); }
  .aiout { padding: 0 14px 14px; }
  .aiout b { display: block; font-size: 12px; color: var(--muted); margin-bottom: 4px; }
  .aitext { white-space: pre-wrap; line-height: 1.55; font-size: 13.5px; max-height: 260px; overflow: auto; }
  .banner { padding: 10px 14px; border-radius: 12px; margin-bottom: 14px; font-size: 13px; font-weight: 600; }
  .banner.ok { background: rgba(46,194,107,0.16); color: #2ec26b; }
  .banner.err { background: rgba(255,90,90,0.14); color: #ff8a8a; }
`;

// Private owner dashboard at /app — lists every recording with Enable/Disable
// and Delete controls. Reachable only behind Cloudflare Access (or the bearer
// token); the Worker fails closed otherwise.
export function renderApp(videos, { base = "", flash = "", error = "" } = {}) {
  const banner = error
    ? `<div class="banner err">${esc(error)}</div>`
    : (flash ? `<div class="banner ok">${esc(flash)}</div>` : "");

  const act = (id, action, label, extra = "") =>
    `<form method="post" action="/app"${extra}>` +
    `<input type="hidden" name="id" value="${esc(id)}" />` +
    `<input type="hidden" name="action" value="${action}" />` +
    `<button class="btn${action === "delete" ? " danger" : ""}" type="submit">${label}</button></form>`;

  const rows = videos.map((v) => {
    const share = esc(v.shareURL || `${base}/v/${v.id}`);
    const status = v.disabled
      ? `<span class="badge off">Disabled</span>`
      : `<span class="badge on">Live</span>`;
    const toggle = v.disabled ? "enable" : "disable";
    const toggleLabel = v.disabled ? "Enable link" : "Disable link";
    const aiBadges =
      (v.transcript ? `<span class="badge ai">📝 transcript</span>` : ``) +
      (v.summary ? `<span class="badge ai">✨ summary</span>` : ``);
    const summaryBlock = v.summary
      ? `<div class="aiout"><b>AI summary</b><div class="aitext">${esc(v.summary)}</div></div>`
      : ``;
    return `
    <div class="card">
      <div class="row approw">
        <div class="grow">
          <div class="t">${esc(v.title)}</div>
          <div class="submeta">
            <span>📅 ${esc(fmtDate(v.createdAt))}</span>
            <span>⏱ ${esc(fmtDuration(v.durationSeconds))}</span>
            <span>🖥 ${esc(v.captureMode || "")}</span>
            ${status}${aiBadges}
          </div>
          <div class="sharerow"><a href="/v/${esc(v.id)}" target="_blank" rel="noopener">${share}</a></div>
        </div>
        <div class="actions">
          ${act(v.id, toggle, toggleLabel)}
          ${act(v.id, "transcribe", v.transcript ? "Re-transcribe" : "Transcribe", ` onsubmit="this.querySelector('button').textContent='Transcribing…'"`)}
          ${act(v.id, "summarize", v.summary ? "Re-summarize" : "Summarize", ` onsubmit="this.querySelector('button').textContent='Summarizing…'"`)}
          ${act(v.id, "delete", "Delete", ` onsubmit="return confirm('Delete this recording everywhere (cloud copy + share link)? This cannot be undone.')"`)}
        </div>
      </div>
      ${summaryBlock}
    </div>`;
  }).join("");

  const body = videos.length
    ? `<div class="list">${rows}</div>`
    : `<div class="empty">No recordings yet. Record something in the Cue app and click <b>Upload to Cloud</b>.</div>`;

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Library · Cue</title><style>${BASE_CSS}${APP_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar">
    <div class="brand"><div class="logo"></div> Cue</div>
    <div class="spacer"></div>
    <div class="count">${videos.length} recording${videos.length === 1 ? "" : "s"}</div>
  </div>
  ${banner}
  ${body}
  <footer>Your private library · only you can see this page</footer>
</div></body></html>`;
}

// Shown when /app is hit without a valid owner credential (e.g. before
// Cloudflare Access is set up, or on a hostname Access doesn't cover).
export function renderAppLocked(reason) {
  const msg = reason || "This dashboard is private. Sign in through Cloudflare Access to view your library.";
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Sign in · Cue</title><style>${BASE_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar"><div class="brand"><div class="logo"></div> Cue</div></div>
  <div class="empty">🔒 ${esc(msg)}</div>
  <footer>Cue · self-hosted</footer>
</div></body></html>`;
}
