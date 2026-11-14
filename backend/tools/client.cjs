// A Socket.IO client for Node scripts, with no extra dependency: the browser build the server ships (by file path,
// since the package doesn't export it), over Node's own WebSocket (Node 22+).
const path = require('path');
const io = require(path.join(path.dirname(require.resolve('socket.io')), '..', 'client-dist', 'socket.io.js'));

module.exports = (url) => io(url, { transports: ['websocket'], forceNew: true });
