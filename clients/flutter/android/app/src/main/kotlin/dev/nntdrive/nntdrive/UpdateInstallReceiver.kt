package dev.nntdrive.nntdrive

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller

/**
 * Receives the installer's final status for the session this app committed.
 *
 * Android reports success or failure here, after the user confirms or dismisses
 * the upgrade. Only the status code and a short message are kept: no file path,
 * package content or account detail.
 */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INSTALL_STATUS) return
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
        UpdateInstallStatus.record(status, message)
    }

    companion object {
        const val ACTION_INSTALL_STATUS = "dev.nntdrive.action.INSTALL_STATUS"
    }
}

/** Last known installer outcome for this process. */
object UpdateInstallStatus {
    const val NONE = -1

    @Volatile
    var lastStatus: Int = NONE
        private set

    @Volatile
    var lastMessage: String = ""
        private set

    fun record(status: Int, message: String) {
        lastStatus = status
        lastMessage = message.take(MAX_MESSAGE)
    }

    private const val MAX_MESSAGE = 200
}
