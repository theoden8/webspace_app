package org.codeberg.theoden8.webspace.testprovider

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class ControlReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action?.substringAfterLast('.')) {
            "TRUST" -> {
                val pkg = intent.getStringExtra("package")
                if (pkg == null) {
                    Log.e(TAG, "TRUST needs a package extra")
                    return
                }
                Allowlist(context).trust(pkg, intent.getStringExtra("fp"))
            }
            "CLEAR" -> Allowlist(context).clear()
            else -> Log.e(TAG, "unknown control action ${intent.action}")
        }
    }
}
