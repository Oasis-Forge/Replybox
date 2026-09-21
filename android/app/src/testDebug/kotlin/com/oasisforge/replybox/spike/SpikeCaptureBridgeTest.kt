package com.oasisforge.replybox.spike

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The bridge's gate, one clause at a time (PERM-12).
 *
 * In `src/testDebug` rather than `src/test` because the class under test is in the
 * debug source set and must stay there: `OwnPackageGuardTest` fails if any file
 * outside `src/debug` and `src/testDebug` so much as names it, and that is the
 * structural half of "a release build cannot take this escape". A test in `src/test`
 * would compile into `testReleaseUnitTest` as well and would drag the reference
 * across that line.
 *
 * `shouldBridge` is pure and takes the three facts it decides on as arguments, for
 * exactly this reason: the decision is three safety clauses, and a decision made
 * inside a `NotificationListenerService` callback could not be asserted at all on a
 * classpath whose `StatusBarNotification` answers null to everything.
 */
class SpikeCaptureBridgeTest {

    @Test
    fun `it is off by default`() {
        // The default is the `enabled` this gets from a device with no flag file:
        // a fresh install, and every install after `spike.sh reset`. Nothing about
        // the notification can switch it on.
        assertFalse(
            SpikeCaptureBridge.shouldBridge(
                enabled = false,
                notificationPackage = OWN,
                ownPackage = OWN,
                channelId = SpikeRawPoster.CHANNEL,
            ),
            "the bridge replayed a notification with the flag off. It is opt-in per drill, because " +
                "while it is open the app's own notification text reaches the shipped queue (PERM-12).",
        )
    }

    @Test
    fun `it replays the poster's own notifications when it is on`() {
        assertTrue(
            SpikeCaptureBridge.shouldBridge(
                enabled = true,
                notificationPackage = OWN,
                ownPackage = OWN,
                channelId = SpikeRawPoster.CHANNEL,
            ),
        )
    }

    @Test
    fun `it never replays another app's notification`() {
        // The spike listener sees every package on the phone, and the shipped
        // listener has already captured this one. Replaying it would store it twice
        // -- the second copy under a package that is not its own -- and the drill
        // would read as a CAP-5 dedup failure that nothing in the app caused.
        for (enabled in listOf(true, false)) {
            assertFalse(
                SpikeCaptureBridge.shouldBridge(
                    enabled = enabled,
                    notificationPackage = "com.google.android.apps.messaging",
                    ownPackage = OWN,
                    channelId = SpikeRawPoster.CHANNEL,
                ),
                "a third-party notification was replayed (flag on: $enabled)",
            )
        }
    }

    @Test
    fun `it never replays a notification from another channel`() {
        // Only the poster's shapes are CAP-21 fixtures. Anything else this app
        // posts -- and anything the Flutter tooling posts in a debug build -- is
        // not, and has no business in the capture queue.
        for (channel in listOf(null, "", "flutter", "replybox-snooze")) {
            assertFalse(
                SpikeCaptureBridge.shouldBridge(
                    enabled = true,
                    notificationPackage = OWN,
                    ownPackage = OWN,
                    channelId = channel,
                ),
                "a notification on channel $channel was replayed",
            )
        }
    }

    @Test
    fun `the substituted package is not this app and not a shipped app`() {
        // The same two properties OwnPackageGuardTest asserts against the source,
        // asserted here against the constant the device actually uses. PERM-12's
        // promise is that Replybox never appears as a source app, and this is the
        // string that decides it.
        assertFalse(
            SpikeCaptureBridge.SUBSTITUTE_PACKAGE == OWN ||
                SpikeCaptureBridge.SUBSTITUTE_PACKAGE.startsWith("$OWN."),
            "the bridged row would appear in the included-apps list as Replybox itself: " +
                SpikeCaptureBridge.SUBSTITUTE_PACKAGE,
        )
        assertEquals(
            "com.oasisforge.spikeraw",
            SpikeCaptureBridge.SUBSTITUTE_PACKAGE,
            "the drill's adb commands and docs/STACK_NOTES.md name this package; change both together",
        )
    }

    private companion object {
        const val OWN = "com.oasisforge.replybox"
    }
}
