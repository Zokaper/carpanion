const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const axios = require('axios');
const path = require('path');
const cookieParser = require('cookie-parser');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: '*',
  }
});

app.use(cors());
app.use(express.urlencoded({ extended: true }));
app.use(express.json());
app.use(cookieParser());

// Serve static files for PWA
app.use(express.static(path.join(__dirname, 'public')));

// Store active car sessions
// Map<sessionId, socketId>
const activeSessions = new Map();

io.on('connection', (socket) => {
  console.log('Client connected:', socket.id);

  socket.on('register_session', (sessionId) => {
    console.log(`Session ${sessionId} registered by socket ${socket.id}`);
    activeSessions.set(sessionId, socket.id);
  });

  socket.on('disconnect', () => {
    console.log('Client disconnected:', socket.id);
    for (const [sessionId, sockId] of activeSessions.entries()) {
      if (sockId === socket.id) {
        activeSessions.delete(sessionId);
        break;
      }
    }
  });

  // --- Passenger Events ---
  socket.on('join_passenger', (sessionId) => {
    console.log(`Passenger ${socket.id} joined session ${sessionId}`);
    socket.join(sessionId);
    socket.data.sessionId = sessionId;
    
    // Request latest queue and permissions from the car
    const carSocketId = activeSessions.get(sessionId);
    if (carSocketId) {
      io.to(carSocketId).emit('request_queue');
      io.to(carSocketId).emit('request_permissions');
    }
  });

  socket.on('request_search', (payload) => {
    const sessionId = socket.data.sessionId;
    const carSocketId = activeSessions.get(sessionId);
    if (carSocketId) {
      // payload may be a bare query string (legacy) or { query, source }.
      const query = typeof payload === 'string' ? payload : (payload && payload.query) || '';
      const source = (payload && payload.source) || 'ytmusic';
      io.to(carSocketId).emit('request_search', { passengerId: socket.id, query, source });
    }
  });

  socket.on('passenger_play_song', (id) => {
    const sessionId = socket.data.sessionId;
    const carSocketId = activeSessions.get(sessionId);
    if (carSocketId) io.to(carSocketId).emit('passenger_play_song', id);
  });

  socket.on('passenger_add_resolved', (song) => {
    const sessionId = socket.data.sessionId;
    const carSocketId = activeSessions.get(sessionId);
    if (carSocketId) io.to(carSocketId).emit('passenger_add_resolved', song);
  });

  socket.on('passenger_delete_song', (playlistItemId) => {
    const sessionId = socket.data.sessionId;
    const carSocketId = activeSessions.get(sessionId);
    if (carSocketId) {
      io.to(carSocketId).emit('passenger_delete_song', playlistItemId);
    }
  });

  socket.on('passenger_reorder_song', (data) => {
    const sessionId = socket.data.sessionId;
    if (sessionId) {
      const carSocketId = activeSessions.get(sessionId);
      if (carSocketId) io.to(carSocketId).emit('passenger_reorder_song', data);
    }
  });

  socket.on('passenger_media_action', (action) => {
    const sessionId = socket.data.sessionId;
    if (sessionId) {
      const carSocketId = activeSessions.get(sessionId);
      if (carSocketId) io.to(carSocketId).emit('passenger_media_action', action);
    }
  });

  socket.on('passenger_search_and_add_song', (query) => {
    const sessionId = socket.data.sessionId;
    const carSocketId = activeSessions.get(sessionId);
    if (carSocketId) {
      io.to(carSocketId).emit('passenger_search_and_add_song', query);
    }
  });

  socket.on('passenger_add_song', (videoId) => {
    const sessionId = socket.data.sessionId;
    const carSocketId = activeSessions.get(sessionId);
    if (carSocketId) {
      // Re-use existing add_song event
      io.to(carSocketId).emit('add_song', { videoId, title: '' });
    }
  });

  // --- Carpanion Events ---
  socket.on('search_results', (data) => {
    // data: { passengerId, results }
    if (data.passengerId) {
      io.to(data.passengerId).emit('search_results', data.results);
    }
  });

  socket.on('update_queue', (queueData) => {
    let queue = typeof queueData === 'string' ? JSON.parse(queueData) : queueData;
    // Find sessionId for this car
    for (const [sessionId, sockId] of activeSessions.entries()) {
      if (sockId === socket.id) {
        io.to(sessionId).emit('queue_updated', queue);
        break;
      }
    }
  });

  socket.on('update_playing_status', (title) => {
    for (const [sessionId, sockId] of activeSessions.entries()) {
      if (sockId === socket.id) {
        io.to(sessionId).emit('now_playing_updated', title);
        break;
      }
    }
  });

  socket.on('update_play_state', (isPlaying) => {
    for (const [sessionId, sockId] of activeSessions.entries()) {
      if (sockId === socket.id) {
        io.to(sessionId).emit('play_state_updated', isPlaying);
        break;
      }
    }
  });

  socket.on('update_permissions', (canEdit) => {
    for (const [sessionId, sockId] of activeSessions.entries()) {
      if (sockId === socket.id) {
        io.to(sessionId).emit('permissions_updated', canEdit);
        break;
      }
    }
  });

  socket.on('update_media_permissions', (canControlMedia) => {
    for (const [sessionId, sockId] of activeSessions.entries()) {
      if (sockId === socket.id) {
        io.to(sessionId).emit('media_permissions_updated', canControlMedia);
        break;
      }
    }
  });
});

// Endpoint for PWA Share Target
app.post('/share', async (req, res) => {
  try {
    const { title, text, url } = req.body;
    const session = req.cookies.session;
    const sharedUrl = url || text;
    
    if (!sharedUrl) {
      return res.redirect('/?error=no_url');
    }

    if (!session || !activeSessions.has(session)) {
      return res.redirect('/?error=invalid_session');
    }

    // Convert link using Odesli
    const odesliResponse = await axios.get(`https://api.song.link/v1-alpha.1/links?url=${encodeURIComponent(sharedUrl)}`);
    const data = odesliResponse.data;
    
    // Find YouTube video ID
    let ytVideoId = null;
    if (data.linksByPlatform && data.linksByPlatform.youtube) {
      const ytUrl = data.linksByPlatform.youtube.url;
      // Extract video ID from youtube url (e.g. https://youtube.com/watch?v=VIDEO_ID)
      const match = ytUrl.match(/[?&]v=([^&]+)/);
      if (match) {
        ytVideoId = match[1];
      }
    }

    if (ytVideoId) {
      const socketId = activeSessions.get(session);
      io.to(socketId).emit('add_song', { videoId: ytVideoId, title: title || '' });
      return res.redirect('/?success=1');
    } else {
      return res.redirect('/?error=not_found_on_youtube');
    }
  } catch (error) {
    console.error('Share error:', error.message);
    return res.redirect('/?error=conversion_failed');
  }
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
