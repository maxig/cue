// src/views.js
function esc(s = "") {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function fmtDuration(seconds = 0) {
  const total = Math.round(seconds);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}
function fmtDate(iso) {
  try {
    return new Date(iso).toLocaleString(void 0, {
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit"
    });
  } catch {
    return iso || "";
  }
}
function vttTimeToSeconds(s) {
  let m = s.match(/(\d{1,3}):(\d{1,2}):(\d{1,2})[.,](\d{1,3})/);
  if (m) return +m[1] * 3600 + +m[2] * 60 + +m[3] + +m[4].padEnd(3, "0") / 1e3;
  m = s.match(/(\d{1,3}):(\d{1,2})[.,](\d{1,3})/);
  if (m) return +m[1] * 60 + +m[2] + +m[3].padEnd(3, "0") / 1e3;
  return null;
}
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
function groupTranscript(segments) {
  const lines = [];
  let cur = null;
  const MIN = 45, HARD = 230, MAX_SECONDS = 14;
  for (const seg of segments) {
    if (!cur) cur = { start: seg.start, text: seg.text };
    else cur.text += ` ${seg.text}`;
    const endsSentence = /[.!?…]["')\]]?$/.test(cur.text);
    const tooLong = cur.text.length >= HARD;
    const spanned = seg.start - cur.start >= MAX_SECONDS && cur.text.length >= MIN;
    if (endsSentence && cur.text.length >= MIN || tooLong || spanned) {
      lines.push(cur);
      cur = null;
    }
  }
  if (cur && cur.text) lines.push(cur);
  return lines;
}
function renderTimedTranscript(vtt) {
  const lines = groupTranscript(parseVTT(vtt));
  if (!lines.length) return null;
  return `<div class="ts-transcript">` + lines.map(
    (l) => `<div class="tline"><button type="button" class="tspill" onclick="seekTo(${l.start.toFixed(2)})">${esc(fmtDuration(l.start))}</button><div class="ttext">${esc(l.text)}</div></div>`
  ).join("") + `</div>`;
}
var BASE_CSS = `
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
var LANDING_CSS = `
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
var UPLOAD_CSS = `
  .upload-card { max-width: 580px; margin: 80px auto; padding: 44px 30px; text-align: center; }
  .spinner { width: 42px; height: 42px; margin: 0 auto 22px; border-radius: 50%;
             border: 3px solid rgba(255,255,255,.12); border-top-color: var(--accent);
             animation: spin .9s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .upload-card h1 { margin: 0 0 10px; font-size: 25px; }
  .upload-card p { color: var(--muted); margin: 0; }
  .upload-card .hint { margin-top: 18px; font-size: 12px; }
`;
var REACTION_EMOJI = ["\u{1F44D}", "\u{1F389}", "\u{1F602}", "\u2764\uFE0F", "\u{1F440}", "\u{1F525}"];
var ENGAGE_CSS = `
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
var PLAYER_JS = `
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
    box.innerHTML = list.length ? list.map(commentHTML).join('') : '<div class="cempty">No comments yet \u2014 be the first.</div>';
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
function renderOwnerBar(v) {
  const act = (action, label, danger = false, extra = "") => `<form method="post" action="/app/v/${esc(v.id)}"${extra}><input type="hidden" name="action" value="${action}" /><button class="btn${danger ? " danger" : ""}" type="submit">${label}</button></form>`;
  const status = v.disabled ? `<span class="badge off">Link disabled</span>` : `<span class="badge on">Link live</span>`;
  const aiBadges = (v.transcript ? `<span class="badge ai">\u{1F4DD} transcript</span>` : ``) + (v.summary ? `<span class="badge ai">\u2728 summary</span>` : ``);
  const toggle = v.disabled ? "enable" : "disable";
  const toggleLabel = v.disabled ? "Enable link" : "Disable link";
  return `
  <div class="card ownerbar">
    <div class="ob-status">${status}${aiBadges}</div>
    <div class="ob-actions">
      ${act(toggle, toggleLabel)}
      ${act("transcribe", v.transcript ? "Re-transcribe" : "Transcribe", false, ` onsubmit="this.querySelector('button').textContent='Transcribing\u2026'"`)}
      ${act("summarize", v.summary ? "Re-summarize" : "Summarize", false, ` onsubmit="this.querySelector('button').textContent='Summarizing\u2026'"`)}
      ${act("declutter", "Remove fillers", false, ` onsubmit="this.querySelector('button').textContent='Cleaning\u2026'"`)}
      ${act("delete", "Delete", true, ` onsubmit="return confirm('Delete this recording everywhere (cloud copy + share link)? This cannot be undone.')"`)}
      <a class="btn" href="/v/${esc(v.id)}" target="_blank" rel="noopener">Open public page \u2197</a>
    </div>
  </div>`;
}
function renderPlayer(v, opts = {}) {
  const { owner = false, counts = {}, comments = [], flash = "", error = "" } = opts;
  const share = esc(v.shareURL);
  const media = esc(v.mediaURL);
  const timedTranscript = v.transcriptVtt ? renderTimedTranscript(v.transcriptVtt) : null;
  const transcriptBody = timedTranscript ? timedTranscript : v.transcript ? `<div class="transcript">${esc(v.transcript)}</div>` : owner ? `No transcript yet \u2014 use <b>Transcribe</b> above to generate one.` : `No transcript has been generated for this recording yet.`;
  const chapters = Array.isArray(v.chapters) ? v.chapters : [];
  const summaryText = String(v.summary || "").replace(/\n\nChapters:\s*\n[\s\S]*$/i, "").trim();
  const chapterBody = chapters.length ? `<div class="chapters"><div class="chapters-label">Chapters</div>${chapters.map(
    (chapter) => `<button type="button" class="chapter" onclick="seekTo(${Number(chapter.startSeconds) || 0})"><time>${esc(fmtDuration(chapter.startSeconds))}</time><span>${esc(chapter.title)}</span></button>`
  ).join("")}</div>` : "";
  const summaryBody = v.summary ? `<div class="transcript">${esc(summaryText)}</div>${chapterBody}` : owner ? `No summary yet \u2014 use <b>Summarize</b> above to generate one.` : `No AI summary has been generated for this recording yet.`;
  const reactionButtons = REACTION_EMOJI.map((e) => {
    const n = Number(counts[e] || 0);
    return `<button type="button" data-emoji="${e}" onclick="react('${e}')"><span class="re">${e}</span><span class="rc">${n > 0 ? n : ""}</span></button>`;
  }).join("");
  const reactionTotal = Object.values(counts).reduce((a, b) => a + Number(b || 0), 0);
  const commentCount = comments.length;
  const banner = owner ? error ? `<div class="banner err">${esc(error)}</div>` : flash ? `<div class="banner ok">${esc(flash)}</div>` : "" : "";
  const ownerBar = owner ? renderOwnerBar(v) : "";
  const commentsJSON = JSON.stringify(comments).replace(/</g, "\\u003c");
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${esc(v.title)} \xB7 Cue</title>
<style>${BASE_CSS}${ENGAGE_CSS}${owner ? APP_CSS : ""}</style>
</head><body>
<div class="wrap">
  <div class="topbar">
    <div class="brand"><div class="logo"></div> Cue</div>
    ${owner ? `<a class="backlink" href="/app">\u2190 Library</a>` : ""}
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
        <div class="comments-head">\u{1F4AC} Comments <span class="cnum" id="cCount">${commentCount}</span></div>
        <form class="comment-form" onsubmit="return postComment(event)">
          <input id="cName" class="cinput" placeholder="Your name (optional)" maxlength="60" autocomplete="name" />
          <textarea id="cBody" class="cinput" placeholder="Add a comment\u2026" maxlength="2000" rows="2" required></textarea>
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
        ${owner ? `<form class="title-form" method="post" action="/app/v/${esc(v.id)}">
              <input type="hidden" name="action" value="rename" />
              <input class="title-input" name="title" value="${esc(v.title)}" maxlength="100" aria-label="Video title" required />
              <button class="btn" type="submit">Save</button>
            </form>` : `<h1 class="title">${esc(v.title)}</h1>`}
        <div class="submeta">
          <span>\u{1F4C5} ${esc(fmtDate(v.createdAt))}</span>
          <span>\u23F1 ${esc(fmtDuration(v.durationSeconds))}</span>
          <span>\u{1F5A5} ${esc(v.captureMode)}</span>
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
          <div class="actline"><b id="aReact">${reactionTotal}</b> reaction${reactionTotal === 1 ? "" : "s"} \xB7 <b id="aComments">${commentCount}</b> comment${commentCount === 1 ? "" : "s"}</div>
        </div>
      </div>
    </div>
  </div>

  <footer>${owner ? "Your private library \xB7 only you can see these controls" : "Shared with Cue \xB7 self-hosted"}</footer>
</div>
<script>
  const VID = ${JSON.stringify(v.id)};
  const OWNER = ${owner ? "true" : "false"};
  const __COMMENTS__ = ${commentsJSON};
  ${PLAYER_JS}
<\/script>
</body></html>`;
}
function renderDisabled() {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Link disabled \xB7 Cue</title><style>${BASE_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar"><div class="brand"><div class="logo"></div> Cue</div></div>
  <div class="empty">This share link has been disabled by its owner.</div>
  <footer>Cue \xB7 self-hosted</footer>
</div></body></html>`;
}
function renderLanding() {
  return `<!doctype html>
  <html lang="en"><head>
  <meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="description" content="Cue is an open-source native macOS screen recorder with instant, self-hosted sharing." />
  <title>Cue \xB7 Native screen recording for macOS</title><style>${BASE_CSS}${LANDING_CSS}</style></head><body>
  <div class="landing">
    <div class="topbar">
      <div class="brand"><div class="logo"></div> Cue</div><div class="spacer"></div>
      <a class="github-badge" href="https://github.com/maxig/cue" target="_blank" rel="noopener">\u2318 Open source \xB7 GitHub \u2197</a>
    </div>
    <main>
      <section class="hero">
        <div class="eyebrow">Native \xB7 private \xB7 yours</div>
        <h1>Record your Mac.<br />Share in a moment.</h1>
        <p>A lightweight, open-source Loom alternative that keeps recordings on your Mac and storage you control.</p>
        <div class="cta-row">
          <a class="download" href="/download">\u2193 Download Cue for macOS</a>
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
        <a class="source" href="https://github.com/maxig/cue#contributing" target="_blank" rel="noopener">Contribute on GitHub \u2197</a>
      </section>
    </main>
    <footer>MIT licensed \xB7 built for macOS \xB7 recordings stay yours</footer>
  </div></body></html>`;
}
function renderUploading(v) {
  const id = JSON.stringify(String(v.id)).replace(/</g, "\\u003c");
  return `<!doctype html>
  <html lang="en"><head>
  <meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="robots" content="noindex" />
  <title>Uploading ${esc(v.title)} \xB7 Cue</title><style>${BASE_CSS}${UPLOAD_CSS}</style></head><body>
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
  <\/script></body></html>`;
}
function renderUploadFailed(v) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" /><meta name="robots" content="noindex" />
  <title>Upload paused \xB7 Cue</title><style>${BASE_CSS}${UPLOAD_CSS}</style></head><body><div class="wrap">
  <div class="topbar"><a class="brand" href="/"><div class="logo"></div> Cue</a></div>
  <main class="card upload-card"><h1>Upload paused</h1><p>${esc(v.title)} is safe on the owner's Mac. They can resume this upload from Cue.</p></main>
  </div></body></html>`;
}
function renderIndex(videos, { notFound } = {}) {
  const rows = videos.map((v) => `
    <a class="card row" href="/v/${esc(v.id)}">
      <div>
        <div class="t">${esc(v.title)}</div>
        <div class="submeta"><span>${esc(fmtDate(v.createdAt))}</span> <span>${esc(fmtDuration(v.durationSeconds))}</span></div>
      </div>
    </a>`).join("");
  const body = notFound ? `<div class="empty">No video found for <code>${esc(notFound)}</code>.</div>` : videos.length ? `<div class="list">${rows}</div>` : `<div class="empty">No recordings shared yet.</div>`;
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Cue</title><style>${BASE_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar"><div class="brand"><div class="logo"></div> Cue</div></div>
  ${body}
  <footer>Cue \xB7 self-hosted</footer>
</div></body></html>`;
}
var APP_CSS = `
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
function renderApp(videos, { base = "", flash = "", error = "", q = "" } = {}) {
  const banner = error ? `<div class="banner err">${esc(error)}</div>` : flash ? `<div class="banner ok">${esc(flash)}</div>` : "";
  const act = (id, action, label, extra = "") => `<form method="post" action="/app"${extra}><input type="hidden" name="id" value="${esc(id)}" /><input type="hidden" name="action" value="${action}" /><button class="btn${action === "delete" ? " danger" : ""}" type="submit">${label}</button></form>`;
  const rows = videos.map((v) => {
    const share = esc(v.shareURL || `${base}/v/${v.id}`);
    const status = v.uploadStatus === "uploading" ? `<span class="badge wait">Uploading</span>` : v.uploadStatus === "failed" ? `<span class="badge fail">Upload paused</span>` : v.disabled ? `<span class="badge off">Disabled</span>` : `<span class="badge on">Live</span>`;
    const toggle = v.disabled ? "enable" : "disable";
    const toggleLabel = v.disabled ? "Enable link" : "Disable link";
    const aiBadges = (v.transcript ? `<span class="badge ai">\u{1F4DD} transcript</span>` : ``) + (v.summary ? `<span class="badge ai">\u2728 summary</span>` : ``);
    const summaryBlock = v.summary ? `<div class="aiout"><b>AI summary</b><div class="aitext">${esc(v.summary)}</div></div>` : ``;
    return `
    <div class="card">
      <div class="row approw">
        <div class="grow">
          <div class="t"><a href="/app/v/${esc(v.id)}">${esc(v.title)}</a></div>
          <div class="submeta">
            <span>\u{1F4C5} ${esc(fmtDate(v.createdAt))}</span>
            <span>\u23F1 ${esc(fmtDuration(v.durationSeconds))}</span>
            <span>\u{1F5A5} ${esc(v.captureMode || "")}</span>
            ${status}${aiBadges}
          </div>
          <div class="sharerow"><a href="/v/${esc(v.id)}" target="_blank" rel="noopener">${share}</a></div>
          ${v.snippet ? `<div class="snippet">${highlightSnippet(v.snippet, q)}</div>` : ``}
        </div>
        <div class="actions">
          <a class="btn" href="/app/v/${esc(v.id)}">Manage</a>
          ${act(v.id, toggle, toggleLabel)}
          ${act(v.id, "transcribe", v.transcript ? "Re-transcribe" : "Transcribe", ` onsubmit="this.querySelector('button').textContent='Transcribing\u2026'"`)}
          ${act(v.id, "summarize", v.summary ? "Re-summarize" : "Summarize", ` onsubmit="this.querySelector('button').textContent='Summarizing\u2026'"`)}
          ${act(v.id, "declutter", "Remove fillers", ` onsubmit="this.querySelector('button').textContent='Cleaning\u2026'"`)}
          ${act(v.id, "delete", "Delete", ` onsubmit="return confirm('Delete this recording everywhere (cloud copy + share link)? This cannot be undone.')"`)}
        </div>
      </div>
      ${summaryBlock}
    </div>`;
  }).join("");
  const body = videos.length ? `<div class="list">${rows}</div>` : q ? `<div class="empty">No recordings match \u201C${esc(q)}\u201D.</div>` : `<div class="empty">No recordings yet. Record something in the Cue app and click <b>Upload to Cloud</b>.</div>`;
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Library \xB7 Cue</title><style>${BASE_CSS}${APP_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar">
    <div class="brand"><div class="logo"></div> Cue</div>
    <form class="searchbar" method="get" action="/app">
      <input type="search" name="q" value="${esc(q)}" placeholder="Search titles & transcripts\u2026" autocomplete="off" />
      <button class="btn" type="submit">Search</button>
      ${q ? `<a class="btn" href="/app">Clear</a>` : ``}
    </form>
    <div class="spacer"></div>
    <div class="count">${q ? `${videos.length} result${videos.length === 1 ? "" : "s"}` : `${videos.length} recording${videos.length === 1 ? "" : "s"}`}</div>
  </div>
  ${banner}
  ${body}
  <footer>Your private library \xB7 only you can see this page</footer>
</div></body></html>`;
}
function renderAppLocked(reason) {
  const msg = reason || "This dashboard is private. Sign in through Cloudflare Access to view your library.";
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Sign in \xB7 Cue</title><style>${BASE_CSS}</style></head><body>
<div class="wrap">
  <div class="topbar"><div class="brand"><div class="logo"></div> Cue</div></div>
  <div class="empty">\u{1F512} ${esc(msg)}</div>
  <footer>Cue \xB7 self-hosted</footer>
</div></body></html>`;
}

// node_modules/aws4fetch/dist/aws4fetch.esm.mjs
var encoder = new TextEncoder();
var HOST_SERVICES = {
  appstream2: "appstream",
  cloudhsmv2: "cloudhsm",
  email: "ses",
  marketplace: "aws-marketplace",
  mobile: "AWSMobileHubService",
  pinpoint: "mobiletargeting",
  queue: "sqs",
  "git-codecommit": "codecommit",
  "mturk-requester-sandbox": "mturk-requester",
  "personalize-runtime": "personalize"
};
var UNSIGNABLE_HEADERS = /* @__PURE__ */ new Set([
  "authorization",
  "content-type",
  "content-length",
  "user-agent",
  "presigned-expires",
  "expect",
  "x-amzn-trace-id",
  "range",
  "connection"
]);
var AwsClient = class {
  constructor({ accessKeyId, secretAccessKey, sessionToken, service, region, cache, retries, initRetryMs }) {
    if (accessKeyId == null) throw new TypeError("accessKeyId is a required option");
    if (secretAccessKey == null) throw new TypeError("secretAccessKey is a required option");
    this.accessKeyId = accessKeyId;
    this.secretAccessKey = secretAccessKey;
    this.sessionToken = sessionToken;
    this.service = service;
    this.region = region;
    this.cache = cache || /* @__PURE__ */ new Map();
    this.retries = retries != null ? retries : 10;
    this.initRetryMs = initRetryMs || 50;
  }
  async sign(input, init) {
    if (input instanceof Request) {
      const { method, url, headers, body } = input;
      init = Object.assign({ method, url, headers }, init);
      if (init.body == null && headers.has("Content-Type")) {
        init.body = body != null && headers.has("X-Amz-Content-Sha256") ? body : await input.clone().arrayBuffer();
      }
      input = url;
    }
    const signer = new AwsV4Signer(Object.assign({ url: input.toString() }, init, this, init && init.aws));
    const signed = Object.assign({}, init, await signer.sign());
    delete signed.aws;
    try {
      return new Request(signed.url.toString(), signed);
    } catch (e) {
      if (e instanceof TypeError) {
        return new Request(signed.url.toString(), Object.assign({ duplex: "half" }, signed));
      }
      throw e;
    }
  }
  async fetch(input, init) {
    for (let i = 0; i <= this.retries; i++) {
      const fetched = fetch(await this.sign(input, init));
      if (i === this.retries) {
        return fetched;
      }
      const res = await fetched;
      if (res.status < 500 && res.status !== 429) {
        return res;
      }
      await new Promise((resolve) => setTimeout(resolve, Math.random() * this.initRetryMs * Math.pow(2, i)));
    }
    throw new Error("An unknown error occurred, ensure retries is not negative");
  }
};
var AwsV4Signer = class {
  constructor({ method, url, headers, body, accessKeyId, secretAccessKey, sessionToken, service, region, cache, datetime, signQuery, appendSessionToken, allHeaders, singleEncode }) {
    if (url == null) throw new TypeError("url is a required option");
    if (accessKeyId == null) throw new TypeError("accessKeyId is a required option");
    if (secretAccessKey == null) throw new TypeError("secretAccessKey is a required option");
    this.method = method || (body ? "POST" : "GET");
    this.url = new URL(url);
    this.headers = new Headers(headers || {});
    this.body = body;
    this.accessKeyId = accessKeyId;
    this.secretAccessKey = secretAccessKey;
    this.sessionToken = sessionToken;
    let guessedService, guessedRegion;
    if (!service || !region) {
      [guessedService, guessedRegion] = guessServiceRegion(this.url, this.headers);
    }
    this.service = service || guessedService || "";
    this.region = region || guessedRegion || "us-east-1";
    this.cache = cache || /* @__PURE__ */ new Map();
    this.datetime = datetime || (/* @__PURE__ */ new Date()).toISOString().replace(/[:-]|\.\d{3}/g, "");
    this.signQuery = signQuery;
    this.appendSessionToken = appendSessionToken || this.service === "iotdevicegateway";
    this.headers.delete("Host");
    if (this.service === "s3" && !this.signQuery && !this.headers.has("X-Amz-Content-Sha256")) {
      this.headers.set("X-Amz-Content-Sha256", "UNSIGNED-PAYLOAD");
    }
    const params = this.signQuery ? this.url.searchParams : this.headers;
    params.set("X-Amz-Date", this.datetime);
    if (this.sessionToken && !this.appendSessionToken) {
      params.set("X-Amz-Security-Token", this.sessionToken);
    }
    this.signableHeaders = ["host", ...this.headers.keys()].filter((header) => allHeaders || !UNSIGNABLE_HEADERS.has(header)).sort();
    this.signedHeaders = this.signableHeaders.join(";");
    this.canonicalHeaders = this.signableHeaders.map((header) => header + ":" + (header === "host" ? this.url.host : (this.headers.get(header) || "").replace(/\s+/g, " "))).join("\n");
    this.credentialString = [this.datetime.slice(0, 8), this.region, this.service, "aws4_request"].join("/");
    if (this.signQuery) {
      if (this.service === "s3" && !params.has("X-Amz-Expires")) {
        params.set("X-Amz-Expires", "86400");
      }
      params.set("X-Amz-Algorithm", "AWS4-HMAC-SHA256");
      params.set("X-Amz-Credential", this.accessKeyId + "/" + this.credentialString);
      params.set("X-Amz-SignedHeaders", this.signedHeaders);
    }
    if (this.service === "s3") {
      try {
        this.encodedPath = decodeURIComponent(this.url.pathname.replace(/\+/g, " "));
      } catch (e) {
        this.encodedPath = this.url.pathname;
      }
    } else {
      this.encodedPath = this.url.pathname.replace(/\/+/g, "/");
    }
    if (!singleEncode) {
      this.encodedPath = encodeURIComponent(this.encodedPath).replace(/%2F/g, "/");
    }
    this.encodedPath = encodeRfc3986(this.encodedPath);
    const seenKeys = /* @__PURE__ */ new Set();
    this.encodedSearch = [...this.url.searchParams].filter(([k]) => {
      if (!k) return false;
      if (this.service === "s3") {
        if (seenKeys.has(k)) return false;
        seenKeys.add(k);
      }
      return true;
    }).map((pair) => pair.map((p) => encodeRfc3986(encodeURIComponent(p)))).sort(([k1, v1], [k2, v2]) => k1 < k2 ? -1 : k1 > k2 ? 1 : v1 < v2 ? -1 : v1 > v2 ? 1 : 0).map((pair) => pair.join("=")).join("&");
  }
  async sign() {
    if (this.signQuery) {
      this.url.searchParams.set("X-Amz-Signature", await this.signature());
      if (this.sessionToken && this.appendSessionToken) {
        this.url.searchParams.set("X-Amz-Security-Token", this.sessionToken);
      }
    } else {
      this.headers.set("Authorization", await this.authHeader());
    }
    return {
      method: this.method,
      url: this.url,
      headers: this.headers,
      body: this.body
    };
  }
  async authHeader() {
    return [
      "AWS4-HMAC-SHA256 Credential=" + this.accessKeyId + "/" + this.credentialString,
      "SignedHeaders=" + this.signedHeaders,
      "Signature=" + await this.signature()
    ].join(", ");
  }
  async signature() {
    const date = this.datetime.slice(0, 8);
    const cacheKey = [this.secretAccessKey, date, this.region, this.service].join();
    let kCredentials = this.cache.get(cacheKey);
    if (!kCredentials) {
      const kDate = await hmac("AWS4" + this.secretAccessKey, date);
      const kRegion = await hmac(kDate, this.region);
      const kService = await hmac(kRegion, this.service);
      kCredentials = await hmac(kService, "aws4_request");
      this.cache.set(cacheKey, kCredentials);
    }
    return buf2hex(await hmac(kCredentials, await this.stringToSign()));
  }
  async stringToSign() {
    return [
      "AWS4-HMAC-SHA256",
      this.datetime,
      this.credentialString,
      buf2hex(await hash(await this.canonicalString()))
    ].join("\n");
  }
  async canonicalString() {
    return [
      this.method.toUpperCase(),
      this.encodedPath,
      this.encodedSearch,
      this.canonicalHeaders + "\n",
      this.signedHeaders,
      await this.hexBodyHash()
    ].join("\n");
  }
  async hexBodyHash() {
    let hashHeader = this.headers.get("X-Amz-Content-Sha256") || (this.service === "s3" && this.signQuery ? "UNSIGNED-PAYLOAD" : null);
    if (hashHeader == null) {
      if (this.body && typeof this.body !== "string" && !("byteLength" in this.body)) {
        throw new Error("body must be a string, ArrayBuffer or ArrayBufferView, unless you include the X-Amz-Content-Sha256 header");
      }
      hashHeader = buf2hex(await hash(this.body || ""));
    }
    return hashHeader;
  }
};
async function hmac(key, string) {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    typeof key === "string" ? encoder.encode(key) : key,
    { name: "HMAC", hash: { name: "SHA-256" } },
    false,
    ["sign"]
  );
  return crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(string));
}
async function hash(content) {
  return crypto.subtle.digest("SHA-256", typeof content === "string" ? encoder.encode(content) : content);
}
var HEX_CHARS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
function buf2hex(arrayBuffer) {
  const buffer = new Uint8Array(arrayBuffer);
  let out = "";
  for (let idx = 0; idx < buffer.length; idx++) {
    const n = buffer[idx];
    out += HEX_CHARS[n >>> 4 & 15];
    out += HEX_CHARS[n & 15];
  }
  return out;
}
function encodeRfc3986(urlEncodedStr) {
  return urlEncodedStr.replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}
function guessServiceRegion(url, headers) {
  const { hostname, pathname } = url;
  if (hostname.endsWith(".on.aws")) {
    const match2 = hostname.match(/^[^.]{1,63}\.lambda-url\.([^.]{1,63})\.on\.aws$/);
    return match2 != null ? ["lambda", match2[1] || ""] : ["", ""];
  }
  if (hostname.endsWith(".r2.cloudflarestorage.com")) {
    return ["s3", "auto"];
  }
  if (hostname.endsWith(".backblazeb2.com")) {
    const match2 = hostname.match(/^(?:[^.]{1,63}\.)?s3\.([^.]{1,63})\.backblazeb2\.com$/);
    return match2 != null ? ["s3", match2[1] || ""] : ["", ""];
  }
  const match = hostname.replace("dualstack.", "").match(/([^.]{1,63})\.(?:([^.]{0,63})\.)?amazonaws\.com(?:\.cn)?$/);
  let service = match && match[1] || "";
  let region = match && match[2];
  if (region === "us-gov") {
    region = "us-gov-west-1";
  } else if (region === "s3" || region === "s3-accelerate") {
    region = "us-east-1";
    service = "s3";
  } else if (service === "iot") {
    if (hostname.startsWith("iot.")) {
      service = "execute-api";
    } else if (hostname.startsWith("data.jobs.iot.")) {
      service = "iot-jobs-data";
    } else {
      service = pathname === "/mqtt" ? "iotdevicegateway" : "iotdata";
    }
  } else if (service === "autoscaling") {
    const targetPrefix = (headers.get("X-Amz-Target") || "").split(".")[0];
    if (targetPrefix === "AnyScaleFrontendService") {
      service = "application-autoscaling";
    } else if (targetPrefix === "AnyScaleScalingPlannerFrontendService") {
      service = "autoscaling-plans";
    }
  } else if (region == null && service.startsWith("s3-")) {
    region = service.slice(3).replace(/^fips-|^external-1/, "");
    service = "s3";
  } else if (service.endsWith("-fips")) {
    service = service.slice(0, -5);
  } else if (region && /-\d$/.test(service) && !/-\d$/.test(region)) {
    [service, region] = [region, service];
  }
  return [HOST_SERVICES[service] || service, region || ""];
}

// node_modules/jose/dist/browser/runtime/webcrypto.js
var webcrypto_default = crypto;
var isCryptoKey = (key) => key instanceof CryptoKey;

// node_modules/jose/dist/browser/lib/buffer_utils.js
var encoder2 = new TextEncoder();
var decoder = new TextDecoder();
var MAX_INT32 = 2 ** 32;
function concat(...buffers) {
  const size = buffers.reduce((acc, { length }) => acc + length, 0);
  const buf = new Uint8Array(size);
  let i = 0;
  for (const buffer of buffers) {
    buf.set(buffer, i);
    i += buffer.length;
  }
  return buf;
}

// node_modules/jose/dist/browser/runtime/base64url.js
var decodeBase64 = (encoded) => {
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
};
var decode = (input) => {
  let encoded = input;
  if (encoded instanceof Uint8Array) {
    encoded = decoder.decode(encoded);
  }
  encoded = encoded.replace(/-/g, "+").replace(/_/g, "/").replace(/\s/g, "");
  try {
    return decodeBase64(encoded);
  } catch {
    throw new TypeError("The input to be decoded is not correctly encoded.");
  }
};

// node_modules/jose/dist/browser/util/errors.js
var JOSEError = class extends Error {
  constructor(message2, options) {
    super(message2, options);
    this.code = "ERR_JOSE_GENERIC";
    this.name = this.constructor.name;
    Error.captureStackTrace?.(this, this.constructor);
  }
};
JOSEError.code = "ERR_JOSE_GENERIC";
var JWTClaimValidationFailed = class extends JOSEError {
  constructor(message2, payload, claim = "unspecified", reason = "unspecified") {
    super(message2, { cause: { claim, reason, payload } });
    this.code = "ERR_JWT_CLAIM_VALIDATION_FAILED";
    this.claim = claim;
    this.reason = reason;
    this.payload = payload;
  }
};
JWTClaimValidationFailed.code = "ERR_JWT_CLAIM_VALIDATION_FAILED";
var JWTExpired = class extends JOSEError {
  constructor(message2, payload, claim = "unspecified", reason = "unspecified") {
    super(message2, { cause: { claim, reason, payload } });
    this.code = "ERR_JWT_EXPIRED";
    this.claim = claim;
    this.reason = reason;
    this.payload = payload;
  }
};
JWTExpired.code = "ERR_JWT_EXPIRED";
var JOSEAlgNotAllowed = class extends JOSEError {
  constructor() {
    super(...arguments);
    this.code = "ERR_JOSE_ALG_NOT_ALLOWED";
  }
};
JOSEAlgNotAllowed.code = "ERR_JOSE_ALG_NOT_ALLOWED";
var JOSENotSupported = class extends JOSEError {
  constructor() {
    super(...arguments);
    this.code = "ERR_JOSE_NOT_SUPPORTED";
  }
};
JOSENotSupported.code = "ERR_JOSE_NOT_SUPPORTED";
var JWEDecryptionFailed = class extends JOSEError {
  constructor(message2 = "decryption operation failed", options) {
    super(message2, options);
    this.code = "ERR_JWE_DECRYPTION_FAILED";
  }
};
JWEDecryptionFailed.code = "ERR_JWE_DECRYPTION_FAILED";
var JWEInvalid = class extends JOSEError {
  constructor() {
    super(...arguments);
    this.code = "ERR_JWE_INVALID";
  }
};
JWEInvalid.code = "ERR_JWE_INVALID";
var JWSInvalid = class extends JOSEError {
  constructor() {
    super(...arguments);
    this.code = "ERR_JWS_INVALID";
  }
};
JWSInvalid.code = "ERR_JWS_INVALID";
var JWTInvalid = class extends JOSEError {
  constructor() {
    super(...arguments);
    this.code = "ERR_JWT_INVALID";
  }
};
JWTInvalid.code = "ERR_JWT_INVALID";
var JWKInvalid = class extends JOSEError {
  constructor() {
    super(...arguments);
    this.code = "ERR_JWK_INVALID";
  }
};
JWKInvalid.code = "ERR_JWK_INVALID";
var JWKSInvalid = class extends JOSEError {
  constructor() {
    super(...arguments);
    this.code = "ERR_JWKS_INVALID";
  }
};
JWKSInvalid.code = "ERR_JWKS_INVALID";
var JWKSNoMatchingKey = class extends JOSEError {
  constructor(message2 = "no applicable key found in the JSON Web Key Set", options) {
    super(message2, options);
    this.code = "ERR_JWKS_NO_MATCHING_KEY";
  }
};
JWKSNoMatchingKey.code = "ERR_JWKS_NO_MATCHING_KEY";
var JWKSMultipleMatchingKeys = class extends JOSEError {
  constructor(message2 = "multiple matching keys found in the JSON Web Key Set", options) {
    super(message2, options);
    this.code = "ERR_JWKS_MULTIPLE_MATCHING_KEYS";
  }
};
JWKSMultipleMatchingKeys.code = "ERR_JWKS_MULTIPLE_MATCHING_KEYS";
var JWKSTimeout = class extends JOSEError {
  constructor(message2 = "request timed out", options) {
    super(message2, options);
    this.code = "ERR_JWKS_TIMEOUT";
  }
};
JWKSTimeout.code = "ERR_JWKS_TIMEOUT";
var JWSSignatureVerificationFailed = class extends JOSEError {
  constructor(message2 = "signature verification failed", options) {
    super(message2, options);
    this.code = "ERR_JWS_SIGNATURE_VERIFICATION_FAILED";
  }
};
JWSSignatureVerificationFailed.code = "ERR_JWS_SIGNATURE_VERIFICATION_FAILED";

// node_modules/jose/dist/browser/lib/crypto_key.js
function unusable(name, prop = "algorithm.name") {
  return new TypeError(`CryptoKey does not support this operation, its ${prop} must be ${name}`);
}
function isAlgorithm(algorithm, name) {
  return algorithm.name === name;
}
function getHashLength(hash2) {
  return parseInt(hash2.name.slice(4), 10);
}
function getNamedCurve(alg) {
  switch (alg) {
    case "ES256":
      return "P-256";
    case "ES384":
      return "P-384";
    case "ES512":
      return "P-521";
    default:
      throw new Error("unreachable");
  }
}
function checkUsage(key, usages) {
  if (usages.length && !usages.some((expected) => key.usages.includes(expected))) {
    let msg = "CryptoKey does not support this operation, its usages must include ";
    if (usages.length > 2) {
      const last = usages.pop();
      msg += `one of ${usages.join(", ")}, or ${last}.`;
    } else if (usages.length === 2) {
      msg += `one of ${usages[0]} or ${usages[1]}.`;
    } else {
      msg += `${usages[0]}.`;
    }
    throw new TypeError(msg);
  }
}
function checkSigCryptoKey(key, alg, ...usages) {
  switch (alg) {
    case "HS256":
    case "HS384":
    case "HS512": {
      if (!isAlgorithm(key.algorithm, "HMAC"))
        throw unusable("HMAC");
      const expected = parseInt(alg.slice(2), 10);
      const actual = getHashLength(key.algorithm.hash);
      if (actual !== expected)
        throw unusable(`SHA-${expected}`, "algorithm.hash");
      break;
    }
    case "RS256":
    case "RS384":
    case "RS512": {
      if (!isAlgorithm(key.algorithm, "RSASSA-PKCS1-v1_5"))
        throw unusable("RSASSA-PKCS1-v1_5");
      const expected = parseInt(alg.slice(2), 10);
      const actual = getHashLength(key.algorithm.hash);
      if (actual !== expected)
        throw unusable(`SHA-${expected}`, "algorithm.hash");
      break;
    }
    case "PS256":
    case "PS384":
    case "PS512": {
      if (!isAlgorithm(key.algorithm, "RSA-PSS"))
        throw unusable("RSA-PSS");
      const expected = parseInt(alg.slice(2), 10);
      const actual = getHashLength(key.algorithm.hash);
      if (actual !== expected)
        throw unusable(`SHA-${expected}`, "algorithm.hash");
      break;
    }
    case "EdDSA": {
      if (key.algorithm.name !== "Ed25519" && key.algorithm.name !== "Ed448") {
        throw unusable("Ed25519 or Ed448");
      }
      break;
    }
    case "Ed25519": {
      if (!isAlgorithm(key.algorithm, "Ed25519"))
        throw unusable("Ed25519");
      break;
    }
    case "ES256":
    case "ES384":
    case "ES512": {
      if (!isAlgorithm(key.algorithm, "ECDSA"))
        throw unusable("ECDSA");
      const expected = getNamedCurve(alg);
      const actual = key.algorithm.namedCurve;
      if (actual !== expected)
        throw unusable(expected, "algorithm.namedCurve");
      break;
    }
    default:
      throw new TypeError("CryptoKey does not support this operation");
  }
  checkUsage(key, usages);
}

// node_modules/jose/dist/browser/lib/invalid_key_input.js
function message(msg, actual, ...types2) {
  types2 = types2.filter(Boolean);
  if (types2.length > 2) {
    const last = types2.pop();
    msg += `one of type ${types2.join(", ")}, or ${last}.`;
  } else if (types2.length === 2) {
    msg += `one of type ${types2[0]} or ${types2[1]}.`;
  } else {
    msg += `of type ${types2[0]}.`;
  }
  if (actual == null) {
    msg += ` Received ${actual}`;
  } else if (typeof actual === "function" && actual.name) {
    msg += ` Received function ${actual.name}`;
  } else if (typeof actual === "object" && actual != null) {
    if (actual.constructor?.name) {
      msg += ` Received an instance of ${actual.constructor.name}`;
    }
  }
  return msg;
}
var invalid_key_input_default = (actual, ...types2) => {
  return message("Key must be ", actual, ...types2);
};
function withAlg(alg, actual, ...types2) {
  return message(`Key for the ${alg} algorithm must be `, actual, ...types2);
}

// node_modules/jose/dist/browser/runtime/is_key_like.js
var is_key_like_default = (key) => {
  if (isCryptoKey(key)) {
    return true;
  }
  return key?.[Symbol.toStringTag] === "KeyObject";
};
var types = ["CryptoKey"];

// node_modules/jose/dist/browser/lib/is_disjoint.js
var isDisjoint = (...headers) => {
  const sources = headers.filter(Boolean);
  if (sources.length === 0 || sources.length === 1) {
    return true;
  }
  let acc;
  for (const header of sources) {
    const parameters = Object.keys(header);
    if (!acc || acc.size === 0) {
      acc = new Set(parameters);
      continue;
    }
    for (const parameter of parameters) {
      if (acc.has(parameter)) {
        return false;
      }
      acc.add(parameter);
    }
  }
  return true;
};
var is_disjoint_default = isDisjoint;

// node_modules/jose/dist/browser/lib/is_object.js
function isObjectLike(value) {
  return typeof value === "object" && value !== null;
}
function isObject(input) {
  if (!isObjectLike(input) || Object.prototype.toString.call(input) !== "[object Object]") {
    return false;
  }
  if (Object.getPrototypeOf(input) === null) {
    return true;
  }
  let proto = input;
  while (Object.getPrototypeOf(proto) !== null) {
    proto = Object.getPrototypeOf(proto);
  }
  return Object.getPrototypeOf(input) === proto;
}

// node_modules/jose/dist/browser/runtime/check_key_length.js
var check_key_length_default = (alg, key) => {
  if (alg.startsWith("RS") || alg.startsWith("PS")) {
    const { modulusLength } = key.algorithm;
    if (typeof modulusLength !== "number" || modulusLength < 2048) {
      throw new TypeError(`${alg} requires key modulusLength to be 2048 bits or larger`);
    }
  }
};

// node_modules/jose/dist/browser/lib/is_jwk.js
function isJWK(key) {
  return isObject(key) && typeof key.kty === "string";
}
function isPrivateJWK(key) {
  return key.kty !== "oct" && typeof key.d === "string";
}
function isPublicJWK(key) {
  return key.kty !== "oct" && typeof key.d === "undefined";
}
function isSecretJWK(key) {
  return isJWK(key) && key.kty === "oct" && typeof key.k === "string";
}

// node_modules/jose/dist/browser/runtime/jwk_to_key.js
function subtleMapping(jwk) {
  let algorithm;
  let keyUsages;
  switch (jwk.kty) {
    case "RSA": {
      switch (jwk.alg) {
        case "PS256":
        case "PS384":
        case "PS512":
          algorithm = { name: "RSA-PSS", hash: `SHA-${jwk.alg.slice(-3)}` };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "RS256":
        case "RS384":
        case "RS512":
          algorithm = { name: "RSASSA-PKCS1-v1_5", hash: `SHA-${jwk.alg.slice(-3)}` };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "RSA-OAEP":
        case "RSA-OAEP-256":
        case "RSA-OAEP-384":
        case "RSA-OAEP-512":
          algorithm = {
            name: "RSA-OAEP",
            hash: `SHA-${parseInt(jwk.alg.slice(-3), 10) || 1}`
          };
          keyUsages = jwk.d ? ["decrypt", "unwrapKey"] : ["encrypt", "wrapKey"];
          break;
        default:
          throw new JOSENotSupported('Invalid or unsupported JWK "alg" (Algorithm) Parameter value');
      }
      break;
    }
    case "EC": {
      switch (jwk.alg) {
        case "ES256":
          algorithm = { name: "ECDSA", namedCurve: "P-256" };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "ES384":
          algorithm = { name: "ECDSA", namedCurve: "P-384" };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "ES512":
          algorithm = { name: "ECDSA", namedCurve: "P-521" };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "ECDH-ES":
        case "ECDH-ES+A128KW":
        case "ECDH-ES+A192KW":
        case "ECDH-ES+A256KW":
          algorithm = { name: "ECDH", namedCurve: jwk.crv };
          keyUsages = jwk.d ? ["deriveBits"] : [];
          break;
        default:
          throw new JOSENotSupported('Invalid or unsupported JWK "alg" (Algorithm) Parameter value');
      }
      break;
    }
    case "OKP": {
      switch (jwk.alg) {
        case "Ed25519":
          algorithm = { name: "Ed25519" };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "EdDSA":
          algorithm = { name: jwk.crv };
          keyUsages = jwk.d ? ["sign"] : ["verify"];
          break;
        case "ECDH-ES":
        case "ECDH-ES+A128KW":
        case "ECDH-ES+A192KW":
        case "ECDH-ES+A256KW":
          algorithm = { name: jwk.crv };
          keyUsages = jwk.d ? ["deriveBits"] : [];
          break;
        default:
          throw new JOSENotSupported('Invalid or unsupported JWK "alg" (Algorithm) Parameter value');
      }
      break;
    }
    default:
      throw new JOSENotSupported('Invalid or unsupported JWK "kty" (Key Type) Parameter value');
  }
  return { algorithm, keyUsages };
}
var parse = async (jwk) => {
  if (!jwk.alg) {
    throw new TypeError('"alg" argument is required when "jwk.alg" is not present');
  }
  const { algorithm, keyUsages } = subtleMapping(jwk);
  const rest = [
    algorithm,
    jwk.ext ?? false,
    jwk.key_ops ?? keyUsages
  ];
  const keyData = { ...jwk };
  delete keyData.alg;
  delete keyData.use;
  return webcrypto_default.subtle.importKey("jwk", keyData, ...rest);
};
var jwk_to_key_default = parse;

// node_modules/jose/dist/browser/runtime/normalize_key.js
var exportKeyValue = (k) => decode(k);
var privCache;
var pubCache;
var isKeyObject = (key) => {
  return key?.[Symbol.toStringTag] === "KeyObject";
};
var importAndCache = async (cache, key, jwk, alg, freeze = false) => {
  let cached = cache.get(key);
  if (cached?.[alg]) {
    return cached[alg];
  }
  const cryptoKey = await jwk_to_key_default({ ...jwk, alg });
  if (freeze)
    Object.freeze(key);
  if (!cached) {
    cache.set(key, { [alg]: cryptoKey });
  } else {
    cached[alg] = cryptoKey;
  }
  return cryptoKey;
};
var normalizePublicKey = (key, alg) => {
  if (isKeyObject(key)) {
    let jwk = key.export({ format: "jwk" });
    delete jwk.d;
    delete jwk.dp;
    delete jwk.dq;
    delete jwk.p;
    delete jwk.q;
    delete jwk.qi;
    if (jwk.k) {
      return exportKeyValue(jwk.k);
    }
    pubCache || (pubCache = /* @__PURE__ */ new WeakMap());
    return importAndCache(pubCache, key, jwk, alg);
  }
  if (isJWK(key)) {
    if (key.k)
      return decode(key.k);
    pubCache || (pubCache = /* @__PURE__ */ new WeakMap());
    const cryptoKey = importAndCache(pubCache, key, key, alg, true);
    return cryptoKey;
  }
  return key;
};
var normalizePrivateKey = (key, alg) => {
  if (isKeyObject(key)) {
    let jwk = key.export({ format: "jwk" });
    if (jwk.k) {
      return exportKeyValue(jwk.k);
    }
    privCache || (privCache = /* @__PURE__ */ new WeakMap());
    return importAndCache(privCache, key, jwk, alg);
  }
  if (isJWK(key)) {
    if (key.k)
      return decode(key.k);
    privCache || (privCache = /* @__PURE__ */ new WeakMap());
    const cryptoKey = importAndCache(privCache, key, key, alg, true);
    return cryptoKey;
  }
  return key;
};
var normalize_key_default = { normalizePublicKey, normalizePrivateKey };

// node_modules/jose/dist/browser/key/import.js
async function importJWK(jwk, alg) {
  if (!isObject(jwk)) {
    throw new TypeError("JWK must be an object");
  }
  alg || (alg = jwk.alg);
  switch (jwk.kty) {
    case "oct":
      if (typeof jwk.k !== "string" || !jwk.k) {
        throw new TypeError('missing "k" (Key Value) Parameter value');
      }
      return decode(jwk.k);
    case "RSA":
      if ("oth" in jwk && jwk.oth !== void 0) {
        throw new JOSENotSupported('RSA JWK "oth" (Other Primes Info) Parameter value is not supported');
      }
    case "EC":
    case "OKP":
      return jwk_to_key_default({ ...jwk, alg });
    default:
      throw new JOSENotSupported('Unsupported "kty" (Key Type) Parameter value');
  }
}

// node_modules/jose/dist/browser/lib/check_key_type.js
var tag = (key) => key?.[Symbol.toStringTag];
var jwkMatchesOp = (alg, key, usage) => {
  if (key.use !== void 0 && key.use !== "sig") {
    throw new TypeError("Invalid key for this operation, when present its use must be sig");
  }
  if (key.key_ops !== void 0 && key.key_ops.includes?.(usage) !== true) {
    throw new TypeError(`Invalid key for this operation, when present its key_ops must include ${usage}`);
  }
  if (key.alg !== void 0 && key.alg !== alg) {
    throw new TypeError(`Invalid key for this operation, when present its alg must be ${alg}`);
  }
  return true;
};
var symmetricTypeCheck = (alg, key, usage, allowJwk) => {
  if (key instanceof Uint8Array)
    return;
  if (allowJwk && isJWK(key)) {
    if (isSecretJWK(key) && jwkMatchesOp(alg, key, usage))
      return;
    throw new TypeError(`JSON Web Key for symmetric algorithms must have JWK "kty" (Key Type) equal to "oct" and the JWK "k" (Key Value) present`);
  }
  if (!is_key_like_default(key)) {
    throw new TypeError(withAlg(alg, key, ...types, "Uint8Array", allowJwk ? "JSON Web Key" : null));
  }
  if (key.type !== "secret") {
    throw new TypeError(`${tag(key)} instances for symmetric algorithms must be of type "secret"`);
  }
};
var asymmetricTypeCheck = (alg, key, usage, allowJwk) => {
  if (allowJwk && isJWK(key)) {
    switch (usage) {
      case "sign":
        if (isPrivateJWK(key) && jwkMatchesOp(alg, key, usage))
          return;
        throw new TypeError(`JSON Web Key for this operation be a private JWK`);
      case "verify":
        if (isPublicJWK(key) && jwkMatchesOp(alg, key, usage))
          return;
        throw new TypeError(`JSON Web Key for this operation be a public JWK`);
    }
  }
  if (!is_key_like_default(key)) {
    throw new TypeError(withAlg(alg, key, ...types, allowJwk ? "JSON Web Key" : null));
  }
  if (key.type === "secret") {
    throw new TypeError(`${tag(key)} instances for asymmetric algorithms must not be of type "secret"`);
  }
  if (usage === "sign" && key.type === "public") {
    throw new TypeError(`${tag(key)} instances for asymmetric algorithm signing must be of type "private"`);
  }
  if (usage === "decrypt" && key.type === "public") {
    throw new TypeError(`${tag(key)} instances for asymmetric algorithm decryption must be of type "private"`);
  }
  if (key.algorithm && usage === "verify" && key.type === "private") {
    throw new TypeError(`${tag(key)} instances for asymmetric algorithm verifying must be of type "public"`);
  }
  if (key.algorithm && usage === "encrypt" && key.type === "private") {
    throw new TypeError(`${tag(key)} instances for asymmetric algorithm encryption must be of type "public"`);
  }
};
function checkKeyType(allowJwk, alg, key, usage) {
  const symmetric = alg.startsWith("HS") || alg === "dir" || alg.startsWith("PBES2") || /^A\d{3}(?:GCM)?KW$/.test(alg);
  if (symmetric) {
    symmetricTypeCheck(alg, key, usage, allowJwk);
  } else {
    asymmetricTypeCheck(alg, key, usage, allowJwk);
  }
}
var check_key_type_default = checkKeyType.bind(void 0, false);
var checkKeyTypeWithJwk = checkKeyType.bind(void 0, true);

// node_modules/jose/dist/browser/lib/validate_crit.js
function validateCrit(Err, recognizedDefault, recognizedOption, protectedHeader, joseHeader) {
  if (joseHeader.crit !== void 0 && protectedHeader?.crit === void 0) {
    throw new Err('"crit" (Critical) Header Parameter MUST be integrity protected');
  }
  if (!protectedHeader || protectedHeader.crit === void 0) {
    return /* @__PURE__ */ new Set();
  }
  if (!Array.isArray(protectedHeader.crit) || protectedHeader.crit.length === 0 || protectedHeader.crit.some((input) => typeof input !== "string" || input.length === 0)) {
    throw new Err('"crit" (Critical) Header Parameter MUST be an array of non-empty strings when present');
  }
  let recognized;
  if (recognizedOption !== void 0) {
    recognized = new Map([...Object.entries(recognizedOption), ...recognizedDefault.entries()]);
  } else {
    recognized = recognizedDefault;
  }
  for (const parameter of protectedHeader.crit) {
    if (!recognized.has(parameter)) {
      throw new JOSENotSupported(`Extension Header Parameter "${parameter}" is not recognized`);
    }
    if (joseHeader[parameter] === void 0) {
      throw new Err(`Extension Header Parameter "${parameter}" is missing`);
    }
    if (recognized.get(parameter) && protectedHeader[parameter] === void 0) {
      throw new Err(`Extension Header Parameter "${parameter}" MUST be integrity protected`);
    }
  }
  return new Set(protectedHeader.crit);
}
var validate_crit_default = validateCrit;

// node_modules/jose/dist/browser/lib/validate_algorithms.js
var validateAlgorithms = (option, algorithms) => {
  if (algorithms !== void 0 && (!Array.isArray(algorithms) || algorithms.some((s) => typeof s !== "string"))) {
    throw new TypeError(`"${option}" option must be an array of strings`);
  }
  if (!algorithms) {
    return void 0;
  }
  return new Set(algorithms);
};
var validate_algorithms_default = validateAlgorithms;

// node_modules/jose/dist/browser/runtime/subtle_dsa.js
function subtleDsa(alg, algorithm) {
  const hash2 = `SHA-${alg.slice(-3)}`;
  switch (alg) {
    case "HS256":
    case "HS384":
    case "HS512":
      return { hash: hash2, name: "HMAC" };
    case "PS256":
    case "PS384":
    case "PS512":
      return { hash: hash2, name: "RSA-PSS", saltLength: alg.slice(-3) >> 3 };
    case "RS256":
    case "RS384":
    case "RS512":
      return { hash: hash2, name: "RSASSA-PKCS1-v1_5" };
    case "ES256":
    case "ES384":
    case "ES512":
      return { hash: hash2, name: "ECDSA", namedCurve: algorithm.namedCurve };
    case "Ed25519":
      return { name: "Ed25519" };
    case "EdDSA":
      return { name: algorithm.name };
    default:
      throw new JOSENotSupported(`alg ${alg} is not supported either by JOSE or your javascript runtime`);
  }
}

// node_modules/jose/dist/browser/runtime/get_sign_verify_key.js
async function getCryptoKey(alg, key, usage) {
  if (usage === "sign") {
    key = await normalize_key_default.normalizePrivateKey(key, alg);
  }
  if (usage === "verify") {
    key = await normalize_key_default.normalizePublicKey(key, alg);
  }
  if (isCryptoKey(key)) {
    checkSigCryptoKey(key, alg, usage);
    return key;
  }
  if (key instanceof Uint8Array) {
    if (!alg.startsWith("HS")) {
      throw new TypeError(invalid_key_input_default(key, ...types));
    }
    return webcrypto_default.subtle.importKey("raw", key, { hash: `SHA-${alg.slice(-3)}`, name: "HMAC" }, false, [usage]);
  }
  throw new TypeError(invalid_key_input_default(key, ...types, "Uint8Array", "JSON Web Key"));
}

// node_modules/jose/dist/browser/runtime/verify.js
var verify = async (alg, key, signature, data) => {
  const cryptoKey = await getCryptoKey(alg, key, "verify");
  check_key_length_default(alg, cryptoKey);
  const algorithm = subtleDsa(alg, cryptoKey.algorithm);
  try {
    return await webcrypto_default.subtle.verify(algorithm, cryptoKey, signature, data);
  } catch {
    return false;
  }
};
var verify_default = verify;

// node_modules/jose/dist/browser/jws/flattened/verify.js
async function flattenedVerify(jws, key, options) {
  if (!isObject(jws)) {
    throw new JWSInvalid("Flattened JWS must be an object");
  }
  if (jws.protected === void 0 && jws.header === void 0) {
    throw new JWSInvalid('Flattened JWS must have either of the "protected" or "header" members');
  }
  if (jws.protected !== void 0 && typeof jws.protected !== "string") {
    throw new JWSInvalid("JWS Protected Header incorrect type");
  }
  if (jws.payload === void 0) {
    throw new JWSInvalid("JWS Payload missing");
  }
  if (typeof jws.signature !== "string") {
    throw new JWSInvalid("JWS Signature missing or incorrect type");
  }
  if (jws.header !== void 0 && !isObject(jws.header)) {
    throw new JWSInvalid("JWS Unprotected Header incorrect type");
  }
  let parsedProt = {};
  if (jws.protected) {
    try {
      const protectedHeader = decode(jws.protected);
      parsedProt = JSON.parse(decoder.decode(protectedHeader));
    } catch {
      throw new JWSInvalid("JWS Protected Header is invalid");
    }
  }
  if (!is_disjoint_default(parsedProt, jws.header)) {
    throw new JWSInvalid("JWS Protected and JWS Unprotected Header Parameter names must be disjoint");
  }
  const joseHeader = {
    ...parsedProt,
    ...jws.header
  };
  const extensions = validate_crit_default(JWSInvalid, /* @__PURE__ */ new Map([["b64", true]]), options?.crit, parsedProt, joseHeader);
  let b64 = true;
  if (extensions.has("b64")) {
    b64 = parsedProt.b64;
    if (typeof b64 !== "boolean") {
      throw new JWSInvalid('The "b64" (base64url-encode payload) Header Parameter must be a boolean');
    }
  }
  const { alg } = joseHeader;
  if (typeof alg !== "string" || !alg) {
    throw new JWSInvalid('JWS "alg" (Algorithm) Header Parameter missing or invalid');
  }
  const algorithms = options && validate_algorithms_default("algorithms", options.algorithms);
  if (algorithms && !algorithms.has(alg)) {
    throw new JOSEAlgNotAllowed('"alg" (Algorithm) Header Parameter value not allowed');
  }
  if (b64) {
    if (typeof jws.payload !== "string") {
      throw new JWSInvalid("JWS Payload must be a string");
    }
  } else if (typeof jws.payload !== "string" && !(jws.payload instanceof Uint8Array)) {
    throw new JWSInvalid("JWS Payload must be a string or an Uint8Array instance");
  }
  let resolvedKey = false;
  if (typeof key === "function") {
    key = await key(parsedProt, jws);
    resolvedKey = true;
    checkKeyTypeWithJwk(alg, key, "verify");
    if (isJWK(key)) {
      key = await importJWK(key, alg);
    }
  } else {
    checkKeyTypeWithJwk(alg, key, "verify");
  }
  const data = concat(encoder2.encode(jws.protected ?? ""), encoder2.encode("."), typeof jws.payload === "string" ? encoder2.encode(jws.payload) : jws.payload);
  let signature;
  try {
    signature = decode(jws.signature);
  } catch {
    throw new JWSInvalid("Failed to base64url decode the signature");
  }
  const verified = await verify_default(alg, key, signature, data);
  if (!verified) {
    throw new JWSSignatureVerificationFailed();
  }
  let payload;
  if (b64) {
    try {
      payload = decode(jws.payload);
    } catch {
      throw new JWSInvalid("Failed to base64url decode the payload");
    }
  } else if (typeof jws.payload === "string") {
    payload = encoder2.encode(jws.payload);
  } else {
    payload = jws.payload;
  }
  const result = { payload };
  if (jws.protected !== void 0) {
    result.protectedHeader = parsedProt;
  }
  if (jws.header !== void 0) {
    result.unprotectedHeader = jws.header;
  }
  if (resolvedKey) {
    return { ...result, key };
  }
  return result;
}

// node_modules/jose/dist/browser/jws/compact/verify.js
async function compactVerify(jws, key, options) {
  if (jws instanceof Uint8Array) {
    jws = decoder.decode(jws);
  }
  if (typeof jws !== "string") {
    throw new JWSInvalid("Compact JWS must be a string or Uint8Array");
  }
  const { 0: protectedHeader, 1: payload, 2: signature, length } = jws.split(".");
  if (length !== 3) {
    throw new JWSInvalid("Invalid Compact JWS");
  }
  const verified = await flattenedVerify({ payload, protected: protectedHeader, signature }, key, options);
  const result = { payload: verified.payload, protectedHeader: verified.protectedHeader };
  if (typeof key === "function") {
    return { ...result, key: verified.key };
  }
  return result;
}

// node_modules/jose/dist/browser/lib/epoch.js
var epoch_default = (date) => Math.floor(date.getTime() / 1e3);

// node_modules/jose/dist/browser/lib/secs.js
var minute = 60;
var hour = minute * 60;
var day = hour * 24;
var week = day * 7;
var year = day * 365.25;
var REGEX = /^(\+|\-)? ?(\d+|\d+\.\d+) ?(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w|years?|yrs?|y)(?: (ago|from now))?$/i;
var secs_default = (str) => {
  const matched = REGEX.exec(str);
  if (!matched || matched[4] && matched[1]) {
    throw new TypeError("Invalid time period format");
  }
  const value = parseFloat(matched[2]);
  const unit = matched[3].toLowerCase();
  let numericDate;
  switch (unit) {
    case "sec":
    case "secs":
    case "second":
    case "seconds":
    case "s":
      numericDate = Math.round(value);
      break;
    case "minute":
    case "minutes":
    case "min":
    case "mins":
    case "m":
      numericDate = Math.round(value * minute);
      break;
    case "hour":
    case "hours":
    case "hr":
    case "hrs":
    case "h":
      numericDate = Math.round(value * hour);
      break;
    case "day":
    case "days":
    case "d":
      numericDate = Math.round(value * day);
      break;
    case "week":
    case "weeks":
    case "w":
      numericDate = Math.round(value * week);
      break;
    default:
      numericDate = Math.round(value * year);
      break;
  }
  if (matched[1] === "-" || matched[4] === "ago") {
    return -numericDate;
  }
  return numericDate;
};

// node_modules/jose/dist/browser/lib/jwt_claims_set.js
var normalizeTyp = (value) => value.toLowerCase().replace(/^application\//, "");
var checkAudiencePresence = (audPayload, audOption) => {
  if (typeof audPayload === "string") {
    return audOption.includes(audPayload);
  }
  if (Array.isArray(audPayload)) {
    return audOption.some(Set.prototype.has.bind(new Set(audPayload)));
  }
  return false;
};
var jwt_claims_set_default = (protectedHeader, encodedPayload, options = {}) => {
  let payload;
  try {
    payload = JSON.parse(decoder.decode(encodedPayload));
  } catch {
  }
  if (!isObject(payload)) {
    throw new JWTInvalid("JWT Claims Set must be a top-level JSON object");
  }
  const { typ } = options;
  if (typ && (typeof protectedHeader.typ !== "string" || normalizeTyp(protectedHeader.typ) !== normalizeTyp(typ))) {
    throw new JWTClaimValidationFailed('unexpected "typ" JWT header value', payload, "typ", "check_failed");
  }
  const { requiredClaims = [], issuer, subject, audience, maxTokenAge } = options;
  const presenceCheck = [...requiredClaims];
  if (maxTokenAge !== void 0)
    presenceCheck.push("iat");
  if (audience !== void 0)
    presenceCheck.push("aud");
  if (subject !== void 0)
    presenceCheck.push("sub");
  if (issuer !== void 0)
    presenceCheck.push("iss");
  for (const claim of new Set(presenceCheck.reverse())) {
    if (!(claim in payload)) {
      throw new JWTClaimValidationFailed(`missing required "${claim}" claim`, payload, claim, "missing");
    }
  }
  if (issuer && !(Array.isArray(issuer) ? issuer : [issuer]).includes(payload.iss)) {
    throw new JWTClaimValidationFailed('unexpected "iss" claim value', payload, "iss", "check_failed");
  }
  if (subject && payload.sub !== subject) {
    throw new JWTClaimValidationFailed('unexpected "sub" claim value', payload, "sub", "check_failed");
  }
  if (audience && !checkAudiencePresence(payload.aud, typeof audience === "string" ? [audience] : audience)) {
    throw new JWTClaimValidationFailed('unexpected "aud" claim value', payload, "aud", "check_failed");
  }
  let tolerance;
  switch (typeof options.clockTolerance) {
    case "string":
      tolerance = secs_default(options.clockTolerance);
      break;
    case "number":
      tolerance = options.clockTolerance;
      break;
    case "undefined":
      tolerance = 0;
      break;
    default:
      throw new TypeError("Invalid clockTolerance option type");
  }
  const { currentDate } = options;
  const now = epoch_default(currentDate || /* @__PURE__ */ new Date());
  if ((payload.iat !== void 0 || maxTokenAge) && typeof payload.iat !== "number") {
    throw new JWTClaimValidationFailed('"iat" claim must be a number', payload, "iat", "invalid");
  }
  if (payload.nbf !== void 0) {
    if (typeof payload.nbf !== "number") {
      throw new JWTClaimValidationFailed('"nbf" claim must be a number', payload, "nbf", "invalid");
    }
    if (payload.nbf > now + tolerance) {
      throw new JWTClaimValidationFailed('"nbf" claim timestamp check failed', payload, "nbf", "check_failed");
    }
  }
  if (payload.exp !== void 0) {
    if (typeof payload.exp !== "number") {
      throw new JWTClaimValidationFailed('"exp" claim must be a number', payload, "exp", "invalid");
    }
    if (payload.exp <= now - tolerance) {
      throw new JWTExpired('"exp" claim timestamp check failed', payload, "exp", "check_failed");
    }
  }
  if (maxTokenAge) {
    const age = now - payload.iat;
    const max = typeof maxTokenAge === "number" ? maxTokenAge : secs_default(maxTokenAge);
    if (age - tolerance > max) {
      throw new JWTExpired('"iat" claim timestamp check failed (too far in the past)', payload, "iat", "check_failed");
    }
    if (age < 0 - tolerance) {
      throw new JWTClaimValidationFailed('"iat" claim timestamp check failed (it should be in the past)', payload, "iat", "check_failed");
    }
  }
  return payload;
};

// node_modules/jose/dist/browser/jwt/verify.js
async function jwtVerify(jwt, key, options) {
  const verified = await compactVerify(jwt, key, options);
  if (verified.protectedHeader.crit?.includes("b64") && verified.protectedHeader.b64 === false) {
    throw new JWTInvalid("JWTs MUST NOT use unencoded payload");
  }
  const payload = jwt_claims_set_default(verified.protectedHeader, verified.payload, options);
  const result = { payload, protectedHeader: verified.protectedHeader };
  if (typeof key === "function") {
    return { ...result, key: verified.key };
  }
  return result;
}

// node_modules/jose/dist/browser/jwks/local.js
function getKtyFromAlg(alg) {
  switch (typeof alg === "string" && alg.slice(0, 2)) {
    case "RS":
    case "PS":
      return "RSA";
    case "ES":
      return "EC";
    case "Ed":
      return "OKP";
    default:
      throw new JOSENotSupported('Unsupported "alg" value for a JSON Web Key Set');
  }
}
function isJWKSLike(jwks) {
  return jwks && typeof jwks === "object" && Array.isArray(jwks.keys) && jwks.keys.every(isJWKLike);
}
function isJWKLike(key) {
  return isObject(key);
}
function clone(obj) {
  if (typeof structuredClone === "function") {
    return structuredClone(obj);
  }
  return JSON.parse(JSON.stringify(obj));
}
var LocalJWKSet = class {
  constructor(jwks) {
    this._cached = /* @__PURE__ */ new WeakMap();
    if (!isJWKSLike(jwks)) {
      throw new JWKSInvalid("JSON Web Key Set malformed");
    }
    this._jwks = clone(jwks);
  }
  async getKey(protectedHeader, token) {
    const { alg, kid } = { ...protectedHeader, ...token?.header };
    const kty = getKtyFromAlg(alg);
    const candidates = this._jwks.keys.filter((jwk2) => {
      let candidate = kty === jwk2.kty;
      if (candidate && typeof kid === "string") {
        candidate = kid === jwk2.kid;
      }
      if (candidate && typeof jwk2.alg === "string") {
        candidate = alg === jwk2.alg;
      }
      if (candidate && typeof jwk2.use === "string") {
        candidate = jwk2.use === "sig";
      }
      if (candidate && Array.isArray(jwk2.key_ops)) {
        candidate = jwk2.key_ops.includes("verify");
      }
      if (candidate) {
        switch (alg) {
          case "ES256":
            candidate = jwk2.crv === "P-256";
            break;
          case "ES256K":
            candidate = jwk2.crv === "secp256k1";
            break;
          case "ES384":
            candidate = jwk2.crv === "P-384";
            break;
          case "ES512":
            candidate = jwk2.crv === "P-521";
            break;
          case "Ed25519":
            candidate = jwk2.crv === "Ed25519";
            break;
          case "EdDSA":
            candidate = jwk2.crv === "Ed25519" || jwk2.crv === "Ed448";
            break;
        }
      }
      return candidate;
    });
    const { 0: jwk, length } = candidates;
    if (length === 0) {
      throw new JWKSNoMatchingKey();
    }
    if (length !== 1) {
      const error = new JWKSMultipleMatchingKeys();
      const { _cached } = this;
      error[Symbol.asyncIterator] = async function* () {
        for (const jwk2 of candidates) {
          try {
            yield await importWithAlgCache(_cached, jwk2, alg);
          } catch {
          }
        }
      };
      throw error;
    }
    return importWithAlgCache(this._cached, jwk, alg);
  }
};
async function importWithAlgCache(cache, jwk, alg) {
  const cached = cache.get(jwk) || cache.set(jwk, {}).get(jwk);
  if (cached[alg] === void 0) {
    const key = await importJWK({ ...jwk, ext: true }, alg);
    if (key instanceof Uint8Array || key.type !== "public") {
      throw new JWKSInvalid("JSON Web Key Set members must be public keys");
    }
    cached[alg] = key;
  }
  return cached[alg];
}
function createLocalJWKSet(jwks) {
  const set = new LocalJWKSet(jwks);
  const localJWKSet = async (protectedHeader, token) => set.getKey(protectedHeader, token);
  Object.defineProperties(localJWKSet, {
    jwks: {
      value: () => clone(set._jwks),
      enumerable: true,
      configurable: false,
      writable: false
    }
  });
  return localJWKSet;
}

// node_modules/jose/dist/browser/runtime/fetch_jwks.js
var fetchJwks = async (url, timeout, options) => {
  let controller;
  let id;
  let timedOut = false;
  if (typeof AbortController === "function") {
    controller = new AbortController();
    id = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, timeout);
  }
  const response = await fetch(url.href, {
    signal: controller ? controller.signal : void 0,
    redirect: "manual",
    headers: options.headers
  }).catch((err) => {
    if (timedOut)
      throw new JWKSTimeout();
    throw err;
  });
  if (id !== void 0)
    clearTimeout(id);
  if (response.status !== 200) {
    throw new JOSEError("Expected 200 OK from the JSON Web Key Set HTTP response");
  }
  try {
    return await response.json();
  } catch {
    throw new JOSEError("Failed to parse the JSON Web Key Set HTTP response as JSON");
  }
};
var fetch_jwks_default = fetchJwks;

// node_modules/jose/dist/browser/jwks/remote.js
function isCloudflareWorkers() {
  return typeof WebSocketPair !== "undefined" || typeof navigator !== "undefined" && navigator.userAgent === "Cloudflare-Workers" || typeof EdgeRuntime !== "undefined" && EdgeRuntime === "vercel";
}
var USER_AGENT;
if (typeof navigator === "undefined" || !navigator.userAgent?.startsWith?.("Mozilla/5.0 ")) {
  const NAME = "jose";
  const VERSION = "v5.10.0";
  USER_AGENT = `${NAME}/${VERSION}`;
}
var jwksCache = /* @__PURE__ */ Symbol();
function isFreshJwksCache(input, cacheMaxAge) {
  if (typeof input !== "object" || input === null) {
    return false;
  }
  if (!("uat" in input) || typeof input.uat !== "number" || Date.now() - input.uat >= cacheMaxAge) {
    return false;
  }
  if (!("jwks" in input) || !isObject(input.jwks) || !Array.isArray(input.jwks.keys) || !Array.prototype.every.call(input.jwks.keys, isObject)) {
    return false;
  }
  return true;
}
var RemoteJWKSet = class {
  constructor(url, options) {
    if (!(url instanceof URL)) {
      throw new TypeError("url must be an instance of URL");
    }
    this._url = new URL(url.href);
    this._options = { agent: options?.agent, headers: options?.headers };
    this._timeoutDuration = typeof options?.timeoutDuration === "number" ? options?.timeoutDuration : 5e3;
    this._cooldownDuration = typeof options?.cooldownDuration === "number" ? options?.cooldownDuration : 3e4;
    this._cacheMaxAge = typeof options?.cacheMaxAge === "number" ? options?.cacheMaxAge : 6e5;
    if (options?.[jwksCache] !== void 0) {
      this._cache = options?.[jwksCache];
      if (isFreshJwksCache(options?.[jwksCache], this._cacheMaxAge)) {
        this._jwksTimestamp = this._cache.uat;
        this._local = createLocalJWKSet(this._cache.jwks);
      }
    }
  }
  coolingDown() {
    return typeof this._jwksTimestamp === "number" ? Date.now() < this._jwksTimestamp + this._cooldownDuration : false;
  }
  fresh() {
    return typeof this._jwksTimestamp === "number" ? Date.now() < this._jwksTimestamp + this._cacheMaxAge : false;
  }
  async getKey(protectedHeader, token) {
    if (!this._local || !this.fresh()) {
      await this.reload();
    }
    try {
      return await this._local(protectedHeader, token);
    } catch (err) {
      if (err instanceof JWKSNoMatchingKey) {
        if (this.coolingDown() === false) {
          await this.reload();
          return this._local(protectedHeader, token);
        }
      }
      throw err;
    }
  }
  async reload() {
    if (this._pendingFetch && isCloudflareWorkers()) {
      this._pendingFetch = void 0;
    }
    const headers = new Headers(this._options.headers);
    if (USER_AGENT && !headers.has("User-Agent")) {
      headers.set("User-Agent", USER_AGENT);
      this._options.headers = Object.fromEntries(headers.entries());
    }
    this._pendingFetch || (this._pendingFetch = fetch_jwks_default(this._url, this._timeoutDuration, this._options).then((json2) => {
      this._local = createLocalJWKSet(json2);
      if (this._cache) {
        this._cache.uat = Date.now();
        this._cache.jwks = json2;
      }
      this._jwksTimestamp = Date.now();
      this._pendingFetch = void 0;
    }).catch((err) => {
      this._pendingFetch = void 0;
      throw err;
    }));
    await this._pendingFetch;
  }
};
function createRemoteJWKSet(url, options) {
  const set = new RemoteJWKSet(url, options);
  const remoteJWKSet = async (protectedHeader, token) => set.getKey(protectedHeader, token);
  Object.defineProperties(remoteJWKSet, {
    coolingDown: {
      get: () => set.coolingDown(),
      enumerable: true,
      configurable: false
    },
    fresh: {
      get: () => set.fresh(),
      enumerable: true,
      configurable: false
    },
    reload: {
      value: () => set.reload(),
      enumerable: true,
      configurable: false,
      writable: false
    },
    reloading: {
      get: () => !!set._pendingFetch,
      enumerable: true,
      configurable: false
    },
    jwks: {
      value: () => set._local?.jwks(),
      enumerable: true,
      configurable: false,
      writable: false
    }
  });
  return remoteJWKSet;
}

// src/index.js
var CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization"
};
var SECURITY_HEADERS = {
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "permissions-policy": "camera=(), microphone=(), geolocation=()",
  "content-security-policy": "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data: https:; media-src 'self' blob: http: https:"
};
var MAX_TRANSCRIBE_BYTES = 100 * 1024 * 1024;
var DEFAULT_MAX_BYTES = 9e9;
var DEFAULT_MEDIA_TTL = 1800;
var DEFAULT_SUMMARY_MODEL = "@cf/meta/llama-3.3-70b-instruct-fp8-fast";
var REACTIONS = ["\u{1F44D}", "\u{1F389}", "\u{1F602}", "\u2764\uFE0F", "\u{1F440}", "\u{1F525}"];
var NO_STORE = { "cache-control": "no-store" };
function json(data, init = {}) {
  return new Response(JSON.stringify(data), {
    status: init.status || 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...CORS,
      ...SECURITY_HEADERS,
      ...init.headers || {}
    }
  });
}
function html(markup, status = 200, extraHeaders = {}) {
  return new Response(markup, {
    status,
    headers: { "content-type": "text/html; charset=utf-8", ...CORS, ...SECURITY_HEADERS, ...extraHeaders }
  });
}
function rowToVideo(row) {
  return {
    id: row.id,
    title: row.title,
    durationSeconds: row.duration_seconds,
    objectKey: row.object_key,
    audioKey: row.audio_key || null,
    bytes: row.bytes || 0,
    width: row.width,
    height: row.height,
    captureMode: row.capture_mode,
    createdAt: row.created_at,
    uploadStatus: row.upload_status || "ready",
    uploadUpdatedAt: row.upload_updated_at || row.created_at,
    disabled: !!row.disabled,
    transcript: row.transcript || null,
    transcriptVtt: row.transcript_vtt || null,
    summary: row.summary || null,
    titleUpdatedAt: row.title_updated_at || row.created_at || null,
    transcriptUpdatedAt: row.transcript == null ? null : row.transcript_updated_at || row.created_at || null,
    summaryUpdatedAt: row.summary == null ? null : row.summary_updated_at || row.created_at || null,
    chapters: parseStoredChapters(row.summary)
  };
}
function cleanTitle(value, maxLength = 100) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, maxLength).trim();
}
function normalizedTimestamp(value, fallback = null) {
  const milliseconds = Date.parse(String(value || ""));
  if (Number.isFinite(milliseconds)) return new Date(milliseconds).toISOString();
  return fallback;
}
function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object || {}, key);
}
function syncText(value, field, maxLength) {
  if (value == null) return null;
  const text = String(value);
  if (text.length > maxLength) throw new Error(`${field} is too large`);
  return text;
}
function generatedTitle(value, fallback) {
  let title = cleanTitle(value, 60).replace(/^["'“”‘’]+|["'“”‘’.:;,-]+$/g, "").trim();
  title = title.split(/\s+/).slice(0, 8).join(" ");
  return title || cleanTitle(fallback, 60) || "Untitled Cue";
}
function hasDefaultTitle(title) {
  const value = cleanTitle(title);
  return !value || /^Untitled Cue$/i.test(value) || /^Cue\s*[·-]/i.test(value);
}
function parseStoredChapters(summary) {
  const marker = /(?:^|\n)Chapters:\s*\n/i;
  const match = marker.exec(String(summary || ""));
  if (!match) return [];
  return String(summary).slice(match.index + match[0].length).split(/\r?\n/).map((line) => {
    const m = /^-\s*(?:(\d+):)?(\d{1,2}):(\d{2})\s+[—-]\s+(.+)$/.exec(line.trim());
    if (!m) return null;
    const seconds = (Number(m[1]) || 0) * 3600 + Number(m[2]) * 60 + Number(m[3]);
    const title = cleanTitle(m[4], 80);
    return title ? { startSeconds: seconds, title } : null;
  }).filter(Boolean).slice(0, 8);
}
function formatChapterTime(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor(total % 3600 / 60);
  const secs = total % 60;
  return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}` : `${minutes}:${String(secs).padStart(2, "0")}`;
}
function baseURL(request, env) {
  if (env.PUBLIC_BASE) return env.PUBLIC_BASE.replace(/\/$/, "");
  return new URL(request.url).origin;
}
function mediaURL(request, env, video) {
  let mediaBase = (env.MEDIA_PUBLIC_BASE || "").replace(/\/$/, "");
  if (mediaBase) {
    if (!/^https?:\/\//i.test(mediaBase)) mediaBase = `https://${mediaBase}`;
    return `${mediaBase}/${video.objectKey}`;
  }
  return `${baseURL(request, env)}/file/${video.objectKey}`;
}
function presignConfig(env) {
  const accountId = env.R2_ACCOUNT_ID;
  const accessKeyId = env.R2_ACCESS_KEY_ID;
  const secretAccessKey = env.R2_SECRET_ACCESS_KEY;
  if (!accountId || !accessKeyId || !secretAccessKey) return null;
  return {
    accountId,
    accessKeyId,
    secretAccessKey,
    bucket: env.R2_BUCKET || "cue",
    ttl: Number(env.MEDIA_URL_TTL) || DEFAULT_MEDIA_TTL
  };
}
async function presignedURL(cfg, key) {
  const client = new AwsClient({
    accessKeyId: cfg.accessKeyId,
    secretAccessKey: cfg.secretAccessKey,
    service: "s3",
    region: "auto"
  });
  const u = new URL(`https://${cfg.accountId}.r2.cloudflarestorage.com/${cfg.bucket}/${key}`);
  u.searchParams.set("X-Amz-Expires", String(cfg.ttl));
  const signed = await client.sign(u.toString(), { method: "GET", aws: { signQuery: true } });
  return signed.url;
}
async function resolveMediaURL(request, env, video) {
  const cfg = presignConfig(env);
  if (cfg) return await presignedURL(cfg, video.objectKey);
  return mediaURL(request, env, video);
}
function decorate(request, env, v) {
  return {
    ...v,
    mediaURL: mediaURL(request, env, v),
    shareURL: `${baseURL(request, env)}/v/${v.id}`
  };
}
async function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const [ah, bh] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b))
  ]);
  return crypto.subtle.timingSafeEqual(ah, bh);
}
var _jwks = null;
var _jwksTeam = null;
function accessJWKS(team) {
  if (!_jwks || _jwksTeam !== team) {
    _jwks = createRemoteJWKSet(new URL(`https://${team}/cdn-cgi/access/certs`));
    _jwksTeam = team;
  }
  return _jwks;
}
function accessToken(request) {
  const header = request.headers.get("cf-access-jwt-assertion");
  if (header) return header;
  const m = (request.headers.get("cookie") || "").match(/(?:^|;\s*)CF_Authorization=([^;]+)/);
  return m ? m[1] : null;
}
async function verifyAccess(request, env) {
  const team = (env.ACCESS_TEAM_DOMAIN || "").trim();
  const aud = (env.ACCESS_AUD || "").trim();
  if (!team || !aud) return null;
  const token = accessToken(request);
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, accessJWKS(team), {
      issuer: `https://${team}`,
      audience: aud
    });
    return payload;
  } catch {
    return null;
  }
}
async function ownerError(request, env) {
  const expected = env.OWNER_TOKEN;
  const got = (request.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (expected && got && await timingSafeEqual(got, expected)) return null;
  if (await verifyAccess(request, env)) return null;
  const accessConfigured = !!(env.ACCESS_TEAM_DOMAIN && env.ACCESS_AUD);
  if (!expected && !accessConfigured) {
    return json({ error: "server not configured: set OWNER_TOKEN (and/or Cloudflare Access)" }, { status: 503 });
  }
  return json({ error: "unauthorized" }, { status: 401 });
}
var index_default = {
  async fetch(request, env) {
    const url = new URL(request.url);
    const { pathname } = url;
    const method = request.method;
    if (method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    try {
      if (pathname === "/healthz") return json({ ok: true, service: "cue-worker" });
      if (pathname === "/api/videos" && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const body = await request.json().catch(() => ({}));
        const { id, title, durationSeconds, objectKey, audioKey, bytes, width, height, captureMode, createdAt } = body || {};
        if (!id || !objectKey) return json({ error: "id and objectKey are required" }, { status: 400 });
        const created = normalizedTimestamp(createdAt, (/* @__PURE__ */ new Date()).toISOString());
        const titleUpdatedAt = normalizedTimestamp(body?.titleUpdatedAt, created);
        const uploadStatus = ["uploading", "ready", "failed"].includes(body?.uploadStatus) ? body.uploadStatus : "ready";
        const uploadUpdatedAt = (/* @__PURE__ */ new Date()).toISOString();
        const disabled = body?.disabled === false ? 0 : 1;
        await env.DB.prepare(
          `INSERT INTO videos (id, title, duration_seconds, object_key, audio_key, bytes, width, height, capture_mode, created_at, upload_status, upload_updated_at, disabled, title_updated_at)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
           ON CONFLICT(id) DO UPDATE SET
             title=CASE WHEN excluded.title_updated_at >= COALESCE(videos.title_updated_at, videos.created_at, '') THEN excluded.title ELSE videos.title END,
             title_updated_at=CASE WHEN excluded.title_updated_at >= COALESCE(videos.title_updated_at, videos.created_at, '') THEN excluded.title_updated_at ELSE videos.title_updated_at END,
             duration_seconds=excluded.duration_seconds,
             object_key=excluded.object_key, audio_key=excluded.audio_key, bytes=excluded.bytes,
             width=excluded.width, height=excluded.height,
             capture_mode=excluded.capture_mode, created_at=excluded.created_at,
             upload_status=excluded.upload_status, upload_updated_at=excluded.upload_updated_at`
        ).bind(
          id,
          title || "Untitled Cue",
          Number(durationSeconds) || 0,
          objectKey,
          audioKey || null,
          Number(bytes) || 0,
          Number(width) || 0,
          Number(height) || 0,
          captureMode || "screen",
          created,
          uploadStatus,
          uploadUpdatedAt,
          disabled,
          titleUpdatedAt
        ).run();
        if (uploadStatus === "ready") await enforceStorageCap(env, id);
        return json({ id, url: `${baseURL(request, env)}/v/${id}` });
      }
      if (pathname === "/api/videos" && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const { results } = await env.DB.prepare(
          "SELECT * FROM videos ORDER BY created_at DESC"
        ).all();
        return json({ videos: (results || []).map((r) => decorate(request, env, rowToVideo(r))) });
      }
      if (pathname === "/api/videos/search" && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const q = (url.searchParams.get("q") || "").trim();
        if (!q) return json({ q: "", videos: [] });
        const rows = await searchVideos(env, q);
        return json({
          q,
          videos: rows.map((r) => {
            const dv = decorate(request, env, rowToVideo(r));
            dv.snippet = transcriptSnippet(r.transcript, q);
            return dv;
          })
        });
      }
      const txMatch = pathname.match(/^\/api\/videos\/([^/]+)\/transcribe$/);
      if (txMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        return await transcribeHTTP(decodeURIComponent(txMatch[1]), url, env);
      }
      const sumMatch = pathname.match(/^\/api\/videos\/([^/]+)\/summarize$/);
      if (sumMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        return await summarizeHTTP(decodeURIComponent(sumMatch[1]), env);
      }
      const titleMatch = pathname.match(/^\/api\/videos\/([^/]+)\/title$/);
      if (titleMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const body = await request.json().catch(() => ({}));
        const title = cleanTitle(body?.title);
        if (!title) return json({ error: "title is required" }, { status: 400 });
        const id = decodeURIComponent(titleMatch[1]);
        const result = await updateTitle(env, id, title, body?.titleUpdatedAt);
        if (!result) return json({ error: "not found" }, { status: 404 });
        return json({ id, ...result });
      }
      const syncMatch = pathname.match(/^\/api\/videos\/([^/]+)\/sync$/);
      if (syncMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const id = decodeURIComponent(syncMatch[1]);
        const db = env.DB.withSession("first-primary");
        const existing = await db.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
        if (!existing) return json({ error: "not found" }, { status: 404 });
        const body = await request.json().catch(() => ({}));
        if (hasOwn(body, "title")) {
          const title = cleanTitle(body.title);
          const updatedAt = normalizedTimestamp(body.titleUpdatedAt);
          if (!title || !updatedAt) return json({ error: "title and titleUpdatedAt are required" }, { status: 400 });
          await db.prepare(
            "UPDATE videos SET title = ?, title_updated_at = ? WHERE id = ? AND COALESCE(title_updated_at, created_at, '') < ?"
          ).bind(title, updatedAt, id, updatedAt).run();
        }
        if (hasOwn(body, "transcript")) {
          const updatedAt = normalizedTimestamp(body.transcriptUpdatedAt);
          if (!updatedAt) return json({ error: "transcriptUpdatedAt is required" }, { status: 400 });
          const transcript = syncText(body.transcript, "transcript", 2e6);
          const transcriptVtt = syncText(body.transcriptVtt, "transcriptVtt", 4e6);
          await db.prepare(
            "UPDATE videos SET transcript = ?, transcript_vtt = ?, transcript_updated_at = ? WHERE id = ? AND COALESCE(transcript_updated_at, '') < ?"
          ).bind(transcript, transcriptVtt, updatedAt, id, updatedAt).run();
        }
        if (hasOwn(body, "summary")) {
          const updatedAt = normalizedTimestamp(body.summaryUpdatedAt);
          if (!updatedAt) return json({ error: "summaryUpdatedAt is required" }, { status: 400 });
          const summary = syncText(body.summary, "summary", 25e4);
          await db.prepare(
            "UPDATE videos SET summary = ?, summary_updated_at = ? WHERE id = ? AND COALESCE(summary_updated_at, '') < ?"
          ).bind(summary, updatedAt, id, updatedAt).run();
        }
        const settled = await db.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
        return json(decorate(request, env, rowToVideo(settled)));
      }
      const declMatch = pathname.match(/^\/api\/videos\/([^/]+)\/declutter$/);
      if (declMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        return await declutterHTTP(decodeURIComponent(declMatch[1]), env);
      }
      const toggleMatch = pathname.match(/^\/api\/videos\/([^/]+)\/(disable|enable)$/);
      if (toggleMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const id = decodeURIComponent(toggleMatch[1]);
        const disabled = toggleMatch[2] === "disable";
        const ok = await setDisabled(env, id, disabled);
        if (!ok) return json({ error: "not found" }, { status: 404 });
        return json({ id, disabled });
      }
      const oneMatch = pathname.match(/^\/api\/videos\/([^/]+)$/);
      if (oneMatch && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(decodeURIComponent(oneMatch[1])).first();
        if (!row) return json({ error: "not found" }, { status: 404 });
        const v = rowToVideo(row);
        const dv = decorate(request, env, v);
        dv.mediaURL = await resolveMediaURL(request, env, v);
        return json(dv);
      }
      if (oneMatch && method === "DELETE") {
        const denied = await ownerError(request, env);
        if (denied) return denied;
        const id = decodeURIComponent(oneMatch[1]);
        const ok = await deleteVideo(env, id);
        if (!ok) return json({ error: "not found" }, { status: 404 });
        return json({ deleted: id });
      }
      const appVideoMatch = pathname.match(/^\/app\/v\/([^/]+)$/);
      if (appVideoMatch && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const id = decodeURIComponent(appVideoMatch[1]);
        const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
        if (!row) return html(renderAppLocked("Recording not found."), 404);
        if (row.upload_status === "uploading") return html(renderUploading(rowToVideo(row)), 200, NO_STORE);
        if (row.upload_status === "failed") return html(renderUploadFailed(rowToVideo(row)), 503, NO_STORE);
        const v = rowToVideo(row);
        const dv = decorate(request, env, v);
        dv.mediaURL = await ownerMediaURL(request, env, v);
        const [counts, comments] = await Promise.all([reactionCounts(env, id), listComments(env, id)]);
        return html(renderPlayer(dv, {
          owner: true,
          counts,
          comments,
          flash: url.searchParams.get("flash") || "",
          error: url.searchParams.get("error") || ""
        }));
      }
      if (appVideoMatch && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const base = baseURL(request, env);
        const origin = request.headers.get("origin");
        if (origin && origin.replace(/\/$/, "") !== base) {
          return html(renderAppLocked("Request blocked (bad origin)."), 403);
        }
        const id = decodeURIComponent(appVideoMatch[1]);
        const form = await request.formData();
        const action = String(form.get("action") || "");
        let flash = "", error = "", gone = false;
        try {
          const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
          if (!row) throw new Error("Recording not found.");
          if (action === "enable" || action === "disable") {
            await setDisabled(env, id, action === "disable");
            flash = `Link ${action === "disable" ? "disabled" : "enabled"}.`;
          } else if (action === "delete") {
            await deleteVideo(env, id);
            gone = true;
            flash = "Recording deleted.";
          } else if (action === "delete-comment") {
            const ok = await deleteComment(env, id, String(form.get("commentId") || ""));
            flash = ok ? "Comment deleted." : "Comment not found.";
          } else if (action === "transcribe") {
            const { text } = await transcribeVideo(env, row, {});
            flash = `Transcribed (${wordCount(text)} words).`;
          } else if (action === "summarize") {
            const insight = await summarizeVideo(env, row);
            flash = `Summary generated${insight.title !== row.title ? ` and named \u201C${insight.title}\u201D` : ""}.`;
          } else if (action === "rename") {
            const title = cleanTitle(form.get("title"));
            if (!title) throw new Error("A title is required.");
            await updateTitle(env, id, title);
            flash = "Title updated.";
          } else if (action === "declutter") {
            await declutterVideo(env, row);
            flash = "Filler words removed.";
          } else {
            throw new Error("unknown action");
          }
        } catch (e) {
          error = String(e && e.message || e);
        }
        const q = error ? `?error=${encodeURIComponent(error)}` : flash ? `?flash=${encodeURIComponent(flash)}` : "";
        const dest = gone ? `${base}/app${q}` : `${base}/app/v/${encodeURIComponent(id)}${q}`;
        return Response.redirect(dest, 303);
      }
      if (pathname.startsWith("/app/file/") && (method === "GET" || method === "HEAD")) {
        const denied = await ownerError(request, env);
        if (denied) return new Response("unauthorized", { status: denied.status, headers: CORS });
        return await serveFile(decodeURIComponent(pathname.slice("/app/file/".length)), request, env, { ownerView: true });
      }
      if (pathname === "/app" && method === "GET") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const q = (url.searchParams.get("q") || "").trim();
        const rows = q ? await searchVideos(env, q) : (await env.DB.prepare("SELECT * FROM videos ORDER BY created_at DESC").all()).results || [];
        const videos = rows.map((r) => {
          const dv = decorate(request, env, rowToVideo(r));
          if (q) dv.snippet = transcriptSnippet(r.transcript, q);
          return dv;
        });
        return html(renderApp(videos, {
          base: baseURL(request, env),
          flash: url.searchParams.get("flash") || "",
          error: url.searchParams.get("error") || "",
          q
        }));
      }
      if (pathname === "/app" && method === "POST") {
        const denied = await ownerError(request, env);
        if (denied) return html(renderAppLocked(), denied.status);
        const base = baseURL(request, env);
        const origin = request.headers.get("origin");
        if (origin && origin.replace(/\/$/, "") !== base) {
          return html(renderAppLocked("Request blocked (bad origin)."), 403);
        }
        const form = await request.formData();
        const id = String(form.get("id") || "");
        const action = String(form.get("action") || "");
        let flash = "", error = "";
        try {
          if (!id) throw new Error("missing id");
          if (action === "enable" || action === "disable") {
            const ok = await setDisabled(env, id, action === "disable");
            flash = ok ? `Link ${action === "disable" ? "disabled" : "enabled"}.` : "Recording not found.";
          } else if (action === "delete") {
            flash = await deleteVideo(env, id) ? "Recording deleted." : "Recording not found.";
          } else if (action === "transcribe" || action === "summarize") {
            const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
            if (!row) throw new Error("Recording not found.");
            if (action === "transcribe") {
              const { text } = await transcribeVideo(env, row, {});
              flash = `Transcribed (${wordCount(text)} words).`;
            } else {
              const insight = await summarizeVideo(env, row);
              flash = `Summary generated${insight.title !== row.title ? ` and named \u201C${insight.title}\u201D` : ""}.`;
            }
          } else if (action === "rename") {
            const title = cleanTitle(form.get("title"));
            if (!title) throw new Error("A title is required.");
            const ok = await updateTitle(env, id, title);
            flash = ok ? "Title updated." : "Recording not found.";
          } else if (action === "declutter") {
            const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
            if (!row) throw new Error("Recording not found.");
            await declutterVideo(env, row);
            flash = "Filler words removed.";
          }
        } catch (e) {
          error = String(e && e.message || e);
        }
        const q = error ? `?error=${encodeURIComponent(error)}` : flash ? `?flash=${encodeURIComponent(flash)}` : "";
        return Response.redirect(`${base}/app${q}`, 303);
      }
      const reactMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/reactions$/);
      if (reactMatch && method === "POST") {
        return await handleReaction(decodeURIComponent(reactMatch[1]), request, env);
      }
      const addCommentMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/comments$/);
      if (addCommentMatch && method === "POST") {
        return await handleAddComment(decodeURIComponent(addCommentMatch[1]), request, env);
      }
      const delCommentMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/comments\/([^/]+)$/);
      if (delCommentMatch && method === "DELETE") {
        return await handleDeleteComment(
          decodeURIComponent(delCommentMatch[1]),
          decodeURIComponent(delCommentMatch[2]),
          request,
          env
        );
      }
      const engageMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/engagement$/);
      if (engageMatch && method === "GET") {
        return await handleEngagement(decodeURIComponent(engageMatch[1]), url, request, env);
      }
      const statusMatch = pathname.match(/^\/api\/public\/videos\/([^/]+)\/status$/);
      if (statusMatch && method === "GET") {
        const id = decodeURIComponent(statusMatch[1]);
        const row = await env.DB.prepare(
          "SELECT upload_status, disabled FROM videos WHERE id = ?"
        ).bind(id).first();
        if (!row) return json({ error: "not found" }, { status: 404, headers: NO_STORE });
        return json({ status: row.upload_status || "ready", disabled: !!row.disabled }, { headers: NO_STORE });
      }
      const vMatch = pathname.match(/^\/v\/([^/]+)$/);
      if (vMatch && method === "GET") {
        const sid = decodeURIComponent(vMatch[1]);
        const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(sid).first();
        if (!row) return html(renderIndex([], { notFound: sid }), 404);
        if (row.disabled) return html(renderDisabled(), 410, NO_STORE);
        if (row.upload_status === "uploading") return html(renderUploading(rowToVideo(row)), 200, NO_STORE);
        if (row.upload_status === "failed") return html(renderUploadFailed(rowToVideo(row)), 503, NO_STORE);
        const v = rowToVideo(row);
        const dv = decorate(request, env, v);
        dv.mediaURL = await resolveMediaURL(request, env, v);
        const [counts, comments] = await Promise.all([reactionCounts(env, sid), listComments(env, sid)]);
        return html(renderPlayer(dv, { counts, comments }));
      }
      if (pathname.startsWith("/file/") && (method === "GET" || method === "HEAD")) {
        return await serveFile(decodeURIComponent(pathname.slice("/file/".length)), request, env);
      }
      if (pathname === "/" && method === "GET") {
        return html(renderLanding());
      }
      if (pathname === "/download" && method === "GET") {
        return Response.redirect("https://github.com/maxig/cue/releases/latest/download/Cue.dmg", 302);
      }
      return json({ error: "not found" }, { status: 404 });
    } catch (err) {
      console.error(JSON.stringify({
        message: "unhandled request error",
        method,
        path: pathname,
        error: String(err && err.message || err)
      }));
      return json({ error: "internal server error" }, { status: 500 });
    }
  }
};
async function serveFile(key, request, env, opts = {}) {
  if (!key) return new Response("missing key", { status: 400, headers: CORS });
  const owner = await env.DB.prepare(
    "SELECT disabled, upload_status FROM videos WHERE object_key = ?1 OR audio_key = ?1"
  ).bind(key).first();
  if (!owner) return new Response("not found", { status: 404, headers: CORS });
  if ((owner.upload_status || "ready") !== "ready") {
    return new Response("upload not ready", { status: 425, headers: { ...CORS, "retry-after": "2" } });
  }
  if (!opts.ownerView && owner.disabled) return new Response("disabled", { status: 410, headers: CORS });
  if (request.method === "HEAD") {
    const head = await env.MEDIA.head(key);
    if (!head) return new Response(null, { status: 404, headers: CORS });
    const h = new Headers(CORS);
    head.writeHttpMetadata(h);
    h.set("etag", head.httpEtag);
    h.set("accept-ranges", "bytes");
    h.set("content-length", String(head.size));
    h.set("cache-control", "private, max-age=0, must-revalidate");
    return new Response(null, { status: 200, headers: h });
  }
  const range = request.headers.get("range");
  let object;
  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (!m || m[1] === "" && m[2] === "") {
      return new Response("invalid range", { status: 416, headers: CORS });
    }
    const start = m && m[1] !== "" ? Number(m[1]) : void 0;
    const end = m && m[2] !== "" ? Number(m[2]) : void 0;
    if (start !== void 0 && (!Number.isSafeInteger(start) || start < 0) || end !== void 0 && (!Number.isSafeInteger(end) || end < 0) || start !== void 0 && end !== void 0 && end < start || start === void 0 && end === 0) {
      return new Response("invalid range", { status: 416, headers: CORS });
    }
    let opts2;
    if (start !== void 0 && end !== void 0) opts2 = { range: { offset: start, length: end - start + 1 } };
    else if (start !== void 0) opts2 = { range: { offset: start } };
    else if (end !== void 0) opts2 = { range: { suffix: end } };
    object = await env.MEDIA.get(key, opts2);
  } else {
    object = await env.MEDIA.get(key);
  }
  if (!object) return new Response("not found", { status: 404, headers: CORS });
  const headers = new Headers(CORS);
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", "private, max-age=0, must-revalidate");
  if (object.range && typeof object.size === "number") {
    const offset = object.range.offset ?? 0;
    const length = object.range.length ?? object.size - offset;
    headers.set("content-range", `bytes ${offset}-${offset + length - 1}/${object.size}`);
    headers.set("content-length", String(length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(object.size));
  return new Response(object.body, { status: 200, headers });
}
function wordCount(text) {
  return text && text.trim() ? text.trim().split(/\s+/).length : 0;
}
async function runWhisper(env, key, lang) {
  const head = await env.MEDIA.head(key);
  if (!head) throw new Error(`object not found: ${key}`);
  if (head.size > MAX_TRANSCRIBE_BYTES) {
    throw new Error(`audio is ${(head.size / 1e6).toFixed(0)} MB; too large to transcribe in-Worker (limit 100 MB).`);
  }
  const object = await env.MEDIA.get(key);
  const audio = arrayBufferToBase64(await object.arrayBuffer());
  const input = { audio };
  if (lang) input.language = lang;
  const result = await env.AI.run("@cf/openai/whisper-large-v3-turbo", input);
  const text = result?.text || "";
  const vtt = Array.isArray(result?.segments) ? result.segments.map((s) => s.vtt).filter(Boolean).join("\n") || null : null;
  return { text, vtt };
}
async function transcribeVideo(env, row, { key, lang } = {}) {
  const objKey = key || row.audio_key || row.object_key;
  const { text, vtt } = await runWhisper(env, objKey, lang);
  const updatedAt = (/* @__PURE__ */ new Date()).toISOString();
  await env.DB.prepare("UPDATE videos SET transcript = ?, transcript_vtt = ?, transcript_updated_at = ? WHERE id = ?").bind(text, vtt, updatedAt, row.id).run();
  return { text, vtt, transcriptUpdatedAt: updatedAt };
}
async function transcribeHTTP(id, url, env) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404 });
  try {
    const { text, vtt, transcriptUpdatedAt } = await transcribeVideo(env, row, {
      key: url.searchParams.get("key") || void 0,
      lang: url.searchParams.get("lang") || void 0
    });
    return json({ id, text, word_count: wordCount(text), vtt, transcriptUpdatedAt });
  } catch (e) {
    return json({ error: String(e && e.message || e) }, { status: 500 });
  }
}
var SUMMARY_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    overview: { type: "string" },
    keyPoints: { type: "array", items: { type: "string" }, minItems: 2, maxItems: 5 },
    chapters: {
      type: "array",
      items: {
        type: "object",
        properties: {
          startSeconds: { type: "number", minimum: 0 },
          title: { type: "string" }
        },
        required: ["startSeconds", "title"]
      },
      maxItems: 8
    }
  },
  required: ["title", "overview", "keyPoints", "chapters"]
};
function structuredResponse(result) {
  const response = result?.response;
  if (response && typeof response === "object") return response;
  if (typeof response !== "string") return null;
  try {
    return JSON.parse(response);
  } catch {
    return null;
  }
}
function cleanChapters(items, durationSeconds, fallbackTitle) {
  const duration = Math.max(0, Number(durationSeconds) || 0);
  const chapters = (Array.isArray(items) ? items : []).map((chapter) => ({
    startSeconds: Math.max(0, Math.round(Number(chapter?.startSeconds) || 0)),
    title: cleanTitle(chapter?.title, 80)
  })).filter((chapter) => chapter.title && (!duration || chapter.startSeconds < duration)).sort((a, b) => a.startSeconds - b.startSeconds).filter((chapter, index, all) => index === 0 || chapter.startSeconds - all[index - 1].startSeconds >= 5).slice(0, 8);
  if (!chapters.length || chapters[0].startSeconds > 5) {
    chapters.unshift({ startSeconds: 0, title: cleanTitle(fallbackTitle, 80) || "Overview" });
  } else {
    chapters[0].startSeconds = 0;
  }
  return chapters;
}
function formatInsightSummary(insight) {
  const parts = [cleanTitle(insight.overview, 900)];
  const points = (Array.isArray(insight.keyPoints) ? insight.keyPoints : []).map((point) => cleanTitle(point, 220)).filter(Boolean).slice(0, 5);
  if (points.length) parts.push(`Key points:
${points.map((point) => `- ${point}`).join("\n")}`);
  if (insight.chapters.length) {
    parts.push(`Chapters:
${insight.chapters.map((chapter) => `- ${formatChapterTime(chapter.startSeconds)} \u2014 ${chapter.title}`).join("\n")}`);
  }
  return parts.filter(Boolean).join("\n\n");
}
async function summarizeVideo(env, row) {
  let transcript = row.transcript;
  let transcriptVtt = row.transcript_vtt;
  if (!transcript) {
    const { text, vtt } = await transcribeVideo(env, row, {});
    transcript = text;
    transcriptVtt = vtt;
  }
  if (!transcript || !transcript.trim()) {
    throw new Error("nothing to summarize \u2014 no transcript (is there audio in this recording?).");
  }
  const model = env.SUMMARY_MODEL || DEFAULT_SUMMARY_MODEL;
  const result = await env.AI.run(model, {
    messages: [
      {
        role: "system",
        content: "Create useful metadata for a screen-recording transcript. The title must be meaningful, specific, at most 8 words, and must not include quotes or generic labels like 'Video' or 'Recording'. Write a concise 2-3 sentence overview, 2-5 short key points, and 2-8 chapters. Chapter startSeconds must come from the supplied WebVTT timestamps; begin the first chapter at 0. If no timestamps are supplied, return one chapter at 0. Be factual and never invent details."
      },
      {
        role: "user",
        content: transcriptVtt ? `Timestamped transcript (WebVTT):

${transcriptVtt.slice(0, 16e3)}` : `Transcript:

${transcript.slice(0, 12e3)}`
      }
    ],
    response_format: { type: "json_schema", json_schema: SUMMARY_SCHEMA },
    max_tokens: 768
  });
  const value = structuredResponse(result);
  if (!value) throw new Error("the summary model returned invalid structured data.");
  const suggestedTitle = generatedTitle(value.title, row.title);
  let title = hasDefaultTitle(row.title) ? suggestedTitle : cleanTitle(row.title);
  const chapters = cleanChapters(value.chapters, row.duration_seconds, suggestedTitle);
  const summary = formatInsightSummary({
    overview: value.overview,
    keyPoints: value.keyPoints,
    chapters
  });
  if (!summary) throw new Error("the summary model returned no usable summary.");
  const summaryUpdatedAt = (/* @__PURE__ */ new Date()).toISOString();
  let titleUpdatedAt = row.title_updated_at || row.created_at || null;
  const db = env.DB.withSession("first-primary");
  await db.prepare("UPDATE videos SET summary = ?, summary_updated_at = ? WHERE id = ?").bind(summary, summaryUpdatedAt, row.id).run();
  if (title !== row.title) {
    const titleUpdate = await db.prepare(
      "UPDATE videos SET title = ?, title_updated_at = ? WHERE id = ? AND COALESCE(title_updated_at, created_at, '') = ?"
    ).bind(title, summaryUpdatedAt, row.id, titleUpdatedAt || "").run();
    if (titleUpdate.meta.changes) titleUpdatedAt = summaryUpdatedAt;
    const settled = await db.prepare("SELECT title, title_updated_at FROM videos WHERE id = ?").bind(row.id).first();
    title = settled?.title || title;
    titleUpdatedAt = settled?.title_updated_at || titleUpdatedAt;
  }
  return { title, summary, chapters, titleUpdatedAt, summaryUpdatedAt };
}
async function summarizeHTTP(id, env) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404 });
  try {
    const insight = await summarizeVideo(env, row);
    return json({ id, ...insight });
  } catch (e) {
    return json({ error: String(e && e.message || e) }, { status: 500 });
  }
}
function removeFillers(text) {
  if (!text || !text.trim()) return text;
  let t = ` ${text} `;
  t = t.replace(/\s+\b(?:um+|uh+|uhm|erm|er+|ah+|hmm+|hm|mhm|mm+)\b\s*,?/gi, " ");
  t = t.replace(/\s+\b(?:you know|i mean)\b\s*,?/gi, " ");
  t = t.replace(/\s{2,}/g, " ").replace(/\s+([,.!?;:])/g, "$1").replace(/,\s*([.!?;:])/g, "$1").replace(/,\s*,/g, ",").replace(/^[\s,;:]+/, "").trim();
  return t;
}
function cleanVttFillers(vtt) {
  if (!vtt) return vtt;
  return String(vtt).split(/\r?\n/).map((line) => {
    const t = line.trim();
    if (!t || t === "WEBVTT" || t.includes("-->") || /^NOTE\b/.test(t)) return line;
    return removeFillers(line);
  }).join("\n");
}
async function declutterVideo(env, row) {
  let transcript = row.transcript;
  let vtt = row.transcript_vtt;
  if (!transcript) {
    const r = await transcribeVideo(env, row, {});
    transcript = r.text;
    vtt = r.vtt;
  }
  if (!transcript || !transcript.trim()) {
    throw new Error("nothing to declutter \u2014 no transcript (is there audio in this recording?).");
  }
  const cleanText = removeFillers(transcript);
  const cleanVtt = cleanVttFillers(vtt);
  const updatedAt = (/* @__PURE__ */ new Date()).toISOString();
  await env.DB.prepare("UPDATE videos SET transcript = ?, transcript_vtt = ?, transcript_updated_at = ? WHERE id = ?").bind(cleanText, cleanVtt, updatedAt, row.id).run();
  return cleanText;
}
async function declutterHTTP(id, env) {
  const row = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404 });
  try {
    const text = await declutterVideo(env, row);
    return json({ id, text, word_count: wordCount(text) });
  } catch (e) {
    return json({ error: String(e && e.message || e) }, { status: 500 });
  }
}
async function updateTitle(env, id, title, proposedUpdatedAt) {
  const db = env.DB.withSession("first-primary");
  const row = await db.prepare("SELECT * FROM videos WHERE id = ?").bind(id).first();
  if (!row) return null;
  const updatedAt = normalizedTimestamp(proposedUpdatedAt, (/* @__PURE__ */ new Date()).toISOString());
  const res = await db.prepare(
    "UPDATE videos SET title = ?, title_updated_at = ? WHERE id = ? AND COALESCE(title_updated_at, created_at, '') < ?"
  ).bind(title, updatedAt, id, updatedAt).run();
  if (res.meta.changes) return { title, titleUpdatedAt: updatedAt };
  const settled = await db.prepare("SELECT title, title_updated_at, created_at FROM videos WHERE id = ?").bind(id).first();
  return {
    title: settled?.title || row.title,
    titleUpdatedAt: settled?.title_updated_at || settled?.created_at || row.title_updated_at || row.created_at || null
  };
}
async function setDisabled(env, id, disabled) {
  const res = await env.DB.prepare("UPDATE videos SET disabled = ? WHERE id = ?").bind(disabled ? 1 : 0, id).run();
  return !!res.meta.changes;
}
async function deleteVideo(env, id) {
  const row = await env.DB.prepare(
    "SELECT object_key, audio_key FROM videos WHERE id = ?"
  ).bind(id).first();
  if (!row) return false;
  await deleteObjects(env, row);
  await env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(id).run();
  await deleteEngagement(env, id);
  return true;
}
async function deleteObjects(env, row) {
  const keys = [row.object_key, row.audio_key].filter(Boolean);
  if (keys.length) await env.MEDIA.delete(keys);
}
async function deleteEngagement(env, id) {
  await env.DB.prepare("DELETE FROM comments WHERE video_id = ?").bind(id).run();
  await env.DB.prepare("DELETE FROM reactions WHERE video_id = ?").bind(id).run();
}
async function enforceStorageCap(env, keepId) {
  const cap = Number(env.MAX_BYTES) || DEFAULT_MAX_BYTES;
  const agg = await env.DB.prepare(
    "SELECT COALESCE(SUM(bytes), 0) AS total FROM videos WHERE upload_status = 'ready'"
  ).first();
  let total = Number(agg?.total || 0);
  if (total <= cap) return;
  const { results } = await env.DB.prepare(
    "SELECT id, object_key, audio_key, bytes FROM videos WHERE id != ? AND upload_status = 'ready' ORDER BY created_at ASC"
  ).bind(keepId).all();
  for (const row of results || []) {
    if (total <= cap) break;
    await deleteObjects(env, row);
    await env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(row.id).run();
    await deleteEngagement(env, row.id);
    total -= Number(row.bytes || 0);
  }
}
async function ownerMediaURL(request, env, video) {
  const cfg = presignConfig(env);
  if (cfg) return await presignedURL(cfg, video.objectKey);
  return `${baseURL(request, env)}/app/file/${video.objectKey}`;
}
async function enabledVideoError(env, id) {
  const row = await env.DB.prepare("SELECT disabled, upload_status FROM videos WHERE id = ?").bind(id).first();
  if (!row) return json({ error: "not found" }, { status: 404, headers: NO_STORE });
  if ((row.upload_status || "ready") !== "ready") {
    return json({ error: "upload not ready" }, { status: 425, headers: { ...NO_STORE, "retry-after": "2" } });
  }
  if (row.disabled) return json({ error: "link disabled" }, { status: 410, headers: NO_STORE });
  return null;
}
function cleanViewerId(v) {
  const s = String(v || "").trim();
  return /^[A-Za-z0-9_-]{1,64}$/.test(s) ? s : null;
}
async function reactionCounts(env, id) {
  const { results } = await env.DB.prepare(
    "SELECT emoji, COUNT(*) AS n FROM reactions WHERE video_id = ? GROUP BY emoji"
  ).bind(id).all();
  const counts = {};
  for (const r of results || []) counts[r.emoji] = Number(r.n) || 0;
  return counts;
}
async function viewerReactions(env, id, viewerId) {
  if (!viewerId) return [];
  const { results } = await env.DB.prepare(
    "SELECT emoji FROM reactions WHERE video_id = ? AND viewer_id = ?"
  ).bind(id, viewerId).all();
  return (results || []).map((r) => r.emoji);
}
async function listComments(env, id, limit = 500) {
  const { results } = await env.DB.prepare(
    "SELECT id, author, body, ts_seconds, created_at FROM comments WHERE video_id = ? ORDER BY created_at ASC LIMIT ?"
  ).bind(id, limit).all();
  return (results || []).map((r) => ({
    id: r.id,
    author: r.author,
    body: r.body,
    tsSeconds: r.ts_seconds == null ? null : Number(r.ts_seconds),
    createdAt: r.created_at
  }));
}
async function handleReaction(id, request, env) {
  const err = await enabledVideoError(env, id);
  if (err) return err;
  const body = await request.json().catch(() => ({}));
  const emoji = String(body.emoji || "");
  const viewerId = cleanViewerId(body.viewerId);
  if (!REACTIONS.includes(emoji)) return json({ error: "unsupported reaction" }, { status: 400, headers: NO_STORE });
  if (!viewerId) return json({ error: "missing viewerId" }, { status: 400, headers: NO_STORE });
  const existing = await env.DB.prepare(
    "SELECT id FROM reactions WHERE video_id = ? AND emoji = ? AND viewer_id = ?"
  ).bind(id, emoji, viewerId).first();
  if (existing) {
    await env.DB.prepare("DELETE FROM reactions WHERE id = ?").bind(existing.id).run();
  } else {
    await env.DB.prepare(
      "INSERT INTO reactions (id, video_id, emoji, viewer_id, created_at) VALUES (?, ?, ?, ?, ?)"
    ).bind(crypto.randomUUID(), id, emoji, viewerId, (/* @__PURE__ */ new Date()).toISOString()).run();
  }
  const [counts, mine] = await Promise.all([reactionCounts(env, id), viewerReactions(env, id, viewerId)]);
  return json({ counts, mine }, { headers: NO_STORE });
}
async function handleAddComment(id, request, env) {
  const err = await enabledVideoError(env, id);
  if (err) return err;
  const b = await request.json().catch(() => ({}));
  const author = String(b.author || "").trim().slice(0, 60) || "Anonymous";
  const text = String(b.body || "").trim().slice(0, 2e3);
  const viewerId = cleanViewerId(b.viewerId);
  let ts = Number(b.tsSeconds);
  ts = Number.isFinite(ts) && ts >= 0 ? ts : null;
  if (!text) return json({ error: "empty comment" }, { status: 400, headers: NO_STORE });
  const comment = {
    id: crypto.randomUUID(),
    author,
    body: text,
    tsSeconds: ts,
    createdAt: (/* @__PURE__ */ new Date()).toISOString()
  };
  await env.DB.prepare(
    "INSERT INTO comments (id, video_id, author, body, viewer_id, ts_seconds, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
  ).bind(comment.id, id, author, text, viewerId, ts, comment.createdAt).run();
  return json({ comment }, { headers: NO_STORE });
}
async function handleDeleteComment(id, cid, request, env) {
  const url = new URL(request.url);
  const viewerId = cleanViewerId(url.searchParams.get("viewer"));
  const row = await env.DB.prepare("SELECT viewer_id FROM comments WHERE id = ? AND video_id = ?").bind(cid, id).first();
  if (!row) return json({ error: "not found" }, { status: 404, headers: NO_STORE });
  const isOwner = !await ownerError(request, env);
  const isAuthor = !!(viewerId && row.viewer_id && await timingSafeEqual(viewerId, row.viewer_id));
  if (!isOwner && !isAuthor) return json({ error: "forbidden" }, { status: 403, headers: NO_STORE });
  await env.DB.prepare("DELETE FROM comments WHERE id = ?").bind(cid).run();
  return json({ deleted: cid }, { headers: NO_STORE });
}
async function handleEngagement(id, url, request, env) {
  const err = await enabledVideoError(env, id);
  if (err) return err;
  const viewerId = cleanViewerId(url.searchParams.get("viewer"));
  const [counts, mine, comments] = await Promise.all([
    reactionCounts(env, id),
    viewerReactions(env, id, viewerId),
    listComments(env, id)
  ]);
  return json({ counts, mine, comments }, { headers: NO_STORE });
}
async function deleteComment(env, id, cid) {
  if (!cid) return false;
  const res = await env.DB.prepare("DELETE FROM comments WHERE id = ? AND video_id = ?").bind(cid, id).run();
  return !!res.meta.changes;
}
async function searchVideos(env, q) {
  const like = `%${q.replace(/[\\%_]/g, "\\$&")}%`;
  const { results } = await env.DB.prepare(
    `SELECT * FROM videos
       WHERE title LIKE ?1 ESCAPE '\\'
          OR transcript LIKE ?1 ESCAPE '\\'
          OR summary LIKE ?1 ESCAPE '\\'
       ORDER BY created_at DESC`
  ).bind(like).all();
  return results || [];
}
function transcriptSnippet(transcript, q, radius = 80) {
  if (!transcript) return "";
  const i = transcript.toLowerCase().indexOf(q.toLowerCase());
  if (i === -1) return "";
  const start = Math.max(0, i - radius);
  const end = Math.min(transcript.length, i + q.length + radius);
  return (start > 0 ? "\u2026" : "") + transcript.slice(start, end).trim() + (end < transcript.length ? "\u2026" : "");
}
function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunk = 32768;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}
export {
  index_default as default
};
/*! Bundled license information:

aws4fetch/dist/aws4fetch.esm.mjs:
  (**
   * @license MIT <https://opensource.org/licenses/MIT>
   * @copyright Michael Hart 2024
   *)
*/
