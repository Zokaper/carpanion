// Horizon Party: the guests' page. Talks to the car (Horizon on the driver's phone) through the relay, protocol 2
// (see server.js). Everything shown comes from the car's `state`; every request carries an id and only the answer to
// the newest one counts, so a slow answer never replaces a newer one.
'use strict';

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

const $ = (id) => document.getElementById(id);
const store = {
  get(k) { try { return localStorage.getItem('party.' + k) || ''; } catch { return ''; } },
  set(k, v) { try { localStorage.setItem('party.' + k, v); } catch { /* private mode: the page still works */ } },
};
// The share target (a song shared from another app) is a plain form post: the relay reads who and where from cookies.
function cookie(k, v) { document.cookie = `${k}=${encodeURIComponent(v)}; path=/; max-age=${30 * 86400}; samesite=lax`; }

const CODE = /^[A-Z2-9]{6}$/;
const params = new URLSearchParams(location.search);
let code = (params.get('session') || store.get('session')).toUpperCase();
let name = store.get('name');
const guestId = store.get('guestId') || (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2));
store.set('guestId', guestId);
cookie('guestId', guestId);
const sharedResult = params.get('shared');
if (params.has('session') || params.has('shared')) history.replaceState(null, '', location.pathname);

// --- Little helpers ----------------------------------------------------------------------------------------------

function el(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === 'class') e.className = v;
    else if (k === 'text') e.textContent = v;
    else if (k === 'style') e.style.cssText = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat()) if (c != null && c !== false) e.append(c);
  return e;
}

const PATHS = {
  plus: '<path d="M12 5v14M5 12h14"/>',
  chev: '<path d="M9 18l6-6-6-6"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  grip: '<circle cx="9" cy="6" r="1"/><circle cx="15" cy="6" r="1"/><circle cx="9" cy="12" r="1"/><circle cx="15" cy="12" r="1"/><circle cx="9" cy="18" r="1"/><circle cx="15" cy="18" r="1"/>',
  play: '<path d="M8 5v14l11-7z"/>',
  pause: '<path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z"/>',
};
function icon(name, cls) {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  s.setAttribute('aria-hidden', 'true');
  if (cls) s.setAttribute('class', cls);
  s.innerHTML = PATHS[name];
  return s;
}

function img(src, cls) {
  const i = el('img', { class: cls, alt: '', loading: 'lazy' });
  if (src) i.src = src;
  return i;
}

function setSrc(i, src) { if (src) { if (i.getAttribute('src') !== src) i.src = src; } else i.removeAttribute('src'); }

function clock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function songs(n) { return n === 1 ? '1 song' : `${n} songs`; }

// The same colour for a name as on the driver's Party tab (Java's String.hashCode, then one of six).
const DARK = ['#F49AC1', '#FFB86B', '#7BE6A8', '#8AB4FF', '#E0A6FF', '#FFD166'];
const LIGHT = ['#B0306A', '#A85A00', '#1E7A4C', '#2F5BD3', '#7E3FB8', '#8A6A00'];
const lightMode = matchMedia('(prefers-color-scheme: light)');
function colorOf(by, mine) {
  if (mine) return 'var(--accent)';
  let h = 0;
  const s = by.toLowerCase();
  for (let i = 0; i < s.length; i++) h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
  return (lightMode.matches ? LIGHT : DARK)[((h % 6) + 6) % 6];
}

function byLine(item, extra) {
  const mine = item.guestId === guestId;
  const parts = [];
  if (item.by) parts.push(el('b', { text: mine ? 'You' : item.by, style: `color:${colorOf(item.by, mine)}` }), ' · ');
  parts.push(extra);
  return parts;
}

let toastTimer;
function toast(text, kind) {
  const t = $('toast');
  t.textContent = text;
  t.className = 'toast' + (kind ? ' ' + kind : '');
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 4000);
}

// --- Screens -------------------------------------------------------------------------------------------------------

function show(id) { for (const s of ['join', 'closed', 'party']) $(s).hidden = s !== id; }

function showJoin(message) {
  $('codeInput').value = code;
  $('nameInput').value = name;
  $('joinError').hidden = !message;
  $('joinError').textContent = message || '';
  show('join');
  (code ? $('nameInput') : $('codeInput')).focus();
}

$('joinForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const c = $('codeInput').value.trim().toUpperCase();
  const n = $('nameInput').value.trim().slice(0, 24);
  if (!CODE.test(c)) { showJoin('The code is 6 letters and numbers, on the driver\'s Party screen.'); return; }
  if (!n) { showJoin('Add your name, so everyone knows whose song is whose.'); $('nameInput').focus(); return; }
  code = c; name = n;
  store.set('session', code); store.set('name', name);
  cookie('session', code); cookie('name', name);
  enterParty();
});

const CLOSED = {
  ended: ['The party\'s over', 'Thanks for the songs. The ones you added still play.', 'Join another party'],
  new_code: ['The driver started a new code', 'This link no longer reaches the car. Scan the new QR code on the driver\'s Party screen, or type the new code.', 'Type the new code'],
  unknown: ['That code isn\'t a party', 'Check the code on the driver\'s Party screen and try again.', 'Type the code'],
};
function closed(reason) {
  const [title, text, button] = CLOSED[reason] || CLOSED.unknown;
  $('closedCode').textContent = 'CODE ' + code;
  $('closedTitle').textContent = title;
  $('closedText').textContent = text;
  $('closedJoin').textContent = button;
  state = null;
  show('closed');
}
$('closedJoin').addEventListener('click', () => { code = ''; showJoin(); });
$('who').addEventListener('click', () => showJoin());

// --- The connection ------------------------------------------------------------------------------------------------

let socket = null;
let online = null; // true: the car is there; false: it isn't; null: we lost the relay

function enterParty() {
  show('party');
  $('partyCode').textContent = code;
  $('who').textContent = name;
  setOnline(null);
  if (socket) { if (socket.connected) socket.emit('guest:join', { session: code, guestId, name }); return; }
  socket = io({ transports: ['websocket', 'polling'] });
  const wake = setTimeout(() => { if (!socket.connected) $('waking').hidden = false; }, 1500);
  socket.on('connect', () => {
    clearTimeout(wake);
    $('waking').hidden = true;
    socket.emit('guest:join', { session: code, guestId, name });
  });
  socket.on('disconnect', () => setOnline(null));
  socket.on('car_status', (d) => setOnline(!!(d && d.online)));
  socket.on('party_closed', (d) => closed(d && d.reason));
  socket.on('state', render);
  socket.on('search_results', onResults);
  socket.on('browse_results', onBrowse);
  socket.on('added', onAdded);
  socket.on('failed', onFailed);
  socket.on('car_offline', onOffline);
}

function setOnline(v) {
  online = v;
  $('dot').classList.toggle('on', v === true);
  const b = $('banner');
  b.replaceChildren();
  if (v === true) { b.hidden = true; return; }
  b.hidden = false;
  if (v === null) {
    b.append(el('b', { text: 'Reconnecting…' }), 'Hang on, this usually takes a few seconds.');
  } else if (!state) {
    b.append(el('b', { text: 'Waiting for the driver\'s phone' }), 'It joins as soon as it has signal. ',
      el('button', { type: 'button', text: 'Wrong code?', onclick: () => showJoin() }));
  } else {
    b.append(el('b', { text: 'The driver\'s phone is offline' }), 'Probably a dead zone. Search and adding come back by themselves.');
  }
}

function send(event, data) {
  if (!socket || !socket.connected) return false;
  socket.emit(event, data);
  return true;
}

// --- The state ------------------------------------------------------------------------------------------------------

let state = null;
let stateAt = 0;

function render(s) {
  state = s;
  stateAt = performance.now();
  if (online !== true) setOnline(true);
  renderNow();
  renderQueue();
  renderMini();
  if (lastShown) renderResults();
  if (stack.length) renderBrowse();
}

function position() {
  if (!state) return 0;
  const n = state.now;
  const p = n.positionMs + (n.playing ? performance.now() - stateAt : 0);
  return n.durationMs > 0 ? Math.min(p, n.durationMs) : p;
}

function items() { return state ? state.queue.items : []; }
function current() { return state ? state.queue.current : -1; }
function upcoming() { const c = current(); return items().slice(c + 1); }
function queued(videoId) { const c = current(); return items().some((it, i) => i >= c && it.videoId === videoId); }

function renderNow() {
  const n = state.now;
  const cur = items()[current()];
  setSrc($('nowCover'), n.thumbnail);
  setSrc($('washImg'), n.thumbnail);
  $('nowTitle').textContent = n.title || 'Nothing playing yet';
  $('nowArtist').textContent = n.artist || '';
  const by = $('nowBy');
  const mine = cur && cur.guestId === guestId;
  by.textContent = n.by ? (mine ? 'Added by you' : `Added by ${n.by}`) : '';
  by.style.color = n.by ? colorOf(n.by, mine) : '';
  $('nowDur').textContent = n.durationMs > 0 ? clock(n.durationMs) : '';
  $('controls').hidden = !state.perms.control;
  $('playIcon').innerHTML = n.playing ? PATHS.pause : PATHS.play;
  // Your songs still to come, with how long until each plays.
  const box = $('mine');
  box.replaceChildren();
  upcoming().forEach((it, i) => {
    if (it.guestId !== guestId || box.children.length >= 3) return;
    box.append(el('div', { class: 'card' }, img(it.thumbnail),
      el('div', { class: 'grow' },
        el('span', { class: 'eyebrow accent', text: 'YOUR SONG' }),
        el('span', { class: 't', text: it.title, style: 'font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis' }),
        el('span', { class: 'dim', style: 'font-size:13px', text: i === 0 ? 'Plays next' : `Plays after ${songs(i)}` })),
      undoButton(it)));
  });
}

function undoButton(it) {
  return el('button', { class: 'ghost', type: 'button', text: 'Undo', onclick: (e) => {
    e.stopPropagation();
    if (send('guest:remove', { itemId: it.id })) { e.currentTarget.closest('.card, .qrow').style.opacity = '0.4'; toast(`Removed “${it.title}”.`); }
  } });
}

let showPlayed = false;
let sortable = null;

function renderQueue() {
  const box = $('queue');
  box.replaceChildren();
  if (sortable) { sortable.destroy(); sortable = null; }
  const all = items();
  const c = current();
  const perms = state.perms;
  const app = all.length > 0 && !all[0].id;
  const ahead = upcoming();
  const picked = ahead.filter((it) => !it.radio).length;
  $('queueCount').textContent = ahead.length ? `${songs(picked)}${ahead.some((it) => it.radio) ? ' · then radio' : ''}` : '';
  if (!all.length) { box.append(el('p', { class: 'note', text: 'Nothing queued yet. Add a song from Search.' })); return; }
  if (app) box.append(el('p', { class: 'note', text: 'The driver is playing from the YT Music app, so this is what it plays. Songs you add start on Horizon\'s player.' }));
  const played = c > 0 ? all.slice(0, c) : [];
  if (played.length) {
    box.append(el('button', { class: 'showplayed', type: 'button', text: showPlayed ? 'Hide played' : `Show ${played.length} played`,
      onclick: () => { showPlayed = !showPlayed; renderQueue(); } }));
    if (showPlayed) played.forEach((it) => box.append(queueRow(it, 'past', perms)));
  }
  if (c >= 0) {
    box.append(el('p', { class: 'section', text: 'NOW PLAYING' }), queueRow(all[c], 'playing', perms));
  }
  if (!ahead.length) return;
  box.append(el('p', { class: 'section', text: 'UP NEXT' }));
  const list = el('div');
  let divided = false;
  ahead.forEach((it) => {
    if (it.radio && !divided) { divided = true; list.append(el('div', { class: 'divider', text: 'Radio after the party\'s songs', 'data-fixed': '1' })); }
    list.append(queueRow(it, it.radio ? 'radio' : '', perms, true));
  });
  box.append(list);
  if (perms.edit && !app && window.Sortable) {
    sortable = Sortable.create(list, {
      handle: '.handle', animation: 150, filter: '[data-fixed]',
      onEnd: (e) => {
        const rows = [...list.children].filter((r) => r.dataset.id);
        const to = rows.findIndex((r) => r.dataset.id === e.item.dataset.id);
        if (e.oldIndex === e.newIndex || to < 0) return;
        list.style.opacity = '0.5';
        send('guest:move', { itemId: e.item.dataset.id, to });
      },
    });
  }
}

function queueRow(it, kind, perms, editable) {
  const mine = it.guestId === guestId;
  const row = el('div', { class: `qrow ${kind}${mine && kind !== 'playing' ? ' own' : ''}`, 'data-id': it.id || null });
  row.append(img(it.thumbnail), el('div', { class: 'grow' }, el('span', { class: 't', text: it.title }),
    el('span', { class: 's' }, byLine(it, it.radio && !it.by ? `${it.artist} · Radio` : it.artist))));
  if (it.id && editable) {
    if (mine) row.append(undoButton(it));
    else if (perms.edit) row.append(el('button', { class: 'del', type: 'button', 'aria-label': `Remove ${it.title}`,
      onclick: (e) => { e.stopPropagation(); if (send('guest:remove', { itemId: it.id })) row.style.opacity = '0.4'; } }, icon('trash')));
    if (perms.edit) row.append(el('span', { class: 'handle', 'aria-label': 'Drag to move' }, icon('grip')));
  }
  if (it.id && perms.control && kind !== 'playing') {
    row.classList.add('tap');
    row.addEventListener('click', () => { if (send('guest:play', { itemId: it.id })) row.style.opacity = '0.5'; });
  }
  return row;
}

function renderMini() {
  const n = state && state.now;
  $('mini').hidden = tab === 'Now' || !n || !n.title;
  if (!n) return;
  setSrc($('miniCover'), n.thumbnail);
  $('miniTitle').textContent = n.title;
  $('miniSub').textContent = n.by ? `${n.artist} · ${n.by}` : n.artist;
}

// The bars and clock move between states.
setInterval(() => {
  if (!state) return;
  const d = state.now.durationMs;
  const f = d > 0 ? position() / d : 0;
  $('nowBar').style.width = (f * 100).toFixed(2) + '%';
  $('miniBar').style.width = `calc(${(f * 100).toFixed(2)}% - ${f * 20}px)`;
  $('nowPos').textContent = clock(position());
}, 500);

document.querySelectorAll('[data-media]').forEach((b) => b.addEventListener('click', () => send('guest:media', { action: b.dataset.media })));

// --- Tabs ------------------------------------------------------------------------------------------------------------

let tab = 'Now';
function setTab(t) {
  tab = t;
  for (const b of document.querySelectorAll('.tabs button')) b.classList.toggle('on', b.dataset.tab === t);
  for (const name of ['Now', 'Search', 'Queue']) $('tab' + name).hidden = name !== t;
  renderMini();
  window.scrollTo(0, 0);
}
document.querySelectorAll('.tabs button').forEach((b) => b.addEventListener('click', () => setTab(b.dataset.tab)));
$('mini').addEventListener('click', () => setTab('Now'));
$('nowAdd').addEventListener('click', () => { setTab('Search'); $('q').focus(); });

// --- Search ----------------------------------------------------------------------------------------------------------

const SEARCH_TIMEOUT_MS = 8000;
let filter = 'all';
let seq = 0;
let waiting = null;   // {id, query, kind} of the search we're waiting on
let lastShown = null; // what the results area shows: {kind, query}
const results = {};   // kind ("all", "songs", "youtube") -> {query, ...answer}
let typing;
let searchTimer;

const q = $('q');
q.addEventListener('input', () => {
  $('qClear').hidden = !q.value;
  clearTimeout(typing);
  typing = setTimeout(() => search(false), 350);
});
q.addEventListener('keydown', (e) => { if (e.key === 'Enter') { clearTimeout(typing); search(false); q.blur(); } });
$('qClear').addEventListener('click', () => {
  q.value = ''; $('qClear').hidden = true; waiting = null; lastShown = null; $('spin').hidden = true;
  $('results').replaceChildren(); q.focus();
});
document.querySelectorAll('.chip').forEach((c) => c.addEventListener('click', () => {
  filter = c.dataset.filter;
  document.querySelectorAll('.chip').forEach((x) => x.classList.toggle('on', x === c));
  search(false);
}));

function kindFor(f) { return f === 'songs' || f === 'youtube' ? f : 'all'; }

function search(force) {
  const query = q.value.trim();
  if (!query) return;
  const kind = kindFor(filter);
  if (!force && results[kind] && results[kind].query === query) { lastShown = { kind, query }; renderResults(); return; }
  if (!force && waiting && waiting.query === query && waiting.kind === kind) return;
  const id = String(++seq);
  waiting = { id, query, kind };
  $('spin').hidden = false;
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => {
    if (!waiting || waiting.id !== id) return;
    waiting = null;
    $('spin').hidden = true;
    note(`No answer for “${query}” after ${SEARCH_TIMEOUT_MS / 1000} s.`, true);
  }, SEARCH_TIMEOUT_MS);
  if (!send('guest:search', { id, query, filter: kind })) {
    waiting = null; $('spin').hidden = true; clearTimeout(searchTimer);
    note('Not connected to the party right now. Try again in a moment.', true);
  }
}

function onResults(d) {
  if (!waiting || d.id !== waiting.id) return; // an older search: a newer one is on its way
  const { kind, query } = waiting;
  waiting = null;
  clearTimeout(searchTimer);
  $('spin').hidden = true;
  if (d.error) { note(d.error, true); return; }
  results[kind] = Object.assign({ query }, d);
  lastShown = { kind, query };
  renderResults();
}

function note(text, retry) {
  const box = $('results');
  box.replaceChildren(el('div', { class: 'note' }, el('p', { text }),
    retry ? el('button', { class: 'primary', type: 'button', text: 'Try again', onclick: () => search(true) }) : null));
  lastShown = null;
}

function renderResults() {
  if (!lastShown) return;
  const r = results[lastShown.kind];
  if (!r) return;
  const box = $('results');
  box.replaceChildren();
  const s = r.songs || [], a = r.artists || [], al = r.albums || [];
  if (filter === 'artists') a.forEach((x) => box.append(artistRow(x)));
  else if (filter === 'albums') al.forEach((x) => box.append(albumRow(x)));
  else if (filter === 'all') {
    if (r.top === 'artist' && a[0]) box.append(artistRow(a[0]));
    if (r.top === 'album' && al[0]) box.append(albumRow(al[0]));
    if (s.length) { box.append(el('p', { class: 'section', text: 'SONGS' })); s.slice(0, 6).forEach((x) => box.append(songRow(x))); }
    const moreArtists = a.filter((x, i) => !(r.top === 'artist' && i === 0)).slice(0, 3);
    if (moreArtists.length) { box.append(el('p', { class: 'section', text: 'ARTISTS' })); moreArtists.forEach((x) => box.append(artistRow(x))); }
    const moreAlbums = al.filter((x, i) => !(r.top === 'album' && i === 0)).slice(0, 4);
    if (moreAlbums.length) { box.append(el('p', { class: 'section', text: 'ALBUMS' })); moreAlbums.forEach((x) => box.append(albumRow(x))); }
  } else s.forEach((x) => box.append(songRow(x)));
  const empty = filter === 'artists' ? !a.length : filter === 'albums' ? !al.length : filter === 'all' ? !(s.length || a.length || al.length) : !s.length;
  if (empty) box.append(el('p', { class: 'note', text: `Nothing for “${r.query}”.` }));
  if (lastShown.kind !== 'youtube') {
    box.append(el('button', { class: 'more', type: 'button', text: 'Not here? Search all of YouTube', onclick: () => {
      filter = 'youtube';
      document.querySelectorAll('.chip').forEach((x) => x.classList.remove('on'));
      search(false);
    } }));
  } else box.prepend(el('p', { class: 'note', style: 'padding-top:4px', text: 'From all of YouTube: live versions, covers and uploads.' }));
}

const adding = new Map();   // request id -> song
const addingIds = new Set(); // video ids on their way

function songRow(s) {
  const right = addingIds.has(s.videoId) ? el('span', { class: 'spin', 'aria-label': 'Adding' })
    : queued(s.videoId) ? el('span', { class: 'tag', text: 'In queue' })
    : el('button', { class: 'add', type: 'button', 'aria-label': `Add ${s.title}`, onclick: () => add(s) }, icon('plus'));
  return el('div', { class: 'row' }, img(s.thumbnail), el('div', { class: 'grow' },
    el('span', { class: 't', text: s.title }), el('span', { class: 's', text: s.artist })), right);
}

function artistRow(a) {
  return el('button', { class: 'row', type: 'button', onclick: () => openBrowse('artist', a.browseId, a.name) },
    img(a.thumbnail, 'round'), el('span', { class: 'grow' }, el('span', { class: 't', text: a.name }), el('span', { class: 's', text: 'Artist' })),
    icon('chev', 'chev'));
}

function albumRow(a) {
  return el('button', { class: 'row', type: 'button', onclick: () => openBrowse('album', a.browseId, a.title) },
    img(a.thumbnail), el('span', { class: 'grow' }, el('span', { class: 't', text: a.title }), el('span', { class: 's', text: a.subtitle })),
    icon('chev', 'chev'));
}

function add(s) {
  if (online !== true) { toast('The driver\'s phone is offline. Try again when it\'s back.', 'bad'); return; }
  const id = String(++seq);
  if (!send('guest:add', { id, videoId: s.videoId, title: s.title, artist: s.artist, thumbnail: s.thumbnail })) {
    toast('Not connected to the party right now. Try again in a moment.', 'bad'); return;
  }
  adding.set(id, s);
  addingIds.add(s.videoId);
  refreshLists();
  setTimeout(() => {
    if (!adding.has(id)) return;
    adding.delete(id); addingIds.delete(s.videoId); refreshLists();
    toast(`Couldn't add “${s.title}”. Try again.`, 'bad');
  }, 12000);
}

function onAdded(d) {
  const s = adding.get(d.id);
  if (s) { adding.delete(d.id); addingIds.delete(s.videoId); }
  const when = d.ahead < 0 ? 'It plays now.' : d.ahead === 0 ? 'It plays next.' : `It plays after ${songs(d.ahead)}.`;
  toast(`Added “${d.title}”. ${when}`, 'good');
  refreshLists();
}

function onFailed(d) {
  const s = d && adding.get(d.id);
  if (s) { adding.delete(d.id); addingIds.delete(s.videoId); refreshLists(); }
  toast((d && d.message) || 'That didn\'t work. Try again.', 'bad');
}

function onOffline(d) {
  if (waiting && d.id === waiting.id) { waiting = null; $('spin').hidden = true; clearTimeout(searchTimer); note('The driver\'s phone is offline, so search is paused. Try again when it\'s back.', true); return; }
  const s = adding.get(d.id);
  if (s) { adding.delete(d.id); addingIds.delete(s.videoId); refreshLists(); toast('The driver\'s phone is offline. Try again when it\'s back.', 'bad'); }
  setOnline(false);
}

function refreshLists() { if (lastShown) renderResults(); if (stack.length) renderBrowse(); }

// --- Artist and album pages --------------------------------------------------------------------------------------------

const stack = []; // pages: {kind, browseId, name, id, data}
let browseTimer;

function openBrowse(kind, browseId, name) {
  stack.push({ kind, browseId, name, id: null, data: null });
  $('searchHome').hidden = true;
  $('browse').hidden = false;
  requestBrowse();
  window.scrollTo(0, 0);
}

function requestBrowse() {
  const page = stack[stack.length - 1];
  page.id = String(++seq);
  page.data = null;
  renderBrowse();
  clearTimeout(browseTimer);
  const id = page.id;
  browseTimer = setTimeout(() => { if (page.id === id && !page.data) { page.data = { error: 'No answer after 10 s.' }; renderBrowse(); } }, 10000);
  if (!send('guest:browse', { id, kind: page.kind, browseId: page.browseId, name: page.name })) {
    page.data = { error: 'Not connected to the party right now.' }; renderBrowse();
  }
}

function onBrowse(d) {
  const page = stack.find((p) => p.id === d.id);
  if (!page) return;
  page.data = d;
  if (page === stack[stack.length - 1]) renderBrowse();
}

$('browseBack').addEventListener('click', () => {
  stack.pop();
  if (stack.length) { renderBrowse(); window.scrollTo(0, 0); return; }
  $('browse').hidden = true;
  $('searchHome').hidden = false;
});

function renderBrowse() {
  const page = stack[stack.length - 1];
  if (!page) return;
  $('browseBackText').textContent = stack.length > 1 ? stack[stack.length - 2].name : 'Results';
  const box = $('browseBody');
  box.replaceChildren();
  const d = page.data;
  const round = page.kind === 'artist';
  box.append(el('div', { class: 'head' }, img(d && d.thumbnail, round ? 'round' : null),
    el('div', {}, el('h2', { text: (d && d.title) || page.name }),
      el('p', { class: 'dim', text: round ? 'Tap + to add a song to the party' : (d && d.subtitle) || 'Album' }))));
  if (!d) { box.append(el('div', { class: 'note' }, el('span', { class: 'spin' }))); return; }
  if (d.error) { box.append(el('div', { class: 'note' }, el('p', { text: d.error }), el('button', { class: 'primary', type: 'button', text: 'Try again', onclick: requestBrowse }))); return; }
  if (d.songs && d.songs.length) {
    if (round) box.append(el('p', { class: 'section', text: 'TOP SONGS' }));
    d.songs.forEach((s) => box.append(songRow(s)));
  }
  if (d.albums && d.albums.length) {
    box.append(el('p', { class: 'section', text: 'ALBUMS AND SINGLES' }));
    box.append(el('div', { class: 'grid' }, d.albums.map((a) => el('button', { class: 'tile', type: 'button', onclick: () => openBrowse('album', a.browseId, a.title) },
      img(a.thumbnail), el('span', { text: a.title }), el('small', { text: a.subtitle })))));
  }
}

// --- Start ------------------------------------------------------------------------------------------------------------

const SHARED = { ok: ['Shared song sent to the car.', 'good'], offline: ['The driver\'s phone is offline. Share it again in a moment.', 'bad'],
  not_found: ['Couldn\'t find that song on YouTube.', 'bad'], failed: ['Couldn\'t read that link.', 'bad'], no_link: ['That share had no link in it.', 'bad'] };

if (CODE.test(code) && name) {
  cookie('session', code); cookie('name', name);
  enterParty();
  if (sharedResult && SHARED[sharedResult]) toast(...SHARED[sharedResult]);
} else showJoin();
