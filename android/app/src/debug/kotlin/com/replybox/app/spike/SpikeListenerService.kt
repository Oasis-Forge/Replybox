package com.replybox.app.spike

import android.app.Notification
import android.app.RemoteInput
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Throwaway capture spike for docs/PLAN.md section 5. Debug source set only: the
 * BIND_NOTIFICATION_LISTENER_SERVICE permission it needs must never reach the
 * release manifest, or the RUN-2 permission gate in release.yml fails the build.
 *
 * It answers nothing by itself. It dumps every notification the listener sees as
 * one JSON object per line, and the spike's five checks are read off those dumps.
 * The shape written here is the shape the PR 2 fixture tests will parse, so the
 * fields are chosen for what the normaliser needs, not for what is easy to read.
 */
class SpikeListenerService : NotificationListenerService() {

    private val dumpFile: File
        get() = File(getExternalFilesDir(null), DUMP_NAME)

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        // Check 3 reads these lines: a listener that silently stopped delivering
        // looks exactly like a quiet phone unless the reconnect is on the record.
        append(JSONObject().put("event", "listener_connected"))
        Log.i(TAG, "connected; dumping to ${dumpFile.absolutePath}")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        instance = null
        append(JSONObject().put("event", "listener_disconnected"))
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        append(describe("posted", sbn))
        // Check 5 needs an action that outlives its notification, so the reply
        // action is kept here and fired later, after the notification is gone.
        // This is also the shape PR 5 needs: the action map cannot be rebuilt
        // from storage, because a PendingIntent is not serialisable.
        sbn.notification.actions.orEmpty()
            .firstOrNull { a -> a.remoteInputs.orEmpty().any { it.allowFreeFormInput } }
            ?.let { replyActions[sbn.key] = it }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap?, reason: Int) {
        append(
            describe("removed", sbn)
                .put("removalReason", reason)
                .put("removalReasonName", reasonName(reason)),
        )
    }

    private fun describe(event: String, sbn: StatusBarNotification): JSONObject {
        val n = sbn.notification
        val extras = n.extras
        return JSONObject().apply {
            put("event", event)
            // The API level a dump was captured at is part of the fixture:
            // redaction widened in 15 and again in 16, so a dump without it
            // cannot be compared against a later one.
            put("sdkInt", Build.VERSION.SDK_INT)
            put("release", Build.VERSION.RELEASE)
            put("key", sbn.key)
            put("package", sbn.packageName)
            put("id", sbn.id)
            put("tag", sbn.tag)
            put("postTime", sbn.postTime)
            put("isClearable", sbn.isClearable)
            put("isOngoing", sbn.isOngoing)
            put("groupKey", sbn.groupKey)
            put("isGroupSummary", n.flags and Notification.FLAG_GROUP_SUMMARY != 0)
            put("flags", n.flags)
            put("channelId", n.channelId)
            put("category", n.category)
            put("shortcutId", n.shortcutId)
            put("when", n.`when`)
            put("template", extras.getString(Notification.EXTRA_TEMPLATE))
            put("title", extras.getCharSequence(Notification.EXTRA_TITLE)?.toString())
            put("text", extras.getCharSequence(Notification.EXTRA_TEXT)?.toString())
            put("subText", extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString())
            put("bigText", extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString())
            put("conversationTitle", extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString())
            put("isGroupConversation", extras.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, false))
            put("selfDisplayName", extras.getCharSequence(Notification.EXTRA_SELF_DISPLAY_NAME)?.toString())
            // Check 2 lives or dies here: in a burst the visible text collapses to
            // "5 new messages", and every individual message has to still be
            // recoverable from this array.
            put("messages", messages(extras))
            put("actions", actions(n))
            put("hasRemoteInput", n.actions?.any { it.remoteInputs?.isNotEmpty() == true } ?: false)
        }
    }

    private fun messages(extras: Bundle): JSONArray {
        val out = JSONArray()
        val raw = extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return out
        for (item in raw) {
            val b = item as? Bundle ?: continue
            out.put(
                JSONObject()
                    .put("sender", b.getCharSequence("sender")?.toString())
                    .put("text", b.getCharSequence("text")?.toString())
                    .put("time", b.getLong("time"))
                    .put("type", b.getString("type")),
            )
        }
        return out
    }

    /**
     * Check 1 is decided by this: an action is only repliable if it carries a
     * RemoteInput that allows free-form text, and PR 5 needs the resultKey to
     * put the reply in the right slot.
     */
    private fun actions(n: Notification): JSONArray {
        val out = JSONArray()
        for (action in n.actions.orEmpty()) {
            val inputs = JSONArray()
            for (input in action.remoteInputs.orEmpty()) {
                inputs.put(
                    JSONObject()
                        .put("resultKey", input.resultKey)
                        .put("label", input.label?.toString())
                        .put("allowFreeFormInput", input.allowFreeFormInput)
                        .put("choices", JSONArray(input.choices?.map { it.toString() }.orEmpty())),
                )
            }
            out.put(
                JSONObject()
                    .put("title", action.title?.toString())
                    .put("semanticAction", action.semanticAction)
                    .put("isContextual", action.isContextual)
                    .put("remoteInputs", inputs),
            )
        }
        return out
    }

    private fun reasonName(reason: Int): String = when (reason) {
        REASON_CLICK -> "CLICK"
        REASON_CANCEL -> "CANCEL"
        REASON_CANCEL_ALL -> "CANCEL_ALL"
        REASON_LISTENER_CANCEL -> "LISTENER_CANCEL"
        REASON_LISTENER_CANCEL_ALL -> "LISTENER_CANCEL_ALL"
        REASON_APP_CANCEL -> "APP_CANCEL"
        REASON_APP_CANCEL_ALL -> "APP_CANCEL_ALL"
        REASON_TIMEOUT -> "TIMEOUT"
        REASON_SNOOZED -> "SNOOZED"
        REASON_ERROR -> "ERROR"
        REASON_PACKAGE_CHANGED -> "PACKAGE_CHANGED"
        REASON_USER_STOPPED -> "USER_STOPPED"
        REASON_PACKAGE_BANNED -> "PACKAGE_BANNED"
        REASON_CHANNEL_BANNED -> "CHANNEL_BANNED"
        REASON_CHANNEL_REMOVED -> "CHANNEL_REMOVED"
        REASON_CLEAR_DATA -> "CLEAR_DATA"
        REASON_ASSISTANT_CANCEL -> "ASSISTANT_CANCEL"
        else -> "UNKNOWN_$reason"
    }

    private fun append(o: JSONObject) {
        try {
            // One object per line. An array would need the file rewritten on every
            // notification, and a burst is exactly when that would drop events.
            dumpFile.appendText(o.toString() + "\n")
        } catch (e: Exception) {
            Log.e(TAG, "could not write dump", e)
        }
    }

    companion object {
        const val TAG = "ReplyboxSpike"
        const val DUMP_NAME = "spike-dump.jsonl"

        /**
         * Reply actions by notification key, held past the notification's own
         * life. In-memory on purpose: a PendingIntent cannot be persisted, so
         * after a process death the reply is gone and the product has to fall
         * back to "open in app". That is the rule check 5 exists to decide.
         */
        val replyActions = mutableMapOf<String, Notification.Action>()

        /**
         * The bound service, so the receiver can clear the shade the way a user
         * would. Throwaway-spike shortcut: real code would not keep a static
         * reference to a Service.
         */
        var instance: SpikeListenerService? = null

        /** Lets the receiver write its outcome into the same dump. */
        fun appendFrom(context: android.content.Context, o: JSONObject) {
            try {
                File(context.getExternalFilesDir(null), DUMP_NAME)
                    .appendText(o.toString() + "\n")
            } catch (e: Exception) {
                Log.e(TAG, "could not write dump", e)
            }
        }
    }
}
