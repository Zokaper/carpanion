import re

with open('android/app/src/main/kotlin/com/example/car_dashboard/MainActivity.kt', 'r', encoding='utf-8') as f:
    content = f.read()

import_old = '''import android.provider.Settings'''
import_new = '''import android.provider.Settings
import android.media.session.MediaSessionManager
import android.media.MediaMetadata
import android.content.Context
import android.content.ComponentName'''

content = content.replace(import_old, import_new)

method_old = '''                "getDashcamStatus" -> {
                    result.success(DashcamListenerService.isRecording)
                }'''

method_new = '''                "getDashcamStatus" -> {
                    result.success(DashcamListenerService.isRecording)
                }
                "getMediaProgress" -> {
                    try {
                        val mediaSessionManager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
                        val componentName = ComponentName(this@MainActivity, DashcamListenerService::class.java)
                        
                        // We need the notification listener permission to get active sessions
                        val controllers = mediaSessionManager.getActiveSessions(componentName)
                        
                        if (controllers.isNotEmpty()) {
                            val controller = controllers[0]
                            val position = controller.playbackState?.position ?: 0L
                            val duration = controller.metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L
                            
                            val map = mapOf(
                                "position" to position,
                                "duration" to duration
                            )
                            result.success(map)
                        } else {
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }'''

content = content.replace(method_old, method_new)

with open('android/app/src/main/kotlin/com/example/car_dashboard/MainActivity.kt', 'w', encoding='utf-8') as f:
    f.write(content)
