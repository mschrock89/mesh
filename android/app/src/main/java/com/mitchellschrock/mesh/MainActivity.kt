package com.mitchellschrock.mesh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {
    private var hasBeenActive = false
    private val updates by lazy { AppUpdateController(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        )
        requestStartupPermissions()
        ContextCompat.startForegroundService(this, Intent(this, MeshService::class.java))
        setContent {
            val ui by MeshHub.ui.collectAsState()
            MeshScreen(ui, updates)
        }
        updates.refreshOnOpen()
    }

    override fun onStart() {
        super.onStart()
        if (hasBeenActive) MeshHub.noteForeground()
        hasBeenActive = true
    }

    override fun onResume() {
        super.onResume()
        updates.onResume()
    }

    override fun onDestroy() {
        updates.close()
        super.onDestroy()
    }

    private fun requestStartupPermissions() {
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.POST_NOTIFICATIONS)
            }
            if (checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.NEARBY_WIFI_DEVICES)
            }
        }
        if (needed.isNotEmpty()) requestPermissions(needed.toTypedArray(), 1)
    }
}
