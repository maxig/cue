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

// --- Timestamped transcript (from stored WebVTT) ----------------------------

// Parse "MM:SS.mmm" / "HH:MM:SS.mmm" (comma or dot) into seconds.
function vttTimeToSeconds(s) {
  let m = s.match(/(\d{1,3}):(\d{1,2}):(\d{1,2})[.,](\d{1,3})/);
  if (m) return (+m[1]) * 3600 + (+m[2]) * 60 + (+m[3]) + (+m[4].padEnd(3, "0")) / 1000;
  m = s.match(/(\d{1,3}):(\d{1,2})[.,](\d{1,3})/);
  if (m) return (+m[1]) * 60 + (+m[2]) + (+m[3].padEnd(3, "0")) / 1000;
  return null;
}

// Parse stored WebVTT (concatenated Whisper cues) into [{ start, text }].
// Tolerant of single- or double-newline separation between cues.
function parseVTT(vtt) {
  const out = [];
  let cur = null;
  for (const raw of String(vtt || "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line === "WEBVTT" || /^NOTE\b/.test(line)) continue;
    const arrow = line.indexOf("-->");
    if (arrow !== -1) {
      if (cur && cur.text) out.push(cur);
      const start = vttTimeToSeconds(line.slice(0, arrow));
      cur = { start: start == null ? 0 : start, text: "" };
    } else if (cur) {
      cur.text = cur.text ? `${cur.text} ${line}` : line;
    }
  }
  if (cur && cur.text) out.push(cur);
  return out;
}

// Aggregate fine cues into readable, sentence-ish lines: keep a short complete
// phrase on its own line, otherwise merge consecutive cues until a sentence end
// (or hard caps), so the result reads like the subtitle blocks in a Loom
// transcript rather than one word-soup paragraph.
function groupTranscript(segments) {
  const lines = [];
  let cur = null;
  const MIN = 45, HARD = 230, MAX_SECONDS = 14;
  for (const seg of segments) {
    if (!cur) cur = { start: seg.start, text: seg.text };
    else cur.text += ` ${seg.text}`;
    const endsSentence = /[.!?…]["')\]]?$/.test(cur.text);
    const tooLong = cur.text.length >= HARD;
    const spanned = (seg.start - cur.start) >= MAX_SECONDS && cur.text.length >= MIN;
    if ((endsSentence && cur.text.length >= MIN) || tooLong || spanned) {
      lines.push(cur);
      cur = null;
    }
  }
  if (cur && cur.text) lines.push(cur);
  return lines;
}

// Build the Loom-style timestamped transcript markup, or null if there's no
// usable VTT. Each timestamp reuses the player's seekTo().
function renderTimedTranscript(vtt) {
  const lines = groupTranscript(parseVTT(vtt));
  if (!lines.length) return null;
  return `<div class="ts-transcript">` + lines.map((l) =>
    `<div class="tline"><button type="button" class="tspill" onclick="seekTo(${l.start.toFixed(2)})">${esc(fmtDuration(l.start))}</button><div class="ttext">${esc(l.text)}</div></div>`
  ).join("") + `</div>`;
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
  .chapters { display: grid; gap: 7px; margin-top: 14px; }
  .chapters-label { color: var(--text); font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .06em; }
  .chapter { width: 100%; display: grid; grid-template-columns: 48px 1fr; gap: 9px; align-items: center;
             border: 1px solid var(--panel-border); background: rgba(255,255,255,.035); color: var(--text);
             border-radius: 10px; padding: 7px 9px; text-align: left; cursor: pointer; font: inherit; }
  .chapter:hover { background: rgba(10,132,255,.12); border-color: rgba(10,132,255,.35); }
  .chapter time { color: var(--accent); font-size: 11.5px; font-weight: 700; }
  .chapter span { font-size: 12.5px; line-height: 1.35; }
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

const LANDING_CSS = `
  .landing { max-width: 920px; margin: 0 auto; padding: 28px 24px 56px; }
  .landing .topbar { margin-bottom: 72px; }
  .github-badge { display: inline-flex; align-items: center; gap: 8px; color: var(--text); font-size: 13px;
                    border: 1px solid var(--panel-border); background: var(--panel); border-radius: 999px;
                    padding: 7px 12px; }
  .hero { text-align: center; max-width: 760px; margin: 0 auto; }
  .eyebrow { color: var(--teal); font-weight: 700; font-size: 13px; letter-spacing: .08em; text-transform: uppercase; }
  .hero h1 { font-size: clamp(42px, 8vw, 76px); line-height: .98; letter-spacing: -.055em; margin: 18px 0 22px; }
  .hero p { color: var(--muted); font-size: clamp(17px, 2.3vw, 21px); max-width: 650px; margin: 0 auto; }
  .cta-row { display: flex; justify-content: center; gap: 12px; flex-wrap: wrap; margin-top: 34px; }
  .download { display: inline-flex; align-items: center; justify-content: center; gap: 9px; background: var(--accent);
              color: #fff; font-weight: 750; border-radius: 14px; padding: 13px 20px; box-shadow: 0 12px 34px rgba(10,132,255,.3); }
  .source { display: inline-flex; align-items: center; color: var(--text); font-weight: 650; border: 1px solid var(--panel-border);
            background: var(--panel); border-radius: 14px; padding: 13px 20px; }
  .steps { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin: 72px 0 18px; }
  .step { padding: 20px; min-height: 150px; }
  .step b { display: grid; place-items: center; width: 28px; height: 28px; border-radius: 9px;
            background: rgba(10,132,255,.16); color: var(--accent); margin-bottom: 17px; }
  .step h2 { font-size: 16px; margin: 0 0 6px; }
  .step p { color: var(--muted); margin: 0; font-size: 13.5px; }
  .contribute { margin-top: 14px; padding: 24px; display: flex; align-items: center; gap: 22px; }
  .contribute h2 { margin: 0 0 5px; font-size: 18px; }
  .contribute p { color: var(--muted); margin: 0; }
  .contribute .source { margin-left: auto; white-space: nowrap; }
  @media (max-width: 700px) {
    .landing .topbar { margin-bottom: 50px; }
    .steps { grid-template-columns: 1fr; margin-top: 52px; }
    .step { min-height: 0; }
    .contribute { align-items: flex-start; flex-direction: column; }
    .contribute .source { margin-left: 0; }
  }
`;

const UPLOAD_CSS = `
  .upload-card { max-width: 580px; margin: 80px auto; padding: 44px 30px; text-align: center; }
  .spinner { width: 42px; height: 42px; margin: 0 auto 22px; border-radius: 50%;
             border: 3px solid rgba(255,255,255,.12); border-top-color: var(--accent);
             animation: spin .9s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .upload-card h1 { margin: 0 0 10px; font-size: 25px; }
  .upload-card p { color: var(--muted); margin: 0; }
  .upload-card .hint { margin-top: 18px; font-size: 12px; }
`;

// Reaction emoji the player offers. Must stay in sync with REACTIONS in
// src/index.js (the server is the authority and rejects anything else).
const REACTION_EMOJI = ["👍", "🎉", "😂", "❤️", "👀", "🔥"];

// Styles for reactions, comments and the owner action bar — layered on BASE_CSS
// for both the public player and the owner view.
const ENGAGE_CSS = `
  .backlink { color: var(--muted); font-size: 13px; }
  .reactions { flex-wrap: wrap; }
  .reactions button { display: inline-flex; align-items: center; gap: 6px; transition: transform .08s ease, background .15s ease; }
  .reactions button .rc { font-size: 12px; font-weight: 700; color: var(--muted); }
  .reactions button.active { background: rgba(10,132,255,0.18); border-color: rgba(10,132,255,0.5); }
  .reactions button.active .rc { color: var(--text); }
  .reactions button:active { transform: scale(0.94); }

  .btn { cursor: pointer; border: 1px solid var(--panel-border); background: rgba(255,255,255,0.06);
         color: var(--text); font-weight: 600; font-size: 12px; border-radius: 10px; padding: 7px 12px;
         text-decoration: none; display: inline-flex; align-items: center; gap: 6px; }
  .btn:hover { background: rgba(255,255,255,0.12); }
  .btn.danger { color: #ff8a8a; border-color: rgba(255,90,90,0.35); }
  .btn.danger:hover { background: rgba(255,90,90,0.14); }
  .btn.primary { background: var(--accent); border-color: transparent; color: #fff; }
  .btn.primary:hover { background: var(--accent); filter: brightness(1.08); }

  .ownerbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;
              padding: 12px 14px; margin-bottom: 14px; }
  .ownerbar .ob-status, .ownerbar .ob-actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .ownerbar form { margin: 0; }
  .title-form { display: flex; gap: 7px; align-items: center; margin: 0 0 8px; }
  .title-input { width: 100%; min-width: 0; background: rgba(255,255,255,.05); border: 1px solid var(--panel-border);
                 color: var(--text); border-radius: 10px; padding: 8px 10px; font-family: inherit; font-size: 17px;
                 line-height: 1.2; font-weight: 700; }
  .title-input:focus { outline: none; border-color: rgba(10,132,255,.65); }

  .commentcard { margin-top: 14px; padding: 14px 16px 16px; }
  .comments-head { font-weight: 700; font-size: 14px; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
  .comments-head .cnum { color: var(--muted); font-weight: 600; }
  .comment-form { display: grid; gap: 8px; margin-bottom: 18px; }
  .cinput { width: 100%; background: rgba(255,255,255,0.05); border: 1px solid var(--panel-border); color: var(--text);
            border-radius: 12px; padding: 10px 12px; font: inherit; resize: vertical; }
  .cinput::placeholder { color: var(--muted); }
  .cinput:focus { outline: none; border-color: rgba(10,132,255,0.6); }
  .cform-row { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
  .pin { color: var(--muted); font-size: 12.5px; display: inline-flex; align-items: center; gap: 6px; cursor: pointer; }
  .pin b { color: var(--text); }

  .comment-list { display: grid; gap: 14px; }
  .cempty { color: var(--muted); font-size: 13px; padding: 4px 0; }
  .comment { display: flex; gap: 10px; }
  .avatar { flex: 0 0 auto; width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center;
            font-size: 13px; font-weight: 700; color: #fff; background: linear-gradient(135deg, var(--accent), var(--teal)); }
  .comment-main { flex: 1; min-width: 0; }
  .comment-meta { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 12.5px; color: var(--muted); }
  .comment-meta .cauthor { color: var(--text); font-weight: 600; }
  .tspill { border: 1px solid rgba(10,132,255,0.4); background: rgba(10,132,255,0.14); color: var(--accent);
            border-radius: 999px; padding: 1px 8px; font-size: 11.5px; font-weight: 700; cursor: pointer; }
  .tspill:hover { background: rgba(10,132,255,0.22); }
  .cbody { color: var(--text); font-size: 14px; line-height: 1.5; margin-top: 3px; white-space: pre-wrap; word-break: break-word; }
  .linklike { border: none; background: none; color: var(--muted); cursor: pointer; font-size: 12px; padding: 0; }
  .linklike:hover { color: #ff8a8a; }
  .actline { color: var(--text); font-size: 13.5px; }
  .ts-transcript { display: grid; gap: 12px; max-height: 360px; overflow: auto; padding-right: 4px; }
  .tline { display: grid; grid-template-columns: 46px 1fr; gap: 10px; align-items: start; }
  .tline .tspill { justify-self: start; margin-top: 1px; }
  .ttext { color: var(--text); line-height: 1.55; font-size: 13.5px; }
`;

// Client logic shared by the public player and the owner view. Injected after a
// small inline preamble that sets VID / OWNER / __COMMENTS__. No template
// placeholders or backticks here, so it nests safely inside renderPlayer.
const PLAYER_JS = `
  function tab(btn, name){
    document.querySelectorAll('.tabs button').forEach(function(b){ b.classList.remove('active'); });
    btn.classList.add('active');
    document.querySelectorAll('.tabbody [data-tab]').forEach(function(d){ d.hidden = d.dataset.tab !== name; });
  }
  function vId(){
    var k = localStorage.getItem('cue.viewer');
    if(!k){ k = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : ('v' + Math.random().toString(36).slice(2) + Date.now().toString(36)); localStorage.setItem('cue.viewer', k); }
    return k;
  }
  function lsGet(k){ try { return JSON.parse(localStorage.getItem(k) || '[]'); } catch(e){ return []; } }
  function lsSet(k, a){ try { localStorage.setItem(k, JSON.stringify(a)); } catch(e){} }
  function reactKey(){ return 'cue.react.' + VID; }
  function myCmtKey(){ return 'cue.cmt.' + VID; }

  function esc(s){ return (s==null?'':String(s)).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
  function pad(n){ return String(n).padStart(2,'0'); }
  function fmtT(s){ s = Math.max(0, Math.round(Number(s)||0)); return Math.floor(s/60) + ':' + pad(s%60); }
  function ago(iso){
    var t = Date.parse(iso); if(isNaN(t)) return '';
    var s = Math.max(1, Math.round((Date.now()-t)/1000));
    if(s<60) return s+'s ago';
    var m = Math.round(s/60); if(m<60) return m+'m ago';
    var h = Math.round(m/60); if(h<24) return h+'h ago';
    var d = Math.round(h/24); if(d<7) return d+'d ago';
    try { return new Date(t).toLocaleDateString(); } catch(e){ return ''; }
  }
  function vEl(){ return document.querySelector('video'); }
  function seekTo(t){ var p = vEl(); if(p){ p.currentTime = Number(t)||0; p.play().catch(function(){}); p.scrollIntoView({behavior:'smooth', block:'start'}); } }

  function applyCounts(counts){
    counts = counts || {};
    document.querySelectorAll('#reactions button').forEach(function(b){
      var n = Number(counts[b.dataset.emoji] || 0);
      b.querySelector('.rc').textContent = n>0 ? n : '';
    });
    var total = 0; Object.keys(counts).forEach(function(k){ total += Number(counts[k]||0); });
    var a = document.getElementById('aReact'); if(a) a.textContent = total;
  }
  function highlightMine(){
    var mine = lsGet(reactKey());
    document.querySelectorAll('#reactions button').forEach(function(b){
      b.classList.toggle('active', mine.indexOf(b.dataset.emoji) >= 0);
    });
  }
  function react(emoji){
    fetch('/api/public/videos/' + encodeURIComponent(VID) + '/reactions', {
      method:'POST', headers:{'content-type':'application/json'},
      body: JSON.stringify({ emoji: emoji, viewerId: vId() })
    }).then(function(r){ return r.ok ? r.json() : null; }).then(function(d){
      if(!d) return; applyCounts(d.counts); lsSet(reactKey(), d.mine || []); highlightMine();
    }).catch(function(){});
  }

  function canDelete(c){ return OWNER || lsGet(myCmtKey()).indexOf(c.id) >= 0; }
  function commentHTML(c){
    var initial = ((c.author||'A').trim().charAt(0) || 'A').toUpperCase();
    var tsPill = (c.tsSeconds!=null && c.tsSeconds!=='') ? '<button type="button" class="tspill" onclick="seekTo(' + Number(c.tsSeconds) + ')">' + fmtT(c.tsSeconds) + '</button>' : '';
    var del = '';
    if(canDelete(c)){
      if(OWNER){
        del = '<form class="cdel" method="post" action="/app/v/' + encodeURIComponent(VID) + '">' +
              '<input type="hidden" name="action" value="delete-comment"><input type="hidden" name="commentId" value="' + esc(c.id) + '">' +
              '<button class="linklike" type="submit">Delete</button></form>';
      } else {
        del = '<button type="button" class="linklike" onclick="delComment(\\'' + esc(c.id) + '\\')">Delete</button>';
      }
    }
    return '<div class="comment" data-id="' + esc(c.id) + '">' +
      '<div class="avatar">' + esc(initial) + '</div>' +
      '<div class="comment-main"><div class="comment-meta">' +
        '<span class="cauthor">' + esc(c.author||'Anonymous') + '</span>' + tsPill +
        '<span class="cwhen" title="' + esc(c.createdAt) + '">' + esc(ago(c.createdAt)) + '</span>' + del +
      '</div><div class="cbody">' + esc(c.body) + '</div></div></div>';
  }
  function renderComments(list){
    var box = document.getElementById('commentList'); if(!box) return;
    box.innerHTML = list.length ? list.map(commentHTML).join('') : '<div class="cempty">No comments yet — be the first.</div>';
    var cc = document.getElementById('cCount'); if(cc) cc.textContent = list.length;
    var ac = document.getElementById('aComments'); if(ac) ac.textContent = list.length;
  }
  function postComment(ev){
    ev.preventDefault();
    var body = document.getElementById('cBody').value;
    if(!body.trim()) return false;
    var name = document.getElementById('cName').value;
    var pin = document.getElementById('cPin');
    var ts = (pin && pin.checked && vEl()) ? vEl().currentTime : null;
    fetch('/api/public/videos/' + encodeURIComponent(VID) + '/comments', {
      method:'POST', headers:{'content-type':'application/json'},
      body: JSON.stringify({ author: name, body: body, viewerId: vId(), tsSeconds: ts })
    }).then(function(r){ return r.ok ? r.json() : r.json().then(function(e){ throw new Error(e.error||'failed'); }); })
      .then(function(d){
        COMMENTS.push(d.comment);
        var mk = lsGet(myCmtKey()); mk.push(d.comment.id); lsSet(myCmtKey(), mk);
        renderComments(COMMENTS);
        document.getElementById('cBody').value = '';
      }).catch(function(e){ alert('Could not post comment: ' + e.message); });
    return false;
  }
  function delComment(id){
    if(!confirm('Delete this comment?')) return;
    fetch('/api/public/videos/' + encodeURIComponent(VID) + '/comments/' + encodeURIComponent(id) + '?viewer=' + encodeURIComponent(vId()), { method:'DELETE' })
      .then(function(r){ if(!r.ok) throw new Error(); COMMENTS = COMMENTS.filter(function(c){ return c.id !== id; }); renderComments(COMMENTS); })
      .catch(function(){ alert('Could not delete comment.'); });
  }

  var COMMENTS = Array.isArray(__COMMENTS__) ? __COMMENTS__.slice() : [];
  document.addEventListener('DOMContentLoaded', function(){
    highlightMine();
    renderComments(COMMENTS);
    var p = vEl(), at = document.getElementById('cPinAt');
    if(p && at){ p.addEventListener('timeupdate', function(){ at.textContent = fmtT(p.currentTime); }); }
  });
`;

// Owner-only status + action bar shown above the video on /app/v/:id. The
// buttons are same-origin form POSTs to /app/v/:id (Origin-checked server side).
function renderOwnerBar(v) {
  const act = (action, label, danger = false, extra = "") =>
    `<form method="post" action="/app/v/${esc(v.id)}"${extra}>` +
    `<input type="hidden" name="action" value="${action}" />` +
    `<button class="btn${danger ? " danger" : ""}" type="submit">${label}</button></form>`;
  const status = v.disabled
    ? `<span class="badge off">Link disabled</span>`
    : `<span class="badge on">Link live</span>`;
  const aiBadges =
    (v.transcript ? `<span class="badge ai">📝 transcript</span>` : ``) +
    (v.summary ? `<span class="badge ai">✨ summary</span>` : ``);
  const toggle = v.disabled ? "enable" : "disable";
  const toggleLabel = v.disabled ? "Enable link" : "Disable link";
  return `
  <div class="card ownerbar">
    <div class="ob-status">${status}${aiBadges}</div>
    <div class="ob-actions">
      ${act(toggle, toggleLabel)}
      ${act("transcribe", v.transcript ? "Re-transcribe" : "Transcribe", false, ` onsubmit="this.querySelector('button').textContent='Transcribing…'"`)}
      ${act("summarize", v.summary ? "Re-summarize" : "Summarize", false, ` onsubmit="this.querySelector('button').textContent='Summarizing…'"`)}
      ${act("declutter", "Remove fillers", false, ` onsubmit="this.querySelector('button').textContent='Cleaning…'"`)}
      ${act("delete", "Delete", true, ` onsubmit="return confirm('Delete this recording everywhere (cloud copy + share link)? This cannot be undone.')"`)}
      <a class="btn" href="/v/${esc(v.id)}" target="_blank" rel="noopener">Open public page ↗</a>
    </div>
  </div>`;
}

// The video page. In owner mode (opts.owner) it adds the action bar, comment
// moderation, and a flash banner; otherwise it's the public share view. Both
// share the reactions bar and comments section.
export function renderPlayer(v, opts = {}) {
  const { owner = false, counts = {}, comments = [], flash = "", error = "" } = opts;
  const share = esc(v.shareURL);
  const media = esc(v.mediaURL);

  const timedTranscript = v.transcriptVtt ? renderTimedTranscript(v.transcriptVtt) : null;
  const transcriptBody = timedTranscript
    ? timedTranscript
    : (v.transcript
        ? `<div class="transcript">${esc(v.transcript)}</div>`
        : (owner
            ? `No transcript yet — use <b>Transcribe</b> above to generate one.`
            : `No transcript has been generated for this recording yet.`));
  const chapters = Array.isArray(v.chapters) ? v.chapters : [];
  const summaryText = String(v.summary || "").replace(/\n\nChapters:\s*\n[\s\S]*$/i, "").trim();
  const chapterBody = chapters.length
    ? `<div class="chapters"><div class="chapters-label">Chapters</div>${chapters.map((chapter) =>
        `<button type="button" class="chapter" onclick="seekTo(${Number(chapter.startSeconds) || 0})"><time>${esc(fmtDuration(chapter.startSeconds))}</time><span>${esc(chapter.title)}</span></button>`
      ).join("")}</div>`
    : "";
  const summaryBody = v.summary
    ? `<div class="transcript">${esc(summaryText)}</div>${chapterBody}`
    : (owner
        ? `No summary yet — use <b>Summarize</b> above to generate one.`
        : `No AI summary has been generated for this recording yet.`);

  const reactionButtons = REACTION_EMOJI.map((e) => {
    const n = Number(counts[e] || 0);
    return `<button type="button" data-emoji="${e}" onclick="react('${e}')"><span class="re">${e}</span><span class="rc">${n > 0 ? n : ""}</span></button>`;
  }).join("");
  const reactionTotal = Object.values(counts).reduce((a, b) => a + Number(b || 0), 0);
  const commentCount = comments.length;

  const banner = owner
    ? (error ? `<div class="banner err">${esc(error)}</div>`
            : (flash ? `<div class="banner ok">${esc(flash)}</div>` : ""))
    : "";
  const ownerBar = owner ? renderOwnerBar(v) : "";

  // Comments render client-side from this payload (one renderer, and it lets the
  // public Delete affordance depend on localStorage). Escape "<" so the JSON
  // can't terminate the <script> element.
  const commentsJSON = JSON.stringify(comments).replace(/</g, "\\u003c");

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(v.title)} · Cue</title>
<style>${BASE_CSS}${ENGAGE_CSS}${owner ? APP_CSS : ""}</style>
</head><body>
<div class="wrap">
  <div class="topbar">
    <div class="brand"><div class="logo"></div> Cue</div>
    ${owner ? `<a class="backlink" href="/app">← Library</a>` : ""}
    <div class="spacer"></div>
    <div class="linkpill">
      <code id="share">${share}</code>
      <button class="copy" onclick="navigator.clipboard.writeText('${share}');this.textContent='Copied'">Copy link</button>
    </div>
  </div>

  ${banner}
  ${ownerBar}

  <div class="layout">
    <div>
      <div class="card videoframe">
        <video controls autoplay playsinline preload="metadata" src="${media}"></video>
      </div>
      <div class="reactions" id="reactions">${reactionButtons}</div>

      <div class="card commentcard">
        <div class="comments-head">💬 Comments <span class="cnum" id="cCount">${commentCount}</span></div>
        <form class="comment-form" onsubmit="return postComment(event)">
          <input id="cName" class="cinput" placeholder="Your name (optional)" maxlength="60" autocomplete="name" />
          <textarea id="cBody" class="cinput" placeholder="Add a comment…" maxlength="2000" rows="2" required></textarea>
          <div class="cform-row">
            <label class="pin"><input type="checkbox" id="cPin" checked /> Pin to <b id="cPinAt">0:00</b></label>
            <button type="submit" class="btn primary">Comment</button>
          </div>
        </form>
        <div class="comment-list" id="commentList"></div>
      </div>
    </div>

    <div class="card">
      <div class="meta">
        ${owner
          ? `<form class="title-form" method="post" action="/app/v/${esc(v.id)}">
              <input type="hidden" name="action" value="rename" />
              <input class="title-input" name="title" value="${esc(v.title)}" maxlength="100" aria-label="Video title" required />
              <button class="btn" type="submit">Save</button>
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
        <div data-tab="summary">${summaryBody}</div>
        <div data-tab="transcript" hidden>${transcriptBody}</div>
        <div data-tab="activity" hidden>
          <div class="actline"><b id="aReact">${reactionTotal}</b> reaction${reactionTotal === 1 ? "" : "s"} · <b id="aComments">${commentCount}</b> comment${commentCount === 1 ? "" : "s"}</div>
        </div>
      </div>
    </div>
  </div>

  <footer>${owner ? "Your private library · only you can see these controls" : "Shared with Cue · self-hosted"}</footer>
</div>
<script>
  const VID = ${JSON.stringify(v.id)};
  const OWNER = ${owner ? "true" : "false"};
  const __COMMENTS__ = ${commentsJSON};
  ${PLAYER_JS}
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
  <meta name="description" content="Cue is an open-source native macOS screen recorder with instant, self-hosted sharing." />
  <title>Cue · Native screen recording for macOS</title><style>${BASE_CSS}${LANDING_CSS}</style></head><body>
  <div class="landing">
    <div class="topbar">
      <div class="brand"><div class="logo"></div> Cue</div><div class="spacer"></div>
      <a class="github-badge" href="https://github.com/maxig/cue" target="_blank" rel="noopener">⌘ Open source · GitHub ↗</a>
    </div>
    <main>
      <section class="hero">
        <div class="eyebrow">Native · private · yours</div>
        <h1>Record your Mac.<br />Share in a moment.</h1>
        <p>A lightweight, open-source Loom alternative that keeps recordings on your Mac and storage you control.</p>
        <div class="cta-row">
          <a class="download" href="/download">↓ Download Cue for macOS</a>
          <a class="source" href="https://github.com/maxig/cue" target="_blank" rel="noopener">View source</a>
        </div>
      </section>
      <section class="steps" aria-label="Install Cue">
        <article class="card step"><b>1</b><h2>Download the DMG</h2><p>The latest signed release downloads directly from GitHub.</p></article>
        <article class="card step"><b>2</b><h2>Move Cue to Applications</h2><p>Open the disk image, then drag Cue into the Applications folder.</p></article>
        <article class="card step"><b>3</b><h2>Grant capture access</h2><p>Launch Cue and allow Screen Recording. Camera and microphone are optional.</p></article>
      </section>
      <section class="card contribute">
        <div><h2>Help make Cue better</h2><p>Report a bug, suggest an idea, or send a pull request. Contributions are welcome.</p></div>
        <a class="source" href="https://github.com/maxig/cue#contributing" target="_blank" rel="noopener">Contribute on GitHub ↗</a>
      </section>
    </main>
    <footer>MIT licensed · built for macOS · recordings stay yours</footer>
  </div></body></html>`;
}

export function renderUploading(v) {
  const id = JSON.stringify(String(v.id)).replace(/</g, "\\u003c");
  return `<!doctype html>
  <html lang="en"><head>
  <meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="robots" content="noindex" />
  <title>Uploading ${esc(v.title)} · Cue</title><style>${BASE_CSS}${UPLOAD_CSS}</style></head><body>
  <div class="wrap">
    <div class="topbar"><a class="brand" href="/"><div class="logo"></div> Cue</a></div>
    <main class="card upload-card"><div class="spinner" aria-hidden="true"></div>
      <h1>Your recording is on its way</h1>
      <p id="uploadMessage">${esc(v.title)} is still uploading. This page will be ready automatically.</p>
      <p class="hint">You can leave this tab open.</p>
    </main>
  </div>
  <script>
    const id=${id};
    async function check(){
      try {
        const r=await fetch('/api/public/videos/'+encodeURIComponent(id)+'/status',{cache:'no-store'});
        if(!r.ok)return;
        const s=await r.json();
        if(s.disabled || s.status==='ready'){ location.reload(); return; }
        if(s.status==='failed'){
          document.querySelector('.spinner').style.display='none';
          document.getElementById('uploadMessage').textContent='The upload paused. The owner can resume it from the Cue app.';
          return;
        }
      } catch(e) {}
      setTimeout(check,2000);
    }
    setTimeout(check,1200);
  </script></body></html>`;
}

export function renderUploadFailed(v) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" /><meta name="robots" content="noindex" />
  <title>Upload paused · Cue</title><style>${BASE_CSS}${UPLOAD_CSS}</style></head><body><div class="wrap">
  <div class="topbar"><a class="brand" href="/"><div class="logo"></div> Cue</a></div>
  <main class="card upload-card"><h1>Upload paused</h1><p>${esc(v.title)} is safe on the owner's Mac. They can resume this upload from Cue.</p></main>
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
  .badge.wait { color: #ffbf5b; background: rgba(255,191,91,0.14); }
  .badge.fail { color: #ff8a8a; background: rgba(255,90,90,0.14); }
  .actions { display: flex; gap: 8px; align-items: center; }
  .actions form { margin: 0; }
  .btn { cursor: pointer; border: 1px solid var(--panel-border); background: rgba(255,255,255,0.06);
         color: var(--text); font-weight: 600; font-size: 12px; border-radius: 10px; padding: 7px 12px; }
  .btn:hover { background: rgba(255,255,255,0.12); }
  .btn.danger { color: #ff8a8a; border-color: rgba(255,90,90,0.35); }
  .btn.danger:hover { background: rgba(255,90,90,0.14); }
  .count { color: var(--muted); font-size: 13px; }
  .row .t a { color: var(--text); text-decoration: none; }
  .row .t a:hover { color: var(--accent); }
  .actions { flex-wrap: wrap; }
  .badge.ai { color: var(--accent); background: rgba(10,132,255,0.14); }
  .aiout { padding: 0 14px 14px; }
  .aiout b { display: block; font-size: 12px; color: var(--muted); margin-bottom: 4px; }
  .aitext { white-space: pre-wrap; line-height: 1.55; font-size: 13.5px; max-height: 260px; overflow: auto; }
  .banner { padding: 10px 14px; border-radius: 12px; margin-bottom: 14px; font-size: 13px; font-weight: 600; }
  .banner.ok { background: rgba(46,194,107,0.16); color: #2ec26b; }
  .banner.err { background: rgba(255,90,90,0.14); color: #ff8a8a; }
  .searchbar { display: flex; align-items: center; gap: 8px; flex: 1; max-width: 520px; margin: 0 8px; }
  .searchbar input { flex: 1; background: rgba(255,255,255,0.05); border: 1px solid var(--panel-border); color: var(--text);
                     border-radius: 10px; padding: 7px 12px; font: inherit; }
  .searchbar input::placeholder { color: var(--muted); }
  .searchbar input:focus { outline: none; border-color: rgba(10,132,255,0.6); }
  .snippet { margin-top: 6px; font-size: 12.5px; color: var(--muted); line-height: 1.5; }
  .snippet mark { background: rgba(10,132,255,0.30); color: var(--text); border-radius: 3px; padding: 0 2px; }
`;

// Wrap occurrences of the query in <mark>, escaping everything else (raw text
// in → safe HTML out). ASCII case-insensitive, which matches the SQL LIKE scan.
function highlightSnippet(text, q) {
  if (!q) return esc(text);
  const lower = String(text).toLowerCase();
  const ql = q.toLowerCase();
  let out = "", i = 0, idx = lower.indexOf(ql);
  while (idx !== -1) {
    out += esc(text.slice(i, idx)) + "<mark>" + esc(text.slice(idx, idx + q.length)) + "</mark>";
    i = idx + q.length;
    idx = lower.indexOf(ql, i);
  }
  return out + esc(text.slice(i));
}

// Private owner dashboard at /app — lists every recording with Enable/Disable
// and Delete controls. Reachable only behind Cloudflare Access (or the bearer
// token); the Worker fails closed otherwise.
export function renderApp(videos, { base = "", flash = "", error = "", q = "" } = {}) {
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
    const status = v.uploadStatus === "uploading"
      ? `<span class="badge wait">Uploading</span>`
      : (v.uploadStatus === "failed"
          ? `<span class="badge fail">Upload paused</span>`
          : (v.disabled
              ? `<span class="badge off">Disabled</span>`
              : `<span class="badge on">Live</span>`));
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
          <div class="t"><a href="/app/v/${esc(v.id)}">${esc(v.title)}</a></div>
          <div class="submeta">
            <span>📅 ${esc(fmtDate(v.createdAt))}</span>
            <span>⏱ ${esc(fmtDuration(v.durationSeconds))}</span>
            <span>🖥 ${esc(v.captureMode || "")}</span>
            ${status}${aiBadges}
          </div>
          <div class="sharerow"><a href="/v/${esc(v.id)}" target="_blank" rel="noopener">${share}</a></div>
          ${v.snippet ? `<div class="snippet">${highlightSnippet(v.snippet, q)}</div>` : ``}
        </div>
        <div class="actions">
          <a class="btn" href="/app/v/${esc(v.id)}">Manage</a>
          ${act(v.id, toggle, toggleLabel)}
          ${act(v.id, "transcribe", v.transcript ? "Re-transcribe" : "Transcribe", ` onsubmit="this.querySelector('button').textContent='Transcribing…'"`)}
          ${act(v.id, "summarize", v.summary ? "Re-summarize" : "Summarize", ` onsubmit="this.querySelector('button').textContent='Summarizing…'"`)}
          ${act(v.id, "declutter", "Remove fillers", ` onsubmit="this.querySelector('button').textContent='Cleaning…'"`)}
          ${act(v.id, "delete", "Delete", ` onsubmit="return confirm('Delete this recording everywhere (cloud copy + share link)? This cannot be undone.')"`)}
        </div>
      </div>
      ${summaryBlock}
    </div>`;
  }).join("");

  const body = videos.length
    ? `<div class="list">${rows}</div>`
    : (q
        ? `<div class="empty">No recordings match “${esc(q)}”.</div>`
        : `<div class="empty">No recordings yet. Record something in the Cue app and click <b>Upload to Cloud</b>.</div>`);

  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Library · Cue</title><style>${BASE_CSS}${APP_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar">
    <div class="brand"><div class="logo"></div> Cue</div>
    <form class="searchbar" method="get" action="/app">
      <input type="search" name="q" value="${esc(q)}" placeholder="Search titles & transcripts…" autocomplete="off" />
      <button class="btn" type="submit">Search</button>
      ${q ? `<a class="btn" href="/app">Clear</a>` : ``}
    </form>
    <div class="spacer"></div>
    <div class="count">${q ? `${videos.length} result${videos.length === 1 ? "" : "s"}` : `${videos.length} recording${videos.length === 1 ? "" : "s"}`}</div>
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
