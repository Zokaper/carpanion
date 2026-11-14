// Party relay for Horizon (protocol 2). A pipe between the car (Horizon on the driver's phone) and the guests' page.
//
//   car    -> relay  car:register {session}   claim a code (a new code closes the old one's room)
//                    car:end                   the party ended
//                    room:<event> data         to every guest in the session
//                    to:<event> {to, data}     to one guest socket
//   guest  -> relay  guest:join {session, guestId, name}
//                    guest:<event> data        to the car, with {from, guestId, name} added here
//   relay  -> car    party_guests [{guestId, name}], guest:hello {from, ...} when someone joins
//   relay  -> guest  car_status {online}, party_closed {reason}, car_offline {event, id}
//
// Sessions live in memory only: after a restart (Render's free tier sleeps) the car and the guests register again.

const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const axios = require('axios');
const path = require('path');
const cookieParser = require('cookie-parser');

const app = express();
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: '*' }, maxHttpBufferSize: 1e6 });

app.use(express.urlencoded({ extended: true }));
app.use(cookieParser());
app.use(express.static(path.join(__dirname, 'public'), { setHeaders: (res, file) => {
  // The page and its script change with each deploy: always revalidate them.
  if (/\.(html|js|css|json)$/.test(file)) res.setHeader('Cache-Control', 'no-cache');
} }));

const CODE = /^[A-Z2-9]{6}$/;
/** session -> { car: socketId | null, guests: Map<socketId, {guestId, name}> } */
const sessions = new Map();
/** Codes that were closed, so a guest arriving with one is told why: session -> {reason, at}. */
const closed = new Map();
const CLOSED_KEEP_MS = 24 * 3600 * 1000;

function session(code) {
  let s = sessions.get(code);
  if (!s) { s = { car: null, guests: new Map() }; sessions.set(code, s); }
  return s;
}

function guestList(s) {
  const seen = new Map();
  for (const g of s.guests.values()) seen.set(g.guestId, { guestId: g.guestId, name: g.name });
  return [...seen.values()];
}

function tellCarGuests(code) {
  const s = sessions.get(code);
  if (s && s.car) io.to(s.car).emit('party_guests', guestList(s));
}

function close(code, reason) {
  closed.set(code, { reason, at: Date.now() });
  io.to(code).emit('party_closed', { reason });
  const s = sessions.get(code);
  if (s) for (const id of s.guests.keys()) io.sockets.sockets.get(id)?.leave(code);
  sessions.delete(code);
}

function clean(text, max) {
  return String(text ?? '').replace(/[\u0000-\u001f]/g, '').trim().slice(0, max);
}

function leave(socket) {
  const code = socket.data.session;
  const s = sessions.get(code);
  if (!s) return;
  s.guests.delete(socket.id);
  socket.leave(code);
  tellCarGuests(code);
}

io.on('connection', (socket) => {
  // --- The car ---
  socket.on('car:register', (data) => {
    const code = clean(data?.session, 6).toUpperCase();
    if (!CODE.test(code)) return;
    const old = socket.data.role === 'car' ? socket.data.session : null;
    if (old && old !== code) close(old, 'new_code');
    socket.data = { role: 'car', session: code };
    closed.delete(code);
    const s = session(code);
    s.car = socket.id;
    io.to(code).emit('car_status', { online: true });
    tellCarGuests(code);
    // Guests already there get the state again, as if they had just joined.
    for (const [id, g] of s.guests) socket.emit('guest:hello', { from: id, guestId: g.guestId, name: g.name });
  });

  socket.on('car:end', () => {
    if (socket.data.role === 'car') { close(socket.data.session, 'ended'); socket.data = {}; }
  });

  // --- Guests ---
  socket.on('guest:join', (data) => {
    const code = clean(data?.session, 6).toUpperCase();
    if (!CODE.test(code)) { socket.emit('party_closed', { reason: 'unknown' }); return; }
    const was = closed.get(code);
    if (was && Date.now() - was.at < CLOSED_KEEP_MS) { socket.emit('party_closed', { reason: was.reason }); return; }
    const guestId = clean(data?.guestId, 40) || socket.id;
    const name = clean(data?.name, 24) || 'Guest';
    if (socket.data.session && socket.data.session !== code) leave(socket);
    socket.data = { role: 'guest', session: code, guestId, name };
    socket.join(code);
    const s = session(code);
    s.guests.set(socket.id, { guestId, name });
    socket.emit('car_status', { online: !!s.car });
    if (s.car) io.to(s.car).emit('guest:hello', { from: socket.id, guestId, name });
    tellCarGuests(code);
  });

  socket.onAny((event, data) => {
    const d = socket.data;
    if (d.role === 'car') {
      if (event.startsWith('room:')) io.to(d.session).emit(event.slice(5), data);
      else if (event.startsWith('to:') && data && typeof data.to === 'string') {
        // Only to a guest of this car's own session.
        if (sessions.get(d.session)?.guests.has(data.to)) io.to(data.to).emit(event.slice(3), data.data);
      }
      return;
    }
    if (d.role !== 'guest' || !event.startsWith('guest:') || event === 'guest:join') return;
    const s = sessions.get(d.session);
    const payload = Object.assign({}, typeof data === 'object' && data ? data : {}, { from: socket.id, guestId: d.guestId, name: d.name });
    if (s && s.car) io.to(s.car).emit(event, payload);
    else socket.emit('car_offline', { event: event.slice(6), id: payload.id ?? null });
  });

  socket.on('disconnect', () => {
    const d = socket.data;
    if (d.role === 'car') {
      const s = sessions.get(d.session);
      if (s && s.car === socket.id) { s.car = null; io.to(d.session).emit('car_status', { online: false }); }
    } else if (d.role === 'guest') leave(socket);
  });
});

// Forget sessions nobody is in, and old closed codes.
setInterval(() => {
  for (const [code, s] of sessions) if (!s.car && s.guests.size === 0) sessions.delete(code);
  for (const [code, c] of closed) if (Date.now() - c.at > CLOSED_KEEP_MS) closed.delete(code);
}, 10 * 60 * 1000);

// Share target: a song shared from another app (Spotify, Apple Music…) to the installed page. Odesli finds it on
// YouTube; the car looks up its title.
app.post('/share', async (req, res) => {
  const code = clean(req.cookies.session, 6).toUpperCase();
  const shared = req.body.url || req.body.text || '';
  const s = sessions.get(code);
  if (!shared) return res.redirect('/?shared=no_link');
  if (!s || !s.car) return res.redirect('/?shared=offline');
  try {
    const link = (shared.match(/https?:\/\/\S+/) || [shared])[0];
    const { data } = await axios.get(`https://api.song.link/v1-alpha.1/links?url=${encodeURIComponent(link)}`, { timeout: 8000 });
    const yt = data?.linksByPlatform?.youtubeMusic?.url || data?.linksByPlatform?.youtube?.url || '';
    const id = (yt.match(/[?&]v=([^&]+)/) || [])[1];
    if (!id) return res.redirect('/?shared=not_found');
    io.to(s.car).emit('guest:add', {
      videoId: id, title: '',
      guestId: clean(req.cookies.guestId, 40) || 'shared', name: clean(req.cookies.name, 24) || 'Guest',
    });
    res.redirect('/?shared=ok');
  } catch (e) {
    console.error('share:', e.message);
    res.redirect('/?shared=failed');
  }
});

app.get('/healthz', (req, res) => res.send('ok'));

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => console.log(`Party relay on port ${PORT}`));
