package com.oasisforge.replybox.capture

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * PERM-14's one fact about the phone and its two settings pages, and PERM-15 over
 * both: **nothing in this area adds a permission.**
 *
 * The manufacturer read is executed, because the decision in it is a pure string
 * decision and it is a real one -- the platform has its own placeholder for a
 * property nobody set, and passing that through would put a made-up-looking name on
 * PERM-14's page. The two pages are read from source: an `Intent` cannot be built on
 * this classpath, so what is held instead is which action each one names, that
 * neither is the variant that needs a permission, and that the app-info page can
 * only ever be this app's own.
 */
class SettingsRoutesTest {

    @Test
    fun `the manufacturer is passed through exactly as the device reported it`() {
        // PERM-14 prints this so that an unlisted phone is *visibly* unlisted. A
        // value this function tidied -- lower-cased for the table, title-cased for
        // looks, matched against a list of real names -- would be the app telling
        // someone something about their hardware that the hardware did not say.
        // The lower-casing PERM-14 asks for belongs to the table lookup, which
        // takes a copy (lib/data/battery_guidance.dart), and never to this string.
        assertEquals("Xiaomi", CaptureChannel.reportedManufacturer("Xiaomi"))
        assertEquals("HMD Global", CaptureChannel.reportedManufacturer("HMD Global"))
        assertEquals("samsung", CaptureChannel.reportedManufacturer("samsung"))
    }

    @Test
    fun `surrounding whitespace is trimmed and nothing inside the name is touched`() {
        assertEquals("OnePlus", CaptureChannel.reportedManufacturer("  OnePlus\n"))
        assertEquals(
            "Sony  Mobile",
            CaptureChannel.reportedManufacturer(" Sony  Mobile "),
            "a double space inside a name is what the device reported; only the edges are the channel's to tidy",
        )
    }

    @Test
    fun `nothing to read is the empty string, which the Dart side reads as no answer`() {
        // Empty rather than a channel null: `_invoke` already answers null off
        // Android and on MissingPluginException, so a null here would be
        // indistinguishable from "no host answered". Both end as null in Dart and
        // both draw PERM-14's second branch, but only one of them is a value this
        // method chose.
        assertEquals("", CaptureChannel.reportedManufacturer(null))
        assertEquals("", CaptureChannel.reportedManufacturer(""))
        assertEquals("", CaptureChannel.reportedManufacturer("   "))
    }

    @Test
    fun `the platform's own placeholder is answered as nothing, not printed as a name`() {
        // `Build.MANUFACTURER` is not nullable on a device: where
        // `ro.product.manufacturer` was never set the framework hands back the
        // literal "unknown" (Build.UNKNOWN). Passed through, PERM-14's page would
        // read *This phone reports its manufacturer as unknown* -- a placeholder
        // printed as a make, which is the one thing that line exists not to do.
        //
        // It is not hypothetical either: it is what an emulator commonly reports,
        // and an emulator is the only hardware this app has been driven on (spike,
        // 21 September 2026). The honest answer is PERM-14's other branch, *This
        // phone did not report a manufacturer*, which is exactly what happened.
        assertEquals("", CaptureChannel.reportedManufacturer("unknown"))
        assertEquals("", CaptureChannel.reportedManufacturer("Unknown"))
        assertEquals("", CaptureChannel.reportedManufacturer("  UNKNOWN  "))
    }

    @Test
    fun `a real make is not silenced because the placeholder is a word in it`() {
        // Matched against the whole trimmed value and nothing looser -- no
        // contains, no prefix. The table lookup is an exact match for the same
        // reason (decision 11): a near-match is a phone nobody has tested.
        assertEquals("Unknown Devices Ltd", CaptureChannel.reportedManufacturer("Unknown Devices Ltd"))
        assertEquals("unknownable", CaptureChannel.reportedManufacturer("unknownable"))
    }

    @Test
    fun `the manufacturer is the only thing this build asks about the handset`() {
        val offenders = mutableListOf<String>()
        for (source in shippedKotlin()) {
            val text = withoutComments(source.readText())
            for (token in FORBIDDEN_DEVICE_READS) {
                if (text.contains(token)) offenders.add("${source.name}: $token")
            }
        }

        assertEquals(
            emptyList(),
            offenders,
            "PERM-14 asks for a manufacturer and PERM-15 adds no permission, so nothing else about the " +
                "handset is read. A model, a fingerprint, a serial or an Android ID beside it would turn one " +
                "fact about a make into something that identifies a phone -- inside an app whose first " +
                "principle is that nothing leaves it (product principle 1, INB-24).",
        )
    }

    @Test
    fun `both pages are the unguarded actions, and the one that needs a permission is nowhere`() {
        val channel = withoutComments(channelText())

        assertTrue(
            channel.contains("Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS"),
            "PERM-14's first page is the battery-optimisation *list*, which is unguarded",
        )
        assertTrue(
            channel.contains("Settings.ACTION_APPLICATION_DETAILS_SETTINGS"),
            "PERM-14's second page is this app's own app-info screen, which is unguarded for one's own package",
        )

        val offenders = shippedFiles()
            .filter { withoutComments(it.readText()).contains(REQUEST_EXEMPTION) }
            .map { it.name }

        assertEquals(
            emptyList(),
            offenders,
            "PERM-15 names REQUEST_IGNORE_BATTERY_OPTIMIZATIONS as never declared, and the action that asks " +
                "for the exemption directly is what needs it. PERM-14 opens a page to look at instead of a " +
                "switch to flip, and says plainly that the app cannot change any of those settings for " +
                "itself -- so neither the permission nor the action it goes with exists in this build.",
        )
    }

    @Test
    fun `the app-info page can only ever be this app's own`() {
        val branch = bodyOf(withoutComments(channelText()), """"openAppInfoSettings" ->""")

        assertTrue(
            branch.contains("""Uri.fromParts("package", context.packageName, null)"""),
            "the package is this process's own and is taken from the Context, never from the call. A method " +
                "that took a package name would be a way to open a settings page about somebody else's app " +
                "-- a question about the phone, asked outside the one gate every such question goes through " +
                "(SourceAppInfo.mayAsk, INB-20).",
        )
        assertFalse(
            branch.contains("call."),
            "this method takes no argument, and must not grow one. Found: $branch",
        )
    }

    @Test
    fun `a page that does not open is a false and never a throw`() {
        val channel = withoutComments(channelText())

        for (branch in listOf(""""openBatteryOptimisationSettings" ->""", """"openAppInfoSettings" ->""")) {
            val body = bodyOf(channel, branch)
            assertTrue(
                body.contains("start("),
                "PERM-14's pages answer through the same `start()` PERM-7 uses, which catches " +
                    "ActivityNotFoundException and SecurityException. A page this phone does not have is " +
                    "then a false the screen replaces with the written path, rather than a button that does " +
                    "nothing or an error a screen has to decode. Found: $body",
            )
        }
    }

    @Test
    fun `no source set that ships declares a permission`() {
        // PERM-15, as `tool/check_permissions.sh` will read it off the built
        // artifact with an empty ALLOWED. This is the same claim one commit
        // earlier: src/main is the only source set a release build merges, and
        // nothing this area added -- Build.MANUFACTURER, the two settings intents,
        // requestRebind -- needs a permission of any kind.
        val manifest = withoutXmlComments(
            File(androidAppDir(), "src/main/AndroidManifest.xml").readText(),
        )

        assertFalse(
            manifest.contains("<uses-permission"),
            "the release manifest declares a permission. RUN-2's gate reads the built artifact's permission " +
                "list against an empty ALLOWED and fails in both directions, and the privacy policy says the " +
                "release build requests none (PERM-15, CAP-20).",
        )
    }

    private companion object {

        /** The action and the permission that go together, and neither may exist here. */
        const val REQUEST_EXEMPTION = "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"

        /**
         * Everything about the handset that is not its make.
         *
         * `Build.VERSION.SDK_INT` and `Build.VERSION.RELEASE` are deliberately not
         * on this list: CAP-25 records them with every fixture because a capture is
         * only comparable against another one taken at the same API level, and an
         * OS version describes the platform rather than the phone.
         */
        val FORBIDDEN_DEVICE_READS = listOf(
            "Build.MODEL",
            "Build.BRAND",
            "Build.DEVICE",
            "Build.PRODUCT",
            "Build.HARDWARE",
            "Build.FINGERPRINT",
            "Build.SERIAL",
            "Build.BOARD",
            "getSerial",
            "ANDROID_ID",
            "getImei",
            "getSubscriberId",
        )

        fun channelText(): String =
            File(captureDir(), "CaptureChannel.kt").readText().replace("\r\n", "\n")

        fun captureDir(): File = File(androidAppDir(), "src/main/kotlin/com/oasisforge/replybox/capture")

        /** Every Kotlin source a release variant compiles, not just the capture package. */
        fun shippedKotlin(): List<File> =
            File(androidAppDir(), "src/main/kotlin").walkTopDown()
                .filter { it.isFile && it.name.endsWith(".kt") }
                .toList()
                .sorted()

        /** The same, plus the manifest: everything a release variant ships from src/main. */
        fun shippedFiles(): List<File> =
            shippedKotlin() + File(androidAppDir(), "src/main/AndroidManifest.xml")

        fun withoutComments(source: String): String =
            Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL).replace(source, "")
                .replace(Regex("//[^\n]*"), "")

        fun withoutXmlComments(xml: String): String =
            Regex("<!--.*?-->", RegexOption.DOT_MATCHES_ALL).replace(xml, "")

        /**
         * One `when` branch's text: from its arrow to the blank line that ends it.
         *
         * Enough to ask what a branch does without the next branch answering for
         * it, which is the whole risk in a file where five of them now sit in a row.
         */
        fun bodyOf(source: String, signature: String): String {
            val start = source.indexOf(signature)
            if (start < 0) return ""
            val rest = source.substring(start + signature.length)
            val end = rest.indexOf("\n\n")
            return if (end < 0) rest else rest.substring(0, end)
        }
    }
}
