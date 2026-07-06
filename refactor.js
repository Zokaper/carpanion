const fs = require('fs');

let content = fs.readFileSync('lib/ui/queue_tab.dart', 'utf8');

// 1. Replace _lastValidIndex with _currentPlayingIndex
content = content.replace(/int _lastValidIndex = -1;/g, 'int _currentPlayingIndex = -1;');

// 2. Replace _onDashboardUpdate auto-recovery logic
content = content.replace(/if \(_queueStarted\) \{([\s\S]*?)_scrollToPlayingTrack\(\);/g, `if (_queueStarted) {
        int index = _ytService.currentQueue.indexWhere((item) {
          final qTitle = (item['title'] ?? '').toLowerCase();
          final dTitle = _lastTrack.toLowerCase();
          return qTitle == dTitle || qTitle.contains(dTitle) || dTitle.contains(qTitle);
        });

        if (index != -1) {
          _currentPlayingIndex = index;
        } else {
          if (_currentPlayingIndex != -1 && _ytService.currentQueue.length > _currentPlayingIndex + 1) {
            _currentPlayingIndex++;
            debugPrint("Auto-DJ: Playing next song at index $_currentPlayingIndex");
            final nextVideoId = _ytService.currentQueue[_currentPlayingIndex]['videoId'];
            _playQueueAt(nextVideoId, _currentPlayingIndex);
          } else if (_currentPlayingIndex != -1 && _ytService.currentQueue.length <= _currentPlayingIndex + 1) {
            _currentPlayingIndex = -1;
          }
        }
      }

      _scrollToPlayingTrack();`);

// 3. Fix add_song socket auto-start
content = content.replace(/if \(!_queueStarted && _ytService.playlistId != null\) \{\s*_playQueue\(_ytService.playlistId!\);\s*\}/g, `if (!_queueStarted && _ytService.currentQueue.isNotEmpty) {
            _playQueue();
          }`);

// 4. Fix passenger_search_and_add_song auto-start
content = content.replace(/if \(!_queueStarted && _ytService.playlistId != null\) \{\s*_playQueue\(_ytService.playlistId!\);\s*\}/g, `if (!_queueStarted && _ytService.currentQueue.isNotEmpty) {
          _playQueue();
        }`);

// 5. Replace passenger_media_action next/prev throttling logic
const mediaActionRegex = /if \(action == 'playPause'\) \{([\s\S]*?)\} else if \(action == 'previous'\) \{([\s\S]*?)\}/g;
content = content.replace(mediaActionRegex, `if (action == 'playPause') {
            await FlutterMediaController.togglePlayPause();
          } else if (action == 'next') {
            if (_queueStarted && _currentPlayingIndex != -1 && _ytService.currentQueue.length > _currentPlayingIndex + 1) {
              _currentPlayingIndex++;
              _playQueueAt(_ytService.currentQueue[_currentPlayingIndex]['videoId'], _currentPlayingIndex);
            } else {
              await FlutterMediaController.nextTrack();
            }
          } else if (action == 'previous') {
            if (_queueStarted && _currentPlayingIndex > 0) {
              _currentPlayingIndex--;
              _playQueueAt(_ytService.currentQueue[_currentPlayingIndex]['videoId'], _currentPlayingIndex);
            } else {
              await FlutterMediaController.previousTrack();
            }
          }`);

// 6. Rewrite _playQueue and _playQueueAt
const playQueueRegex = /void _playQueue\(String playlistId\) \{([\s\S]*?)void _playQueueAt\(String videoId, String playlistId\) \{([\s\S]*?)\} \/\//g;
content = content.replace(playQueueRegex, `void _playQueue() {
    if (_ytService.currentQueue.isEmpty) return;
    setState(() {
      _queueStarted = true;
      _showQrCodeOverlay = false;
      _currentPlayingIndex = 0;
    });
    _playQueueAt(_ytService.currentQueue[0]['videoId'], 0);
  }

  void _playQueueAt(String videoId, int index) {
    _currentPlayingIndex = index;
    final intent = AndroidIntent(
      action: 'action_view',
      data: 'https://music.youtube.com/watch?v=$videoId',
      package: 'com.google.android.apps.youtube.music',
    );
    intent.launch().catchError((e) {
      debugPrint("Could not launch targeted YT Music intent: $e");
    });
    
    if (mounted) {
      Provider.of<DashboardProvider>(context, listen: false).setWaitingForMusic();
    }
    
    Future.delayed(const Duration(seconds: 2), () {
      final backIntent = AndroidIntent(
        action: 'action_main',
        package: 'com.example.car_dashboard',
        componentName: 'com.example.car_dashboard.MainActivity',
        flags: [268435456, 131072],
      );
      backIntent.launch().catchError((e) => debugPrint("Could not reorder Dashboard to front: $e"));
    });
  } //`);

// 7. Fix "START COLLAB" button
content = content.replace(/onPressed: ytService\.playlistId != null \? \(\) \{([\s\S]*?)\_playQueue\(ytService\.playlistId!\);([\s\S]*?)\} : null,/g, `onPressed: () {
                          if (ytService.currentQueue.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Please add at least one song to start the collab!')),
                            );
                          } else {
                            _playQueue();
                          }
                        },`);

fs.writeFileSync('lib/ui/queue_tab.dart', content);
