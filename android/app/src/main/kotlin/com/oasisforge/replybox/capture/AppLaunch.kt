package com.oasisforge.replybox.capture

import android.app.ActivityOptions
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle

/**
 * INB-13's two launches, and the line between them.
 *
 * ## The two paths are not interchangeable
 *
 * INB-13 names exactly two ways the bottom bar's control can open a source app,
 * and which one runs is decided before the tap, because the label says which:
 *
 *  - **`Open chat`** -- this process still holds that conversation's
 *    notification, so the app fires *the notification's own content intent*,
 *    taken from [ReplyActions], the same in-memory map that holds CAP-14's
 *    reply actions.
 *  - **`Open <app>`** -- nothing is held, so the app starts the package's own
 *    launcher intent and claims nothing about where that lands.
 *
 * Neither is a fallback for the other. A held content intent that fails is a
 * failure, not a reason to open the app's home screen instead: the user was
 * offered `Open chat` and silently landing them somewhere else is the same lie
 * the no-op launcher told. So [openChat] never reaches for a launcher intent and
 * [openApp] never reaches for a held one, and a JVM test asserts both by handing
 * in targets that record what was asked for (AppLaunchTest).
 *
 * ## Nothing is added to either intent
 *
 * Product principle 1, spelled out by INB-13: *neither intent carries an extra, a
 * message, a sender or a conversation identifier the app added.* A content intent
 * is sent exactly as the source app built it, and a launcher intent is exactly
 * what the package manager handed over. Nothing here puts a value onto either
 * one, guesses a deep link from a conversation key, or builds a component into
 * another app's internals -- and AppLaunchTest reads this source to keep it that
 * way, because the compiler cannot.
 *
 * The one thing the send now carries beside the intent is an [android.app.ActivityOptions]
 * bundle, and it is not part of the intent at all: it says who is answering for the
 * activity start (see `SystemLaunchTargets.senderOptions`). It holds no extra, no
 * component and no data, and the fill-in argument -- the only place a sender may
 * merge values into someone else's intent -- is null.
 *
 * ## Nothing here cancels a notification
 *
 * Firing a content intent may make the *source app* cancel its own notification,
 * and CAP-22 reads that removal like any other and marks the conversation read --
 * the user opened the chat. What Replybox must never do is cancel one itself
 * (CAP-10, INB-17). No call in this file touches a notification, and
 * AppLaunchTest asserts the capture package holds no cancel call at all.
 *
 * ## Why the rule takes its targets through an interface
 *
 * The same reason [SourceAppInfo] does: the stub android.jar on the unit-test
 * classpath answers null to every framework call, so neither a `PendingIntent`
 * nor a `PackageManager` can be built there. Behind [LaunchTargets] the decisions
 * worth asserting -- which target is asked for, what happens when there is none,
 * what happens when starting it throws -- run as the shipped code and not as a
 * copy of it.
 */
internal object AppLaunch {

    /**
     * INB-13's `Open chat`: the notification's own content intent, or false when
     * this process is not holding one for [notificationKey].
     *
     * False here is not "try the other path". It means the state the label was
     * drawn from has gone -- the listener reconnected and rebuilt the map
     * (CAP-13, CAP-14), or the entry was evicted -- and INB-13 spends that the
     * same way it spends any failed launch: one snackbar, nothing else on screen
     * changes.
     */
    fun openChat(notificationKey: String, targets: LaunchTargets): Boolean =
        fire { targets.heldChat(notificationKey) }

    /**
     * INB-13's `Open <app>`: the package's own launcher intent.
     *
     * This path used to be dead for every package outside the shipped six: the
     * manifest declared only those, so `getLaunchIntentForPackage` answered null
     * for every app that joined the inbox by posting (INB-20). Since 22 September
     * 2026 `<queries>` also carries a MAIN + LAUNCHER filter, so it resolves for
     * any launchable app on the phone and the control works where the label says
     * it will.
     *
     * Null from [LaunchTargets.appLauncher] is the cases that are left, and the app
     * still does not try to tell them apart here (INB-16): the package is not
     * installed, or it is installed with no launcher activity and so has nothing to
     * start. Both are the same snackbar, which names no app.
     *
     * The second of those should now be rare, and when it happens it is a race
     * rather than a state: since 23 September 2026 the lookup carries
     * [SourceAppInfo.KEY_LAUNCHABLE] beside the presence, so a package with no
     * launcher activity draws a line and not a control, and nothing offers this
     * launch for it. What is left here is the app being uninstalled, or its last
     * launcher activity disabled, between the lookup and the tap.
     *
     * Nothing in this file reads [SourceAppInfo]'s presence, deliberately -- a
     * launch that resolved nothing is a failed launch whatever a lookup said a
     * frame earlier, and folding the two would let a stale `installed` turn a
     * failure into a success.
     */
    fun openApp(packageName: String, targets: LaunchTargets): Boolean {
        // The same gate SourceAppInfo.lookup applies, for the same reason and on
        // the same record: resolving a launcher intent is a question about the
        // phone, so it is asked only about a package the manifest names or one
        // this install has seen post a notification. Without it the widened
        // `<queries>` would make this method a yes/no oracle on any package name
        // a caller cared to pass, which is the half of the promise the manifest
        // stopped holding on 22 September 2026.
        if (!SourceAppInfo.mayAsk(packageName, targets::hasPosted)) return false
        return fire { targets.appLauncher(packageName) }
    }

    /**
     * Resolve, start, and answer whether it went.
     *
     * Both halves are inside the same `try` because INB-13 makes them one
     * outcome: *a launch that throws or resolves to nothing changes nothing on
     * screen.* A resolve that throws -- a `SecurityException` from the package
     * manager, say -- is a launch that did not happen, and the user is told the
     * one true thing either way.
     *
     * The failure line names no package (INB-24): [CaptureLog] is the package's
     * only route to logcat and it takes the exception's class name, never the
     * exception.
     */
    private fun fire(resolve: () -> Launch?): Boolean {
        return try {
            val target = resolve() ?: return false
            target.start()
            true
        } catch (e: Exception) {
            CaptureLog.failure("a source app could not be opened", e)
            false
        }
    }
}

/**
 * One thing that can be started, already resolved.
 *
 * Deliberately not an `Intent`: a `PendingIntent` is sent and an `Intent` is
 * started, and the two paths must not be able to drift into sharing a "build an
 * intent" helper -- which is where an added extra or a guessed component would
 * arrive. Here each path hands back a closure over what it already has, and
 * [AppLaunch] only starts it.
 */
internal fun interface Launch {

    /** Throws whatever the framework throws; [AppLaunch] turns that into false. */
    fun start()
}

/**
 * What a launch needs from the phone, as the two questions INB-13 asks.
 *
 * Null means "there is nothing to start", which is a real answer and never an
 * error: a cold start holds no notification, and a package outside the
 * manifest's `<queries>` resolves to nothing (INB-16).
 */
internal interface LaunchTargets {

    /** The content intent held for [notificationKey] this run, or null. */
    fun heldChat(notificationKey: String): Launch?

    /**
     * Whether this install has seen [packageName] post a notification
     * ([CaptureStore]'s own record, never a question put to the phone).
     *
     * [openChat] needs no equivalent: it is keyed by a notification this process
     * is holding, so it can only ever name a conversation that arrived here.
     */
    fun hasPosted(packageName: String): Boolean

    /** [packageName]'s own launcher intent, or null when there is none to start. */
    fun appLauncher(packageName: String): Launch?
}

/**
 * The real one.
 *
 * Holds the application context, like the rest of the channel: this outlives any
 * one Activity and holding one here would leak it. That is also why a launcher
 * intent is started with `FLAG_ACTIVITY_NEW_TASK` -- an Activity-less context has
 * no task to start into.
 *
 * No permission is involved in either path and none is added to the manifest:
 * starting another app's launcher intent is ordinary, and sending a
 * `PendingIntent` runs as the app that created it. RUN-2's permission list is
 * unchanged by this file (CAP-20).
 */
internal class SystemLaunchTargets(private val context: Context) : LaunchTargets {

    override fun hasPosted(packageName: String): Boolean =
        CaptureStore.of(context).hasEverSeen(packageName)

    override fun heldChat(notificationKey: String): Launch? {
        val held = ReplyActions.contentIntentFor(notificationKey) ?: return null
        // Nothing of ours is filled in: the third argument is the fill-in the
        // sender may merge into the intent, and null is what says the intent goes
        // exactly as the source app built it (INB-13, product principle 1). The
        // fourth to sixth are a finish callback, its handler and a required
        // permission, none of which this path has; the seventh is [senderOptions],
        // which carries no intent data of any kind -- only who is answering for
        // the start.
        return Launch { held.send(context, 0, null, null, null, null, senderOptions()) }
    }

    /**
     * What this app says about *its own* right to start an activity, when it sends
     * someone else's `PendingIntent` (INB-13's 23 September 2026 correction).
     *
     * ## What the drill measured
     *
     * On the emulator at API 37, `send()` on a two-second-old Google Messages
     * notification **succeeded and opened nothing**:
     *
     * ```
     * Background activity launch blocked! ... balAllowedByPiCreator: BSP.NONE
     * ```
     *
     * The block is attributed to the *creator*: Google Messages built the intent
     * without opting into background starts, which is the ordinary thing for an app
     * to do -- it expects the shade, a privileged sender, to fire it. Replybox is
     * not privileged; it is an ordinary app that happens to be on screen with the
     * user's finger on the button.
     *
     * Since Android 14, an app targeting API 34 or above no longer lends its own
     * start privileges to a `PendingIntent` it sends unless it says so, and the
     * default became "denied". That default is the whole defect: this app *is* in
     * the foreground when the control is tapped, so it has the privilege the launch
     * needed and was simply not offering it. [ActivityOptions] is how it is offered,
     * and it is a statement about the sender, never about the intent -- no extra, no
     * component, no data (product principle 1, AppLaunchTest).
     *
     * Null below API 34, where the option does not exist and none is needed: a
     * foreground sender's privileges were lent implicitly there.
     *
     * ## Measured both ways, on the same phone, on the same notification
     *
     * Emulator, API 37, 23 September 2026, a Google Messages conversation with its
     * notification still held. Without the bundle the system refuses and says
     * exactly what would have changed its mind:
     *
     * ```
     * Background activity launch blocked! ... balAllowedByPiCreator: BSP.NONE;
     *   realCallingPackage: com.oasisforge.replybox; realCallingUidHasVisibleActivity: true;
     *   realCallerStartMode: MODE_BACKGROUND_ACTIVITY_START_SYSTEM_DEFINED;
     *   balAllowedByPiSender: BSP.ALLOW_FGS; resultIfPiSenderAllowsBal: BAL_ALLOW_VISIBLE_WINDOW
     * ```
     *
     * With it, the same tap on the same conversation:
     *
     * ```
     * START u0 {... cmp=com.google.android.apps.messaging/.ui.ConversationListActivity}
     *   from uid 10150 (realCallingUid=10249) (BAL_ALLOW_VISIBLE_WINDOW [realCaller]) result code=0
     * ```
     *
     * The app was on screen in both runs. The only difference is whether it offered
     * the privilege it already had.
     *
     * **It is still best effort and the app does not trust it.** A grant can be
     * refused -- by a phone that is not in the foreground by then, by an OEM, by a
     * creator's own restriction -- and the send reports success either way, so
     * `android_app_launcher.dart` checks that Replybox actually stopped being the
     * app on screen before it calls this a launch. INB-13's snackbar is the outcome
     * when it did not; what the correction removes is the third outcome, the tap
     * that did nothing and said nothing.
     */
    private fun senderOptions(): Bundle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return null
        return ActivityOptions.makeBasic()
            .setPendingIntentBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
            )
            .toBundle()
    }

    override fun appLauncher(packageName: String): Launch? {
        // The package manager's own answer, unmodified. `getLaunchIntentForPackage`
        // is filtered by package visibility; the manifest's MAIN + LAUNCHER filter
        // is what now puts a launchable app inside that filter, and a package with
        // no launcher activity still answers null here without the app having
        // learnt anything about the phone (INB-13, INB-16, INB-20).
        val intent = context.packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return Launch { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }
}
