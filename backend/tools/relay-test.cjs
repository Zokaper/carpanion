// End-to-end check of the relay (protocol 2) with a scripted car and two guests: `node tools/relay-test.cjs`.
// Starts the server on a spare port, runs through join, requests, replies, offline, new code and end, then exits
// non-zero on the first failure.
const { spawn } = require('child_process');
const path = require('path');
const connect = require('./client.cjs');

const PORT = 3999;
const URL = `http://localhost:${PORT}`;
const server = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], { env: { ...process.env, PORT }, stdio: 'pipe' });

const wait = (ms) => new Promise((r) => setTimeout(r, ms));
function next(socket, event, ms = 2000) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`no ${event} within ${ms} ms`)), ms);
    socket.once(event, (d) => { clearTimeout(t); resolve(d); });
  });
}
function none(socket, event, ms = 400) {
  return new Promise((resolve, reject) => {
    const h = () => reject(new Error(`unexpected ${event}`));
    socket.once(event, h);
    setTimeout(() => { socket.off(event, h); resolve(); }, ms);
  });
}
function check(ok, what) { if (!ok) throw new Error(what); console.log('  ok  ' + what); }
async function up(s) { if (!s.connected) await next(s, 'connect'); return s; }

(async () => {
  await new Promise((r) => server.stdout.once('data', r));
  const car = await up(connect(URL));
  const ann = await up(connect(URL));
  const bob = await up(connect(URL));

  // A guest arriving before the car hears it's offline, and is still in the room.
  ann.emit('guest:join', { session: 'ABC234', guestId: 'g-ann', name: 'Ann' });
  check((await next(ann, 'car_status')).online === false, 'guest before the car: offline');
  ann.emit('guest:search', { id: '1', query: 'x' });
  check((await next(ann, 'car_offline')).id === '1', 'request with no car: car_offline with its id');

  // The car registers: the waiting guest gets online and the car a hello and the guest list.
  const hello = next(car, 'guest:hello');
  const guests = next(car, 'party_guests');
  const online = next(ann, 'car_status');
  car.emit('car:register', { session: 'ABC234' });
  check((await online).online === true, 'car registers: guests see it online');
  check((await hello).name === 'Ann', 'car registers: hello for each guest already there');
  check((await guests).length === 1, 'car registers: guest list');

  // A second guest joins; the car hears of it.
  const hello2 = next(car, 'guest:hello');
  const guests2 = next(car, 'party_guests');
  bob.emit('guest:join', { session: 'abc234', guestId: 'g-bob', name: '  Bob  ' });
  check((await hello2).name === 'Bob', 'join: car gets a hello (code case and name spaces cleaned)');
  check((await guests2).map((g) => g.name).sort().join() === 'Ann,Bob', 'join: guest list has both');

  // A guest request reaches the car with who sent it; a guest can't pretend to be another.
  const req = next(car, 'guest:search');
  ann.emit('guest:search', { id: '7', query: 'kendrick', guestId: 'g-bob', from: 'nope' });
  const r = await req;
  check(r.id === '7' && r.query === 'kendrick', 'request forwarded to the car');
  check(r.guestId === 'g-ann' && r.from === ann.id && r.name === 'Ann', 'relay sets from, guestId and name');

  // A reply goes to that guest only; a room event to both.
  const annGets = next(ann, 'search_results');
  const bobNot = none(bob, 'search_results');
  car.emit('to:search_results', { to: ann.id, data: { id: '7', songs: [] } });
  check((await annGets).id === '7', 'to: reaches the one guest');
  await bobNot;
  const sa = next(ann, 'state'), sb = next(bob, 'state');
  car.emit('room:state', { queue: { items: [], current: -1 } });
  await sa; await sb;
  check(true, 'room: reaches every guest');

  // Guests can't use car events.
  const noState = none(bob, 'state');
  ann.emit('room:state', { fake: true });
  ann.emit('car:end');
  await noState;
  check(true, 'guests can\'t send room events or end the party');

  // The car drops: guests see it offline, then back.
  const off = next(ann, 'car_status');
  car.disconnect();
  check((await off).online === false, 'car disconnects: guests see it offline');
  const car2 = await up(connect(URL));
  const on2 = next(bob, 'car_status');
  const hellos = [];
  car2.on('guest:hello', (h) => hellos.push(h.name));
  car2.emit('car:register', { session: 'ABC234' });
  check((await on2).online === true, 'car back: guests see it online');
  await wait(200);
  check(hellos.sort().join() === 'Ann,Bob', 'car back: hello for each guest, so it resends the state');

  // A new code closes the old room; a guest coming back with the old code is told why.
  const closedA = next(ann, 'party_closed');
  car2.emit('car:register', { session: 'XYZ567' });
  check((await closedA).reason === 'new_code', 'new code: old room told new_code');
  const late = await up(connect(URL));
  late.emit('guest:join', { session: 'ABC234', guestId: 'g-late', name: 'Late' });
  check((await next(late, 'party_closed')).reason === 'new_code', 'old code later: party_closed new_code');

  // Ending closes the room.
  bob.emit('guest:join', { session: 'XYZ567', guestId: 'g-bob', name: 'Bob' });
  await next(bob, 'car_status');
  const ended = next(bob, 'party_closed');
  car2.emit('car:end');
  check((await ended).reason === 'ended', 'end: guests told ended');

  // A bad code is refused at once.
  late.emit('guest:join', { session: 'nope', guestId: 'g', name: 'x' });
  check((await next(late, 'party_closed')).reason === 'unknown', 'bad code: unknown');

  console.log('relay: all checks passed');
  process.exit(0);
})().catch((e) => { console.error('FAIL: ' + e.message); process.exit(1); }).finally(() => server.kill());
