package com.oasisforge.replybox.spike

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import org.json.JSONObject

/**
 * Posts, on demand from adb, the notification shapes nothing on the device can
 * otherwise produce. Debug source set only, with the rest of the spike: nothing
 * declared here exists in a release build, and `release.yml`'s permission gate
 * never has to reason about it (CAP-20, PERM-15).
 *
 * WHY this exists: CAP-21 keeps a notification that carries no `MessagingStyle`
 * history when its `category` is `msg`, `social` or `email`, and offers a reply on
 * it only when the notification itself carries a `RemoteInput`. That gate could not
 * be driven on 21 September 2026 and still cannot be driven any other way:
 * `cmd notification post` has no category flag, a shell-posted `MessagingStyle`
 * carries no category key at all, and no installed app posts a non-`MessagingStyle`
 * msg/social/email notification on demand. So CAP-21 -- the path where Android's
 * redaction marker was found leaking two rounds ago -- had no device evidence and no
 * fixture. Same for CAP-6 (group summary) and CAP-7 (ongoing), which were inferred
 * from what the spike happened to capture rather than posted on purpose, and for
 * CAP-8's exact distinction between a title Android EMPTIED to `""` and a title that
 * was never set at all, which `NotificationProjection` documents as a residual and
 * which decides whether a notification reads as hidden.
 *
 * KNOWN LIMIT, and it is the important one. This posts under Replybox's own package,
 * and `ReplyboxListenerService.capture` drops `sbn.packageName == packageName`
 * before CAP-1's filter ever runs (PERM-12). So the SHIPPED LISTENER stores nothing
 * posted from here, by design, and nothing in this APK weakens that: measured on the
 * device on 21 September 2026 -- 11 notifications posted, the included-apps store
 * unchanged, zero `raw` rows.
 *
 * What this drives by itself is the platform half: what actually arrives for each
 * shape -- whether `category` survives, whether `EXTRA_TITLE` arrives absent or as
 * `""`, whether `FLAG_ONGOING_EVENT` and `FLAG_GROUP_SUMMARY` are set, whether a
 * `RemoteInput` is attached and round-trips -- read off the spike listener, which has
 * no own-package filter. Those are exactly the fields
 * `NotificationProjection.isCapturable` gates on, so a dump taken here feeds the
 * shipped projection in a Kotlin unit test.
 *
 * The STORAGE half -- one raw message per notification, the app as the thread, a
 * three-times re-post leaving one row, CAP-6 and CAP-7 dropping -- is driven by
 * [SpikeCaptureBridge], which replays these notifications through the shipped
 * projection, store and queue under a substituted package name. It is off until
 * `spike.sh bridge on`, it changes nothing in `src/main`, and it does not stand in
 * for a third-party package: read its header before trusting a drill result. End to
 * end from a genuine third-party package stays undriven and must be reported as
 * undriven (CAP-25).
 *
 * The invocation style is `SpikeReplyReceiver`'s, and so is its trap: `adb shell`
 * hands the command to a shell ON the device, which re-splits it on spaces, so
 * everything goes to adb as ONE string with the device-side quoting written into it.
 *
 *   adb shell "am broadcast -a com.oasisforge.replybox.SPIKE_POST \
 *     -n com.oasisforge.replybox/.spike.SpikeRawPoster \
 *     --es shape 'raw-msg' --es text 'a raw line'"
 *
 * `tool/spike.sh post <shape> [text]` wraps that. Every post writes what it was
 * ASKED for into the same dump the listener writes what it SAW into, in that order,
 * so one file holds both halves and a shape that did not arrive the way it was built
 * is visible without a second source.
 */
class SpikeRawPoster : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_REPLY) {
            recordReply(context, intent)
            return
        }
        if (intent.action == ACTION_BRIDGE) {
            // The only way SpikeCaptureBridge is ever switched on, and it is off
            // until this runs. See that class for why the escape is here and not in
            // the shipped listener (PERM-12).
            SpikeCaptureBridge.setOn(context, intent.getBooleanExtra("on", false))
            Log.i(TAG, "bridge on=${SpikeCaptureBridge.isOn(context)}")
            return
        }

        val shape = intent.getStringExtra("shape") ?: "raw-msg"
        val spec = specFor(shape, intent)
        if (spec == null) {
            SpikeListenerService.appendFrom(
                context,
                JSONObject().put("event", "post_request").put("shape", shape)
                    .put("result", "unknown_shape").put("known", SHAPES.joinToString(",")),
            )
            Log.w(TAG, "unknown shape $shape; known: ${SHAPES.joinToString(",")}")
            return
        }

        val manager = context.getSystemService(NotificationManager::class.java)
        // A denied POST_NOTIFICATIONS is silent from a receiver -- `notify` simply
        // does nothing -- and that looked like a broken poster for a while. Say so.
        if (!manager.areNotificationsEnabled()) {
            SpikeListenerService.appendFrom(
                context,
                JSONObject().put("event", "post_request").put("shape", shape)
                    .put("result", "notifications_disabled"),
            )
            Log.w(TAG, "notifications are off for this app; run: spike.sh grant-post")
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Replybox raw-shape poster", NotificationManager.IMPORTANCE_LOW),
        )

        // Intent before delivery: the dump then reads as "this is what was built"
        // followed by the listener's "this is what arrived", and the two can differ.
        SpikeListenerService.appendFrom(context, spec.describe().put("result", "posting"))
        manager.notify(spec.tag, spec.id, build(context, spec))
        Log.i(TAG, "posted $shape as id=${spec.id} tag=${spec.tag}")
    }

    /** What was asked for, before the platform has had a chance to change it. */
    private class Spec(
        val shape: String,
        val id: Int,
        val tag: String,
        val category: String?,
        val titleMode: String,
        val title: String,
        val text: String,
        val style: String,
        val withReply: Boolean,
        val ongoing: Boolean,
        val summary: Boolean,
    ) {
        fun describe(): JSONObject = JSONObject()
            .put("event", "post_request")
            .put("sdkInt", Build.VERSION.SDK_INT)
            .put("release", Build.VERSION.RELEASE)
            .put("shape", shape)
            .put("id", id)
            .put("tag", tag)
            .put("askedCategory", category)
            .put("askedTitleMode", titleMode)
            .put("askedTitle", if (titleMode == "text") title else if (titleMode == "empty") "" else null)
            .put("askedText", text)
            .put("askedStyle", style)
            .put("askedRemoteInput", withReply)
            .put("askedOngoing", ongoing)
            .put("askedGroupSummary", summary)
    }

    /**
     * The named shapes are CAP-21's and CAP-6/7/8's bullets one for one, so a drill
     * step and a rule clause have the same name. Every field is still overridable by
     * its own extra, because the next question is never one of these seven.
     */
    private fun specFor(shape: String, intent: Intent): Spec? {
        val base: Spec = when (shape) {
            // CAP-21's raw line: no MessagingStyle history, category msg.
            "raw-msg" -> Spec(shape, 9001, "spike-raw-msg", Notification.CATEGORY_MESSAGE, "text", "Raw sender", "a raw line", "none", false, false, false)
            "raw-social" -> Spec(shape, 9002, "spike-raw-social", Notification.CATEGORY_SOCIAL, "text", "Raw social", "someone mentioned you", "none", false, false, false)
            "raw-email" -> Spec(shape, 9003, "spike-raw-email", Notification.CATEGORY_EMAIL, "text", "Raw email", "one new mail", "none", false, false, false)
            // CAP-21: no reply is offered on a raw line unless the notification
            // itself carries one, so both halves of that have to be postable.
            "raw-reply" -> Spec(shape, 9004, "spike-raw-reply", Notification.CATEGORY_MESSAGE, "text", "Raw repliable", "a raw line you can answer", "none", true, false, false)
            // The gate must NOT open: an included app's non-MessagingStyle
            // notification with no category at all is ignored (CAP-2, CAP-21).
            "raw-nocategory" -> Spec(shape, 9005, "spike-raw-nocat", null, "text", "Raw uncategorised", "a promotion, not a message", "none", false, false, false)
            // The shape that duplicated a raw message on every update: one id,
            // posted three times with different text (CAP-5). Three and not two:
            // two re-posts can pass a dedup that keys on "the same as last time",
            // and the everyday shape -- a chat notification updating as lines
            // arrive -- posts the same id many times over. `spike.sh raw` drives it
            // three times; `spike.sh repost [n]` drives it as often as asked.
            "repost" -> Spec(shape, 9006, "spike-raw-repost", Notification.CATEGORY_MESSAGE, "text", "Raw sender", "the first text", "none", false, false, false)
            // CAP-8 on CAP-21's path. The app cannot make a redaction marker and
            // must not try: the marker is a system string, CAP-8 recognises hidden
            // messages structurally and never by matching it, and a marker this
            // class typed would be the app asserting its own answer. Only Android's
            // own OTP redaction can produce one, so this shape gives it something
            // to redact -- a raw (non-MessagingStyle) msg-category notification
            // whose text carries a code -- and `raw-otp-control` posts the same
            // shape with no code in it. The pair is the result either way: both
            // altered, or neither. Redaction cannot be switched off at API 37
            // (`spike.sh redact`), so this is observed and not arranged.
            "raw-otp" -> Spec(shape, 9012, "spike-raw-otp", Notification.CATEGORY_MESSAGE, "text", "Bank", "Your one-time code is 418923. Do not share it.", "none", false, false, false)
            "raw-otp-control" -> Spec(shape, 9013, "spike-raw-otp-control", Notification.CATEGORY_MESSAGE, "text", "Bank", "an ordinary message with no code in it", "none", false, false, false)
            // CAP-8's exact distinction, and the residual NotificationProjection
            // documents: "" is a value and survives, absent is not the same fact.
            "title-empty" -> Spec(shape, 9007, "spike-title-empty", Notification.CATEGORY_MESSAGE, "empty", "", "text with an emptied title", "none", false, false, false)
            "title-absent" -> Spec(shape, 9008, "spike-title-absent", Notification.CATEGORY_MESSAGE, "absent", "", "text with no title set at all", "none", false, false, false)
            // CAP-7: driven, not inferred.
            "ongoing" -> Spec(shape, 9009, "spike-ongoing", Notification.CATEGORY_MESSAGE, "text", "Ongoing", "syncing in the background", "none", false, true, false)
            // CAP-6: driven, not inferred. Its child is posted beside it, because a
            // summary alone says nothing about whether the children still arrive.
            "summary" -> Spec(shape, 9010, "spike-summary", Notification.CATEGORY_MESSAGE, "text", "Group summary", "2 new messages", "none", false, false, true)
            "summary-child" -> Spec(shape, 9011, "spike-summary-child", Notification.CATEGORY_MESSAGE, "text", "Raw sender", "a child of the summary", "none", false, false, false)
            else -> return null
        }
        return Spec(
            shape = base.shape,
            id = intent.getIntExtra("id", base.id),
            tag = intent.getStringExtra("tag") ?: base.tag,
            // `--es category none` is how you ask for no category key, because an
            // absent extra means "keep the shape's own" and cannot also mean null.
            category = intent.getStringExtra("category")
                ?.let { if (it == "none") null else it } ?: base.category,
            titleMode = intent.getStringExtra("titleMode") ?: base.titleMode,
            title = intent.getStringExtra("title") ?: base.title,
            text = intent.getStringExtra("text") ?: base.text,
            style = intent.getStringExtra("style") ?: base.style,
            withReply = intent.getBooleanExtra("reply", base.withReply),
            ongoing = intent.getBooleanExtra("ongoing", base.ongoing),
            summary = intent.getBooleanExtra("summary", base.summary),
        )
    }

    private fun build(context: Context, spec: Spec): Notification {
        val b = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentText(spec.text)
        // Absent is not empty: `setContentTitle("")` writes EXTRA_TITLE as "", and
        // never calling it leaves EXTRA_TITLE out of the bundle. CAP-8's hidden
        // check turns on that difference, so the poster must be able to make both
        // and must not "helpfully" default one into the other.
        when (spec.titleMode) {
            "absent" -> Unit
            "empty" -> b.setContentTitle("")
            else -> b.setContentTitle(spec.title)
        }
        spec.category?.let { b.setCategory(it) }
        when (spec.style) {
            // Still non-MessagingStyle, but with EXTRA_TEMPLATE actually set, which
            // is the common raw shape and a different row in the dump from a plain
            // notification whose template is absent (CAP-2 reads EXTRA_TEMPLATE).
            "bigtext" -> b.setStyle(Notification.BigTextStyle().bigText(spec.text))
            "inbox" -> b.setStyle(Notification.InboxStyle().addLine(spec.text))
            else -> Unit
        }
        if (spec.ongoing) b.setOngoing(true)
        if (spec.summary) b.setGroup(GROUP).setGroupSummary(true)
        if (spec.shape == "summary-child") b.setGroup(GROUP)
        if (spec.withReply) b.addAction(replyAction(context, spec))
        return b.build()
    }

    /**
     * A free-form RemoteInput on a plain action, which is what CAP-21 means by the
     * notification carrying one. It is routed back here so the reply can actually be
     * fired and seen to land: an action that is merely present proves less than one
     * whose result key comes back with the typed text in it.
     */
    private fun replyAction(context: Context, spec: Spec): Notification.Action {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val pending = PendingIntent.getBroadcast(
            context,
            spec.id,
            Intent(ACTION_REPLY)
                .setClassName(context, SpikeRawPoster::class.java.name)
                .putExtra("shape", spec.shape),
            flags,
        )
        return Notification.Action.Builder(
            android.R.drawable.stat_notify_chat,
            "Reply",
            pending,
        ).addRemoteInput(RemoteInput.Builder(RESULT_KEY).setLabel("Reply").build()).build()
    }

    private fun recordReply(context: Context, intent: Intent) {
        val results = RemoteInput.getResultsFromIntent(intent)
        SpikeListenerService.appendFrom(
            context,
            JSONObject()
                .put("event", "poster_reply_received")
                .put("shape", intent.getStringExtra("shape"))
                .put("resultKey", RESULT_KEY)
                .put("text", results?.getCharSequence(RESULT_KEY)?.toString())
                .put("result", if (results == null) "no_remote_input_results" else "received"),
        )
        Log.i(TAG, "poster reply: ${results?.getCharSequence(RESULT_KEY)}")
    }

    /**
     * `internal` rather than private for [CHANNEL] alone: [SpikeCaptureBridge]
     * replays only notifications posted on this channel, and a second copy of the
     * string in that class would be a second definition of which notifications the
     * bridge may touch (its narrowest safety clause).
     */
    internal companion object {
        const val TAG = "SpikeRawPoster"
        const val CHANNEL = "spike-raw"
        const val GROUP = "spike-raw-group"
        const val RESULT_KEY = "spike_raw_reply"
        const val ACTION_REPLY = "com.oasisforge.replybox.SPIKE_POST_REPLY"
        const val ACTION_BRIDGE = "com.oasisforge.replybox.SPIKE_BRIDGE"
        val SHAPES = listOf(
            "raw-msg", "raw-social", "raw-email", "raw-reply", "raw-nocategory",
            "repost", "title-empty", "title-absent", "ongoing", "summary", "summary-child",
            "raw-otp", "raw-otp-control",
        )
    }
}
