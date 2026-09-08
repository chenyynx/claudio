package com.k9i.ccpocket

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Receives external deep links without creating a second Flutter engine inside
 * the sender's task, then forwards the URI to the canonical app task.
 */
class DeepLinkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val sourceIntent = intent
        val uri = sourceIntent.data
        val supported = sourceIntent.action == Intent.ACTION_VIEW &&
            uri?.scheme == SCHEME &&
            uri.host in SUPPORTED_HOSTS

        if (supported) {
            val mainIntent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                data = uri
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            startActivity(mainIntent)
        }

        finish()
    }

    private companion object {
        const val SCHEME = "ccpocket"
        val SUPPORTED_HOSTS = setOf("connect", "session")
    }
}
