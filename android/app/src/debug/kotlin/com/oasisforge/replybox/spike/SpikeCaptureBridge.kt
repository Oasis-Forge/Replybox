package com.oasisforge.replybox.spike

import android.content.Context
import android.content.pm.PackageManager
import android.service.notification.StatusBarNotification
import android.util.Log
import com.oasisforge.replybox.capture.CaptureEvents
import com.oasisforge.replybox.capture.CaptureQueue
import com.oasisforge.replybox.capture.CaptureStore
import com.oasisforge.replybox.capture.NotificationProjection
import org.json.JSONObject
import java.io.File

/**
 * Debug-only. Replays a notification **this app posted** through the SHIPPED
 * capture path -- `NotificationProjection`, `CaptureStore`, `CaptureQueue` -- under
 * a substituted package name, so CAP-21's storage half can be driven on a device.
 *
 * ## Why this exists rather than a hatch in the listener
 *
 * `SpikeRawPoster` posts the only CAP-21 shapes the device can make, and posts them
 * under Replybox's own package. `ReplyboxListenerService.capture` drops
 * `sbn.packageName == packageName` as its first statement (PERM-12), so the shipped
 * listener stores nothing from the poster: measured on 21 September 2026, 11
 * notifications posted, the included-apps store unchanged, `content_kind='raw'`
 * count 0. Everything downstream of the listener -- one raw message per
 * notification, the app as the thread, a three-times re-post leaving one row, the
 * redaction marker on a raw line, CAP-6 and CAP-7 actually dropping -- therefore had
 * no device evidence at all.
 *
 * The obvious fix is a debug-only exception to that drop. It was rejected. PERM-12
 * is a safety rule, and an exception to a safety rule that lives inside the shipped
 * class is one edit away from a release build whatever guards it: the guard would
 * have to be trusted, the class would carry a branch that must never be taken, and
 * the review of every later change to that file would have to re-establish it. It
 * would also break PERM-12 twice over on the drill device -- `store.recordSeen`
 * would put **Replybox itself** into its own included-apps list, and the user would
 * then have to switch Replybox on inside Replybox before anything was stored.
 *
 * So nothing in `src/main` changes. This class lives in the debug source set, is off
 * until the spike tool turns it on, and reaches the shipped path the way any caller
 * can: through the public API of `CaptureStore` and `CaptureQueue`.
 *
 * ## What is real in the row it writes, and what is not
 *
 * Real, and the reason this is device evidence rather than a fixture: the
 * `StatusBarNotification` is the one the platform delivered, the projection is the
 * shipped `NotificationProjection.project`, the capturable gate is the shipped
 * `isCapturable` (so CAP-6's summary and CAP-7's ongoing are dropped by the shipped
 * code, not by this one), the queue file is the shipped queue, and the drain, the
 * ingest, CAP-5's dedup and the inbox row are all the shipped ones.
 *
 * Substituted, and it is exactly one field: `package`. The row names
 * [SUBSTITUTE_PACKAGE] instead of this app, and carries `bridgedFrom` beside it so
 * the queue file says what happened rather than reading as a genuine capture. The
 * `key` and `groupKey` fields still contain the real package, because they are the
 * platform's own identity strings and rewriting them would fabricate more than this
 * is willing to.
 *
 * ## What this therefore does NOT prove, and PERM-12's promise
 *
 * PERM-12's user-visible promise -- Replybox never appears as a source app -- holds
 * while the bridge is open: the included-apps row is [SUBSTITUTE_PACKAGE], never
 * `com.oasisforge.replybox`, and the shipped listener still drops this app's own
 * notifications before anything is read out of them. PERM-12's other sentence does
 * not hold as written: text the app itself posted does reach the native queue and
 * can become a message here. That is the cost, it is debug-only and opt-in, and it
 * is why the drill in `docs/STACK_NOTES.md` ends by deleting what it stored.
 *
 * And the inbox row a drill produces is **not what a user would see**. It is what a
 * user would see if a third-party app posted that exact notification. The listener's
 * own read of a genuine third-party package -- CAP-1's first sighting, the label
 * lookup, the package filter -- stays undriven and stays provisional under CAP-25.
 * The only thing that closes that is a second APK with its own `applicationId`
 * posting these shapes.
 */
object SpikeCaptureBridge {

    /**
     * The package the bridged row claims. Deliberately not the app's own id and not
     * a prefix of it: a row under `com.oasisforge.replybox.something` would read, in
     * the included-apps list and in a database dump, as Replybox appearing in its
     * own list, which is the exact thing PERM-12 forbids. It is also not any package
     * in `ShippedApps.PACKAGES`, or CAP-1 would switch it on by itself and the drill
     * would skip the step that proves the user's choice is what enables capture.
     *
     * No app of this name is installed, so the shipped label fallback (the package
     * name itself) is what the chooser shows -- which is the same fallback a real
     * uninstalled-since package gets, and is honest about there being no app there.
     */
    const val SUBSTITUTE_PACKAGE = "com.oasisforge.spikeraw"

    /** Existence is the flag; the file holds the time it was turned on. */
    private const val FLAG_NAME = "spike-bridge.on"

    /**
     * Whether a notification the spike listener just saw should be replayed.
     *
     * Pure, and tested one row at a time in `SpikeCaptureBridgeTest`, because every
     * clause is a safety property rather than a convenience:
     *
     *  - `enabled` false is the default, and the default is off. The tool turns it
     *    on for a drill and `spike.sh reset` turns it off again.
     *  - only this app's own notifications are replayed. A third-party notification
     *    the spike listener also sees has already gone through the shipped listener,
     *    and bridging it would store it a second time under a package that is not
     *    its own -- a corrupted drill that would read as a CAP-5 dedup failure.
     *  - only the poster's channel. The app's other debug notifications, and
     *    anything the Flutter tooling posts, are not CAP-21 shapes and have no
     *    business in the queue.
     */
    fun shouldBridge(
        enabled: Boolean,
        notificationPackage: String,
        ownPackage: String,
        channelId: String?,
    ): Boolean = enabled &&
        notificationPackage == ownPackage &&
        channelId == SpikeRawPoster.CHANNEL

    /** Off unless the flag file is there. A fresh install has no flag. */
    fun isOn(context: Context): Boolean = try {
        flagFile(context).exists()
    } catch (e: Exception) {
        Log.w(TAG, "could not read the bridge flag", e)
        false
    }

    /** Turned on and off only from `SpikeRawPoster`, which only adb can reach. */
    fun setOn(context: Context, on: Boolean) {
        val file = flagFile(context)
        try {
            if (on) file.writeText(System.currentTimeMillis().toString()) else file.delete()
        } catch (e: Exception) {
            Log.w(TAG, "could not write the bridge flag", e)
        }
        SpikeListenerService.appendFrom(
            context,
            JSONObject().put("event", "bridge_flag").put("on", isOn(context))
                .put("substitutePackage", SUBSTITUTE_PACKAGE),
        )
    }

    /**
     * Runs the shipped capture sequence in the shipped order: record the sighting,
     * ask whether the package is on, apply the capturable gate, project, append.
     *
     * The order is copied from `ReplyboxListenerService.capture` on purpose. INB-20
     * requires the sighting before the drop, and CAP-1 requires that a package that
     * is off never has its title or text projected -- so a drill that skipped
     * `recordSeen` would also skip the step where the user turns the app on, and
     * would prove something easier than the rule.
     *
     * [event] is `posted` or `removed`; a removal records no sighting, exactly as
     * the shipped `removed` does.
     */
    fun bridge(
        context: Context,
        sbn: StatusBarNotification,
        event: String,
        removalReasonName: String? = null,
    ) {
        if (!shouldBridge(isOn(context), sbn.packageName, context.packageName, sbn.notification.channelId)) return
        try {
            val store = CaptureStore.of(context)
            val enabled = if (event == "removed") {
                store.isEnabled(SUBSTITUTE_PACKAGE)
            } else {
                store.recordSeen(SUBSTITUTE_PACKAGE, labelFor(context, SUBSTITUTE_PACKAGE), System.currentTimeMillis())
            }
            if (!enabled) {
                report(context, event, sbn, "package_off")
                return
            }
            if (!NotificationProjection.isCapturable(sbn)) {
                // CAP-6 and CAP-7 land here, and the dump saying so IS the evidence
                // that the shipped gate dropped them.
                report(context, event, sbn, "not_capturable")
                return
            }
            val row = NotificationProjection.project(event, sbn, removalReasonName)
                .put("package", SUBSTITUTE_PACKAGE)
                // So capture-queue.jsonl says what this is. Dart ignores a key it
                // does not read, the same way it ignores the queue's own queuedAt.
                .put("bridgedFrom", sbn.packageName)
            CaptureQueue.of(context).append(row)
            CaptureEvents.signal(row.toString())
            report(context, event, sbn, "appended")
        } catch (e: Exception) {
            Log.e(TAG, "bridge failed", e)
            report(context, event, sbn, "failed")
        }
    }

    /**
     * One line per decision, into the same dump the poster and the spike listener
     * write to, so the drill reads as build -> arrive -> bridge in one file.
     */
    private fun report(context: Context, event: String, sbn: StatusBarNotification, result: String) {
        SpikeListenerService.appendFrom(
            context,
            JSONObject()
                .put("event", "bridge")
                .put("bridgedEvent", event)
                .put("key", sbn.key)
                .put("tag", sbn.tag)
                .put("channelId", sbn.notification.channelId)
                .put("substitutePackage", SUBSTITUTE_PACKAGE)
                .put("result", result),
        )
    }

    /** The shipped listener's fallback, reproduced: an unknown package is its own label. */
    @Suppress("DEPRECATION")
    private fun labelFor(context: Context, packageName: String): String = try {
        val pm = context.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        packageName
    } catch (e: Exception) {
        packageName
    }

    private fun flagFile(context: Context): File = File(context.getExternalFilesDir(null), FLAG_NAME)

    private const val TAG = "ReplyboxSpike"
}
