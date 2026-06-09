package com.example.car_dashboard

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.app.Notification
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import java.io.ByteArrayOutputStream

class DashcamListenerService : NotificationListenerService() {

    companion object {
        var instance: DashcamListenerService? = null
        var isRecording: Boolean = false
        val activeNotificationsMap = mutableMapOf<String, Map<String, Any>>()
        val activeIntents = mutableMapOf<String, android.app.PendingIntent>()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        checkDashcam(sbn)
        cacheNotification(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName == "com.helge.droiddashcam") {
            var stillRecording = false
            for (n in activeNotifications) {
                if (n.packageName == "com.helge.droiddashcam" && n.id != sbn.id) {
                    stillRecording = true
                    break
                }
            }
            isRecording = stillRecording
        }
        activeNotificationsMap.remove(sbn.key)
        activeIntents.remove(sbn.key)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        for (sbn in activeNotifications) {
            checkDashcam(sbn)
            cacheNotification(sbn)
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        instance = null
    }

    private fun checkDashcam(sbn: StatusBarNotification) {
        if (sbn.packageName == "com.helge.droiddashcam") {
            isRecording = true
        }
    }

    private fun cacheNotification(sbn: StatusBarNotification) {
        val notification = sbn.notification
        // Exclude ongoing (persistent), media notifications, and group summaries
        val isOngoing = (notification.flags and Notification.FLAG_ONGOING_EVENT) != 0
        val isGroupSummary = (notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        val isMedia = notification.extras.getString(Notification.EXTRA_TEMPLATE) == "android.app.Notification\$MediaStyle"
        
        if (isOngoing || isMedia || isGroupSummary) {
            return
        }

        val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val subText = notification.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: ""
        val packageName = sbn.packageName
        
        var appName = ""
        try {
            val appInfo = packageManager.getApplicationInfo(packageName, 0)
            appName = packageManager.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {}

        if (title.isNotEmpty() || text.isNotEmpty()) {
            val map = mutableMapOf<String, Any>(
                "key" to sbn.key,
                "title" to title,
                "text" to text,
                "subText" to subText,
                "appName" to appName,
                "package" to packageName,
                "postTime" to sbn.postTime.toString()
            )
            
            // Save intent for later execution
            if (notification.contentIntent != null) {
                activeIntents[sbn.key] = notification.contentIntent
            }
            
            try {
                var bitmap: Bitmap? = null
                
                // Always prioritize the application icon to avoid displaying notification content (e.g. movie posters)
                try {
                    val iconDrawable = packageManager.getApplicationIcon(packageName)
                    bitmap = drawableToBitmap(iconDrawable)
                } catch (e: Exception) {}
                
                // Fallback to small/large icons if app icon is somehow unavailable
                if (bitmap == null) {
                    val smallIcon = notification.smallIcon
                    if (smallIcon != null) {
                        val drawable = smallIcon.loadDrawable(this)
                        if (drawable != null) {
                            bitmap = drawableToBitmap(drawable)
                        }
                    }
                }

                if (bitmap != null) {
                    val stream = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    map["icon"] = stream.toByteArray()
                }
            } catch (e: Exception) {
                // Ignore icon extraction failure
            }
            
            activeNotificationsMap[sbn.key] = map
        }
    }
    
    private fun drawableToBitmap(drawable: Drawable): Bitmap? {
        if (drawable is BitmapDrawable) {
            if (drawable.bitmap != null) {
                return drawable.bitmap
            }
        }
        val bitmap: Bitmap = if (drawable.intrinsicWidth <= 0 || drawable.intrinsicHeight <= 0) {
            Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        } else {
            Bitmap.createBitmap(drawable.intrinsicWidth, drawable.intrinsicHeight, Bitmap.Config.ARGB_8888)
        }
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }
}
