package com.ublox.akvalink

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Android drops incoming Wi-Fi multicast packets unless a multicast lock is
 *  held — needed for mDNS discovery (net/station_discovery.dart) to receive
 *  any replies at all, even with CHANGE_WIFI_MULTICAST_STATE granted. */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "akvalink/multicast_lock",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> {
                    if (multicastLock == null) {
                        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wifi.createMulticastLock("akvalink-mdns").apply {
                            setReferenceCounted(true)
                        }
                    }
                    multicastLock?.acquire()
                    result.success(null)
                }
                "release" -> {
                    if (multicastLock?.isHeld == true) multicastLock?.release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
