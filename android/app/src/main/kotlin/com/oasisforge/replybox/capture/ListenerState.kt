package com.oasisforge.replybox.capture

/**
 * Whether this process's listener is bound (PERM-10), as three values and not two.
 *
 * A top-level object for the same reason [ReplyActions] is one: reached through the
 * service class it is one careless field away from pinning a dead Service. It holds
 * a `Boolean?` and nothing else -- no Context, no component, no time.
 *
 * ## Null is not "disconnected"
 *
 * There is no public API that answers "is *my* listener connected". The one thing
 * the platform gives is a pair of lifecycle callbacks into the service, so the
 * honest answer is a record of what this process has observed through them -- and
 * a process that has observed neither has learned nothing at all.
 *
 * The app and the listener share a process (the service declares no
 * `android:process`), so the Activity's first resume can run in a process the
 * framework started for the Activity while the listener happens to be unbound, or
 * in one where the binding is in flight and the callback simply has not fired yet.
 * Those two are the same observation: nothing. PERM-10 draws its line on a
 * **false**, so a null that decayed into a false would accuse a listener that is
 * merely slow to bind -- the one thing that rule names, and the reason its
 * ten-second wait exists.
 *
 * ## What the flag genuinely knows
 *
 *  - **true**: `onListenerConnected` fired in this process and no disconnection has
 *    been seen since. At that moment the listener was bound and the framework was
 *    willing to hand over `activeNotifications` (CAP-13's re-read runs off the same
 *    callback).
 *  - **false**: `onListenerDisconnected` fired in this process and no connection has
 *    been seen since. That callback is also what `NotificationListenerService`'s own
 *    `onDestroy` runs, so a service torn down while the Flutter process lives on
 *    lands here too -- which is the case the Activity is most likely to resume into.
 *  - **null**: neither has fired since this process started.
 *
 * ## What it cannot know, and must not be read as
 *
 *  - **A true can be stale.** The framework promises the connected callback on a
 *    bind; it does not promise the disconnected one for every way a binding can
 *    end. Whether a revocation reports itself at all was not measured (spike,
 *    21 September 2026, check 3 -- CAP-25), so a `true` means "the last thing this
 *    process was told", never "bound right now". PERM-10 spends it as the absence
 *    of evidence to the contrary and shows no line, which is the direction that
 *    cannot lie to the user; PERM-11 is what covers a listener that died quietly,
 *    and it states only when something last arrived.
 *  - **It is not the grant.** A bound listener is neither necessary nor sufficient
 *    evidence that notification access is on. That is `hasAccess`'s question and
 *    PERM-5 says it is read from `Settings.Secure` every single time.
 *  - **It is not a rate limiter.** PERM-10's at-most-one-request-per-resume and
 *    60-second floor are *not* here and must not arrive here: one refresh is one
 *    resume, and only the state layer knows where a refresh began. They live in
 *    `PermissionsProvider.refresh` (`lib/providers/permissions_provider.dart`).
 *
 * ## Nothing here is persisted, and nothing may be
 *
 * PERM-5's discipline is that the state of the platform is read from the platform.
 * A stored "it was connected" would outlive the connection it described and would
 * be exactly the flag PERM-5 forbids -- one written by this app that a screen then
 * reads as a fact about the phone. The process dying takes this with it, and a
 * fresh process starting at null rather than at a remembered true is the whole
 * point: it is the safe direction.
 */
object ListenerState {

    /**
     * Written on the platform's callback thread and read on the platform thread of
     * a method call microseconds later, so the write has to be visible without a
     * lock. A boxed `Boolean?` is a reference field and `@Volatile` publishes it
     * like any other.
     */
    @Volatile
    var connected: Boolean? = null
        private set

    /** `onListenerConnected` fired. */
    fun onConnected() {
        connected = true
    }

    /** `onListenerDisconnected` fired. */
    fun onDisconnected() {
        connected = false
    }

    /**
     * Back to "nothing observed", for a unit test and for nothing else.
     *
     * This object is a process singleton and the whole suite shares one JVM, so
     * without this the claim worth the most -- that a process which has seen
     * neither callback answers null rather than false -- could only be asserted by
     * whichever test happened to run first, and would silently stop being asserted
     * the day another test ran before it. It is internal, it is named as a
     * test-only door, and `ListenerStateTest` fails if any shipped file calls it:
     * a production caller would be manufacturing the one state PERM-10 reads as
     * "learned nothing" out of a state the app had in fact learned.
     */
    internal fun forget() {
        connected = null
    }
}
