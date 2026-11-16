// Claude Config Map — UI. Talks to the native app through window.webkit.messageHandlers.bridge.
(function () {
  'use strict';
  const $ = s => document.querySelector(s);
  const esc = window.escapeHTML;

  // ---------- bridge ----------
  const pending = {}; let seq = 0;
  const native = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge);
  window.__reply = (id, data) => { const f = pending[id]; delete pending[id]; if (f) f(data); };
  function call(cmd, args = {}) {
    if (!native) return Promise.resolve(null);
    return new Promise(res => { const id = ++seq; pending[id] = res; window.webkit.messageHandlers.bridge.postMessage(Object.assign({ id, cmd }, args)); });
  }

  // ---------- constants ----------
  const LEVELS = [
    { key: 'account', name: 'Account', desc: 'claude.ai: every app & device you sign in to' },
    { key: 'org', name: 'Organization', desc: 'Managed policy for everyone on this Mac' },
    { key: 'mac', name: 'This Mac', desc: 'Every Claude Code session, any folder' },
    { key: 'project', name: 'Project', desc: 'Sessions started in that folder' },
    { key: 'subfolder', name: 'Subfolder', desc: 'When Claude works with files there' },
  ];
  const LEVEL_NAME = { account: 'Account', org: 'Organization', mac: 'This Mac', project: 'Project', subfolder: 'Subfolder', folder: 'Parent folder', memory: 'Auto memory' };
  const KIND_LABEL = { 'claude-md': 'CLAUDE.md', 'claude-local': 'local notes', import: 'import', rule: 'rule', settings: 'settings', skill: 'skill', agent: 'agent', 'memory-index': 'memory index', memory: 'memory', notes: 'notes', 'account-item': 'account' };
  const KIND_ORDER = ['claude-md', 'import', 'claude-local', 'rule', 'memory-index', 'memory', 'skill', 'agent', 'settings', 'notes', 'account-item'];
  const LOAD_LABEL = { 'every-chat': 'every chat', description: 'description', 'on-demand': 'on demand', 'not-in-context': 'settings', 'not-loaded': 'not loaded', account: 'claude.ai' };
  const LOAD_LONG = {
    'every-chat': 'Loaded in every chat',
    description: 'Name + description in every chat; full text on demand',
    'on-demand': 'Loaded on demand',
    'not-in-context': 'Not sent to the model (configures Claude Code)',
    'not-loaded': 'Not loaded into chats',
    account: 'Managed on claude.ai',
  };
  const lc = l => `var(--c-${l || 'mac'})`;
  const fmtTok = n => n >= 10000 ? (n / 1000).toFixed(0) + 'k' : n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n);
  const fmtDate = s => { if (!s) return '—'; const d = new Date(s); return isNaN(d) ? s : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }); };
  const fmtSize = n => n == null ? '—' : n < 1024 ? n + ' B' : (n / 1024).toFixed(1) + ' KB';

  // ---------- state ----------
  const S = { data: null, view: 'map', sel: null, selScope: null, filter: '', stack: null, stackPath: null, raw: false,
              optEmpty: true, optOutside: false, collapsed: new Set(), layout: 'tree' };
  try { const l = localStorage.getItem('layout'); if (l === 'tree' || l === 'columns') S.layout = l; } catch (e) { /* storage unavailable */ }
  let scopeById = {}, filesByScope = {}, childrenOf = {}, fileById = {};

  function index() {
    scopeById = {}; filesByScope = {}; childrenOf = {}; fileById = {};
    for (const s of S.data.scopes) { scopeById[s.id] = s; filesByScope[s.id] = []; }
    for (const s of S.data.scopes) if (s.parent) (childrenOf[s.parent] = childrenOf[s.parent] || []).push(s.id);
    for (const f of S.data.files) { fileById[f.id] = f; (filesByScope[f.scope] = filesByScope[f.scope] || []).push(f); }
    for (const k in filesByScope) filesByScope[k].sort((a, b) => KIND_ORDER.indexOf(a.kind) - KIND_ORDER.indexOf(b.kind));
    for (const s of S.data.scopes) if (s.outside) S.collapsed.add(s.id);
  }
  const perChatOf = id => (filesByScope[id] || []).reduce((t, f) => t + (f.perChat || 0), 0);
  function descendants(id, out = new Set()) { out.add(id); for (const c of childrenOf[id] || []) descendants(c, out); return out; }
  function ancestorsOf(id, out = new Set()) { let s = scopeById[id]; while (s) { out.add(s.id); s = scopeById[s.parent]; } return out; }
  const hasFilesDeep = id => (filesByScope[id] || []).length > 0 || (childrenOf[id] || []).some(hasFilesDeep);
  function visible(s) {
    if (s.outside && !S.optOutside) return false;
    if (s.level === 'project' && !S.optEmpty && !hasFilesDeep(s.id)) return false;
    return true;
  }
  function matches(f) {
    if (!S.filter) return true;
    const q = S.filter.toLowerCase();
    return (f.name || '').toLowerCase().includes(q) || (f.display || '').toLowerCase().includes(q) || (f.content || '').toLowerCase().includes(q);
  }

  // ---------- load ----------
  async function refresh() {
    $('#mapStatus').textContent = 'Scanning…';
    const d = await call('scan');
    if (!d) { $('#map').innerHTML = '<div class="empty-state">Open this page through the Claude Config Map app.</div>'; $('#mapStatus').textContent = ''; return; }
    S.data = d; index();
    if (S.sel && !fileById[S.sel] && !String(S.sel).startsWith('stack:')) S.sel = null;
    if (S.selScope && !scopeById[S.selScope]) S.selScope = null;
    renderRoots(); renderMap(); fillStackPick(); renderDetail();
    if (S.view === 'stack' && S.stackPath) loadStack(S.stackPath);
    const outside = d.scopes.filter(s => s.outside).length;
    $('#mapStatus').textContent = `Scanned ${new Date(d.scannedAt).toLocaleTimeString()} · ${d.files.length} files` + (outside && !S.optOutside ? ` · ${outside} memory folder(s) outside your scan folders hidden` : '');
  }

  // ---------- map ----------
  function chipHTML(f) {
    let badge;
    if (f.perChat > 0) badge = `<span class="badge cost" title="${esc(LOAD_LONG[f.load])}">~${fmtTok(f.perChat)}</span>`;
    else if (f.load === 'account') badge = '';
    else badge = `<span class="ld ld-${f.load}">${LOAD_LABEL[f.load] || f.load}</span>`;
    const name = f.kind === 'import' ? `<span class="imp">↳ ${esc(f.name)}</span>` : esc(f.name);
    const cls = ['chip', S.sel === f.id ? 'sel' : '', matches(f) ? '' : 'dim'].join(' ');
    return `<div class="${cls}" data-file="${esc(f.id)}" title="${esc(f.display || '')}"><span class="n">${f.kind === 'account-item' ? '' : `<span class="k">${KIND_LABEL[f.kind] || f.kind}</span>`}${name}</span>${badge}</div>`;
  }

  function cardHTML(s, hl) {
    const files = filesByScope[s.id] || [];
    const pc = perChatOf(s.id);
    const lvl = s.level;
    const collapsed = S.collapsed.has(s.id);
    const dim = (hl && !hl.has(s.id)) || (S.filter && files.length && !files.some(matches)) || (S.filter && !files.length);
    const cls = ['card', collapsed ? 'collapsed' : '', S.selScope === s.id ? 'sel' : '', dim ? 'dim' : '', s.outside ? 'outside' : ''].join(' ');
    let sub = s.display || '';
    if (s.outside) sub = s.missing ? s.encoded : sub + ' · not in scan folders';
    let body;
    if (files.length) body = `<div class="chips">${files.map(chipHTML).join('')}</div>`;
    else if (s.level === 'account') body = `<div class="empty-note">${esc(s.note || '')}</div>`;
    else if (s.level === 'org') body = `<div class="empty-note">No managed policy on this Mac.</div>`;
    else body = `<div class="empty-note">No Claude files here. Inherits everything to the left.</div>`;
    return `<div class="${cls}" data-scope="${esc(s.id)}" style="--lc:${lc(lvl === 'project' && s.folder ? 'folder' : lvl)}">
      <div class="card-h"><span class="caret">▼</span><div class="grow"><div class="ttl">${esc(s.label)}</div>${sub ? `<div class="sub">${esc(sub)}</div>` : ''}</div>
      ${pc ? `<span class="badge cost" title="Estimated tokens these files add to every chat">~${fmtTok(pc)}/chat</span>` : `<span class="badge">${files.length}</span>`}</div>
      ${body}</div>`;
  }

  function highlightSet() {
    if (S.sel && fileById[S.sel]) return descendants(fileById[S.sel].scope); // what this file applies to
    if (S.selScope) return ancestorsOf(S.selScope);                        // what affects this folder
    return null;
  }

  function renderMap() {
    if (!S.data) return;
    const hl = highlightSet();
    const map = $('#map');
    map.classList.toggle('tree', S.layout === 'tree');
    document.querySelectorAll('.layout-toggle button').forEach(b => b.classList.toggle('active', b.dataset.layout === S.layout));
    map.innerHTML = (S.layout === 'tree' ? treeHTML(hl) : columnsHTML(hl)) + '<svg class="links"></svg>';
    map.style.setProperty('--subcol', S.data.scopes.some(s => s.level === 'subfolder') ? 'minmax(200px, 1fr)' : 'minmax(130px, .5fr)');
    requestAnimationFrame(drawLinks);
  }

  const projectSort = (a, b) => (!!a.outside - !!b.outside) || (!a.folder - !b.folder) || a.label.localeCompare(b.label);

  // Left-to-right: one column per level.
  function columnsHTML(hl) {
    return LEVELS.map(L => {
      let scopes = S.data.scopes.filter(s => s.level === L.key && visible(s));
      if (L.key === 'project') scopes.sort(projectSort);
      if (L.key === 'subfolder') { // keep subfolders roughly in their project's order
        const order = S.data.scopes.filter(s => s.level === 'project').map(s => s.id);
        const top = s => { let x = s; while (x && x.level === 'subfolder') x = scopeById[x.parent]; return x ? order.indexOf(x.id) : 0; };
        scopes.sort((a, b) => top(a) - top(b));
      }
      return `<div class="col" data-level="${L.key}"><div class="col-head"><div class="t"><span class="dot" style="background:${lc(L.key)}"></span>${L.name}</div><div class="d">${L.desc}</div></div>
        ${scopes.map(s => cardHTML(s, hl)).join('') || (L.key === 'subfolder' ? '<div class="empty-note">No nested CLAUDE.md or .claude folders in subfolders.</div>' : '')}</div>`;
    }).join('');
  }

  // Top-down: one row per level; subfolders nest under their project.
  function treeHTML(hl) {
    const head = (key, name, desc) => `<div class="tier-head"><span class="dot" style="background:${lc(key)}"></span><strong>${name}</strong><span class="muted">${desc}</span></div>`;
    const tier = (key, name, desc, inner) => `<div class="tier" data-level="${key}">${head(key, name, desc)}${inner}</div>`;
    let html = ['account', 'org', 'mac'].map(k => {
      const L = LEVELS.find(x => x.key === k);
      return tier(k, L.name, L.desc, `<div class="tier-cards">${S.data.scopes.filter(s => s.level === k).map(s => cardHTML(s, hl)).join('')}</div>`);
    }).join('');
    const folders = S.data.scopes.filter(s => s.folder && visible(s));
    if (folders.length) html += tier('folder', 'Parent folders', 'A CLAUDE.md here applies to every project inside', `<div class="tier-cards">${folders.map(s => cardHTML(s, hl)).join('')}</div>`);
    const subs = id => (childrenOf[id] || []).map(c => scopeById[c]).filter(s => s.level === 'subfolder')
      .map(s => `<div class="sub">${cardHTML(s, hl)}${subs(s.id)}</div>`).join('');
    const projects = S.data.scopes.filter(s => s.level === 'project' && !s.folder && visible(s)).sort(projectSort);
    const grid = projects.map(p => { const k = subs(p.id); return `<div class="pgroup">${cardHTML(p, hl)}${k ? `<div class="subs">${k}</div>` : ''}</div>`; }).join('');
    html += tier('project', 'Projects', 'Sessions started in that folder. Subfolders (loaded when Claude works there) sit under their project.',
      `<div class="pgrid">${grid || '<div class="empty-note">No projects yet. Add a scan folder.</div>'}</div>`);
    return html;
  }

  function drawLinks() {
    const map = $('#map'), svg = map.querySelector('svg.links');
    if (!svg) return;
    const mr = map.getBoundingClientRect();
    const hl = highlightSet();
    const tree = S.layout === 'tree';
    const pos = {};
    map.querySelectorAll('.card').forEach(c => {
      const r = c.getBoundingClientRect();
      pos[c.dataset.scope] = { l: r.left - mr.left, r: r.right - mr.left, t: r.top - mr.top, b: r.bottom - mr.top, cx: (r.left + r.right) / 2 - mr.left, y: r.top - mr.top + 19 };
    });
    let paths = '';
    for (const s of S.data.scopes) {
      const a = pos[s.parent], b = pos[s.id];
      if (!a || !b) continue;
      const on = hl ? (hl.has(s.id) && hl.has(s.parent)) : true;
      const col = lc(s.level === 'project' && s.folder ? 'folder' : s.level);
      let d, dot;
      if (tree && s.level === 'subfolder') { // elbow from the parent's left edge down into the nested card
        const x = a.l + 11;
        d = `M${x},${a.b} L${x},${b.y - 8} Q${x},${b.y} ${x + 8},${b.y} L${b.l},${b.y}`; dot = [b.l, b.y];
      } else if (tree) {
        const my = (a.b + b.t) / 2;
        d = `M${a.cx},${a.b} C${a.cx},${my} ${b.cx},${my} ${b.cx},${b.t}`; dot = [b.cx, b.t];
      } else if (Math.abs(a.l - b.l) < 5) {
        const x = a.l - 2; d = `M${x},${a.y} C${x - 26},${a.y} ${x - 26},${b.y} ${x},${b.y}`; dot = [x, b.y];
      } else {
        const x1 = a.r, x2 = b.l, mx = (x1 + x2) / 2; d = `M${x1},${a.y} C${mx},${a.y} ${mx},${b.y} ${x2},${b.y}`; dot = [x2, b.y];
      }
      paths += `<path d="${d}" fill="none" stroke="${col}" stroke-width="${hl && on ? 2.2 : 1.4}" stroke-opacity="${hl ? (on ? 0.9 : 0.12) : 0.45}"/>`;
      if (!hl || on) paths += `<circle cx="${dot[0]}" cy="${dot[1]}" r="3" fill="${col}" fill-opacity="${hl ? 0.9 : 0.6}"/>`;
    }
    svg.setAttribute('width', map.scrollWidth); svg.setAttribute('height', map.scrollHeight);
    svg.innerHTML = paths;
  }

  // ---------- detail ----------
  function fileDetailHTML(f) {
    const lvl = f.level === 'project' && scopeById[f.scope] && scopeById[f.scope].folder ? 'folder' : f.level;
    let content;
    if (S.raw || f.format !== 'md') {
      let txt = f.content || '';
      if (f.format === 'json' && !S.raw) { try { txt = JSON.stringify(JSON.parse(txt), null, 2); } catch (e) { /* keep raw */ } }
      content = `<pre class="raw">${esc(txt) || '<span class="muted">(empty file)</span>'}</pre>`;
    } else content = `<div class="md">${window.renderMarkdown(f.content || '') || '<p class="muted">(empty file)</p>'}</div>`;
    const tokens = f.perChat > 0
      ? `<strong>~${fmtTok(f.perChat)} tokens per chat</strong>` + (f.tokens !== f.perChat ? ` <span class="muted">(whole file ~${fmtTok(f.tokens)})</span>` : '')
      : `~${fmtTok(f.tokens || 0)} tokens <span class="muted">when loaded</span>`;
    return `<div style="--lc:${lc(lvl)}">
      <div class="lvl"><span class="dot" style="background:${lc(lvl)}"></span>${LEVEL_NAME[lvl] || lvl} · ${KIND_LABEL[f.kind] || f.kind}</div>
      <h2>${esc(f.name)}</h2>
      <span class="ld ld-${f.load}">${LOAD_LONG[f.load] || f.load}</span>
      <dl class="kv">
        <dt>Full path</dt><dd><div class="path">${esc(f.path || '')}</div>
          <div class="actions"><button class="btn small" data-act="reveal">Show in Finder</button><button class="btn small" data-act="copy">Copy path</button></div></dd>
        <dt>Applies to</dt><dd>${esc(f.appliesTo || '—')}</dd>
        ${f.why ? `<dt>Why it's here</dt><dd>${esc(f.why)}</dd>` : ''}
        <dt>Token estimate</dt><dd>${tokens}<div class="muted small">${(f.words || 0).toLocaleString()} words ÷ 0.75</div></dd>
        <dt>Last modified</dt><dd>${fmtDate(f.modified)}</dd>
        <dt>Size</dt><dd>${fmtSize(f.size)}${f.truncated ? ' <span class="muted">(showing first 200 KB)</span>' : ''}</dd>
      </dl>
      ${f.note ? `<div class="note">${window.renderMarkdown(f.note).replace(/^<p>|<\/p>$/g, '')}</div>` : ''}
      <div class="content-head"><h3>Contents</h3>${f.format === 'md' ? `<button class="btn small" data-act="raw">${S.raw ? 'Rendered' : 'Raw'}</button>` : ''}</div>
      ${content}</div>`;
  }

  function scopeDetailHTML(s) {
    const files = filesByScope[s.id] || [];
    const lvl = s.level === 'project' && s.folder ? 'folder' : s.level;
    const canStack = s.path && ['project', 'subfolder'].includes(s.level) && !s.missing;
    return `<div style="--lc:${lc(lvl)}">
      <div class="lvl"><span class="dot" style="background:${lc(lvl)}"></span>${LEVEL_NAME[lvl]}</div>
      <h2>${esc(s.label)}</h2>
      <dl class="kv">
        ${s.path ? `<dt>Folder</dt><dd><div class="path">${esc(s.path)}</div></dd>` : ''}
        <dt>Applies to</dt><dd>${esc(s.appliesTo || '—')}</dd>
        <dt>Adds per chat</dt><dd><strong>~${fmtTok(perChatOf(s.id))} tokens</strong> <span class="muted">from this level's files</span></dd>
      </dl>
      ${s.note ? `<div class="note">${esc(s.note)}</div>` : ''}
      ${s.outside ? `<div class="note">This folder has Claude auto memory but isn't inside your scan folders${s.missing ? ', and it no longer exists on disk' : ''}.</div>` : ''}
      ${canStack ? `<button class="btn primary" data-act="stack" data-path="${esc(s.path)}">What applies here? →</button>` : ''}
      <div class="content-head"><h3>Files at this level (${files.length})</h3></div>
      <div class="chips" style="padding:0">${files.map(chipHTML).join('') || '<div class="muted">None. Sessions here get only the levels to the left.</div>'}</div>
      <p class="muted small" style="margin-top:14px">Highlighted on the map: this folder and every level that affects it.</p></div>`;
  }

  function overviewHTML() {
    const d = S.data;
    if (!d) return '<p class="muted">Loading…</p>';
    const projects = d.scopes.filter(s => s.level === 'project' && !s.outside && !s.folder).length;
    const base = ['org', 'mac'].reduce((t, id) => t + perChatOf(id), 0);
    const loadKeys = ['every-chat', 'description', 'on-demand', 'not-in-context', 'not-loaded'];
    return `<h2>Overview</h2>
      <p class="muted">Every Claude Code instruction and config file found on this Mac, by level. Click a file to see what it applies to, or a folder to see what affects it.</p>
      <div class="stats">
        <div class="stat"><div class="v">~${fmtTok(base)}</div><div class="l">tokens every session pays, in any folder (org + this Mac)</div></div>
        <div class="stat"><div class="v">${projects}</div><div class="l">projects in ${d.roots.length} scan folder${d.roots.length === 1 ? '' : 's'}</div></div>
        <div class="stat"><div class="v">${d.files.length}</div><div class="l">files and items found</div></div>
        <div class="stat"><div class="v">${d.files.filter(f => f.perChat > 0).length}</div><div class="l">add tokens to every chat somewhere</div></div>
      </div>
      <div class="content-head"><h3>How files load</h3></div>
      <div class="legend">${loadKeys.map(k => `<div><span class="ld ld-${k}">${LOAD_LABEL[k]}</span><span>${LOAD_LONG[k]}</span></div>`).join('')}</div>
      <div class="content-head"><h3>Levels (widest → narrowest)</h3></div>
      <div class="legend">${LEVELS.map(L => `<div><span class="dot" style="background:${lc(L.key)}"></span><span><strong>${L.name}</strong>: ${L.desc}</span></div>`).join('')}</div>
      <p class="footnote">Token estimates are words ÷ 0.75. They don't include Claude Code's own system prompt, tool definitions, MCP servers, or account-level skills. Nothing is ever written to the files shown here.</p>`;
  }

  function currentFile() {
    if (!S.sel) return null;
    if (S.sel.startsWith('stack:') && S.stack) {
      const [, list, i] = S.sel.split(':');
      return (S.stack[list] || [])[+i] || null;
    }
    return fileById[S.sel] || null;
  }

  function renderDetail() {
    const f = currentFile();
    const el = $('#detail');
    if (f) el.innerHTML = fileDetailHTML(f);
    else if (S.selScope && scopeById[S.selScope]) el.innerHTML = scopeDetailHTML(scopeById[S.selScope]);
    else el.innerHTML = overviewHTML();
  }

  // ---------- stack view ----------
  function fillStackPick() {
    const sel = $('#stackPick');
    const opts = S.data.scopes.filter(s => s.path && ['project', 'subfolder'].includes(s.level) && !s.missing && (!s.outside || S.optOutside));
    sel.innerHTML = '<option value="">Pick a scanned folder…</option>' + opts.map(s => `<option value="${esc(s.path)}">${esc(s.display)}</option>`).join('');
    if (S.stackPath) sel.value = S.stackPath;
  }

  async function loadStack(path) {
    S.stackPath = path;
    $('#stackFolder').textContent = '…';
    const st = await call('stack', { path });
    if (!st) return;
    S.stack = st;
    $('#stackPick').value = st.folder;
    if (S.sel && S.sel.startsWith('stack:')) S.sel = null;
    renderStack(); renderDetail();
  }

  function rowLevel(f) { return f.level === 'memory' ? 'memory' : f.level; }
  function rowsHTML(list, key, numbered, tokFn) {
    if (!list.length) return '<div class="muted">None.</div>';
    return `<div class="rows">${list.map((f, i) => `
      <div class="row ${S.sel === `stack:${key}:${i}` ? 'sel' : ''}" data-stack="stack:${key}:${i}" style="--lc:${lc(rowLevel(f))}">
        <div class="num">${numbered ? i + 1 : ''}</div>
        <div><div><span class="nm">${esc(f.kind === 'skill' || f.kind === 'agent' ? f.name : f.name)}</span> <span class="ld ld-${f.load}">${LOAD_LABEL[f.load]}</span> <span class="muted small">${LEVEL_NAME[rowLevel(f)] || ''}</span></div>
          <div class="why">${esc(f.why || f.appliesTo || '')}</div><div class="p">${esc(f.display || f.path)}</div></div>
        <div class="tk">${tokFn(f)}</div></div>`).join('')}</div>`;
  }

  function renderStack() {
    const st = S.stack;
    $('#stackFolder').textContent = st.display;
    const total = st.totalPerChat || 0;
    const bar = st.everyChat.filter(f => f.perChat > 0).map(f =>
      `<span style="width:${(100 * f.perChat / Math.max(total, 1)).toFixed(2)}%;background:${lc(rowLevel(f))}" title="${esc(f.name)}: ~${f.perChat} tokens"></span>`).join('');
    $('#stackBody').innerHTML = `
      <div class="total"><span class="v">~${fmtTok(total)}</span><span class="muted">tokens loaded at the start of every chat here, from ${st.everyChat.length} file${st.everyChat.length === 1 ? '' : 's'}</span></div>
      ${st.gitRoot ? `<div class="muted small">Git project root: ${esc(st.gitRoot)}</div>` : ''}
      <div class="bar">${bar}</div>
      <div class="sec"><h3>1 · Loaded at the start of every chat</h3><span class="muted small">in load order: broadest first, closest folder last</span></div>
      ${rowsHTML(st.everyChat, 'everyChat', true, f => `~${fmtTok(f.perChat)}`)}
      <div class="sec"><h3>2 · Loaded on demand</h3><span class="muted small">only when Claude works in a subfolder, uses a skill, or reads a memory topic</span></div>
      ${rowsHTML(st.onDemand, 'onDemand', false, f => `<span class="muted">~${fmtTok(f.tokens)} if loaded</span>`)}
      <div class="sec"><h3>3 · Settings</h3><span class="muted small">configure Claude Code (permissions, model, hooks); not sent to the model. Lowest → highest priority.</span></div>
      ${rowsHTML(st.settings, 'settings', true, () => '<span class="muted">0</span>')}
      <p class="footnote">Estimates are words ÷ 0.75. Not included: Claude Code's own system prompt and tools, MCP servers, plugins, and skills enabled on your claude.ai account. The auto memory index counts only the first 200 lines / 25 KB, the part that loads at startup.</p>`;
  }

  // ---------- roots popover ----------
  function renderRoots() {
    const d = S.data;
    $('#rootsBtn').textContent = `Scan folders (${d.roots.length})`;
    $('#rootsPop').innerHTML = `<h4>Scan folders</h4><p class="muted small" style="margin:0 0 8px">Projects inside these folders appear on the map. Read-only: nothing in them is ever changed.</p>
      ${d.roots.map((r, i) => `<div class="root-row"><span title="${esc(r)}">${esc(d.rootsDisplay[i])}</span><button data-remove="${esc(r)}" title="Remove">✕</button></div>`).join('') || '<div class="muted">No scan folders yet.</div>'}
      <div class="actions" style="margin-top:10px"><button class="btn primary small" id="addRoot">Add folder…</button></div>`;
  }

  // ---------- events ----------
  function setView(v) {
    S.view = v;
    document.querySelectorAll('.tabs button').forEach(b => b.classList.toggle('active', b.dataset.view === v));
    $('#mapView').hidden = v !== 'map'; $('#stackView').hidden = v !== 'stack';
    if (v === 'stack' && !S.stackPath && S.data) {
      const first = S.data.scopes.find(s => s.level === 'project' && s.path && !s.outside && !s.folder);
      if (first) loadStack(first.path);
    }
    if (v === 'map') requestAnimationFrame(drawLinks);
  }

  document.addEventListener('click', async e => {
    const t = e.target;
    const tab = t.closest('.tabs button'); if (tab) return setView(tab.dataset.view);
    const lay = t.closest('.layout-toggle button');
    if (lay) { S.layout = lay.dataset.layout; try { localStorage.setItem('layout', S.layout); } catch (e) { /* ignore */ } renderMap(); return; }
    if (t.closest('#rootsBtn')) { $('#rootsPop').hidden = !$('#rootsPop').hidden; return; }
    if (t.closest('#addRoot')) { $('#rootsPop').hidden = true; if (await call('addRoot')) refresh(); return; }
    const rm = t.closest('[data-remove]'); if (rm) { await call('removeRoot', { path: rm.dataset.remove }); refresh(); return; }
    if (!t.closest('#rootsPop')) $('#rootsPop').hidden = true;
    if (t.closest('#refreshBtn')) return refresh();
    if (t.closest('#stackChoose')) { const p = await call('pickFolder'); if (p) loadStack(p); return; }
    const act = t.closest('[data-act]');
    if (act) {
      const f = currentFile();
      if (act.dataset.act === 'reveal' && f) call('reveal', { path: f.path });
      if (act.dataset.act === 'copy' && f) { call('copy', { text: f.path }); act.textContent = 'Copied'; setTimeout(() => act.textContent = 'Copy path', 1200); }
      if (act.dataset.act === 'raw') { S.raw = !S.raw; renderDetail(); }
      if (act.dataset.act === 'stack') { setView('stack'); loadStack(act.dataset.path); }
      return;
    }
    const chip = t.closest('.chip');
    if (chip) { S.sel = S.sel === chip.dataset.file ? null : chip.dataset.file; S.selScope = null; S.raw = false; renderMap(); renderDetail(); return; }
    const caret = t.closest('.caret');
    if (caret) { const id = caret.closest('.card').dataset.scope; S.collapsed.has(id) ? S.collapsed.delete(id) : S.collapsed.add(id); renderMap(); return; }
    const card = t.closest('.card-h');
    if (card) { const id = card.closest('.card').dataset.scope; S.selScope = S.selScope === id ? null : id; S.sel = null; renderMap(); renderDetail(); return; }
    const row = t.closest('.row');
    if (row) { S.sel = row.dataset.stack; S.raw = false; renderStack(); renderDetail(); return; }
    if (t.closest('.map') && !t.closest('.card')) { S.sel = null; S.selScope = null; renderMap(); renderDetail(); }
  });
  $('#search').addEventListener('input', e => { S.filter = e.target.value.trim(); renderMap(); });
  $('#optEmpty').addEventListener('change', e => { S.optEmpty = e.target.checked; renderMap(); });
  $('#optOutside').addEventListener('change', e => { S.optOutside = e.target.checked; renderMap(); fillStackPick(); refreshStatus(); });
  $('#stackPick').addEventListener('change', e => { if (e.target.value) loadStack(e.target.value); });
  window.addEventListener('resize', () => requestAnimationFrame(drawLinks));
  document.addEventListener('keydown', e => { if (e.key === 'Escape') { S.sel = null; S.selScope = null; renderMap(); renderDetail(); } });
  function refreshStatus() {
    const outside = S.data.scopes.filter(s => s.outside).length;
    $('#mapStatus').textContent = `Scanned ${new Date(S.data.scannedAt).toLocaleTimeString()} · ${S.data.files.length} files` + (outside && !S.optOutside ? ` · ${outside} memory folder(s) outside your scan folders hidden` : '');
  }

  // Hooks for the native menu and for README screenshots
  window.__refresh = refresh;
  window.__focusSearch = () => { setView('map'); $('#search').focus(); };
  window.__setup = async (o = {}) => {
    if (o.layout) { S.layout = o.layout; renderMap(); }
    if (o.optOutside) { S.optOutside = true; $('#optOutside').checked = true; renderMap(); }
    if (o.selectFile) { const f = S.data.files.find(x => x.display === o.selectFile || x.id === o.selectFile); if (f) { S.sel = f.id; renderMap(); renderDetail(); } }
    if (o.selectScope) { const s = S.data.scopes.find(x => x.label === o.selectScope); if (s) { S.selScope = s.id; renderMap(); renderDetail(); } }
    if (o.view === 'stack') { setView('stack'); await loadStack(o.stackPath); if (o.stackRow != null) { S.sel = `stack:everyChat:${o.stackRow}`; renderStack(); renderDetail(); } }
    return true;
  };

  refresh();
})();
