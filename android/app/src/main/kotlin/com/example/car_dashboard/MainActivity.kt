package com.example.car_dashboard

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.media.session.MediaSessionManager
import android.media.MediaMetadata
import android.content.Context
import android.content.ComponentName
import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.telecom.TelecomManager
import android.content.IntentFilter
import android.content.BroadcastReceiver
import android.telephony.TelephonyManager
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.core.app.ActivityCompat
import android.app.role.RoleManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.media.AudioManager

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.car_dashboard/system"
    private var methodChannel: MethodChannel? = null
    private var phoneStateReceiver: BroadcastReceiver? = null

    companion object {
        var instance: MainActivity? = null
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
    }

    fun notifyCallStateChanged(stateInt: Int, number: String?) {
        runOnUiThread {
            methodChannel?.invokeMethod("onCallStateChanged", mapOf<String, Any>(
                "stateInt" to stateInt,
                "number" to (number ?: "")
            ))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "bringToFront" -> {
                    val intent = Intent(this, MainActivity::class.java)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    startActivity(intent)
                    result.success(true)
                }
                "startDashcam" -> {
                    try {
                        val launchIntent = Intent("com.helge.droiddashcam.START_RECORDING")
                        launchIntent.setPackage("com.helge.droiddashcam")
                        sendBroadcast(launchIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopDashcam" -> {
                    try {
                        val launchIntent = Intent("com.helge.droiddashcam.STOP_RECORDING")
                        launchIntent.setPackage("com.helge.droiddashcam")
                        sendBroadcast(launchIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getBrightnessInfo" -> {
                    try {
                        val brightness = Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS)
                        val mode = Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE)
                        result.success(mapOf("brightness" to brightness, "adaptive" to (mode == Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC)))
                    } catch(e: Exception) {
                        result.success(mapOf("brightness" to 128, "adaptive" to true))
                    }
                }
                "setSystemBrightness" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.System.canWrite(context)) {
                        val intent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS)
                        intent.data = android.net.Uri.parse("package:" + context.packageName)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val mode = call.argument<Boolean>("adaptive")
                        if (mode != null) {
                            Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE, if (mode) Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC else Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
                        }
                        val brightness = call.argument<Int>("brightness")
                        if (brightness != null) {
                            Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, brightness)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getRingerMode" -> {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    result.success(audioManager.ringerMode)
                }
                "setRingerMode" -> {
                    try {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val mode = call.argument<Int>("mode") ?: AudioManager.RINGER_MODE_NORMAL
                        audioManager.ringerMode = mode
                        result.success(true)
                    } catch (e: SecurityException) {
                        val intent = Intent(android.provider.Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(false)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "checkOverlay" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        result.success(Settings.canDrawOverlays(this))
                    } else {
                        result.success(true)
                    }
                }
                "requestOverlay" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
                        startActivity(intent)
                        result.success(true)
                    } else {
                        result.success(true)
                    }
                }
                "checkNotificationAccess" -> {
                    val componentName = android.content.ComponentName(this, DashcamListenerService::class.java)
                    val enabledListeners = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
                    val hasAccess = enabledListeners?.contains(componentName.flattenToString()) == true
                    result.success(hasAccess)
                }
                "requestNotificationAccess" -> {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    startActivity(intent)
                    result.success(true)
                }
                "getDashcamStatus" -> {
                    result.success(DashcamListenerService.isRecording)
                }
                "isNavigating" -> {
                    result.success(DashcamListenerService.isNavigating)
                }
                "getNetworkStatus" -> {
                    try {
                        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val network = connectivityManager.activeNetwork
                        val capabilities = connectivityManager.getNetworkCapabilities(network)
                        
                        var isWifi = false
                        var wifiBars = 0
                        var isCellular = false
                        var cellularBars = 0
                        
                        if (capabilities != null) {
                            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                                isWifi = true
                                val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                val wifiInfo = wifiManager.connectionInfo
                                wifiBars = WifiManager.calculateSignalLevel(wifiInfo.rssi, 5)
                            }
                            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                                isCellular = true
                            }
                        }
                        
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                            val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as android.telephony.TelephonyManager
                            val signal = telephonyManager.signalStrength
                            if (signal != null) {
                                cellularBars = signal.level
                            }
                        }
                        
                        result.success(mapOf(
                            "isWifi" to isWifi,
                            "wifiBars" to wifiBars,
                            "isCellular" to isCellular,
                            "cellularBars" to cellularBars
                        ))
                    } catch (e: Exception) {
                        result.success(mapOf(
                            "isWifi" to false,
                            "wifiBars" to 0,
                            "isCellular" to false,
                            "cellularBars" to 0
                        ))
                    }
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
                }
                "getCurrentMediaMetadata" -> {
                    try {
                        val mediaSessionManager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
                        val componentName = ComponentName(this@MainActivity, DashcamListenerService::class.java)
                        val controllers = mediaSessionManager.getActiveSessions(componentName)
                        val controller = controllers.firstOrNull { it.packageName == "com.google.android.apps.youtube.music" }
                            ?: controllers.firstOrNull()
                        if (controller != null) {
                            val md = controller.metadata
                            val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE)
                                ?: md?.getString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE) ?: ""
                            val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                                ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
                            val album = md?.getString(MediaMetadata.METADATA_KEY_ALBUM) ?: ""
                            // TEMP RECON (Feature C): dump every id-ish field so we can tell
                            // whether any reliably carries the current track's videoId
                            // (especially for tracks YT Music autoplayed). Remove once decided.
                            android.util.Log.d("MediaRecon",
                                "title=$title" +
                                " | MEDIA_ID=${md?.getString(MediaMetadata.METADATA_KEY_MEDIA_ID)}" +
                                " | desc.mediaId=${md?.description?.mediaId}" +
                                " | desc.mediaUri=${md?.description?.mediaUri}" +
                                " | activeQueueItemId=${controller.playbackState?.activeQueueItemId}")
                            result.success(mapOf(
                                "title" to title,
                                "artist" to artist,
                                "album" to album
                            ))
                        } else {
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
                "getActiveNotifications" -> {
                    try {
                        val notifications = DashcamListenerService.activeNotificationsMap.values.toList()
                        result.success(notifications)
                    } catch (e: Exception) {
                        result.success(emptyList<Map<String, Any>>())
                    }
                }
                "clearAllNotifications" -> {
                    try {
                        DashcamListenerService.instance?.cancelAllNotifications()
                        DashcamListenerService.activeNotificationsMap.clear()
                        DashcamListenerService.activeIntents.clear()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FAILED", "Could not clear notifications", null)
                    }
                }
                "clearNotification" -> {
                    val key = call.argument<String>("key")
                    if (key != null) {
                        try {
                            DashcamListenerService.instance?.cancelNotification(key)
                            DashcamListenerService.activeNotificationsMap.remove(key)
                            DashcamListenerService.activeIntents.remove(key)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("FAILED", "Could not clear notification", null)
                        }
                    } else {
                        result.error("INVALID", "Key is null", null)
                    }
                }
                "openNotification" -> {
                    val key = call.argument<String>("key")
                    if (key != null) {
                        try {
                            val intent = DashcamListenerService.activeIntents[key]
                            if (intent != null) {
                                // Try to launch the pending intent
                                try {
                                    val options = android.app.ActivityOptions.makeBasic()
                                    if (android.os.Build.VERSION.SDK_INT >= 34) {
                                        options.setPendingIntentBackgroundActivityStartMode(
                                            android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                                        )
                                    }
                                    intent.send(null, 0, null, null, null, null, options.toBundle())
                                    result.success(true)
                                    return@setMethodCallHandler
                                } catch (e: Exception) {
                                    // Fall through to fallback
                                }
                            }
                            
                            // Fallback
                            val packageName = DashcamListenerService.activeNotificationsMap[key]?.get("package") as? String
                            if (packageName != null) {
                                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                                if (launchIntent != null) {
                                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(launchIntent)
                                    result.success(true)
                                    return@setMethodCallHandler
                                }
                            }
                            result.error("FAILED", "No intent found", null)
                        } catch (e: Exception) {
                            result.error("FAILED", "Could not open notification", null)
                        }
                    } else {
                        result.error("INVALID", "Key is null", null)
                    }
                }
                "checkPhonePermissions" -> {
                    val readPhoneState = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
                    val callPhone = ContextCompat.checkSelfPermission(this, Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED
                    val readCallLog = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED
                    val readContacts = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED
                    val answerPhoneCalls = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ContextCompat.checkSelfPermission(this, Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED
                    } else {
                        true
                    }
                    result.success(readPhoneState && callPhone && answerPhoneCalls && readCallLog && readContacts)
                }
                "requestPhonePermissions" -> {
                    val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.ANSWER_PHONE_CALLS, Manifest.permission.CALL_PHONE, Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS)
                    } else {
                        arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.CALL_PHONE, Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS)
                    }
                    ActivityCompat.requestPermissions(this, permissions, 1002)
                    result.success(true)
                }
                "isDefaultDialer" -> {
                    val telecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                    result.success(telecomManager.defaultDialerPackage == packageName)
                }
                "answerCall" -> {
                    try {
                        val call = CallService.activeCall
                        if (call != null) {
                            call.answer(android.telecom.VideoProfile.STATE_AUDIO_ONLY)
                            result.success(true)
                        } else {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                if (ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED) {
                                    val telecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                                    telecomManager.acceptRingingCall()
                                    result.success(true)
                                } else {
                                    result.error("PERMISSION_DENIED", "Missing ANSWER_PHONE_CALLS permission", null)
                                }
                            } else {
                                result.error("UNSUPPORTED", "acceptRingingCall requires API 26+", null)
                            }
                        }
                    } catch (e: Exception) {
                        result.error("FAILED", "Could not answer call: ${e.message}", null)
                    }
                }
                "endCall" -> {
                    try {
                        val call = CallService.activeCall
                        if (call != null) {
                            if (call.state == android.telecom.Call.STATE_RINGING) {
                                call.reject(false, null)
                            } else {
                                call.disconnect()
                            }
                            result.success(true)
                        } else {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                if (ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED) {
                                    val telecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                                    val ended = telecomManager.endCall()
                                    result.success(ended)
                                } else {
                                    result.error("PERMISSION_DENIED", "Missing ANSWER_PHONE_CALLS permission", null)
                                }
                            } else {
                                result.error("UNSUPPORTED", "endCall requires API 28+", null)
                            }
                        }
                    } catch (e: Exception) {
                        result.error("FAILED", "Could not end call: ${e.message}", null)
                    }
                }
                "toggleMute" -> {
                    try {
                        val mute = call.argument<Boolean>("mute") ?: false
                        CallService.instance?.setMuted(mute)
                        CallService.isMuted = mute
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FAILED", "Could not toggle mute: ${e.message}", null)
                    }
                }
                "requestDefaultDialer" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val roleManager = getSystemService(Context.ROLE_SERVICE) as RoleManager
                            if (roleManager.isRoleAvailable(RoleManager.ROLE_DIALER) && !roleManager.isRoleHeld(RoleManager.ROLE_DIALER)) {
                                val intent = roleManager.createRequestRoleIntent(RoleManager.ROLE_DIALER)
                                startActivityForResult(intent, 1003)
                            }
                        } else {
                            val telecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                            if (telecomManager.defaultDialerPackage != packageName) {
                                val intent = Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER)
                                intent.putExtra(TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME, packageName)
                                startActivityForResult(intent, 1004)
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FAILED", "Could not request default dialer: ${e.message}", null)
                    }
                }
                "makeCall" -> {
                    val number = call.argument<String>("number")
                    if (number != null) {
                        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED) {
                            try {
                                lastOutgoingNumber = number
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                    val telecomManager = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
                                    val uri = Uri.parse("tel:$number")
                                    telecomManager.placeCall(uri, android.os.Bundle())
                                } else {
                                    val intent = Intent(Intent.ACTION_CALL)
                                    intent.data = Uri.parse("tel:$number")
                                    startActivity(intent)
                                }

                                // Delay and forcefully bring the app back to the front
                                // to hide the system dialer UI that pops up automatically
                                android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                                    val bringIntent = Intent(this@MainActivity, MainActivity::class.java)
                                    bringIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                                    startActivity(bringIntent)
                                }, 600)

                                result.success(true)
                            } catch (e: Exception) {
                                result.error("FAILED", "Could not make call: ${e.message}", null)
                            }
                        } else {
                            result.error("PERMISSION_DENIED", "Missing CALL_PHONE permission", null)
                        }
                    } else {
                        result.error("INVALID", "Number is null", null)
                    }
                }
                "playFromMediaSession" -> {
                    try {
                        val videoId = call.argument<String>("videoId")
                        val query = call.argument<String>("query") ?: ""
                        val mediaSessionManager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
                        val componentName = ComponentName(this@MainActivity, DashcamListenerService::class.java)
                        val controllers = mediaSessionManager.getActiveSessions(componentName)
                        
                        val ytController = controllers.firstOrNull { 
                            it.packageName == "com.google.android.apps.youtube.music" 
                        }
                        
                        if (ytController != null) {
                            if (videoId != null && videoId.isNotEmpty()) {
                                // Primary: playFromUri — confirmed working, no UI flash
                                val uri = android.net.Uri.parse("https://music.youtube.com/watch?v=$videoId")
                                val extras = android.os.Bundle()
                                extras.putString("android.intent.extra.focus", "vnd.android.cursor.item/audio")
                                ytController.transportControls.playFromUri(uri, extras)
                                android.util.Log.d("Carpanion", "playFromUri sent to YT Music: $uri")
                                result.success(mapOf(
                                    "success" to true,
                                    "method" to "playFromUri",
                                    "videoId" to videoId
                                ))
                            } else if (query.isNotEmpty()) {
                                // Fallback: playFromSearch (less reliable, may be ignored by YT Music)
                                val extras = android.os.Bundle()
                                extras.putString("query", query)
                                extras.putString("android.intent.extra.focus", "vnd.android.cursor.item/audio")
                                ytController.transportControls.playFromSearch(query, extras)
                                android.util.Log.d("Carpanion", "playFromSearch sent to YT Music: $query")
                                result.success(mapOf(
                                    "success" to true,
                                    "method" to "playFromSearch",
                                    "query" to query
                                ))
                            } else {
                                result.success(mapOf(
                                    "success" to false,
                                    "error" to "No videoId or query provided"
                                ))
                            }
                        } else {
                            android.util.Log.w("Carpanion", "No YT Music media session found")
                            result.success(mapOf(
                                "success" to false,
                                "error" to "No YT Music media session found"
                            ))
                        }
                    } catch (e: Exception) {
                        android.util.Log.e("Carpanion", "playFromMediaSession error: ${e.message}")
                        result.success(mapOf(
                            "success" to false,
                            "error" to (e.message ?: "Unknown error")
                        ))
                    }
                }
                "seekTo" -> {
                    try {
                        val positionMs = (call.argument<Number>("position"))?.toLong()
                        if (positionMs == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val mediaSessionManager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
                        val componentName = ComponentName(this@MainActivity, DashcamListenerService::class.java)
                        val controllers = mediaSessionManager.getActiveSessions(componentName)
                        val ytController = controllers.firstOrNull {
                            it.packageName == "com.google.android.apps.youtube.music"
                        } ?: controllers.firstOrNull()
                        if (ytController != null) {
                            ytController.transportControls.seekTo(positionMs)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        android.util.Log.e("Carpanion", "seekTo error: ${e.message}")
                        result.success(false)
                    }
                }
                "getYtmCookies" -> {
                    // The WebView shares the app's global CookieManager, so this
                    // returns the full cookie string for music.youtube.com AFTER an
                    // in-app login — including httpOnly ones like __Secure-3PAPISID.
                    try {
                        val cookies = android.webkit.CookieManager.getInstance()
                            .getCookie("https://music.youtube.com")
                        result.success(cookies)
                    } catch (e: Exception) {
                        android.util.Log.e("Carpanion", "getYtmCookies error: ${e.message}")
                        result.success(null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        setupPhoneStateReceiver()
    }

    private var lastOutgoingNumber: String = ""

    private fun setupPhoneStateReceiver() {
        if (phoneStateReceiver == null) {
            val filter = IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED)
            phoneStateReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action == TelephonyManager.ACTION_PHONE_STATE_CHANGED) {
                        val stateStr = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
                        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER) ?: ""
                        
                        var finalNumber = number
                        if (finalNumber.isEmpty() && stateStr == TelephonyManager.EXTRA_STATE_OFFHOOK) {
                            finalNumber = lastOutgoingNumber
                        } else if (stateStr == TelephonyManager.EXTRA_STATE_IDLE) {
                            lastOutgoingNumber = ""
                        }
                        
                        runOnUiThread {
                            // Automatically bring the dashboard to front during active calls or ringing
                            if (stateStr == TelephonyManager.EXTRA_STATE_RINGING || stateStr == TelephonyManager.EXTRA_STATE_OFFHOOK) {
                                val bringIntent = Intent(this@MainActivity, MainActivity::class.java)
                                bringIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                                startActivity(bringIntent)
                            }
                            
                            methodChannel?.invokeMethod("onCallStateChanged", mapOf(
                                "state" to (stateStr ?: ""),
                                "number" to finalNumber
                            ))
                        }
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(phoneStateReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(phoneStateReceiver, filter)
            }
        }
    }

    override fun onDestroy() {
        if (instance == this) instance = null
        if (phoneStateReceiver != null) {
            unregisterReceiver(phoneStateReceiver)
            phoneStateReceiver = null
        }
        super.onDestroy()
    }
}
