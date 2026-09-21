package com.oasisforge.replybox.capture

import java.io.File
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * CAP-1's native filter: which packages capture is on for, before any Dart exists.
 *
 * The failure these guard is the one the product cannot survive -- capturing from an
 * app the user explicitly said no to, with nothing on screen saying so (product
 * principle 4). Everything here is about that: the one-shot default fires once and
 * never again, and a store that cannot be read captures nothing at all rather than
 * guessing.
 */
class CaptureStoreTest {

    private lateinit var dir: File
    private lateinit var file: File

    @BeforeTest
    fun setUp() {
        dir = newTempDir("replybox-store")
        file = File(dir, "capture-store.json")
        // CaptureFaults is a process-wide object with no reset and these tests share a
        // JVM, so each starts from a known value: an unreadable store left by another
        // test must not read as this one's fault (CAP-12).
        CaptureFaults.setStoreUnreadable(false)
    }

    @AfterTest
    fun tearDown() {
        CaptureFaults.setStoreUnreadable(false)
        dir.deleteRecursively()
    }

    @Test
    fun `a shipped app defaults on at its first sighting and an unknown app does not`() {
        val store = storeOn(file)

        // Decision 9, CAP-1: the six shipped apps are on the first time this install
        // sees them post, and INB-20 requires the apps row before the answer.
        assertTrue(store.recordSeen("com.whatsapp", "WhatsApp", T))
        val whatsapp = store.takeSeenApps().single { it.packageName == "com.whatsapp" }
        assertEquals("WhatsApp", whatsapp.label)
        assertEquals(T, whatsapp.lastSeenAt)
        assertTrue(whatsapp.enabledByDefault)

        // Every other app is off until the user turns it on, and it still gets its
        // row -- that row is the only thing kept about an app we do not capture from.
        assertFalse(store.recordSeen("com.example.notes", "Notes", T))
        val notes = store.takeSeenApps().single { it.packageName == "com.example.notes" }
        assertEquals("Notes", notes.label)
        assertFalse(notes.enabledByDefault)
    }

    @Test
    fun `a shipped app the user turned off is never defaulted back on by a later sighting`() {
        val store = storeOn(file)
        assertTrue(store.recordSeen("com.whatsapp", "WhatsApp", T))
        store.ackSeenApps(listOf("com.whatsapp"))
        assertTrue(store.takeSeenApps().isEmpty())

        // The switch moves off (INB-22). Dart holds a row for it and left it out of
        // the enabled list, which is the user's answer and nothing else.
        store.setEnabledPackages(emptyList(), listOf("com.whatsapp"))
        assertFalse(store.isEnabled("com.whatsapp"))

        // The next notification from it is dropped, and the row it queues must not
        // carry the default a second time -- an enabledByDefault row arriving in the
        // chooser would switch back on an app the user said no to.
        assertFalse(store.recordSeen("com.whatsapp", "WhatsApp", T + 1))
        assertFalse(store.takeSeenApps().single().enabledByDefault)

        // And it stays off across a restart: the answer is on disk, not in this
        // instance. everSeen is what makes the default one-shot.
        assertFalse(storeOn(file).recordSeen("com.whatsapp", "WhatsApp", T + 2))
    }

    @Test
    fun `an unreadable store captures nothing, reports the fault, and is not overwritten`() {
        val armed = storeOn(file)
        assertTrue(armed.recordSeen("com.whatsapp", "WhatsApp", T))
        armed.ackSeenApps(listOf("com.whatsapp"))
        assertTrue(file.readText().contains("com.whatsapp"))

        // A half-written file: the realistic corruption, and the one that would be
        // read as "nothing is enabled" by a store that failed open.
        val corrupt = """{"enabled":["com.whatsapp","com.face"""
        file.writeText(corrupt)

        // load() runs once per instance, so a new instance is the reload.
        val reloaded = storeOn(file)

        // CAP-1 fails closed: not "nothing is enabled" but "the contents are unknown",
        // so capture stops for every package, shipped or not, rather than re-enabling
        // one the user had switched off (product principle 4).
        assertFalse(reloaded.recordSeen("com.whatsapp", "WhatsApp", T + 1))
        assertFalse(reloaded.recordSeen("com.google.android.apps.messaging", "Messages", T + 1))
        assertFalse(reloaded.recordSeen("com.example.notes", "Notes", T + 1))
        assertFalse(reloaded.isEnabled("com.whatsapp"))

        // CAP-12, RUN-1: an absence the app cannot explain reads as a bug, so the
        // fact has to be reachable by a screen and not only logged.
        assertEquals(true, CaptureFaults.snapshot()["storeUnreadable"])

        // And the file we could not understand is not ours to replace: writing this
        // process's empty set over it would make the unknown state permanent.
        assertEquals(corrupt, file.readText())
        assertFalse(File(dir, "capture-store.json.tmp").exists())
    }

    @Test
    fun `a repaired store comes back on but never defaults a shipped app on again`() {
        file.writeText("""{"enabled":["com.whatsapp""")
        val store = storeOn(file)
        assertFalse(store.recordSeen("com.whatsapp", "WhatsApp", T))
        assertEquals(true, CaptureFaults.snapshot()["storeUnreadable"])

        // INB-22 makes the database the single authority on what is on, so this call
        // -- and only this call -- repairs the store.
        store.setEnabledPackages(listOf("com.whatsapp"), listOf("com.whatsapp"))
        assertTrue(store.isEnabled("com.whatsapp"))
        assertEquals(false, CaptureFaults.snapshot()["storeUnreadable"])

        // everSeen is not recoverable that way, so the one-shot default stays
        // disarmed for good: a shipped app seen for the "first" time after a repair
        // may be one the user switched off before the corruption. The chooser becomes
        // the only way an app goes on, which is a stated limit rather than a grant
        // nobody gave (CAP-1, PERM-5, INB-21).
        assertFalse(store.recordSeen("org.telegram.messenger", "Telegram", T + 1))
        assertFalse(store.takeSeenApps().single { it.packageName == "org.telegram.messenger" }.enabledByDefault)
        assertFalse(storeOn(file).isEnabled("org.telegram.messenger"))
    }

    @Test
    fun `takeSeenApps does not clear, and ackSeenApps releases exactly what it is given`() {
        val store = storeOn(file)
        store.recordSeen("com.whatsapp", "WhatsApp", T)
        store.recordSeen("com.example.notes", "Notes", T + 1)

        // Taking hands the rows over without clearing, and can hand them over twice:
        // a process killed between the answer and Dart's write would otherwise lose a
        // shipped app's one-shot default for good, and the app would be silently
        // uncaptured with nothing on screen (CAP-1, decision 9, PERM-3).
        assertEquals(listOf("com.whatsapp", "com.example.notes"), store.takeSeenApps().map { it.packageName })
        assertEquals(listOf("com.whatsapp", "com.example.notes"), store.takeSeenApps().map { it.packageName })

        store.ackSeenApps(listOf("com.whatsapp"))

        val left = store.takeSeenApps().single()
        assertEquals("com.example.notes", left.packageName)
        assertEquals("Notes", left.label)
        assertEquals(T + 1, left.lastSeenAt)
        assertFalse(left.enabledByDefault)
        // Acking a package that is not pending changes nothing.
        store.ackSeenApps(listOf("com.example.unknown"))
        assertEquals(listOf("com.example.notes"), storeOn(file).takeSeenApps().map { it.packageName })
    }

    @Test
    fun `a package the user turned off is not resurrected by the pending set`() {
        val store = storeOn(file)
        assertTrue(store.recordSeen("com.whatsapp", "WhatsApp", T))
        store.ackSeenApps(listOf("com.whatsapp"))
        store.setEnabledPackages(emptyList(), listOf("com.whatsapp"))
        assertFalse(store.isEnabled("com.whatsapp"))

        // It posts again while off, so it is pending again -- un-acked, and off.
        assertFalse(store.recordSeen("com.whatsapp", "WhatsApp", T + 1))
        assertTrue(store.takeSeenApps().any { it.packageName == "com.whatsapp" })

        // The next sync carries the user's list, which still does not name it. An
        // un-acked row must not put it back: that would switch on an app the user
        // turned off the moment it posted anything (INB-22, product principle 4).
        store.setEnabledPackages(listOf("com.instagram.android"), listOf("com.whatsapp", "com.instagram.android"))

        assertFalse(store.isEnabled("com.whatsapp"))
        assertFalse(store.recordSeen("com.whatsapp", "WhatsApp", T + 2))
        assertFalse(storeOn(file).isEnabled("com.whatsapp"))
    }

    @Test
    fun `a switch moving off takes effect at once, even while that package's row is un-acked`() {
        val store = storeOn(file)
        assertTrue(store.recordSeen("com.whatsapp", "WhatsApp", T))
        store.ackSeenApps(listOf("com.whatsapp"))

        // It posts again while Dart is not running -- the normal case, and the whole
        // reason the queue exists -- so its row is pending and un-acked at the moment
        // the user moves the switch. Being un-acked must not buy it a reprieve: Dart
        // holds a row for it, so its absence from the enabled list is the user's
        // answer, and INB-22 makes a switch take effect from the moment it moves.
        assertTrue(store.recordSeen("com.whatsapp", "WhatsApp", T + 1))
        assertTrue(store.takeSeenApps().any { it.packageName == "com.whatsapp" })

        store.setEnabledPackages(emptyList(), listOf("com.whatsapp"))

        // CAP-1 puts the drop before anything reaches the native queue, so the very
        // next notification from it is never projected at all.
        assertFalse(store.isEnabled("com.whatsapp"))
        assertFalse(store.recordSeen("com.whatsapp", "WhatsApp", T + 2))
        assertFalse(storeOn(file).isEnabled("com.whatsapp"))
    }

    @Test
    fun `a shipped app enabled seconds ago survives a sync that has not been handed its row`() {
        val store = storeOn(file)
        assertTrue(store.recordSeen("com.whatsapp", "WhatsApp", T))

        // Dart has never been handed this package -- it is in neither list -- so its
        // absence says nothing about what the user wants, and a plain replace would
        // drop every notification it posts until the next sync pass (CAP-1,
        // decision 9).
        store.setEnabledPackages(listOf("com.instagram.android"), listOf("com.instagram.android"))

        assertTrue(store.isEnabled("com.whatsapp"))
        assertTrue(store.recordSeen("com.whatsapp", "WhatsApp", T + 1))
        assertTrue(store.isEnabled("com.instagram.android"))
    }
}
