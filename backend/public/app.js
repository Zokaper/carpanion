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

if (sessionParam) {
  // Store session in cookie for share_target POST request
  document.cookie = `session=${sessionParam}; path=/; max-age=86400`;
  document.getElementById('message').innerText = `Connected to car session: ${sessionParam}`;
} else {
  // Check if session exists in cookie
  const match = document.cookie.match(new RegExp('(^| )session=([^;]+)'));
  if (match) {
    document.getElementById('message').innerText = `Connected to car session: ${match[2]}`;
  } else {
    document.getElementById('message').innerText = 'No session found. Please scan the QR code in the Carpanion app.';
  }
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
      if (choiceResult.outcome === 'accepted') {
        console.log('User accepted the A2HS prompt');
      }
      deferredPrompt = null;
    });
  });
});
