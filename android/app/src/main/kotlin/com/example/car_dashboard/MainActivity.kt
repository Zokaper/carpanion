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
