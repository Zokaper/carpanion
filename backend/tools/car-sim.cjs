// A scripted car, for working on the guests' page without Horizon: `node tools/car-sim.cjs [CODE]` (URL env: the
// relay, default http://localhost:3000). Registers CODE (default TEST23), answers searches and artist/album pages from
// a small made-up catalogue, keeps a queue the way Horizon does (party songs after the party's songs still to come,
// then the rest, then radio), plays a song every 60 s, and grants edit and playback rights.
// ROTATION=1: a Rotation party instead (everyone's own queue, taking turns; Horizon's core/Rotation.kt in small), with
// guest:mine, and a pretend YT Music sign-in (the code is FAKE-CODE, the token comes 3 s later) and library.
const connect = require('./client.cjs');

const url = process.env.URL || 'http://localhost:3000';
const code = (process.argv[2] || 'TEST23').toUpperCase();
const s = connect(url);
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

const art = (id) => `https://i.ytimg.com/vi/${id}/hqdefault.jpg`;
const song = (videoId, title, artist) => ({ videoId, title, artist, thumbnail: art(videoId) });
const CATALOGUE = [
  song('4NRXx6U8ABQ', 'Blinding Lights', 'The Weeknd'), song('34Na4j8AVgA', 'Starboy', 'The Weeknd, Daft Punk'),
  song('tollGa3S0o8', 'Save Your Tears', 'The Weeknd'), song('tvTRZJ-4EyI', 'HUMBLE.', 'Kendrick Lamar'),
  song('H58vbez_m4E', 'Not Like Us', 'Kendrick Lamar'), song('smqhSl0u_sI', 'Money Trees', 'Kendrick Lamar, Jay Rock'),
  song('4zzP7c0iqdU', 'Tennessee Whiskey', 'Chris Stapleton'), song('TUVcZfQe-Kw', 'Levitating', 'Dua Lipa'),
  song('oygrmJFKYZY', 'Don\'t Start Now', 'Dua Lipa'), song('gGdGFtwCNBE', 'Mr. Brightside', 'The Killers'),
];
const ARTISTS = [
  { browseId: 'UC-weeknd', name: 'The Weeknd', thumbnail: art('34Na4j8AVgA') },
  { browseId: 'UC-kendrick', name: 'Kendrick Lamar', thumbnail: art('tvTRZJ-4EyI') },
  { browseId: 'UC-dua', name: 'Dua Lipa', thumbnail: art('TUVcZfQe-Kw') },
];
const ALBUMS = [
  { browseId: 'MPRE-afterhours', title: 'After Hours', subtitle: 'Album • The Weeknd • 2020', thumbnail: art('4NRXx6U8ABQ') },
  { browseId: 'MPRE-damn', title: 'DAMN.', subtitle: 'Album • Kendrick Lamar • 2017', thumbnail: art('tvTRZJ-4EyI') },
  { browseId: 'MPRE-fn', title: 'Future Nostalgia', subtitle: 'Album • Dua Lipa • 2020', thumbnail: art('TUVcZfQe-Kw') },
];

let uid = 1;
const item = (sng, by = null, radio = false) => ({ id: String(uid++), ...sng, by: by ? by.name : '', guestId: by ? by.id : '', radio });
const queue = [item(CATALOGUE[9], { id: 'driver', name: 'Driver' }), item(CATALOGUE[0], { id: 'g-noura', name: 'Noura' }),
  item(CATALOGUE[2]), item(CATALOGUE[1], null, true), item(CATALOGUE[8], null, true)];
let current = 1;
let playing = true;
let startedAt = Date.now() - 76_000;
let pausedAt = 0;
const DURATION = 200_000;
const perms = { edit: true, control: true };

// --- Rotation (ROTATION=1) --------------------------------------------------------------------------------------------
const ROT = process.env.ROTATION === '1';
const rot = { perTurn: 1, turn: 0, played: 1, people: [{ id: 'driver', name: 'Driver', endless: true, sittingOut: false, queue: [] }] };
if (ROT) {
  rot.people[0].queue = [CATALOGUE[0], CATALOGUE[2], CATALOGUE[1]].map((x) => item(x, { id: 'driver', name: 'Driver' }));
  queue.splice(0, queue.length, item(CATALOGUE[9], { id: 'driver', name: 'Driver' }));
  current = 0;
}
const person = (id) => rot.people.find((p) => p.id === id);
function join(id, name) { if (!person(id)) rot.people.push({ id, name, endless: false, sittingOut: false, queue: [] }); }
function upcoming(limit = 50) {
  const taken = rot.people.map(() => 0);
  const ready = (i) => !rot.people[i].sittingOut && taken[i] < rot.people[i].queue.length;
  const out = [];
  let t = rot.turn, p = rot.played;
  while (out.length < limit) {
    if (p >= rot.perTurn || !ready(t)) {
      let n = -1;
      for (let k = 1; k <= rot.people.length; k++) if (ready((t + k) % rot.people.length)) { n = (t + k) % rot.people.length; break; }
      if (n < 0) break;
      t = n; p = 0;
    }
    out.push(rot.people[t].queue[taken[t]++]); p++;
  }
  return out;
}
function started(it) {
  const i = rot.people.findIndex((p) => p.id === it.guestId);
  if (i < 0) return;
  rot.people[i].queue = rot.people[i].queue.filter((x) => x.id !== it.id);
  if (i === rot.turn && rot.played >= 1 && rot.played < rot.perTurn) rot.played++; else { rot.turn = i; rot.played = 1; }
}
function rotationJson() {
  const up = upcoming();
  const starts = [];
  let last = rot.turn;
  for (const it of up) { const i = rot.people.findIndex((p) => p.id === it.guestId); if (i < last) starts.push(it.id); last = i; }
  return { perTurn: rot.perTurn, turn: rot.people[rot.turn].id, people: rot.people.map((p) => ({ ...p, count: p.queue.filter((x) => !x.radio).length, signedIn: false })),
    upcoming: up, roundStarts: starts };
}

function state() {
  const now = queue[current];
  const pos = playing ? Date.now() - startedAt : pausedAt;
  const items = ROT ? queue.slice(0, current + 1).concat(upcoming(10)) : queue;
  return { queue: { items, current }, perms, mode: ROT ? 'rotation' : 'open', rotation: ROT ? rotationJson() : undefined,
    now: { title: now.title, artist: now.artist, thumbnail: now.thumbnail, by: now.by, durationMs: DURATION, positionMs: pos, playing } };
}
const sendState = () => s.emit('room:state', state());
const reply = (o, event, data) => s.emit('to:' + event, { to: o.from, data: Object.assign({ id: o.id }, data) });
function advance(to) {
  if (ROT && to > current) {
    const next = upcoming(1)[0] || item(CATALOGUE[Math.floor(Math.random() * CATALOGUE.length)], null, true);
    started(next);
    queue.splice(current + 1, queue.length, next);
    current++; startedAt = Date.now(); pausedAt = 0;
    log('rotation: playing', next.title, 'by', next.by || 'radio');
    sendState();
    return;
  }
  current = Math.min(to, queue.length - 1);
  startedAt = Date.now(); pausedAt = 0;
  if (current >= queue.length - 2) queue.push(item(CATALOGUE[Math.floor(Math.random() * CATALOGUE.length)], null, true));
  sendState();
}
setInterval(() => { if (playing && Date.now() - startedAt > 60_000) advance(current + 1); }, 1000);

s.on('connect', () => { log('connected, registering', code); s.emit('car:register', { session: code }); });
s.on('party_guests', (g) => log('guests:', g.map((x) => x.name).join(', ') || '(none)'));
s.on('guest:hello', (o) => {
  log('hello', o.name);
  if (ROT) { join(o.guestId, o.name); sendState(); }
  s.emit('to:state', { to: o.from, data: state() });
});
const LISTS = { RDMM: CATALOGUE.slice(0, 6), LM: CATALOGUE.slice(3, 9), PLroadtrip: CATALOGUE.slice(5, 10) };
s.on('guest:signin', (o) => {
  log('sign-in from', o.name);
  reply(o, 'auth_code', { userCode: 'FAKE-CODE', url: 'about:blank', expiresIn: 1800 });
  setTimeout(() => reply(o, 'auth_token', { refreshToken: 'fake-token-' + o.guestId }), 3000);
});
s.on('guest:auth', (o) => { log('auth from', o.name); reply(o, 'auth_state', { signedIn: true, expired: false }); });
s.on('guest:signout', (o) => log('sign-out from', o.name));
s.on('guest:library', (o) => setTimeout(() => reply(o, 'library_results', { signedIn: true,
  mixes: [{ playlistId: 'RDMM', title: 'My Mix', subtitle: 'Made from your listening', thumbnail: '' }],
  playlists: [{ playlistId: 'LM', title: 'Liked Music', subtitle: 'Auto playlist • 6 songs', thumbnail: art('TUVcZfQe-Kw') },
    { playlistId: 'PLroadtrip', title: 'Road trip', subtitle: '5 songs', thumbnail: art('gGdGFtwCNBE') }] }), 400));
s.on('guest:mine', (o) => {
  if (!ROT) { reply(o, 'failed', { message: 'This party has one shared queue' }); return; }
  join(o.guestId, o.name);
  const me = person(o.guestId);
  const by = { id: o.guestId, name: o.name };
  log('mine', o.op, 'from', o.name);
  if (o.op === 'add') {
    const list = o.playlistId ? (LISTS[o.playlistId] || []) : (o.songs || []);
    me.queue.push(...list.map((x) => item({ videoId: x.videoId, title: x.title, artist: x.artist, thumbnail: x.thumbnail || art(x.videoId) }, by)));
    reply(o, 'added', { title: list.length === 1 ? list[0].title : `${list.length} songs`, count: list.length, mine: true });
  } else if (o.op === 'remove') me.queue = me.queue.filter((x) => x.id !== o.itemId);
  else if (o.op === 'move') { const i = me.queue.findIndex((x) => x.id === o.itemId); if (i >= 0) { const [x] = me.queue.splice(i, 1); me.queue.splice(o.to, 0, x); } }
  else if (o.op === 'clear') me.queue = [];
  else if (o.op === 'shuffle') me.queue.sort(() => Math.random() - 0.5);
  else if (o.op === 'endless') me.endless = !!o.on;
  sendState();
});
s.on('guest:search', (o) => {
  const q = o.query.toLowerCase();
  const hit = (t) => t.toLowerCase().includes(q);
  const songs = CATALOGUE.filter((x) => hit(x.title) || hit(x.artist));
  const artists = ARTISTS.filter((x) => hit(x.name));
  const albums = ALBUMS.filter((x) => hit(x.title) || hit(x.subtitle));
  // Slow and out of order on purpose: short queries answer last, as a weak signal would.
  const delay = 300 + Math.max(0, 6 - q.length) * 400;
  log(`search "${o.query}" (${o.filter}) from ${o.name}, answering in ${delay} ms`);
  setTimeout(() => reply(o, 'search_results', { query: o.query, songs, artists: o.filter === 'all' ? artists : undefined,
    albums: o.filter === 'all' ? albums : undefined, top: artists.length ? 'artist' : songs.length ? 'song' : null }), delay);
});
s.on('guest:browse', (o) => {
  log('browse', o.kind, o.browseId);
  setTimeout(() => {
    if (o.kind === 'playlist') {
      reply(o, 'browse_results', { kind: 'playlist', title: o.name, playlistId: o.browseId, songs: LISTS[o.browseId] || [] });
    } else if (o.kind === 'artist') {
      const a = ARTISTS.find((x) => x.browseId === o.browseId) || ARTISTS[0];
      reply(o, 'browse_results', { kind: 'artist', title: a.name, thumbnail: a.thumbnail,
        songs: CATALOGUE.filter((x) => x.artist.includes(a.name)), albums: ALBUMS.filter((x) => x.subtitle.includes(a.name)) });
    } else {
      const a = ALBUMS.find((x) => x.browseId === o.browseId) || ALBUMS[0];
      const artist = a.subtitle.split(' • ')[1];
      reply(o, 'browse_results', { kind: 'album', title: a.title, subtitle: artist, thumbnail: a.thumbnail,
        songs: CATALOGUE.filter((x) => x.artist.includes(artist)) });
    }
  }, 500);
});
s.on('guest:add', (o) => {
  const by = { id: o.guestId, name: o.name };
  if (ROT) {
    join(o.guestId, o.name);
    const it = item({ videoId: o.videoId, title: o.title || 'Shared song', artist: o.artist || '', thumbnail: o.thumbnail || art(o.videoId) }, by);
    person(o.guestId).queue.push(it);
    log(`add "${o.title}" to ${o.name}'s queue`);
    if (o.from) reply(o, 'added', { title: o.title, ahead: upcoming().findIndex((x) => x.id === it.id), mine: true });
    sendState();
    return;
  }
  let at = current + 1;
  for (let i = current + 1; i < queue.length && !queue[i].radio; i++) if (queue[i].guestId) at = i + 1;
  queue.splice(at, 0, item({ videoId: o.videoId, title: o.title || 'Shared song', artist: o.artist || '', thumbnail: o.thumbnail || art(o.videoId) }, by));
  log(`add "${o.title}" by ${o.name}, ahead ${at - current - 1}`);
  if (o.from) reply(o, 'added', { title: o.title, ahead: at - current - 1 });
  sendState();
});
s.on('guest:remove', (o) => {
  const i = queue.findIndex((x) => x.id === o.itemId);
  if (i <= current) return;
  if (!perms.edit && queue[i].guestId !== o.guestId) { reply(o, 'failed', { message: 'The driver hasn\'t let guests remove songs' }); return; }
  log('remove', queue[i].title, 'by', o.name);
  queue.splice(i, 1);
  sendState();
});
s.on('guest:move', (o) => {
  const i = queue.findIndex((x) => x.id === o.itemId);
  if (i <= current || !perms.edit) return;
  const [x] = queue.splice(i, 1);
  queue.splice(current + 1 + o.to, 0, { ...x, radio: false });
  log('move', x.title, 'to', o.to);
  sendState();
});
s.on('guest:play', (o) => { const i = queue.findIndex((x) => x.id === o.itemId); if (i > current) { const [x] = queue.splice(i, 1); queue.splice(current + 1, 0, x); advance(current + 1); } });
s.on('guest:media', (o) => {
  log('media', o.action, 'from', o.name);
  if (o.action === 'next') advance(current + 1);
  else if (o.action === 'previous') advance(Math.max(0, current - 1));
  else if (playing) { pausedAt = Date.now() - startedAt; playing = false; sendState(); }
  else { startedAt = Date.now() - pausedAt; playing = true; sendState(); }
});
