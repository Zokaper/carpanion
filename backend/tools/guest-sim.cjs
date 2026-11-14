// A scripted guest, for testing a party without a second phone:
//
//   node tools/guest-sim.cjs CODE NAME "song query" ["another query" ...]
//
// Joins CODE as NAME, then for each query searches (everything, like the page's All tab) and adds the first song.
// Env: URL (relay, default https://carpanion.onrender.com), STAY (ms to stay after the last add, default 5000),
// UNDO=1 (take your last song back out before leaving).
const connect = require('./client.cjs');

const [code, name, ...queries] = process.argv.slice(2);
if (!code || !name) { console.error('usage: node tools/guest-sim.cjs CODE NAME "query" ...'); process.exit(2); }
const url = process.env.URL || 'https://carpanion.onrender.com';
const stay = Number(process.env.STAY || 5000);
const guestId = 'sim-' + name.toLowerCase();

const s = connect(url);
let state = null;
let seq = 0;
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
function ask(event, data, answer, ms = 15000) {
  const id = String(++seq);
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => { s.off(answer, h); reject(new Error(`no ${answer} for ${event} in ${ms} ms`)); }, ms);
    function h(d) { if (d && d.id === id) { clearTimeout(t); s.off(answer, h); resolve(d); } }
    s.on(answer, h);
    s.emit(event, Object.assign({ id }, data));
  });
}

s.on('connect', () => { log('connected to', url); s.emit('guest:join', { session: code, guestId, name }); });
s.on('car_status', (d) => log('car', d.online ? 'online' : 'OFFLINE'));
s.on('party_closed', (d) => { log('party closed:', d.reason); process.exit(1); });
s.on('car_offline', (d) => log('car offline for', d.event));
s.on('failed', (d) => log('failed:', d.message));
s.on('state', (d) => {
  state = d;
  const c = d.queue.current;
  const next = d.queue.items.slice(c + 1, c + 4).map((it) => `${it.title}${it.by ? ' (' + it.by + ')' : ''}`).join(' | ');
  log(`now: ${d.now.title} ${d.now.playing ? '▶' : '⏸'}  next: ${next}`);
});

(async () => {
  await new Promise((r) => s.once('state', r));
  let last = null;
  for (const q of queries) {
    const t0 = Date.now();
    const r = await ask('guest:search', { query: q, filter: 'all' }, 'search_results');
    if (r.error) { log(`search "${q}": ${r.error}`); continue; }
    log(`search "${q}": ${r.songs.length} songs, ${(r.artists || []).length} artists, ${(r.albums || []).length} albums in ${Date.now() - t0} ms`);
    const song = r.songs[0];
    if (!song) continue;
    const a = await ask('guest:add', song, 'added');
    log(`added "${a.title}", ahead ${a.ahead}`);
    last = song.videoId;
  }
  await new Promise((r) => setTimeout(r, stay));
  if (process.env.UNDO && last && state) {
    const it = state.queue.items.find((x) => x.videoId === last && x.guestId === guestId);
    if (it) { s.emit('guest:remove', { itemId: it.id }); log('undo', it.title); await new Promise((r) => setTimeout(r, 1500)); }
  }
  process.exit(0);
})().catch((e) => { log('error:', e.message); process.exit(1); });
