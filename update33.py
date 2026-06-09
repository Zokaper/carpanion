import re

with open('android/app/src/main/kotlin/com/example/car_dashboard/MainActivity.kt', 'r', encoding='utf-8') as f:
    content = f.read()

import_old = '''import android.content.ComponentName'''
import_new = '''import android.content.ComponentName
import android.graphics.Bitmap
import java.io.ByteArrayOutputStream'''
content = content.replace(import_old, import_new)

method_old = '''                        } else {
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                else -> {'''

method_new = '''                        } else {
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "getMediaArt" -> {
                    try {
                        val mediaSessionManager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
                        val componentName = ComponentName(this@MainActivity, DashcamListenerService::class.java)
                        
                        val controllers = mediaSessionManager.getActiveSessions(componentName)
                        
                        if (controllers.isNotEmpty()) {
                            val controller = controllers[0]
                            var bitmap = controller.metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
                            if (bitmap == null) {
                                bitmap = controller.metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART)
                            }
                            if (bitmap == null) {
                                bitmap = controller.metadata?.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)
                            }
                            
                            if (bitmap != null) {
                                val stream = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                                val byteArray = stream.toByteArray()
                                result.success(byteArray)
                            } else {
                                result.success(null)
                            }
                        } else {
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                else -> {'''

content = content.replace(method_old, method_new)

with open('android/app/src/main/kotlin/com/example/car_dashboard/MainActivity.kt', 'w', encoding='utf-8') as f:
    f.write(content)
