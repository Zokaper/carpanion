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
        var isNavigating: Boolean = false
        val activeNotificationsMap = mutableMapOf<String, Map<String, Any>>()
        val activeIntents = mutableMapOf<String, android.app.PendingIntent>()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        checkDashcam(sbn)
        checkNavigation(sbn)
        cacheNotification(sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName == "com.google.android.apps.maps") {
            var stillNavigating = false
            for (n in activeNotifications) {
                if (n.packageName == "com.google.android.apps.maps" && n.id != sbn.id) {
                    val isOngoing = (n.notification.flags and Notification.FLAG_ONGOING_EVENT) != 0
                    if (isOngoing) {
                        stillNavigating = true
                        break
                    }
                }
            }
            isNavigating = stillNavigating
        }

        if (sbn.packageName == "com.helge.droiddashcam") {
            updateDashcamRecordingState(sbn.id)
        }
        activeNotificationsMap.remove(sbn.key)
        activeIntents.remove(sbn.key)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        for (sbn in activeNotifications) {
            checkDashcam(sbn)
            checkNavigation(sbn)
            cacheNotification(sbn)
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        instance = null
    }

    private fun isDashcamRecordingNotification(sbn: StatusBarNotification): Boolean {
        if (sbn.packageName != "com.helge.droiddashcam") return false
        val notification = sbn.notification
        val usesChronometer = notification.extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER, false)
        if (usesChronometer) return true
        
        val title = notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.lowercase() ?: ""
        val text = notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.lowercase() ?: ""
        return title.contains("record") || text.contains("record") || title.contains("rec") || text.contains("rec")
    }

    private fun checkDashcam(sbn: StatusBarNotification) {
        if (sbn.packageName == "com.helge.droiddashcam") {
            if (isDashcamRecordingNotification(sbn)) {
                isRecording = true
            } else {
                updateDashcamRecordingState(sbn.id)
            }
        }
    }

    private fun updateDashcamRecordingState(excludeId: Int = -1) {
        var stillRecording = false
        try {
            for (n in activeNotifications) {
                if (n.id != excludeId && isDashcamRecordingNotification(n)) {
                    stillRecording = true
                    break
                }
            }
        } catch (e: Exception) {}
        isRecording = stillRecording
    }

    private fun checkNavigation(sbn: StatusBarNotification) {
        if (sbn.packageName == "com.google.android.apps.maps") {
            val isOngoing = (sbn.notification.flags and Notification.FLAG_ONGOING_EVENT) != 0
            if (isOngoing) {
                isNavigating = true
            }
            // TEMP RECON (Feature B): dump the Maps ongoing notification extras so we can
            // confirm Maps still posts while projecting to Android Auto and see which
            // fields carry ETA vs remaining distance. Remove once parsing is settled.
            val ex = sbn.notification.extras
            android.util.Log.d("NavRecon",
                "ongoing=$isOngoing" +
                " | TITLE=${ex.getCharSequence(Notification.EXTRA_TITLE)}" +
                " | TEXT=${ex.getCharSequence(Notification.EXTRA_TEXT)}" +
                " | SUB_TEXT=${ex.getCharSequence(Notification.EXTRA_SUB_TEXT)}" +
                " | SUMMARY=${ex.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)}" +
                " | INFO=${ex.getCharSequence(Notification.EXTRA_INFO_TEXT)}" +
                " | LINES=${ex.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.joinToString(" // ")}")
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
            val currentMessagesList = mutableListOf<Map<String, String>>()
            val extras = notification.extras
            val messagesArray = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
            if (messagesArray != null && messagesArray.isNotEmpty()) {
                for (p in messagesArray) {
                    if (p is android.os.Bundle) {
                        val msgText = p.getCharSequence("text")?.toString()
                        var sender = p.getCharSequence("sender")?.toString()
                        if (sender == null) {
                            try {
                                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                                    val person = p.getParcelable<android.app.Person>("sender_person")
                                    sender = person?.name?.toString()
                                }
                            } catch (e: Exception) {}
                        }
                        val time = p.getLong("time", 0L)
                        
                        if (msgText != null) {
                            currentMessagesList.add(mapOf(
                                "text" to msgText, 
                                "sender" to (sender ?: ""),
                                "time" to time.toString()
                            ))
                        }
                    }
                }
            } else {
                val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
                if (lines != null && lines.isNotEmpty()) {
                    for (line in lines) {
                        currentMessagesList.add(mapOf("text" to line.toString(), "sender" to "", "time" to sbn.postTime.toString()))
                    }
                } else if (text.isNotEmpty()) {
                    currentMessagesList.add(mapOf("text" to text, "sender" to "", "time" to sbn.postTime.toString()))
                }
            }

            val existingMap = activeNotificationsMap[sbn.key]
            @Suppress("UNCHECKED_CAST")
            val existingMessages = (existingMap?.get("messages") as? List<Map<String, String>>) ?: emptyList()
            
            val mergedMessages = existingMessages.toMutableList()
            for (msg in currentMessagesList) {
                val isDuplicate = mergedMessages.any { existing -> 
                    existing["text"] == msg["text"] && 
                    (msg["time"] == "0" || existing["time"] == msg["time"] || existing["time"] == "0")
                }
                if (!isDuplicate) {
                    mergedMessages.add(msg)
                }
            }

            val map = mutableMapOf<String, Any>(
                "key" to sbn.key,
                "title" to title,
                "text" to text,
                "subText" to subText,
                "appName" to appName,
                "package" to packageName,
                "postTime" to sbn.postTime.toString()
            )
            if (mergedMessages.isNotEmpty()) {
                map["messages"] = mergedMessages
            }
            
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
