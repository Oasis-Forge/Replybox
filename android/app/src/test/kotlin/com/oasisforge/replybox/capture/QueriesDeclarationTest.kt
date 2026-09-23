package com.oasisforge.replybox.capture

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The source manifest's `<queries>`, and the routes to the package manager it
 * opens (INB-13, INB-16, INB-20, CAP-20).
 *
 * `tool/check_queries.sh` checks the **built** manifest on every release, which
 * is the copy that matters and the only one that catches a merge. This file
 * checks the source one, because it runs on every commit and because two of
 * these are premises the code above depends on rather than facts about a build:
 *
 *  * without the MAIN + LAUNCHER filter, [SourceAppInfo] answers `gone` for
 *    every launchable app that is not one of the six -- package visibility hides
 *    them, `getApplicationInfo` throws NameNotFound, and nothing else in the
 *    build notices. That is the one sentence INB-16 forbids the app to guess,
 *    said about every app the user has;
 *  * with `QUERY_ALL_PACKAGES`, every package is visible, `unknown` could never
 *    honestly be reached, and the gate in [SourceAppInfo.mayAsk] would be
 *    decoration on a build that can already see the phone's app list.
 *
 * `test/shipped_apps_test.dart` owns the six `<package>` entries against the
 * Dart and Kotlin copies of the shipped list; what is asserted here is only what
 * this package's own behaviour rests on.
 */
class QueriesDeclarationTest {

    @Test
    fun `queries declares the launcher filter INB-13's control needs`() {
        val queries = queriesElement()

        assertTrue(
            queries.contains("android.intent.action.MAIN") && queries.contains("android.intent.category.LAUNCHER"),
            "The MAIN + LAUNCHER intent filter is gone from <queries>. `Open <app>` then resolves nothing for " +
                "every package outside the shipped six (INB-13), and worse, INB-16's lookup reads package " +
                "visibility as an uninstall and tells the user every app that has messaged them is gone. " +
                "Developer decision, 22 September 2026.",
        )
    }

    @Test
    fun `queries still declares the PROCESS_TEXT intent the Flutter engine needs`() {
        assertTrue(
            queriesElement().contains("android.intent.action.PROCESS_TEXT"),
            "the <queries> element held this before anything was added to it; replacing it rather than adding " +
                "to it breaks text selection",
        )
    }

    @Test
    fun `queries names the shipped six one by one, beside the filter`() {
        // The filter covers an app while it has a launcher activity; these
        // entries cover these six whatever shape they are in, which is what
        // makes a NameNotFound for one of them mean "uninstalled" and nothing
        // else -- and what lets PERM-3's disclosure resolve their labels before
        // any of them has posted.
        val queries = queriesElement()
        val missing = ShippedApps.PACKAGES.filterNot { queries.contains("\"$it\"") }

        assertEquals(
            emptyList(),
            missing,
            "a shipped package is not declared by name in <queries> (INB-16, INB-20)",
        )
    }

    @Test
    fun `the release manifest asks for no permission at all`() {
        // CAP-20 and PERM-15: capture is a service declaration, not a requested
        // permission, and RUN-2's ALLOWED is empty. QUERY_ALL_PACKAGES is named
        // separately because it is the one this area could plausibly reach for.
        // Comments stripped first, and that is not tidiness: the <queries>
        // element's own comment explains at length that QUERY_ALL_PACKAGES is
        // absent and that no <uses-permission> belongs in this file, so a test
        // reading the raw text would fail on the words that say the right thing.
        val manifest = withoutComments(manifestText())

        assertFalse(
            manifest.contains("QUERY_ALL_PACKAGES"),
            "the app never enumerates installed packages (INB-20). <queries> declares what it can see and the " +
                "gate in SourceAppInfo.mayAsk declares what it asks; this permission would make both moot.",
        )
        assertFalse(
            manifest.contains("<uses-permission"),
            "src/main declares a permission. RUN-2's gate reads the built APK's permission list against an " +
                "empty ALLOWED, so this fails the release build -- and the privacy policy says the release " +
                "build requests none (CAP-20, PERM-15).",
        )
    }

    @Test
    fun `only the three known files reach the package manager, anywhere in the app's Kotlin`() {
        // The gate is a property of two entry points, not of the process. A new
        // file holding a PackageManager could ask it anything Android will
        // answer, and nothing would notice -- so a new one has to be a decision
        // somebody made rather than a line somebody added.
        //
        // Scoped to the whole `com.oasisforge.replybox` tree, not to `capture/`.
        // The message below says "nowhere else", and MainActivity.kt sits one
        // directory up: a `getApplicationInfo` or a `getLaunchIntentForPackage`
        // written there would bypass mayAsk entirely with every gate green, and
        // `test/package_visibility_test.dart`'s enumeration scan cannot catch it
        // either -- those two calls are the legitimate per-package asks INB-16
        // and INB-13 are built on, so they could never be on its banned list.
        //
        // Matched case-insensitively, so the type, the `context.packageManager`
        // property and a `getPackageManager()` call all count as holding one.
        // Comments stripped first, for the same reason the manifest's are: three
        // of these files explain at length what a PackageManager may and may not
        // be asked, and a test reading raw text would be answered by the prose.
        //
        // ReplyboxListenerService is on this list on purpose: it resolves a label
        // for a package at the moment that package posts, which is the same rule
        // reached from the other side (INB-20's `apps` row).
        val root = File(androidAppDir(), "src/main/kotlin/com/oasisforge/replybox")
        val sources = root.walkTopDown().filter { it.isFile && it.name.endsWith(".kt") }.toList()
        val paths = sources.associateWith { it.relativeTo(root).invariantSeparatorsPath }

        assertTrue(
            paths.values.any { !it.startsWith("capture/") },
            "this scan found no Kotlin outside capture/, so it is the narrow scan again and MainActivity.kt " +
                "-- the one file that is not in the capture package and does hold a Context -- is unwatched " +
                "(INB-20).",
        )

        val reaching = sources
            .filter { withoutKotlinComments(it.readText()).contains("packagemanager", ignoreCase = true) }
            .map { paths.getValue(it) }
            .sorted()

        assertEquals(
            listOf("capture/AppLaunch.kt", "capture/ReplyboxListenerService.kt", "capture/SourceAppInfo.kt"),
            reaching,
            "a file in the app now talks to the package manager. Every route to it has to go " +
                "through SourceAppInfo.mayAsk -- Replybox only ever asks about a package that has already " +
                "sent the user a notification, and that promise is held here and nowhere else now that " +
                "<queries> makes every launchable app visible.",
        )
    }

    private companion object {

        fun manifestText(): String =
            File(androidAppDir(), "src/main/AndroidManifest.xml").readText().replace("\r\n", "\n")

        /** XML comments removed, so prose about an element never answers for it. */
        fun withoutComments(xml: String): String = Regex("<!--.*?-->", RegexOption.DOT_MATCHES_ALL).replace(xml, "")

        /** The same, for Kotlin: a sentence about a `PackageManager` is not one. */
        fun withoutKotlinComments(source: String): String =
            Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL).replace(source, "")
                .replace(Regex("//[^\n]*"), "")

        /**
         * The `<queries>` element's own text, with its comments gone, so a
         * package name or an action sitting somewhere else in the manifest --
         * or merely written about in a note -- cannot answer for the
         * declaration.
         */
        fun queriesElement(): String {
            val manifest = withoutComments(manifestText())
            val open = manifest.indexOf("<queries>")
            val close = manifest.indexOf("</queries>")
            assertTrue(open >= 0 && close > open, "no <queries> element in the source manifest")
            return manifest.substring(open, close)
        }
    }
}
