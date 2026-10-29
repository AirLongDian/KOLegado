package io.legado.app.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.view.KeyEvent
import io.legado.app.model.AudioPlay
import io.legado.app.model.ReadBook
import io.legado.app.service.AudioPlayService

class MediaButtonReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (handleIntent(context, intent) && isOrderedBroadcast) abortBroadcast()
    }
    companion object {
        fun handleIntent(context: Context, intent: Intent): Boolean {
            if (intent.action != Intent.ACTION_MEDIA_BUTTON) return false
            val key = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return false
            if (key.action != KeyEvent.ACTION_DOWN) return true
            when (key.keyCode) {
                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> ReadBook.moveToPrevChapter()
                KeyEvent.KEYCODE_MEDIA_NEXT -> ReadBook.moveToNextChapter()
                else -> readAloud(context)
            }
            return true
        }
        fun readAloud(context: Context, isMediaKey: Boolean = true) {
            if (AudioPlayService.isRun) {
                if (AudioPlayService.pause) AudioPlay.resume(context) else AudioPlay.pause(context)
            }
        }
    }
}
