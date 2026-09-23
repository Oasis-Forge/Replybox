package com.oasisforge.replybox.capture

import android.app.Notification
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * CAP-14's reply-action map: notification key to what this process still holds for
 * that notification, kept for the life of the process and past the notification's
 * own dismissal.
 *
 * A top-level object rather than a companion on the listener service, because a
 * companion is reached through the service class and it is one careless field away
 * from pinning a dead Service -- which is exactly what the spike did knowingly.
 * Nothing here holds a Context: a `Notification.Action` carries a PendingIntent,
 * which is a token into the system process, and RemoteInputs, which are parcelable
 * descriptions. That is also why the map cannot be persisted and why a cold start
 * legitimately falls back to "open in app" (CAP-14, INB-13).
 *
 * ## Why the content intent lives in this map and not beside it
 *
 * INB-13 says `Open chat` fires the notification's own content intent "from the
 * same in-memory map that holds CAP-14's reply actions", and that is one map here
 * rather than two on purpose. Two parallel maps would evict independently, so a
 * key could keep its reply action and lose its content intent -- the thread would
 * then draw `Open chat` from [canReplyTo] and have nothing to fire. One entry, one
 * eviction, one lifetime.
 */
object ReplyActions {

    /**
     * Every notification an included app posts adds an entry, and a phone that is
     * never rebooted posts a great many. The map is bounded and least-recently-used
     * so it cannot grow for the life of the process; [canReplyTo] counts as a use,
     * so the conversations the inbox is actually asking about are the ones that
     * stay. Evicting an entry only costs INB-13's fallback to "open in app", which
     * is the same answer a cold start gives.
     */
    private const val MAX_ENTRIES = 200

    /**
     * One notification's live handles: the action that can answer it (CAP-14) and
     * the intent that opens it where it lives (INB-13). Either may be absent --
     * a notification can carry a reply action and no content intent, or the
     * reverse -- and absent is what both readers below answer with.
     */
    private class Held {
        var action: Notification.Action? = null
        var contentIntent: PendingIntent? = null
    }

    private val held = object : LinkedHashMap<String, Held>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Held>): Boolean =
            size > MAX_ENTRIES
    }

    @Synchronized
    fun remember(notificationKey: String, action: Notification.Action) {
        entry(notificationKey).action = action
    }

    /**
     * INB-13's `Open chat` half of the same entry.
     *
     * Written by `ReplyboxListenerService.capture`, beside the `remember` above and
     * for every notification that survives CAP-1's filter. It was dead for one
     * release, and what that cost is worth stating: a content intent is the **only**
     * way this app can open a source app the manifest's `<queries>` does not declare
     * -- it needs no package visibility, while `getLaunchIntentForPackage` answers
     * null for an undeclared package and INB-20 keeps `QUERY_ALL_PACKAGES` out of
     * the build. Without the writer, every app that joined the inbox by posting a
     * notification (INB-20's second source) had a control that could never open
     * anything.
     */
    @Synchronized
    fun rememberContentIntent(notificationKey: String, contentIntent: PendingIntent) {
        entry(notificationKey).contentIntent = contentIntent
    }

    /** Read as a use, which is what keeps an open conversation's action in the map. */
    @Synchronized
    fun canReplyTo(notificationKey: String): Boolean = held[notificationKey]?.action != null

    /**
     * Whether `Open chat` can be offered for [notificationKey] (INB-13).
     *
     * The label is decided before the tap, so the screen has to be able to ask this
     * without firing anything -- exactly as [canReplyTo] is asked for the reply
     * field that will stand in the same place. Asking is also a use, so the
     * conversation the user is looking at keeps its entry.
     *
     * A false here is not "offer the other path anyway": for an undeclared package
     * there is no other path, and INB-16 is what the screen says instead.
     */
    @Synchronized
    fun hasContentIntent(notificationKey: String): Boolean = held[notificationKey]?.contentIntent != null

    /**
     * The content intent held for [notificationKey], or null (INB-13).
     *
     * Also read as a use, for the same reason: the conversation the user is
     * looking at is the one whose entry should survive the next two hundred
     * notifications.
     */
    @Synchronized
    fun contentIntentFor(notificationKey: String): PendingIntent? = held[notificationKey]?.contentIntent

    /**
     * Drops everything held.
     *
     * CAP-14 makes repliability a property of this run, and the listener being
     * disconnected ends that run's claim on it: capture has stopped (PERM-8), so an
     * action held from before is a reply bar offered over a notification nobody is
     * telling this process about any more. PERM-8 requires the fallback to "open in
     * app" while access is missing, and this is what makes it true rather than
     * asserted. A reconnection rebuilds the map from what is still posted (CAP-13).
     *
     * INB-13's `Open chat` goes with it, and must: a content intent held over a
     * disconnection is a label promising a chat this process is no longer being
     * told anything about.
     */
    @Synchronized
    fun clear() {
        held.clear()
    }

    /** The entry for [notificationKey], created empty if this is its first handle. */
    private fun entry(notificationKey: String): Held = held.getOrPut(notificationKey) { Held() }
}

/**
 * The live-event nudge. The queue is the delivery path; this only tells a running
 * Dart isolate that there is something to drain, so INB-25's one-second deadline
 * needs no polling.
 */
object CaptureEvents {

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    fun attach(eventSink: EventChannel.EventSink?) {
        sink = eventSink
    }

    fun detach() {
        sink = null
    }

    /**
     * The listener's callbacks do not promise a thread and an EventSink must be
     * touched from the platform thread, so every signal is posted there.
     */
    fun signal(json: String) {
        val current = sink ?: return
        main.post {
            // Re-read rather than closing over `current`: the stream can be
            // cancelled between the post and the run, and a sink used after cancel
            // throws.
            sink?.takeIf { it === current }?.success(json)
        }
    }
}

/**
 * The platform side of `com.oasisforge.replybox/capture`.
 *
 * Every call is answered synchronously on the platform thread. The queue is capped
 * at thirty days of rows (CAP-15) and holds one short line per event, so a drain is
 * a small file read -- and an asynchronous answer here would need its own ordering
 * guarantee against the listener's appends for no measured gain.
 */
class CaptureChannel private constructor(private val context: Context) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {

    private val queue: CaptureQueue by lazy { CaptureQueue.of(context) }
    private val store: CaptureStore by lazy { CaptureStore.of(context) }

    /** INB-13's two launch paths, against the real phone (see [AppLaunch]). */
    private val launchTargets: LaunchTargets by lazy { SystemLaunchTargets(context) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasAccess" -> result.success(hasAccess())

            "openAccessSettings" ->
                if (openAccessSettings()) {
                    result.success(null)
                } else {
                    // PERM-7's third branch: a build can ship without either screen.
                    // Reported as a failure rather than a silent success, so the
                    // disclosure can replace its button with the written path instead
                    // of leaving one that does nothing.
                    result.error(
                        "no_settings_page",
                        "This device has no notification-access settings screen.",
                        null,
                    )
                }

            // PERM-10, and the whole answer is that it may be null. There is no
            // public "is my listener connected" API, so this hands over what this
            // process has observed through the two lifecycle callbacks and nothing
            // more: true, false, or null for "neither has fired here yet"
            // (ListenerState says at length what each one does and does not know).
            //
            // `ListenerState.connected` is passed straight through and is never
            // collapsed -- no `?: false`, no `== true`. A null read as a false is
            // PERM-10's line drawn over a listener that is merely slow to bind, on a
            // first resume, which is the one failure that rule is written against;
            // a null read as a true would be the app claiming capture is running on
            // no evidence at all. Both directions are wrong, so the third value
            // crosses the channel as a third value and the state layer decides.
            "listenerConnected" -> result.success(ListenerState.connected)

            // PERM-10's one action. Boolean, never an error result: the rule spends
            // "the request was made" and "it could not even be made" the same way --
            // it waits ten seconds and asks `listenerConnected` again -- so a second
            // failure shape here would only give the Dart side something to collapse
            // back into false.
            //
            // **No rate limiting lives in this file, deliberately.** PERM-10's
            // at-most-one-request-per-resume and 60-second floor are enforced in
            // `PermissionsProvider.refresh` (`lib/providers/permissions_provider.dart`),
            // because one refresh is one resume and only the state layer knows where
            // a resume began; a clock in here would count calls instead and would
            // quietly disagree with the line the user is shown.
            "requestListenerRebind" -> result.success(requestListenerRebind())

            "drainQueue" -> result.success(queue.drain())

            "ackQueue" -> {
                queue.ack(call.stringList())
                result.success(null)
            }

            // CAP-1, INB-20: Dart writes these rows before it mirrors its own
            // enabled set back down, or a shipped-app default this listener has just
            // applied would be overwritten by a set computed before it existed.
            //
            // Two-phase like the queue, and for the same reason: this hands the rows
            // over and keeps them. A read that cleared would lose a shipped app's
            // one-shot default to a process killed before Dart's write landed, and
            // the app would go silently uncaptured (CAP-1, decision 9, PERM-3).
            "takeSeenApps" -> result.success(
                store.takeSeenApps().map {
                    mapOf(
                        "package" to it.packageName,
                        "label" to it.label,
                        "lastSeenAt" to it.lastSeenAt,
                        "enabledByDefault" to it.enabledByDefault,
                    )
                },
            )

            "ackSeenApps" -> {
                store.ackSeenApps(call.stringList())
                result.success(null)
            }

            // CAP-1, INB-22: two lists, not one. `enabled` is what Dart's rows say
            // is on; `known` is every package Dart holds a row for, on or off, which
            // is what lets the store tell "the user said no" from "Dart has never
            // heard of this package" (CaptureStore.setEnabledPackages).
            //
            // A call missing either list is refused rather than half-applied. There
            // is no safe substitute: an empty `enabled` stops capture everywhere, and
            // an empty `known` re-opens the hole this pair closes, so the honest
            // answer is to change nothing and let Dart surface it -- INB-22's switch
            // must not report a move the phone did not make.
            "setEnabledPackages" -> {
                val enabled = call.stringListArg(ARG_ENABLED)
                val known = call.stringListArg(ARG_KNOWN)
                if (enabled == null || known == null) {
                    result.error(
                        "bad_arguments",
                        "setEnabledPackages needs an '$ARG_ENABLED' and a '$ARG_KNOWN' list of packages.",
                        null,
                    )
                } else {
                    store.setEnabledPackages(enabled, known)
                    result.success(null)
                }
            }

            "canReplyTo" -> result.success(ReplyActions.canReplyTo(call.string().orEmpty()))

            // INB-13: which of the two launches the control may offer, asked before
            // the tap because the label says which one will run. It is the same
            // shape as "canReplyTo" and for the same reason -- a screen cannot fire
            // a path to find out whether it exists.
            "canOpenChat" -> result.success(
                ReplyActions.hasContentIntent(call.string().orEmpty()),
            )

            // INB-13's two launches. Two methods and not one with a mode flag: the
            // path is decided before the tap, by the label the user read, and a
            // single method taking "a package or a notification key" is one
            // refactor away from quietly falling back from one path to the other.
            //
            // Both answer a boolean and never an error. INB-13 makes "it threw" and
            // "there was nothing to start" the same outcome on screen -- one
            // snackbar, nothing else changed -- so an error here would only give the
            // Dart side a second shape to collapse back into false.
            "openChat" -> result.success(
                AppLaunch.openChat(call.string().orEmpty(), launchTargets),
            )

            "openApp" -> result.success(
                AppLaunch.openApp(call.string().orEmpty(), launchTargets),
            )

            // INB-1, INB-16: one source app's label and icon, and which of the
            // three things the app is allowed to say about whether it is still
            // installed. The whole rule is in SourceAppInfo, including the gate
            // that keeps a package the manifest never declared from reaching the
            // package manager at all.
            "lookupPackage" -> result.success(
                SourceAppInfo.lookup(call.string().orEmpty(), SourceAppInfo.facts(context)),
            )

            // CAP-12, RUN-1: what capture could not do, so a screen can say it.
            // Counts and times only -- never a package and never a payload.
            "captureFaults" -> result.success(CaptureFaults.snapshot())

            // PERM-14: the one fact the app prints about the phone, and the only
            // thing this channel ever reads off `Build`. A public field, no
            // permission (PERM-15), and no other device identifier goes with it --
            // not the model, not the fingerprint, not the serial, none of which the
            // rule asks for and any of which would start identifying the handset
            // rather than describing its make.
            //
            // Empty string rather than null across the channel, because the Dart
            // side already maps "" to null and a method channel's null is
            // indistinguishable from "no host answered" (`_invoke` returns null off
            // Android and on MissingPluginException). The screen's two branches are
            // "the device reported this" and "the device reported nothing", and both
            // have to survive a build with no platform behind it.
            "deviceManufacturer" -> result.success(reportedManufacturer(Build.MANUFACTURER))

            // PERM-14's first page: the system's battery-optimisation *list*, which
            // is unguarded. ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS -- the one
            // that asks for the exemption directly -- needs
            // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, and PERM-15 forbids it, so it
            // appears nowhere in this build and PERM-14 offers a page to look at
            // instead of a switch to flip. The app changes nothing about its own
            // battery treatment and says so.
            //
            // Answers through the same `start()` as PERM-7, so a page that does not
            // exist is a false rather than a throw, and the screen replaces the
            // control with the written path.
            "openBatteryOptimisationSettings" ->
                result.success(start(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)))

            // PERM-14's second page: this package's own app-info screen, which is
            // also unguarded for one's own package. `Uri.fromParts` rather than
            // `Uri.parse("package:" + ...)`: fromParts builds an opaque URI with the
            // package as its scheme-specific part and encodes it, so nothing about
            // the string can be read as a path. It names this app and no other --
            // PERM-14 never offers to open a page about somebody else's app.
            "openAppInfoSettings" -> result.success(
                start(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        .setData(Uri.fromParts("package", context.packageName, null)),
                ),
            )

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) = CaptureEvents.attach(events)

    override fun onCancel(arguments: Any?) = CaptureEvents.detach()

    /**
     * PERM-5: read from the system on every ask, never from anything the app stored.
     *
     * Compared as a component, not as a package: `enabled_notification_listeners`
     * lists flattened ComponentNames, and a debug build carries the throwaway spike
     * listener beside this one, so a package-level match would report access that
     * this service does not have. The setting key is @hide in the SDK but has been
     * stable since API 18; the androidx helper that wraps it only answers at package
     * granularity.
     */
    private fun hasAccess(): Boolean {
        val flattened = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        val mine = listenerComponent()
        return flattened.split(':').any { entry ->
            ComponentName.unflattenFromString(entry)?.let {
                it.packageName == mine.packageName && it.className == mine.className
            } == true
        }
    }

    /**
     * PERM-7: the per-app detail page first, so the user lands on one switch rather
     * than a list to hunt through, then the whole-list page. Started from the
     * application context with NEW_TASK rather than from the Activity: the channel
     * outlives any one Activity and holding one here would leak it.
     */
    private fun openAccessSettings(): Boolean {
        // ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS and its component extra are
        // API 29. Below that there is only the list page.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val detail = Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                .putExtra(
                    Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                    listenerComponent().flattenToString(),
                )
            if (start(detail)) return true
        }
        return start(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }

    /**
     * PERM-10: asks Android to bind this app's listener again.
     *
     * `NotificationListenerService.requestRebind(ComponentName)` is static, arrived
     * in API 24 (minSdk is 24, so it is always there) and needs **no permission**
     * (PERM-15): the system checks that the component belongs to the calling app and
     * that the user has approved it, which is a grant this app already holds or does
     * not, never one it asks for here.
     *
     * The component is [listenerComponent], the same one `hasAccess` compares
     * against and the same one PERM-7's detail intent carries. Asking for a rebind
     * of anything else is not a thing this app has any business doing, and the
     * platform refuses it anyway.
     *
     * ## What the true means, and what it does not
     *
     * True is "the request was made", and that is all it may ever be read as. The
     * platform reports no outcome: a rebind is asynchronous, `onListenerConnected`
     * is the only thing that ever says it worked, and a true here that was read as a
     * connection would put "capture is running" on screen with nothing behind it
     * (product principle 3). PERM-10 therefore waits its ten seconds and asks
     * `listenerConnected` again.
     *
     * False is "the request could not even be made", which is not evidence about the
     * listener in either direction and must not be reported to the user as a failure
     * of capture. `RuntimeException` is the whole catch on purpose: the call rethrows
     * a dead system server from the binder as an unchecked exception, and the two
     * plausible refusals -- a `SecurityException` for a component the caller does not
     * own, an `IllegalArgumentException` for one that cannot be resolved -- are both
     * subclasses of it, so naming them separately would only look more thorough.
     */
    private fun requestListenerRebind(): Boolean = try {
        NotificationListenerService.requestRebind(listenerComponent())
        true
    } catch (e: RuntimeException) {
        // Nothing logged, and nothing to log: the answer is the return value, this
        // path names no package and carries no payload (INB-24), and a listener the
        // phone would not rebind is PERM-10's line rather than a fault report.
        false
    }

    /**
     * Tried rather than resolved: `resolveActivity` is filtered by package
     * visibility on API 30 and above, so a settings screen that exists can answer
     * "no such activity" to a query while still starting perfectly well.
     */
    private fun start(intent: Intent): Boolean = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    }

    private fun listenerComponent() = ComponentName(context, ReplyboxListenerService::class.java)

    /**
     * The contract passes arguments positionally. A single-entry map is unwrapped as
     * well, so a caller that sends `{'packages': [...]}` is not silently answered
     * with an empty list -- a filter that quietly captures nothing is the worst
     * failure this channel can have.
     */
    private fun MethodCall.positional(): Any? {
        val args = arguments
        return if (args is Map<*, *> && args.size == 1) args.values.first() else args
    }

    private fun MethodCall.stringList(): List<String> =
        (positional() as? List<*>)?.mapNotNull { it as? String }.orEmpty()

    private fun MethodCall.string(): String? = positional() as? String

    /**
     * A named argument, for the one call that carries more than one list. Named
     * rather than positional there because two lists of package names in a row are
     * one transposition away from a filter that captures the wrong apps.
     *
     * Null when the argument is absent or is not a list; the caller refuses the
     * call rather than reading it as an empty list, because empty is a real and
     * very different answer for both of setEnabledPackages' lists.
     */
    private fun MethodCall.stringListArg(name: String): List<String>? {
        val args = arguments as? Map<*, *> ?: return null
        val value = args[name] as? List<*> ?: return null
        return value.mapNotNull { it as? String }
    }

    companion object {
        const val METHOD_CHANNEL = "com.oasisforge.replybox/capture"
        const val EVENT_CHANNEL = "com.oasisforge.replybox/capture_events"

        /** The two argument names of `setEnabledPackages`; the Dart side sends both. */
        const val ARG_ENABLED = "enabled"
        const val ARG_KNOWN = "known"

        /**
         * `android.os.Build.UNKNOWN`'s value, written out rather than referenced.
         *
         * The platform substitutes this literal for any build property that was
         * never set, `ro.product.manufacturer` included, and the emulator the app
         * is driven on is one of the devices that leaves it unset. Referenced as
         * `Build.UNKNOWN` it would be a constant the unit-test classpath's stub
         * `android.jar` can answer null for, so the test that proves the mapping
         * would be proving it against null -- the failure mode CaptureLogTest
         * describes, a check that quietly stops matching. It has not moved since
         * API 1 and `SettingsRoutesTest` is what holds the pairing.
         */
        private const val UNREPORTED = "unknown"

        /**
         * `Build.MANUFACTURER` as PERM-14 may print it, or `""` for "the device
         * reported nothing".
         *
         * Trimmed, and otherwise passed through exactly: not lower-cased, not
         * title-cased, not looked up in a list of real names. PERM-14 prints this to
         * the user so that an unlisted phone is *visibly* unlisted, and anything
         * this function invented would be the app telling someone something about
         * their hardware that the hardware did not say. The lower-casing PERM-14
         * asks for belongs to the table lookup, which takes a copy
         * (`batteryGuidanceFor`, `lib/data/battery_guidance.dart`), and never to the
         * string the screen draws (LANG-5).
         *
         * ## Why the platform's own "unknown" is answered as nothing
         *
         * `Build.MANUFACTURER` is not nullable on a device: where the property was
         * never set the framework hands back the literal [UNREPORTED]. Passing that
         * through would put *This phone reports its manufacturer as unknown* on
         * screen -- the app printing a placeholder as though it were a make, which
         * is the one thing PERM-14's manufacturer line exists not to do. It is also
         * not hypothetical: it is what an emulator commonly reports, and the
         * emulator is the only hardware this app has been driven on (spike,
         * 21 September 2026).
         *
         * So the platform's placeholder is mapped to the app's own absence and
         * PERM-14's second branch says *This phone did not report a manufacturer*,
         * which is exactly what happened. Matched case-insensitively against the
         * whole trimmed value and nothing looser: a make whose name merely contains
         * the word is a real make and is printed.
         */
        internal fun reportedManufacturer(reported: String?): String {
            val trimmed = reported?.trim().orEmpty()
            return if (trimmed.equals(UNREPORTED, ignoreCase = true)) "" else trimmed
        }

        /** Called from MainActivity.configureFlutterEngine. */
        fun register(engine: FlutterEngine, context: Context) {
            val handler = CaptureChannel(context.applicationContext)
            val messenger = engine.dartExecutor.binaryMessenger
            MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(handler)
            EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(handler)
        }
    }
}
