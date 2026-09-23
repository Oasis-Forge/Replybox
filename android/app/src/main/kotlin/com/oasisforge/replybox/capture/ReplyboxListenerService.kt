package com.oasisforge.replybox.capture

import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * The notification listener. Everything the app ever holds enters here.
 *
 * CAP-20: notification access is not a permission the app requests. It is the
 * `android:permission` attribute on this service's manifest entry, naming the
 * permission the *system* must hold to bind it, and the user grants it in system
 * settings. No `<uses-permission>` is added anywhere for capture, which is why
 * RUN-2's gate in release.yml never fires for it.
 *
 * Every callback below returns almost immediately. The framework dispatches them
 * on the main looper, and capture is disk and binder work -- a package-manager
 * lookup, a rewrite of the included-apps store, an append to the hand-over queue,
 * once per notification. A reboot hands the listener everything in the shade at
 * once, so doing that inline would freeze the UI for as many notifications as the
 * phone had waiting. The work goes to [worker] instead.
 */
class ReplyboxListenerService : NotificationListenerService() {

    private val queue: CaptureQueue by lazy { CaptureQueue.of(this) }
    private val store: CaptureStore by lazy { CaptureStore.of(this) }

    /**
     * One thread, not a pool. Order is part of the contract: CAP-5 identifies a
     * message by its notification key and its index in that notification's
     * history, and CAP-22 reads a removal against the notification it followed, so
     * a burst that arrived in one order must reach the queue in that order. A pool
     * would reorder it, and the queue is append-only with no sequence number to
     * sort back by.
     *
     * The same thread carries the lifecycle callbacks and the reply-action map, so
     * a disconnect's clear always lands *after* the events that preceded it and
     * never before them (CAP-14, PERM-8).
     */
    private val worker: ExecutorService =
        Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "replybox-capture") }

    override fun onCreate() {
        super.onCreate()
        // CAP-15: the 30-day sweep runs on service start, which is the only moment
        // that is guaranteed to happen on a phone whose owner never opens the app.
        submit { queue.prune(System.currentTimeMillis()) }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        // PERM-10: recorded here in the callback body and not on [worker]. This is a
        // volatile field write with no disk and no binder in it, and PERM-10 asks
        // this question from the platform thread microseconds later on a resume --
        // routing it through the single-threaded worker would put a reboot's worth of
        // queued captures in front of the answer and report "not connected" about a
        // listener that had already said otherwise. The ordering the worker exists to
        // protect is between *events*, and this is not one.
        ListenerState.onConnected()
        // PERM-8 opens a capture_sessions row off this, and PERM-9 needs the time to
        // be the one the callback fired at, not the one Dart drained at.
        val now = System.currentTimeMillis()
        // CAP-13: the reconnection re-read. Every still-posted notification goes
        // through the queue as an ordinary "posted" event, so Dart's CAP-5 dedup
        // reconciles it against what it already stored instead of this code trying
        // to guess what arrived while the app was dead. The same pass rebuilds
        // CAP-14's reply map, which is why it cannot be skipped when the queue looks
        // empty: a PendingIntent is not serialisable and this is the only way back.
        //
        // The array is fetched here rather than on the worker: it is one binder call
        // -- the per-notification work is what moves off the main thread -- and it is
        // documented against a listener that is connected, which is this callback and
        // not an arbitrary moment later.
        val active = try {
            activeNotifications
        } catch (e: Exception) {
            // Documented to throw if the listener is not connected yet; a rebind
            // will call this again.
            CaptureLog.failure("could not re-read the active notifications", e)
            null
        }
        submit {
            enqueue(NotificationProjection.lifecycle("listener_connected", now))
            // Rebuilt, never added to (CAP-14): an action remembered before this
            // connection belongs to a notification this process is no longer being
            // told about, and INB-13 would offer a reply bar over a PendingIntent
            // that answers nothing. What is still posted is re-remembered by the
            // pass below; what is not is gone, which is the honest state.
            ReplyActions.clear()
            active?.forEach { capture(it, System.currentTimeMillis()) }
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        // PERM-10, and the one write in this file that has to survive a teardown.
        // `NotificationListenerService.onDestroy` calls this callback, and this
        // class's own onDestroy shuts the worker down before it reaches super -- so
        // on that path every `submit` below is refused and only what happens here
        // lands. That is the right way round: the queue row is a nicety after the
        // service is gone, while "this process's listener is not bound" is precisely
        // what the next resume asks about (PERM-10, PERM-8).
        ListenerState.onDisconnected()
        val now = System.currentTimeMillis()
        submit {
            enqueue(NotificationProjection.lifecycle("listener_disconnected", now))
            // PERM-8: capture has stopped, so nothing may still claim it can answer
            // a conversation in place. Every thread falls back to "open in app"
            // (CAP-14, INB-13, PERM-8) until a reconnection rebuilds the map.
            //
            // Cleared here, on the worker, and not in the callback: the clear has to
            // land after the events that arrived before the disconnect, and clearing
            // on the main thread would let their queued remembers repopulate the map
            // behind it.
            ReplyActions.clear()
        }
    }

    override fun onDestroy() {
        // Lets whatever is already queued finish -- those are captured events with
        // nowhere else to go -- and refuses new work.
        worker.shutdown()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val now = System.currentTimeMillis()
        submit { capture(sbn, now) }
    }

    /**
     * The overload the framework calls below API 26. CAP-22: the removal reason
     * comes from the event, so this one enqueues none rather than inventing one --
     * an absent `removalReasonName` reads as "unrecognised" in CAP-22's table and
     * changes nothing, which is the correct outcome for a reason nobody told us.
     *
     * super is not called, and here that is housekeeping rather than correctness:
     * `NotificationListenerService`'s default two-argument implementation chains
     * down to the one-argument `onNotificationRemoved(sbn)`, which this class does
     * not override, so calling it would reach an empty method. The overload that
     * actually has to refuse the chain is the three-argument one below.
     */
    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap?) {
        submit { removed(sbn, null) }
    }

    /**
     * The three-argument overload carries the reason and is API 26; minSdk is 24, so
     * both exist and exactly one of them fires on any given device. On 26 and above
     * the framework calls this one and never the other.
     *
     * **super is deliberately not called here.** The framework's default
     * three-argument implementation chains down to the *two-argument* overload,
     * which this class does override -- so a chained call would run the block above
     * as well and enqueue the same removal a second time, that copy carrying no
     * reason. CAP-22 acts on the reason, so the duplicate would also be the one that
     * changes nothing, leaving two removal rows for one event with only Dart's
     * CAP-5 dedup between them and a conversation marked read twice.
     */
    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap?, reason: Int) {
        val reasonName = NotificationProjection.reasonName(reason)
        submit { removed(sbn, reasonName) }
    }

    /**
     * CAP-1's drop, in the order INB-20 fixes: the app is recorded as seen first,
     * then the filter runs, and only then is anything read out of the notification.
     * A package that is off never has its title or text projected, let alone
     * written -- the row INB-20 keeps is package, label and last-seen, and nothing
     * else.
     *
     * [seenAt] is the time the callback fired, not the time this ran: INB-21 orders
     * the chooser by `last_seen_at`, and a queue that is catching up after a reboot
     * would otherwise stamp forty notifications with one moment of its own.
     *
     * Runs on [worker].
     */
    private fun capture(sbn: StatusBarNotification, seenAt: Long) {
        // PERM-12: nothing from the app's own package ever reaches the queue. It is
        // also what keeps Replybox out of its own included-apps list.
        if (sbn.packageName == packageName) return
        val enabled = store.recordSeen(sbn.packageName, labelFor(sbn.packageName), seenAt)
        if (!enabled) return
        if (!NotificationProjection.isCapturable(sbn)) return
        // CAP-14: held for the life of this connection and past the notification's
        // own life -- the spike's check 5 fired one after every notification had
        // been cancelled. Only for notifications that survived the filter: an action
        // for something the app never stored could never be reached anyway.
        NotificationProjection.replyAction(sbn.notification)?.let { ReplyActions.remember(sbn.key, it) }
        // INB-13's `Open chat`, and the only path that can open a source app the
        // manifest's <queries> does not declare: a content intent needs no package
        // visibility at all, while getLaunchIntentForPackage answers null for every
        // undeclared package (INB-20 keeps QUERY_ALL_PACKAGES out of the build). So
        // without this line the thread's only control is dead for every app that
        // reached the inbox by posting rather than by shipping in the list.
        //
        // Same entry, same eviction, same lifetime as the reply action above
        // (ReplyActions): one of the two handles may be absent, and nothing here
        // reads the intent -- it is held as the source app built it and sent that
        // way (product principle 1).
        sbn.notification.contentIntent?.let { ReplyActions.rememberContentIntent(sbn.key, it) }
        enqueue(NotificationProjection.project("posted", sbn))
    }

    /**
     * A removal runs the same gate without recording a sighting: INB-20's
     * `last_seen_at` means the app was seen *posting*, and a removal is the opposite
     * event. The gate still runs, because CAP-1 forbids a disabled package's title
     * and text reaching the queue by any route, and a removal carries both.
     *
     * Runs on [worker].
     */
    private fun removed(sbn: StatusBarNotification, reasonName: String?) {
        if (sbn.packageName == packageName) return
        if (!store.isEnabled(sbn.packageName)) return
        if (!NotificationProjection.isCapturable(sbn)) return
        enqueue(NotificationProjection.project("removed", sbn, reasonName))
    }

    /**
     * Every event goes into the queue, and the EventChannel is only a nudge to drain
     * it (CAP-13). Delivering live events *instead* would leave the app with two
     * delivery paths and one acknowledgement path: an event sent live while Dart was
     * mid-drain would either be stored twice or be left in the queue for thirty days.
     * One path in, one ack out, and the live stream carries a copy purely so INB-25's
     * one-second deadline does not need a poll.
     *
     * The copy is a nudge and nothing else, right down to the Dart side: `_applyLive`
     * ignores the payload and only asks for a drain (android_capture_service.dart).
     * So an event whose append failed is **lost**. There is no row to drain, the
     * signal that follows it starts a drain that finds nothing, and no isolate ever
     * reads what this passes. It is still signalled, because the drain it triggers
     * costs one empty file read and rows that *did* land are worth picking up -- not
     * because anything is being rescued.
     *
     * That is the deliberate trade. The event used to be delivered live when the
     * append failed, and a second delivery path with one acknowledgement path raced
     * the drain and stored messages twice; losing the event is the smaller harm.
     * What survives the loss is the count: CaptureQueue records the failed write in
     * CaptureFaults -- a count and a time, never the payload -- so Dart can read it
     * and a screen can say the app is holding less than it claims, rather than the
     * event disappearing in silence (CAP-12, RUN-1).
     */
    private fun enqueue(row: JSONObject) {
        queue.append(row)
        CaptureEvents.signal(row.toString())
    }

    /**
     * Hands one unit of capture work to [worker], and never lets it reach the
     * framework as a crash: a listener that dies on one malformed notification
     * stops capturing every later one.
     *
     * Nothing logged here carries a payload -- no package, no title, no text, and
     * not the throwable either. The work this wraps reads a notification's title,
     * text and message history, so an exception raised inside it can be carrying
     * that content in its own message; CaptureLog is what keeps it out of logcat
     * (INB-24, product principle 1).
     */
    private fun submit(work: () -> Unit) {
        try {
            worker.execute {
                try {
                    work()
                } catch (e: Exception) {
                    CaptureLog.failure("a capture task failed", e)
                }
            }
        } catch (e: RejectedExecutionException) {
            // The service is being destroyed. The queue on disk is what survives a
            // restart, so this loses at most the event that arrived during teardown.
            CaptureLog.failure("capture work was refused; the listener is stopping", e)
        }
    }

    /**
     * INB-1, INB-20: the label the chooser shows, resolved at the moment the package
     * posts.
     *
     * Since the manifest's `<queries>` gained a MAIN + LAUNCHER intent filter
     * (22 September 2026) every launchable app on the phone is visible to this
     * process, so this resolves a real label for effectively every package that can
     * reach this callback. The package-name fallback is no longer package visibility
     * hiding an app that is plainly there: what is left under it is a package the
     * manager genuinely cannot resolve -- one with no launcher activity, or one
     * uninstalled between the post and this line. It stays a fallback and never a
     * dropped row, because INB-20's row is keyed on the package and the label is only
     * what it is drawn with.
     *
     * Why this call is inside the promise but outside [SourceAppInfo.mayAsk]: the
     * promise is that Replybox asks the phone only about a package that has already
     * sent the user a notification, and `packageName` here *is* that package --
     * [capture] calls this for the notification it is holding and for nothing else.
     * It cannot route through `mayAsk`, because `mayAsk` answers from [CaptureStore]'s
     * record of what has posted and the very next line is the `recordSeen` write that
     * creates it: this call is the source of that record rather than a consumer of it,
     * and gating it on itself would mean no package could ever be named the first time
     * it wrote. That is why QueriesDeclarationTest keeps this file on the short list
     * allowed to hold a `PackageManager` at all.
     *
     * A binder call, which is half of why [capture] runs off the main thread.
     */
    @Suppress("DEPRECATION")
    private fun labelFor(packageName: String): String = try {
        val info = packageManager.getApplicationInfo(packageName, 0)
        packageManager.getApplicationLabel(info).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        packageName
    } catch (e: Exception) {
        packageName
    }

    // The capture package logs through CaptureLog and nowhere else, so this class
    // keeps no TAG of its own (INB-24; CaptureLogTest asserts the package holds one
    // android.util.Log call in total).
}
