package com.github.veneraworks.veneraplus

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class DownloadBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    private val isVisible: () -> Boolean,
    private val requestNotifications: () -> Unit,
) {
    private val channel = MethodChannel(messenger, "venera/downloads")
    private val main = Handler(Looper.getMainLooper())
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private var owner: String? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    init {
        channel.setMethodCallHandler { call, result ->
            val requestedOwner = call.argument<String>("owner")
            if (requestedOwner.isNullOrBlank()) {
                result.error("invalid_owner", "A download owner is required", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "bind" -> {
                        val previous = DownloadService.state.active
                        if (previous != null && previous.owner != requestedOwner) {
                            DownloadService.stopOwned(previous.owner, previous.id)
                        }
                        DownloadService.state.bind(requestedOwner)
                        owner = requestedOwner
                        DownloadService.onStopped = { session, reason ->
                            channel.invokeMethod("stopped", mapOf(
                                "owner" to session.owner, "session" to session.id, "reason" to reason,
                            ))
                        }
                        try {
                            watchNetwork()
                        } catch (error: Exception) {
                            // Backoff timers still recover without connectivity hints.
                            Log.w("DownloadService", "Cannot observe network changes", error)
                        }
                        result.success(null)
                    }
                    "start" -> {
                        val id = call.argument<Int>("session") ?: -1
                        val existing = DownloadService.state.active
                        if (owner != requestedOwner || (existing == null && !isVisible())) {
                            result.success(false)
                        } else {
                            val session = DownloadService.state.start(
                                requestedOwner, id, call.argument<Int>("progress") ?: 0,
                                call.argument<Boolean>("waiting") ?: false, SystemClock.elapsedRealtime(),
                            )
                            if (session == null) {
                                result.success(false)
                            } else {
                                try {
                                    ContextCompat.startForegroundService(context, Intent(context, DownloadService::class.java))
                                    result.success(true)
                                } catch (error: Exception) {
                                    DownloadService.stopOwned(requestedOwner, id)
                                    result.error("download_service_start", error.toString(), null)
                                    return@setMethodCallHandler
                                }
                                // Denying notifications does not prohibit an FGS. Ask only
                                // during the first user-started transfer, never on heartbeat.
                                if (isVisible()) {
                                    try { requestNotifications() }
                                    catch (error: Exception) { Log.w("DownloadService", "Cannot request notifications", error) }
                                }
                            }
                        }
                    }
                    "update" -> {
                        val session = DownloadService.state.update(
                            requestedOwner, call.argument<Int>("session") ?: -1,
                            call.argument<Int>("progress") ?: 0,
                            call.argument<Boolean>("waiting") ?: false, SystemClock.elapsedRealtime(),
                        )
                        if (session != null) DownloadService.instance?.refresh()
                        result.success(null)
                    }
                    "stop" -> {
                        DownloadService.stopOwned(requestedOwner, call.argument<Int>("session") ?: -1)
                        result.success(null)
                    }
                    "dispose" -> {
                        disposeOwner(requestedOwner)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("download_service", error.toString(), null)
            }
        }
    }

    private fun watchNetwork() {
        if (networkCallback != null) return
        val callback = object : ConnectivityManager.NetworkCallback() {
            private var available: Network? = null
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val validated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                if (!validated) {
                    if (available == network) available = null
                    return
                }
                if (available == network) return
                available = network
                main.post {
                    if (networkCallback === this && owner != null) {
                        channel.invokeMethod("networkAvailable", mapOf("owner" to owner))
                    }
                }
            }

            override fun onLost(network: Network) {
                if (available == network) available = null
            }
        }
        // The app's minimum Android SDK is 24, where the default-network API
        // also follows VPN/default-route changes instead of every Wi-Fi link.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            connectivity.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        }
    }

    private fun disposeOwner(requestedOwner: String) {
        if (owner != requestedOwner) return
        val session = DownloadService.state.active
        if (session?.owner == requestedOwner) DownloadService.stopOwned(requestedOwner, session.id)
        if (DownloadService.state.dispose(requestedOwner)) DownloadService.onStopped = null
        owner = null
        networkCallback?.let { connectivity.unregisterNetworkCallback(it) }
        networkCallback = null
        main.removeCallbacksAndMessages(null)
    }

    fun close() {
        owner?.let { disposeOwner(it) }
        channel.setMethodCallHandler(null)
    }
}
