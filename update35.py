import re

with open('lib/main.dart', 'r', encoding='utf-8') as f:
    content = f.read()

img_old = '''                  child: provider.currentThumbnailUrl.isNotEmpty
                      ? Image.network(
                          provider.currentThumbnailUrl, 
                          fit: BoxFit.cover, 
                          errorBuilder: (c, e, s) => const Icon(Icons.music_video_rounded, color: Colors.white24, size: 60)
                        )
                      : const Center(
                          child: Icon(Icons.music_video_rounded, color: Colors.white24, size: 60),
                        ),'''

img_new = '''                  child: provider.currentAlbumArtBytes != null
                      ? Image.memory(
                          provider.currentAlbumArtBytes!, 
                          fit: BoxFit.cover, 
                          errorBuilder: (c, e, s) => const Icon(Icons.music_video_rounded, color: Colors.white24, size: 60)
                        )
                      : const Center(
                          child: Icon(Icons.music_video_rounded, color: Colors.white24, size: 60),
                        ),'''

content = content.replace(img_old, img_new)

with open('lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(content)
