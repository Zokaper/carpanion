const fs = require('fs');

async function download() {
  const url = 'https://github.com/fluidicon.png';
  const response = await fetch(url);
  const buffer = await response.arrayBuffer();
  fs.writeFileSync('icon-192.png', Buffer.from(buffer));
  fs.writeFileSync('icon-512.png', Buffer.from(buffer));
}

download().then(() => console.log('Icons downloaded!')).catch(console.error);
