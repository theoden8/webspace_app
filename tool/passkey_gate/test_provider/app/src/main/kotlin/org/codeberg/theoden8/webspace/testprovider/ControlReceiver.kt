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
                val fp = intent.getStringExtra("fp")
                if (pkg == null || fp == null) {
                    Log.e(TAG, "TRUST needs --es package and --es fp")
                    return
                }
                Allowlist(context).trust(pkg, fp)
            }
            "CLEAR" -> Allowlist(context).clear()
            else -> Log.e(TAG, "unknown control action ${intent.action}")
        }
    }
}
