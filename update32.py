import re

with open('lib/main.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Remove _progressController from MediaControlPanel
state_old = '''class _MediaControlPanelState extends State<MediaControlPanel> with SingleTickerProviderStateMixin {
  late AnimationController _progressController;

  @override
  void initState() {
    super.initState();
    // Simulate a 3-minute song progress
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(minutes: 3),
    );
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }'''

state_new = '''class _MediaControlPanelState extends State<MediaControlPanel> {
  // Removed fake progress controller
'''

content = content.replace(state_old, state_new)

# 2. Remove progressController logic inside build()
logic_old = '''    if (isPlaying && !_progressController.isAnimating) {
      _progressController.forward();
    } else if (!isPlaying && _progressController.isAnimating) {
      _progressController.stop();
    }
    
    // Reset if track changes
    if (_progressController.isCompleted) {
       _progressController.reset();
       _progressController.forward();
    }'''

logic_new = '''    // Logic handled natively now'''

content = content.replace(logic_old, logic_new)

# 3. Replace AnimatedBuilder with real Slider
slider_old = '''          // Progress Bar
          AnimatedBuilder(
            animation: _progressController,
            builder: (context, child) {
              return Container(
                height: 4,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: provider.isPlaying ? _progressController.value : 0.0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E5FF),
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00E5FF).withOpacity(0.5),
                          blurRadius: 4,
                        )
                      ]
                    ),
                  ),
                ),
              );
            }
          ),'''

slider_new = '''          // Real Native Progress Bar
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withOpacity(0.1),
              thumbColor: Colors.white,
              trackHeight: 4.0,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0),
              overlayColor: Colors.white.withOpacity(0.2),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16.0),
            ),
            child: Slider(
              value: provider.mediaPosition.clamp(0.0, provider.mediaDuration),
              min: 0.0,
              max: provider.mediaDuration,
              onChanged: (value) {
                // Seek not supported natively through this plugin yet
              },
            ),
          ),'''

content = content.replace(slider_old, slider_new)

# 4. Remove fake reset on buttons
btn_old = '''              _buildControlButton(
                icon: Icons.skip_previous_rounded,
                size: 26,
                onPressed: () {
                  _handleMediaAction('previous');
                  _progressController.reset();
                  if (isPlaying) _progressController.forward();
                },
              ),
              
              _buildPlayPauseButton(
                isPlaying: isPlaying,
                onPressed: () {
                  provider.setPlaying(!isPlaying);
                  _handleMediaAction('playPause');
                },
              ),
              
              _buildControlButton(
                icon: Icons.skip_next_rounded,
                size: 26,
                onPressed: () {
                  _handleMediaAction('next');
                  _progressController.reset();
                  if (isPlaying) _progressController.forward();
                },
              ),'''

btn_new = '''              _buildControlButton(
                icon: Icons.skip_previous_rounded,
                size: 26,
                onPressed: () {
                  _handleMediaAction('previous');
                },
              ),
              
              _buildPlayPauseButton(
                isPlaying: isPlaying,
                onPressed: () {
                  provider.setPlaying(!isPlaying);
                  _handleMediaAction('playPause');
                },
              ),
              
              _buildControlButton(
                icon: Icons.skip_next_rounded,
                size: 26,
                onPressed: () {
                  _handleMediaAction('next');
                },
              ),'''

content = content.replace(btn_old, btn_new)

with open('lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(content)
