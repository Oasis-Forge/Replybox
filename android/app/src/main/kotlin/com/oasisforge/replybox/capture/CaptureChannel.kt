package com.oasisforge.replybox.capture

import android.app.Notification
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * CAP-14's reply-action map: notification key to the action that can answer it,
 * held for the life of the process and past the notification's own dismissal.
 *
 * A top-level object rather than a companion on the listener service, because a
 * companion is reached through the service class and it is one careless field away
 * from pinning a dead Service -- which is exactly what the spike did knowingly.
 * Nothing here holds a Context: a `Notification.Action` carries a PendingIntent,
 * which is a token into the system process, and RemoteInputs, which are parcelable
 * descriptions. That is also why the map cannot be persisted and why a cold start
 * legitimately falls back to "open in app" (CAP-14, INB-13).
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

    private val actions = object : LinkedHashMap<String, Notification.Action>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Notification.Action>): Boolean =
            size > MAX_ENTRIES
    }

    @Synchronized
    fun remember(notificationKey: String, action: Notification.Action) {
        actions[notificationKey] = action
    }

    /** Read as a use, which is what keeps an open conversation's action in the map. */
    @Synchronized
    fun canReplyTo(notificationKey: String): Boolean = actions[notificationKey] != null

    /**
     * Drops every held action.
     *
     * CAP-14 makes repliability a property of this run, and the listener being
     * disconnected ends that run's claim on it: capture has stopped (PERM-8), so an
     * action held from before is a reply bar offered over a notification nobody is
     * telling this process about any more. PERM-8 requires the fallback to "open in
     * app" while access is missing, and this is what makes it true rather than
     * asserted. A reconnection rebuilds the map from what is still posted (CAP-13).
     */
    @Synchronized
    fun clear() {
        actions.clear()
    }
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

            // CAP-12, RUN-1: what capture could not do, so a screen can say it.
            // Counts and times only -- never a package and never a payload.
            "captureFaults" -> result.success(CaptureFaults.snapshot())

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

        /** Called from MainActivity.configureFlutterEngine. */
        fun register(engine: FlutterEngine, context: Context) {
            val handler = CaptureChannel(context.applicationContext)
            val messenger = engine.dartExecutor.binaryMessenger
            MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(handler)
            EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(handler)
        }
    }
}
