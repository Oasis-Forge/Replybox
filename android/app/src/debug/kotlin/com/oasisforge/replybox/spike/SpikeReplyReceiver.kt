package com.oasisforge.replybox.spike

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import org.json.JSONObject

/**
 * Check 5 of docs/PLAN.md section 5: does a reply still deliver through an
 * action's PendingIntent after the user has dismissed the notification it came
 * from, and for how long. Debug source set only, with the rest of the spike.
 *
 *   adb shell am broadcast -a com.oasisforge.replybox.SPIKE_REPLY \
 *     -n com.oasisforge.replybox/.spike.SpikeReplyReceiver \
 *     --es key '<notification key>' --es text 'a reply'
 *
 * The outcome is written into the same dump as the notifications, so one file
 * tells the whole story: what arrived, what was dismissed, what the reply did.
 */
class SpikeReplyReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        // Clearing the shade through the listener is what a user swiping the
        // notification away does, and `adb shell service call notification` is
        // not: it left the notification listed and made the first check-5 run
        // look like a pass when nothing had been dismissed.
        if (intent.action == "com.oasisforge.replybox.SPIKE_DISMISS") {
            val service = SpikeListenerService.instance
            service?.cancelAllNotifications()
            SpikeListenerService.appendFrom(
                context,
                JSONObject()
                    .put("event", "dismiss_all")
                    .put("result", if (service == null) "no_listener_bound" else "cancelled"),
            )
            return
        }

        val requestedKey = intent.getStringExtra("key")
        val text = intent.getStringExtra("text") ?: "spike reply"

        // With no key, reply to whatever was seen last: after a dismissal the
        // key is awkward to pass by hand, and the interesting case is "the one
        // that just went away" rather than a specific one.
        val key = requestedKey ?: SpikeListenerService.replyActions.keys.lastOrNull()
        val out = JSONObject()
            .put("event", "reply_attempt")
            .put("key", key)
            .put("requestedKey", requestedKey)
            .put("knownKeys", SpikeListenerService.replyActions.keys.size)
            .put("text", text)

        val action = key?.let { SpikeListenerService.replyActions[it] }
        if (action == null) {
            // Not a failure of the mechanism: it means the process was restarted
            // and the in-memory map is empty, which is itself the answer to
            // "how long does a held reply last".
            SpikeListenerService.appendFrom(context, out.put("result", "no_action_held"))
            Log.i(SpikeListenerService.TAG, "no held reply action for $key")
            return
        }

        val inputs = action.remoteInputs.orEmpty()
        val results = Bundle().apply {
            for (input in inputs) putCharSequence(input.resultKey, text)
        }
        val fillIn = Intent()
        RemoteInput.addResultsToIntent(inputs, fillIn, results)

        try {
            action.actionIntent.send(context, 0, fillIn)
            SpikeListenerService.appendFrom(
                context,
                out.put("result", "sent")
                    .put("resultKeys", inputs.joinToString(",") { it.resultKey }),
            )
            Log.i(SpikeListenerService.TAG, "reply sent for $key")
        } catch (e: PendingIntent.CanceledException) {
            // The case the REP rules hang on: the action is gone and the app can
            // only offer "open in app".
            SpikeListenerService.appendFrom(context, out.put("result", "pending_intent_cancelled"))
            Log.w(SpikeListenerService.TAG, "PendingIntent cancelled for $key", e)
        }
    }
}
