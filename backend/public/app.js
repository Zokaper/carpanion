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
  let sortableInstance = null;
  let isQueueSyncing = false;
  let currentPlayingTitle = "";

  socket.on('connect', () => {
    socket.emit('join_passenger', currentSession);
  });

  socket.on('queue_updated', (queue) => {
    currentQueueState = queue;
    isQueueSyncing = false;
    document.getElementById('queueList').style.opacity = '1';
    renderQueue();
  });

  socket.on('now_playing_updated', (title) => {
    currentPlayingTitle = title;
    renderQueue();
  });

  socket.on('permissions_updated', (allowEditing) => {
    canEdit = allowEditing;
    renderQueue();
  });

  socket.on('media_permissions_updated', (canControlMedia) => {
    if (canControlMedia) {
      mediaControls.classList.remove('hidden');
    } else {
      mediaControls.classList.add('hidden');
    }
  });

  function renderQueue() {
    const list = document.getElementById('queueList');
    list.innerHTML = '';
    
    if (sortableInstance) {
      sortableInstance.destroy();
      sortableInstance = null;
    }
    
    currentQueueState.forEach((item, index) => {
      const li = document.createElement('li');
      li.className = 'queue-item' + (currentPlayingTitle === item.title ? ' playing' : '');
      li.dataset.id = item.id;
      li.dataset.videoId = item.videoId;
      li.innerHTML = `
        <img src="${item.thumbnail}" alt="thumb" onerror="this.src='data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI0OCIgaGVpZ2h0PSI0OCI+PHJlY3Qgd2lkdGg9IjQ4IiBoZWlnaHQ9IjQ4IiBmaWxsPSIjMzMzIi8+PC9zdmc+'">
        <div class="info">
          <div class="title">${item.title}</div>
          <div class="artist">${item.artist || 'Unknown Artist'}</div>
        </div>
        ${canEdit ? `
          <div class="controls">
            <button class="icon-btn delete-btn" onclick="deleteSong('${item.id}')" aria-label="Remove from queue">
              <svg viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
            </button>
            <div class="drag-handle" aria-label="Drag to reorder">
              <svg viewBox="0 0 24 24"><circle cx="9" cy="6" r="1.6"/><circle cx="15" cy="6" r="1.6"/><circle cx="9" cy="12" r="1.6"/><circle cx="15" cy="12" r="1.6"/><circle cx="9" cy="18" r="1.6"/><circle cx="15" cy="18" r="1.6"/></svg>
            </div>
          </div>
        ` : ''}
      `;
      list.appendChild(li);
    });

    if (canEdit && !isQueueSyncing) {
      sortableInstance = Sortable.create(list, {
        handle: '.drag-handle',
        animation: 150,
        onEnd: function (evt) {
          if (evt.oldIndex === evt.newIndex) return;
          const item = currentQueueState[evt.oldIndex];
          isQueueSyncing = true;
          document.getElementById('queueList').style.opacity = '0.5';
          reorder(item.id, item.videoId, evt.newIndex);
        }
      });
    }
  }

  window.deleteSong = (playlistItemId) => {
    isQueueSyncing = true;
    document.getElementById('queueList').style.opacity = '0.5';
    socket.emit('passenger_delete_song', playlistItemId);
  };

  window.reorder = (playlistItemId, videoId, newPosition) => {
    socket.emit('passenger_reorder_song', { playlistItemId, videoId, newPosition });
  };

  // Search Logic
  let searchTimeout;
  const searchInput = document.getElementById('searchInput');
  const searchModeToggle = document.getElementById('searchMode');
  const mediaControls = document.getElementById('mediaControls');
  const btnPrev = document.getElementById('btnPrev');
  const btnPlayPause = document.getElementById('btnPlayPause');
  const btnNext = document.getElementById('btnNext');

  const ICON_PLAY = '<svg viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>';
  const ICON_PAUSE = '<svg viewBox="0 0 24 24"><path d="M6 5h4v14H6zM14 5h4v14h-4z"/></svg>';
  let isPlaying = true; // Optimistic: controls only show while media is active

  btnPrev.addEventListener('click', () => socket.emit('passenger_media_action', 'previous'));
  btnPlayPause.addEventListener('click', () => {
    socket.emit('passenger_media_action', 'playPause');
    // Optimistic flip for snappy feedback; the dashboard confirms via play_state_updated.
    isPlaying = !isPlaying;
    btnPlayPause.innerHTML = isPlaying ? ICON_PAUSE : ICON_PLAY;
  });
  btnNext.addEventListener('click', () => socket.emit('passenger_media_action', 'next'));

  // Authoritative play/pause state pushed from the dashboard.
  socket.on('play_state_updated', (playing) => {
    isPlaying = !!playing;
    btnPlayPause.innerHTML = isPlaying ? ICON_PAUSE : ICON_PLAY;
  });

  document.addEventListener('click', (e) => {
    const searchResultsBox = document.getElementById('searchResults');
    if (e.target.tagName === 'BUTTON' || (!searchInput.contains(e.target) && !searchResultsBox.contains(e.target))) {
      searchResultsBox.classList.add('hidden');
      if (e.target.tagName !== 'BUTTON') {
        // If clicking entirely off the search, clear it to clean up the UI
        searchInput.value = '';
      }
    }
  });

  searchInput.addEventListener('input', (e) => {
    const query = e.target.value;
    if (!query) {
      document.getElementById('searchResults').classList.add('hidden');
      return;
    }
    clearTimeout(searchTimeout);
    searchTimeout = setTimeout(() => {
      if (searchModeToggle.checked) {
        socket.emit('request_search', query);
      } else {
        fetch(`https://itunes.apple.com/search?term=${encodeURIComponent(query)}&entity=song&limit=10`)
          .then(res => res.json())
          .then(data => {
            renderSearchResults(data.results.map(item => ({
              id: item.trackId,
              title: item.trackName,
              channel: item.artistName,
              thumbnail: item.artworkUrl100 || item.artworkUrl60,
              isItunes: true
            })));
          })
          .catch(err => console.error(err));
      }
    }, 500);
  });

  socket.on('search_results', (results) => {
    if (searchModeToggle.checked) {
      renderSearchResults(results.map(item => ({
        ...item,
        isItunes: false
      })));
    }
  });

  function renderSearchResults(results) {
    // Drop late-arriving network responses if the user has already cleared the search or tapped "Add"
    if (!searchInput.value.trim()) return;
    
    const container = document.getElementById('searchResults');
    container.innerHTML = '';
    if (results.length === 0) {
      container.innerHTML = '<div class="result-item" style="padding: 16px;">No results</div>';
    } else {
      results.forEach(item => {
        const li = document.createElement('li');
        const escapedTitle = item.title.replace(/'/g, "\\'").replace(/"/g, "&quot;");
        const escapedChannel = item.channel.replace(/'/g, "\\'").replace(/"/g, "&quot;");
        li.innerHTML = `
          <img src="${item.thumbnail}">
          <div class="search-info">
            <div class="search-title">${item.title}</div>
            <div class="search-artist">${item.channel}</div>
          </div>
          <button onclick="addResolvedSong('${item.videoId || ''}', '${escapedTitle}', '${escapedChannel}', ${item.isItunes})">Add</button>
        `;
        container.appendChild(li);
      });
    }
    container.classList.remove('hidden');
  }

  window.addResolvedSong = (videoId, title, artist, isItunes) => {
    if (isItunes) {
      socket.emit('passenger_search_and_add_song', `${title} ${artist}`);
    } else {
      socket.emit('passenger_add_song', videoId);
    }
    clearTimeout(searchTimeout);
    const searchResultsBox = document.getElementById('searchResults');
    searchResultsBox.innerHTML = '';
    searchResultsBox.classList.add('hidden');
    searchInput.value = '';
    document.getElementById('status').innerText = 'Adding to queue...';
    document.getElementById('status').className = 'success';
    setTimeout(() => {
      document.getElementById('status').innerText = '';
      document.getElementById('status').className = '';
    }, 3000);
  };
}
