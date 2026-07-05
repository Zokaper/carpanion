// Register service worker for PWA
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('sw.js')
    .then(() => console.log('Service Worker Registered'))
    .catch(err => console.error('Service Worker Error', err));
}

// Handle Session from URL
const urlParams = new URLSearchParams(window.location.search);
const sessionParam = urlParams.get('session');
const errorParam = urlParams.get('error');
const successParam = urlParams.get('success');

let currentSession = null;

if (sessionParam) {
  document.cookie = `session=${sessionParam}; path=/; max-age=86400`;
  currentSession = sessionParam;
} else {
  const match = document.cookie.match(new RegExp('(^| )session=([^;]+)'));
  if (match) {
    currentSession = match[2];
  }
}

if (currentSession) {
  document.getElementById('message').innerText = `Session: ${currentSession}`;
} else {
  document.getElementById('message').innerText = 'No session found. Please scan the QR code in the Carpanion app.';
}

if (errorParam) {
  document.getElementById('status').innerText = `Error: ${errorParam}`;
  document.getElementById('status').className = 'error';
} else if (successParam) {
  document.getElementById('status').innerText = 'Song added to queue!';
  document.getElementById('status').className = 'success';
}

// PWA Install Prompt
let deferredPrompt;
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  const installBtn = document.getElementById('installBtn');
  installBtn.style.display = 'block';
  
  installBtn.addEventListener('click', () => {
    installBtn.style.display = 'none';
    deferredPrompt.prompt();
    deferredPrompt.userChoice.then((choiceResult) => {
      deferredPrompt = null;
    });
  });
});

// --- WebSockets & App Logic ---
if (currentSession && typeof io !== 'undefined') {
  const socket = io();
  let canEdit = false;
  let currentQueueState = [];

  socket.on('connect', () => {
    socket.emit('join_passenger', currentSession);
  });

  socket.on('queue_updated', (queue) => {
    currentQueueState = queue;
    renderQueue();
  });

  socket.on('permissions_updated', (allowEditing) => {
    canEdit = allowEditing;
    renderQueue();
  });

  function renderQueue() {
    const list = document.getElementById('queueList');
    list.innerHTML = '';
    currentQueueState.forEach((item, index) => {
      const li = document.createElement('li');
      li.className = 'queue-item';
      li.innerHTML = `
        <img src="${item.thumbnail}" alt="thumb">
        <div class="info">
          <div class="title">${item.title}</div>
        </div>
        ${canEdit ? `
          <div class="controls">
            ${index > 0 ? `<button onclick="reorder('${item.id}', '${item.videoId}', ${item.position - 1})">⬆️</button>` : ''}
            ${index < currentQueueState.length - 1 ? `<button onclick="reorder('${item.id}', '${item.videoId}', ${item.position + 1})">⬇️</button>` : ''}
            <button onclick="deleteSong('${item.id}')" style="background: #ff5252">❌</button>
          </div>
        ` : ''}
      `;
      list.appendChild(li);
    });
  }

  window.deleteSong = (playlistItemId) => {
    socket.emit('passenger_delete_song', playlistItemId);
  };

  window.reorder = (playlistItemId, videoId, newPosition) => {
    socket.emit('passenger_reorder_song', { playlistItemId, videoId, newPosition });
  };

  // Search Logic
  let searchTimeout;
  document.getElementById('searchInput').addEventListener('input', (e) => {
    const query = e.target.value;
    if (!query) {
      document.getElementById('searchResults').classList.add('hidden');
      return;
    }
    clearTimeout(searchTimeout);
    searchTimeout = setTimeout(() => {
      socket.emit('request_search', query);
    }, 500);
  });

  socket.on('search_results', (results) => {
    const container = document.getElementById('searchResults');
    container.innerHTML = '';
    if (results.length === 0) {
      container.innerHTML = '<div class="result-item" style="padding: 16px;">No results</div>';
    } else {
      results.forEach(item => {
        const div = document.createElement('div');
        div.className = 'result-item';
        div.innerHTML = `
          <img src="${item.thumbnail}">
          <div class="info">
            <div class="title">${item.title}</div>
            <div class="channel">${item.channel}</div>
          </div>
          <button onclick="addSong('${item.videoId}')">Add</button>
        `;
        container.appendChild(div);
      });
    }
    container.classList.remove('hidden');
  });

  window.addSong = (videoId) => {
    socket.emit('passenger_add_song', videoId);
    document.getElementById('searchResults').classList.add('hidden');
    document.getElementById('searchInput').value = '';
    document.getElementById('status').innerText = 'Song added via Search!';
    document.getElementById('status').className = 'success';
    setTimeout(() => { document.getElementById('status').innerText = ''; }, 3000);
  };
}
