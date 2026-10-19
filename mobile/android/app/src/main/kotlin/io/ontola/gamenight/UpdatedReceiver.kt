package io.ontola.gamenight

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// Android closes GameNight while it replaces it. When the player tapped
/// "Restart now", open the new version again; an update installed while the
/// app was in the background stays out of the way.
class UpdatedReceiver : BroadcastReceiver() {
    companion object {
        const val PREFS = "gamenight_update"
        const val REOPEN = "reopen"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val reopen = prefs.getBoolean(REOPEN, false)
        prefs.edit().remove(REOPEN).apply()
        if (!reopen) return
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        try {
            context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            // Newer Android may not let a receiver open an activity.
        }
    }
}
