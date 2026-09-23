package com.oasisforge.replybox.capture

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * INB-1 and INB-16, run rather than described.
 *
 * The two things worth asserting about [SourceAppInfo.lookup] are both about
 * restraint: which packages it is willing to ask the phone about, and which of
 * the three answers each outcome produces. Neither needs a real
 * `PackageManager`, and neither could use one here -- the stub android.jar on
 * this classpath answers null to every framework call -- so the rule takes its
 * facts through an interface and this file hands it a fake that records what it
 * was asked.
 *
 * ## What the 22 September 2026 decision moved into this file
 *
 * The gate used to be [ShippedApps.PACKAGES] and the manifest used to declare
 * exactly those six, so "the app never queries a package it has not declared"
 * was held by the manifest and merely reflected here. The manifest now declares
 * a MAIN + LAUNCHER filter as well, which makes every launchable app visible to
 * this process -- so the manifest holds nothing of the sort any more and **this
 * file is where the promise lives**:
 *
 * > Replybox can see which apps are launchable, but only ever asks about a
 * > package that has already sent the user a notification. It never lists what
 * > is on the phone.
 *
 * So what that buys, in the order it matters:
 *
 *  1. a package this install has never seen post is answered **without the
 *     package manager being touched**, whatever a caller passes and whatever the
 *     phone would have said;
 *  2. a package that *has* posted is answered properly, which is the whole point
 *     of the change -- INB-13's control and INB-16's `gone` were both dead for
 *     every app that joined the inbox by posting (INB-20);
 *  3. a failure is `unknown` and never `gone`, which is the one wrong answer
 *     INB-16 names -- telling the user an app is uninstalled without having seen
 *     that it is.
 */
class SourceAppInfoTest {

    /**
     * A package manager that remembers every package it was asked about, so a
     * test can assert on the asks that did not happen.
     *
     * [posted] is this install's `everSeen` record ([CaptureStore.hasEverSeen] on
     * a device), kept apart from [installed] on purpose: "this app has messaged
     * the user" and "this app is on the phone" are two different facts, and the
     * gate reads the first while the lookup reads the second.
     */
    private class RecordingFacts(
        private val installed: Map<String, PackageFace> = emptyMap(),
        private val failOn: Set<String> = emptySet(),
        private val posted: Set<String> = emptySet(),
        private val postedThrows: Boolean = false,
    ) : PackageFacts {

        val asked = mutableListOf<String>()

        override fun hasPosted(packageName: String): Boolean {
            if (postedThrows) throw IllegalStateException("the capture store could not be read")
            return packageName in posted
        }

        override fun faceOf(packageName: String): PackageFace? {
            asked.add(packageName)
            if (packageName in failOn) throw IllegalStateException("the package manager could not say")
            return installed[packageName]
        }
    }

    private val shipped = ShippedApps.PACKAGES.first()
    private val posted = "com.example.some.other.app"
    private val silent = "com.example.never.posted"

    @Test
    fun `a shipped package the phone has is installed, with its label and icon`() {
        val icon = byteArrayOf(1, 2, 3)
        val facts = RecordingFacts(installed = mapOf(shipped to PackageFace("Messages", icon, launchable = true)))

        val answer = SourceAppInfo.lookup(shipped, facts)

        assertEquals(SourceAppInfo.PRESENCE_INSTALLED, answer[SourceAppInfo.KEY_PRESENCE])
        assertEquals("Messages", answer[SourceAppInfo.KEY_LABEL])
        assertEquals(icon, answer[SourceAppInfo.KEY_ICON])
    }

    @Test
    fun `a shipped package is asked about before it has ever posted`() {
        // PERM-3 and INB-21 both draw rows for the six before any of them has
        // sent anything: the disclosure names every app that will be captured
        // without being chosen, and the chooser's first launch puts all six in
        // its second group. Gating on "has posted" alone would blank both.
        val facts = RecordingFacts(installed = mapOf(shipped to PackageFace("Messages", null, launchable = true)))

        assertEquals(SourceAppInfo.PRESENCE_INSTALLED, SourceAppInfo.lookup(shipped, facts)[SourceAppInfo.KEY_PRESENCE])
        assertEquals(listOf(shipped), facts.asked)
    }

    @Test
    fun `a shipped package the phone does not have is gone`() {
        // The case the app has always been allowed to report as an uninstall:
        // the manifest names this package one by one, so it is visible whatever
        // shape it is in and a NameNotFound can only be absence (INB-16).
        val answer = SourceAppInfo.lookup(shipped, RecordingFacts())

        assertEquals(SourceAppInfo.PRESENCE_GONE, answer[SourceAppInfo.KEY_PRESENCE])
        assertNull(answer[SourceAppInfo.KEY_LABEL], "a gone app has no label to carry")
        assertNull(answer[SourceAppInfo.KEY_ICON], "a gone app has no icon to carry")
    }

    @Test
    fun `a package that has posted is looked up like any other, though it ships in nothing`() {
        // The change this file exists over. Before 22 September 2026 this
        // answered `unknown`, which is what made INB-13's control permanently
        // dead for INB-20's second source -- every app that reached the inbox by
        // posting rather than by shipping in the list.
        val icon = byteArrayOf(7)
        val facts = RecordingFacts(
            installed = mapOf(posted to PackageFace("Shopping", icon, launchable = true)),
            posted = setOf(posted),
        )

        val answer = SourceAppInfo.lookup(posted, facts)

        assertEquals(SourceAppInfo.PRESENCE_INSTALLED, answer[SourceAppInfo.KEY_PRESENCE])
        assertEquals("Shopping", answer[SourceAppInfo.KEY_LABEL])
        assertEquals(icon, answer[SourceAppInfo.KEY_ICON])
    }

    @Test
    fun `a package that has posted and is no longer on the phone is gone`() {
        // INB-16's tri-state gets *more* useful, not less: `sourceAppGone` is
        // now truthful for an app that messaged the user and has since been
        // uninstalled, where before the app withheld it and left a control that
        // could never work. The residual SourceAppInfo states is the other
        // shape -- an installed app with no launcher activity -- and nothing in
        // the data can tell the two apart.
        val facts = RecordingFacts(posted = setOf(posted))

        val answer = SourceAppInfo.lookup(posted, facts)

        assertEquals(SourceAppInfo.PRESENCE_GONE, answer[SourceAppInfo.KEY_PRESENCE])
        assertEquals(listOf(posted), facts.asked)
    }

    @Test
    fun `a package that has never posted is unknown and the package manager is never asked`() {
        // The promise, as an executed assertion. The manifest no longer refuses
        // this lookup -- a launchable app is visible now -- so if this gate goes,
        // nothing else stops the app reading the phone's app list one name at a
        // time.
        val facts = RecordingFacts(
            installed = mapOf(silent to PackageFace("Banking", byteArrayOf(9), launchable = true)),
        )

        val answer = SourceAppInfo.lookup(silent, facts)

        assertEquals(SourceAppInfo.PRESENCE_UNKNOWN, answer[SourceAppInfo.KEY_PRESENCE])
        assertNull(answer[SourceAppInfo.KEY_LABEL])
        assertNull(answer[SourceAppInfo.KEY_ICON])
        assertEquals(
            emptyList(),
            facts.asked,
            "Replybox only ever asks the package manager about a package that has already sent the user a " +
                "notification, or one of the six the manifest names and PERM-3's disclosure shows. This " +
                "answer has to be reached without asking, or the app is making package-visibility lookups " +
                "for apps the user was never told about (INB-1, INB-20, CAP-20).",
        )
    }

    @Test
    fun `a store that cannot say whether the package posted is unknown, and nothing is asked`() {
        // Fail closed. A capture store that could not be read is not permission
        // to ask anyway, and `unknown` is the honest answer for a build that has
        // lost its own record of what has messaged this phone.
        val facts = RecordingFacts(
            installed = mapOf(posted to PackageFace("Shopping", null, launchable = true)),
            posted = setOf(posted),
            postedThrows = true,
        )

        assertEquals(SourceAppInfo.PRESENCE_UNKNOWN, SourceAppInfo.lookup(posted, facts)[SourceAppInfo.KEY_PRESENCE])
        assertEquals(emptyList(), facts.asked)
    }

    @Test
    fun `mayAsk is the rule, and it is two conditions and no others`() {
        // Read as itself rather than inferred from an answer, because this is
        // the predicate AppLaunch.openApp shares -- both of the channel's routes
        // to the package manager go through it.
        val hasPosted = { name: String -> name == posted }

        assertTrue(SourceAppInfo.mayAsk(shipped, hasPosted), "the six are named in the manifest and on the disclosure")
        assertTrue(SourceAppInfo.mayAsk(posted, hasPosted), "it has already sent the user a notification")
        assertFalse(SourceAppInfo.mayAsk(silent, hasPosted), "nothing else is asked about, ever")
    }

    @Test
    fun `the record the gate reads is the one the listener writes`() {
        // The gate is only as true as its source. CaptureStore.everSeen is
        // written by recordSeen *before* CAP-1's drop, so a package whose row is
        // off still counts as having posted -- which is what INB-22 needs, since
        // turning a row off changes nothing on screen but the switch and its
        // conversations keep their icons and INB-13's control.
        val store = storeOn(java.io.File(newTempDir("source-app-info"), "capture-store.json"))
        val off = "com.example.switched.off"

        assertFalse(store.hasEverSeen(off), "nothing has posted on a fresh install")
        assertFalse(store.recordSeen(off, "Off", T), "an unshipped package is not captured from until it is on")
        assertTrue(store.hasEverSeen(off), "it posted, so the app may ask about it -- capture is a separate question")
        assertFalse(store.hasEverSeen(silent), "a package nobody has heard from is still unasked")
    }

    @Test
    fun `a lookup that fails is unknown and never gone`() {
        // A dead binder, a security exception, anything that is not "no such
        // package". INB-16: the app never tells the user an app is uninstalled
        // unless it can see that it is, so a failure says less rather than
        // guessing -- and the row keeps `Open in app` instead of gaining a
        // sourceAppGone line about an app that is still there.
        val facts = RecordingFacts(failOn = setOf(shipped))

        val answer = SourceAppInfo.lookup(shipped, facts)

        assertEquals(SourceAppInfo.PRESENCE_UNKNOWN, answer[SourceAppInfo.KEY_PRESENCE])
        assertEquals(listOf(shipped), facts.asked, "a package the gate admitted is asked about before it fails")
    }

    @Test
    fun `an installed app with no drawable icon is still installed`() {
        // The icon and the presence are two facts, and INB-16's line is about the
        // second. An icon that could not be drawn costs INB-1's fallback to the
        // generic source icon and must not cost the row its answer.
        val facts = RecordingFacts(mapOf(shipped to PackageFace("Messages", null, launchable = true)))
        val answer = SourceAppInfo.lookup(shipped, facts)

        assertEquals(SourceAppInfo.PRESENCE_INSTALLED, answer[SourceAppInfo.KEY_PRESENCE])
        assertEquals("Messages", answer[SourceAppInfo.KEY_LABEL])
        assertNull(answer[SourceAppInfo.KEY_ICON])
    }

    @Test
    fun `an installed app with no launcher activity is installed, and says it cannot be opened`() {
        // The 23 September 2026 drill, as an assertion. `com.android.shell` is
        // installed, resolves a label and an icon, and has no launcher activity,
        // so the thread drew `Open Shell` and answered every tap with "Could not
        // open that app." Presence answers "does this package exist" and the
        // control needs "can I open it": two questions, two answers, and the code
        // was asking the first while meaning the second (INB-13).
        val facts = RecordingFacts(
            installed = mapOf(posted to PackageFace("Shell", byteArrayOf(4), launchable = false)),
            posted = setOf(posted),
        )

        val answer = SourceAppInfo.lookup(posted, facts)

        assertEquals(
            SourceAppInfo.PRESENCE_INSTALLED,
            answer[SourceAppInfo.KEY_PRESENCE],
            "INB-16: the app is on the phone, and saying `gone` about it would be the uninstall this app " +
                "never observed",
        )
        assertEquals("Shell", answer[SourceAppInfo.KEY_LABEL], "a row that cannot be opened still has a name")
        assertEquals(false, answer[SourceAppInfo.KEY_LAUNCHABLE], "and nothing to open")
    }

    @Test
    fun `launchability is a separate fact and never decides the presence`() {
        // The two must not be folded in either direction. An app with no launcher
        // activity is not gone (INB-16's sentence would be false), and an app that
        // is gone carries no launchability at all -- there was nothing to ask.
        val noLauncher = RecordingFacts(
            installed = mapOf(shipped to PackageFace("Messages", null, launchable = false)),
        )
        val launchable = RecordingFacts(
            installed = mapOf(shipped to PackageFace("Messages", null, launchable = true)),
        )

        assertEquals(SourceAppInfo.PRESENCE_INSTALLED, SourceAppInfo.lookup(shipped, noLauncher)[SourceAppInfo.KEY_PRESENCE])
        assertEquals(true, SourceAppInfo.lookup(shipped, launchable)[SourceAppInfo.KEY_LAUNCHABLE])

        for (answer in listOf(
            SourceAppInfo.lookup(shipped, RecordingFacts()),
            SourceAppInfo.lookup(silent, RecordingFacts()),
        )) {
            assertNull(
                answer[SourceAppInfo.KEY_LAUNCHABLE],
                "a package that resolved nothing was never asked whether it could be started, and a false " +
                    "here would read as `there is nothing to open` about an app that may not even be there",
            )
        }
    }

    @Test
    fun `every shipped package is one the app is willing to ask about`() {
        // test/shipped_apps_test.dart pins this set to the manifest's <package>
        // entries in source and tool/check_queries.sh pins the built manifest on
        // every release. If a shipped app were outside the gate, its row could
        // never show an icon before it first posted, for an app captured by
        // default (CAP-1) and named on the disclosure (PERM-3).
        val facts = RecordingFacts()
        for (packageName in ShippedApps.PACKAGES) {
            SourceAppInfo.lookup(packageName, facts)
        }
        assertEquals(ShippedApps.PACKAGES.toList(), facts.asked)
    }

    @Test
    fun `the answer always carries all four keys`() {
        // The channel hands this map to Dart as-is. A key missing on one branch
        // and present on another is how a caller ends up reading a stale label
        // beside a `gone`.
        val here = RecordingFacts(mapOf(shipped to PackageFace("Messages", byteArrayOf(1), launchable = true)))
        for (answer in listOf(
            SourceAppInfo.lookup(shipped, here),
            SourceAppInfo.lookup(shipped, RecordingFacts()),
            SourceAppInfo.lookup(silent, RecordingFacts()),
        )) {
            assertTrue(answer.containsKey(SourceAppInfo.KEY_PRESENCE), "presence is missing from $answer")
            assertTrue(answer.containsKey(SourceAppInfo.KEY_LABEL))
            assertTrue(answer.containsKey(SourceAppInfo.KEY_LAUNCHABLE), "launchability is missing from $answer")
            assertTrue(answer.containsKey(SourceAppInfo.KEY_ICON))
        }
    }
}
