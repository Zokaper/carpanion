package com.example.car_dashboard

import android.content.Intent
import android.telecom.Call
import android.telecom.InCallService
import android.util.Log

class CallService : InCallService() {
    companion object {
        var instance: CallService? = null
        var activeCall: Call? = null
        var isMuted: Boolean = false
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        if (instance == this) instance = null
        super.onDestroy()
    }

    private val callCallback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) {
            super.onStateChanged(call, state)
            Log.d("CallService", "onStateChanged: $state")
            notifyState(call, state)
        }
    }

    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        Log.d("CallService", "onCallAdded")
        activeCall = call
        call.registerCallback(callCallback)
        notifyState(call, call.state)

        // Bring the app to the foreground since we manage the UI
        val intent = Intent(this, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        startActivity(intent)
    }

    override fun onCallRemoved(call: Call) {
        super.onCallRemoved(call)
        Log.d("CallService", "onCallRemoved")
        call.unregisterCallback(callCallback)
        if (activeCall == call) {
            activeCall = null
            MainActivity.instance?.notifyCallStateChanged(Call.STATE_DISCONNECTED, null)
        }
    }

    private fun notifyState(call: Call, state: Int) {
        var number: String? = null
        try {
            number = call.details?.handle?.schemeSpecificPart
        } catch (e: Exception) {
            // Handle parsing error
        }
        MainActivity.instance?.notifyCallStateChanged(state, number)
    }
}
