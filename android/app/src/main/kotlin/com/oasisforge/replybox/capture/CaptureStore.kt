package com.oasisforge.replybox.capture

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * The little state CAP-1 needs before Dart exists: which packages are included,
 * which ones this install has ever seen post, and the `apps` rows waiting to be
 * handed over (INB-20).
 *
 * It has to be native and it has to be on disk. The first notification after a
 * grant can arrive while the Flutter app has never run, and CAP-1 says the drop is
 * native-side -- so the filter cannot wait to be told what to filter.
 *
 * Stored as one JSON file in `context.filesDir` rather than in SharedPreferences,
 * so it sits in the same `domain="file"` that data_extraction_rules.xml already
 * excludes (CAP-24). SharedPreferences lands in `domain="sharedpref"`, which is not
 * excluded, and this file names every app that has notified the phone.
 *
 * Every method does disk I/O inside its lock. The listener never calls one from a
 * notification callback -- it hands the whole of capture to one background thread
 * (ReplyboxListenerService) -- and the MethodChannel's calls are a rewrite of one
 * small file, at most once per sync pass.
 */
class CaptureStore private constructor(private val file: File) {

    /** One row of INB-20's `apps` table, on its way to Dart. */
    data class SeenApp(
        val packageName: String,
        val label: String,
        val lastSeenAt: Long,
        val enabledByDefault: Boolean,
    )

    private val lock = Any()
    private var loadAttempted = false

    /**
     * Whether the file on disk was understood. False means fail closed: nothing is
     * enabled, no shipped default is applied, and [persist] refuses to write --
     * see [load].
     */
    private var readable = false

    /**
     * Whether [everSeen] is the whole truth for this install. Decision 9's default
     * fires on a *first* sighting, so an `everSeen` that lost entries would switch
     * a shipped app back on after the user turned it off (product principle 4).
     * An install whose store was once unreadable therefore stops defaulting
     * anything on, for good: the chooser is then the only way an app goes on,
     * which is a stated limit rather than a grant nobody gave (PERM-5, INB-21).
     */
    private var everSeenComplete = true

    private val enabled = linkedSetOf<String>()
    private val everSeen = linkedSetOf<String>()
    private val pending = linkedMapOf<String, SeenApp>()

    /**
     * Records that [packageName] posted, and answers whether the app captures from
     * it (CAP-1). One call, because INB-20 requires the `apps` row to be upserted
     * *before* the drop, and splitting it into "record" and "ask" invites a caller
     * that only ever asks.
     *
     * Returns true only if capture is on for this package.
     */
    fun recordSeen(packageName: String, label: String, now: Long): Boolean = synchronized(lock) {
        load()
        val firstSighting = everSeen.add(packageName)
        // Decision 9: a shipped app switches itself on the first time this install
        // sees it post, and never afterwards. A package added to the shipped list by
        // a later update stays off for an install that already exists -- that user's
        // bargain was struck at their first run (PERM-5).
        val defaulted =
            readable && everSeenComplete && firstSighting && ShippedApps.PACKAGES.contains(packageName)
        if (defaulted) enabled.add(packageName)
        pending[packageName] = SeenApp(
            packageName = packageName,
            label = label,
            lastSeenAt = now,
            // A second sighting before Dart drains must not erase the first one's
            // default, or the app would be captured natively and arrive in the
            // chooser switched off. The row also stays here until Dart acks it
            // (CAP-1, see takeSeenApps), so a re-sighting overwrites rather than
            // adds.
            enabledByDefault = defaulted || pending[packageName]?.enabledByDefault == true,
        )
        persist()
        // With the store unreadable `enabled` is empty and stays empty, so this
        // answers false for everything: capture stops rather than guessing which
        // apps the user had switched on (product principle 4).
        enabled.contains(packageName)
    }

    /** Whether capture is on for a package, without recording a sighting. */
    fun isEnabled(packageName: String): Boolean = synchronized(lock) {
        load()
        enabled.contains(packageName)
    }

    /**
     * The `apps` rows seen and not yet acknowledged, oldest first.
     *
     * It does **not** clear. Clearing here would destroy the row before Dart had
     * written anything: a process killed between this answer and that write would
     * lose a shipped app's one-shot default for good (`everSeen` never fires
     * twice), the next [setEnabledPackages] would drop the package from the native
     * filter, and the app would be silently uncaptured with nothing on screen
     * (CAP-1, decision 9, PERM-3). [ackSeenApps] is the second phase, exactly as
     * CaptureQueue splits drain from ack for the same reason.
     *
     * The cost is that a row can be handed over twice; INB-20's upsert is by
     * package and `enabledIfNew` only ever fires for a row the database does not
     * have, so the repeat changes nothing.
     */
    fun takeSeenApps(): List<SeenApp> = synchronized(lock) {
        load()
        pending.values.toList()
    }

    /**
     * Releases exactly these packages, once Dart has written their `apps` rows.
     * A package seen again between the hand-over and this call keeps its newer row
     * -- it is the same package, so the row is overwritten and released here, and
     * the next sighting queues a fresh one.
     */
    fun ackSeenApps(packages: Collection<String>) = synchronized(lock) {
        if (packages.isEmpty()) return@synchronized
        load()
        var removed = false
        for (packageName in packages) {
            if (pending.remove(packageName) != null) removed = true
        }
        if (removed) persist()
    }

    /**
     * Replaces the included-apps set with what the user's rows say (CAP-1, INB-22).
     *
     * Two lists, because "absent from [packages]" had two meanings and they were
     * being treated as one. [packages] is every package Dart's rows say is on;
     * [known] is every package Dart holds an `apps` row for at all, on or off. So:
     *
     *  * In [known] and not in [packages] -- the user's row says off. It goes off
     *    here, at once, with no exception. INB-22 makes a switch take effect from
     *    the moment it moves, and CAP-1 puts the drop before anything reaches the
     *    native queue, so the next notification from it is never projected at all.
     *  * In neither -- Dart has never been handed this package, so its absence says
     *    nothing about what the user wants. Its native state is kept as it is,
     *    which is what stops a shipped app this listener enabled seconds ago from
     *    being switched off by a set that was computed before it existed (CAP-1,
     *    decision 9).
     *
     * Kept, not forced on: only a package that is *already* enabled here survives
     * the replace. Unioning in every unknown package would switch on an app the
     * user had turned off, the moment it posted anything (INB-22, product principle
     * 4), which is a worse failure than the one this avoids.
     *
     * [pending] alone used to be that test, and it was the wrong question. An entry
     * lands there on *every* sighting, not only the first, so an enabled app that
     * posted while Dart was not running -- the normal case, and the reason the queue
     * exists -- was un-acked at the moment the user switched it off, and the union
     * put it straight back: its sender, title and full text kept reaching the queue
     * until a later pass, which is exactly what CAP-1 forbids. Worse, a package
     * whose `apps` row keeps failing to write is never acked, so it could never be
     * switched off at all. [pending] only ever meant "Dart may not have heard of
     * this yet"; [known] answers that question directly, and Dart's row is the
     * authority on everything else (INB-22).
     */
    fun setEnabledPackages(packages: Collection<String>, known: Collection<String>) = synchronized(lock) {
        load()
        val knownToDart = known.toSet()
        // Both conditions, and narrowly: un-acked *and* unheard-of. A package Dart
        // has a row for is answered by [packages], full stop, and one Dart acked and
        // then left out is Dart's answer too.
        val unheardOf = enabled.filter { pending.containsKey(it) && !knownToDart.contains(it) }
        enabled.clear()
        enabled.addAll(packages)
        enabled.addAll(unheardOf)
        // A store that could not be read is repaired here and only here: this call
        // carries the database's own answer, which INB-22 makes the single
        // authority on what is on. `everSeen` is not recoverable that way, so the
        // repair also disarms the shipped-app default for good (see the field).
        if (!readable) {
            readable = true
            everSeenComplete = false
            CaptureFaults.setStoreUnreadable(false)
        }
        persist()
    }

    /**
     * Reads the file once per process, and fails **closed**.
     *
     * A store that cannot be read is not a store that says "nothing is enabled":
     * it is a store whose contents are unknown. Treating it as empty and carrying
     * on would re-enable every shipped app on its next sighting -- including one
     * the user had explicitly switched off, which is capture from an app they said
     * no to (CAP-1, INB-22, product principle 4). So nothing is enabled, no
     * default is applied, and [persist] refuses to overwrite the file we could not
     * understand; the fact is reported through CaptureFaults so a screen can state
     * it (CAP-12, RUN-1), and the next [setEnabledPackages] from Dart repairs it.
     */
    private fun load() {
        if (loadAttempted) return
        loadAttempted = true
        try {
            if (!file.exists()) {
                // Never written is not the same as unreadable: a fresh install
                // starts readable, with decision 9's defaults armed.
                readable = true
                return
            }
            val root = JSONObject(file.readText())
            root.optJSONArray(KEY_ENABLED)?.let { enabled.addAll(it.strings()) }
            root.optJSONArray(KEY_EVER_SEEN)?.let { everSeen.addAll(it.strings()) }
            root.optJSONArray(KEY_PENDING)?.let { array ->
                for (i in 0 until array.length()) {
                    val o = array.optJSONObject(i) ?: continue
                    val pkg = o.optString("package").takeIf { it.isNotEmpty() } ?: continue
                    pending[pkg] = SeenApp(
                        packageName = pkg,
                        label = o.optString("label", pkg),
                        lastSeenAt = o.optLong("lastSeenAt"),
                        enabledByDefault = o.optBoolean("enabledByDefault", false),
                    )
                }
            }
            everSeenComplete = root.optBoolean(KEY_EVER_SEEN_COMPLETE, true)
            readable = true
        } catch (e: Exception) {
            enabled.clear()
            everSeen.clear()
            pending.clear()
            everSeenComplete = false
            readable = false
            CaptureFaults.setStoreUnreadable(true)
            // Never the contents, and never the throwable either: this file names
            // every app that has notified the phone, and Android's JSONException
            // carries the whole string it failed to parse in its own message
            // (INB-24, and see CaptureLog). Passing `e` to Log here is what wrote
            // that list to logcat.
            CaptureLog.failure("could not read the capture store; capture is off until it is repaired", e)
        }
    }

    private fun persist() {
        // The file was not understood, so it is not ours to replace: writing this
        // process's empty set over it would make the unknown state permanent.
        if (!readable) return
        try {
            val root = JSONObject()
                .put(KEY_ENABLED, JSONArray(enabled.toList()))
                .put(KEY_EVER_SEEN, JSONArray(everSeen.toList()))
                .put(KEY_EVER_SEEN_COMPLETE, everSeenComplete)
                .put(
                    KEY_PENDING,
                    JSONArray().apply {
                        pending.values.forEach {
                            put(
                                JSONObject()
                                    .put("package", it.packageName)
                                    .put("label", it.label)
                                    .put("lastSeenAt", it.lastSeenAt)
                                    .put("enabledByDefault", it.enabledByDefault),
                            )
                        }
                    },
                )
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(root.toString())
            if (!tmp.renameTo(file)) {
                file.writeText(root.toString())
                tmp.delete()
            }
        } catch (e: Exception) {
            CaptureFaults.storeWriteFailed(System.currentTimeMillis())
            // The class only: what was being written is the package list (INB-24).
            CaptureLog.failure("could not write the capture store", e)
        }
    }

    private fun JSONArray.strings(): List<String> =
        (0 until length()).mapNotNull { optString(it).takeIf { s -> s.isNotEmpty() } }

    companion object {
        private const val FILE_NAME = "capture-store.json"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_EVER_SEEN = "everSeen"
        private const val KEY_EVER_SEEN_COMPLETE = "everSeenComplete"
        private const val KEY_PENDING = "pending"

        @Volatile
        private var instance: CaptureStore? = null

        /** One store per process; keeps the File, never the Context. */
        fun of(context: Context): CaptureStore =
            instance ?: synchronized(this) {
                instance ?: CaptureStore(File(context.applicationContext.filesDir, FILE_NAME)).also { instance = it }
            }
    }
}
