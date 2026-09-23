package com.oasisforge.replybox.capture

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import java.io.ByteArrayOutputStream

/**
 * One source app's label and icon, and whether this build can see the app at all
 * (INB-1, INB-16).
 *
 * ## Why the answer is three-valued and never a boolean
 *
 * `PackageManager.getApplicationInfo` throws `NameNotFoundException` for two
 * different facts: there is no such package on this phone, and there is one but
 * package visibility hides it from this app. Collapsed into a boolean the two
 * become one sentence -- "that app is gone" -- and the app would say it about an
 * app the user still has installed. INB-16 forbids exactly that: *the app never
 * tells the user an app is uninstalled unless it can see that it is.*
 *
 * So there are three answers. [PRESENCE_UNKNOWN] is a value a caller has to
 * handle rather than a `false` it can mistake for evidence, and every path that
 * learned nothing lands on it.
 *
 * ## What the manifest declares now, and what that changed here
 *
 * The `<queries>` element used to be the six shipped packages and nothing else,
 * so this file gated every lookup on [ShippedApps.PACKAGES]: outside that set a
 * `NameNotFoundException` could not be told from package visibility, so there was
 * no answer worth the call. The cost was INB-13's control. Every app that reached
 * the inbox by posting a notification (INB-20's second source) was outside the
 * declaration, `getLaunchIntentForPackage` answered null for all of them, and
 * `Open <app>` was a control that failed every time, forever.
 *
 * On 22 September 2026 the developer took that trade with the cost in front of
 * them: `<queries>` now also carries a MAIN + LAUNCHER intent filter, so **every
 * launchable app on the phone is visible to this process**. Still no
 * `QUERY_ALL_PACKAGES` and still no `<uses-permission>` -- tool/check_queries.sh
 * and RUN-2's gate both fail on either.
 *
 * ## Visibility is what Android grants; asking is what this app chooses
 *
 * The promise the user was given is the second half, and it is the half that has
 * to be held in code, because the manifest no longer holds it:
 *
 * > Replybox can see which apps are launchable, but only ever asks about a
 * > package that has already sent the user a notification. It never lists what is
 * > on the phone.
 *
 * [mayAsk] is that sentence, and [lookup] returns through it before `facts` is
 * touched. A package is askable when it is one of the six the manifest names by
 * hand and PERM-3's disclosure shows -- those are asked about before anything has
 * posted, which is how the chooser and the disclosure draw their rows (INB-21,
 * PERM-3) -- or when [PackageFacts.hasPosted] says this install has seen it post,
 * which is [CaptureStore]'s `everSeen`, written by the listener before CAP-1's
 * drop. Nothing else is asked, whatever a caller passes.
 *
 * [AppLaunch.openApp] applies the same [mayAsk] to the same record, so both of
 * the channel's routes to the package manager -- "what does this app look like"
 * and "can this app be started" -- are one rule in one place, and neither is a
 * yes/no oracle a caller can walk a package list through.
 *
 * What that does **not** promise, stated so nobody reads more into it than it
 * says: it is a gate on this method, not on the process. The listener itself
 * resolves a label for every package it sees post (`ReplyboxListenerService`),
 * which is the same rule reached from the other side, and any new code that holds
 * a `PackageManager` can ask it anything Android will answer. The gate is what
 * makes the API refuse rather than what makes the platform refuse, and
 * SourceAppInfoTest is what keeps a future caller from widening it by accident.
 *
 * ## What `gone` is allowed to mean, and the one case it can be wrong about
 *
 * For a package the gate admitted, a resolved lookup is [PRESENCE_INSTALLED] and
 * that is never in doubt. A `NameNotFoundException` is read as [PRESENCE_GONE],
 * and for the six named by `<package>` that is exact: they are visible whatever
 * shape they are in, so not-found is absence and nothing else.
 *
 * For any other package the residual was stated as one shape: **an app that is
 * still installed, has posted a notification, and has no launcher activity is
 * reported gone** -- outside the MAIN + LAUNCHER filter, therefore invisible,
 * therefore not-found. The drill of 23 September 2026 measured that and found the
 * premise is not general. `com.android.shell` has no launcher activity and
 * resolved anyway, with its real label and icon, so the app is not blind to a
 * non-launchable package the way the paragraph assumed; it was blind to the
 * *question*, and answered `installed` to a control that meant "can I open it".
 *
 * So the residual is now the narrower shape it always was, and it is a package
 * this process cannot see at all: an installed app with no launcher activity
 * **that the phone also withholds from `getApplicationInfo`** answers here exactly
 * as an uninstalled one does, and is reported gone. The rest of that case is no
 * longer a wrong sentence: a non-launchable package that resolves is
 * [PRESENCE_INSTALLED] with [KEY_LAUNCHABLE] false, its row keeps the app's real
 * name and icon, and the thread says there is no screen to open instead of
 * offering a control that fails on every tap (INB-13, INB-16).
 *
 * ## Nothing here is remembered, and nothing here is logged
 *
 * No cache on this side. The Dart service memoises each answer for the life of
 * the process (lib/services/android_package_service.dart), so a list that
 * rebuilds asks once per package and never crosses the channel again; holding
 * bitmaps here as well would be memory the system cannot reclaim, bought for a
 * saving Dart already has.
 *
 * INB-24: no package name, no label and no title reaches logcat from this file.
 * The one failure path reports through [CaptureLog], which writes a fixed string
 * and an exception's class name, never the exception itself.
 */
internal object SourceAppInfo {

    /**
     * The three answers, as the strings that cross the channel. The Dart side
     * parses exactly these and reads anything else as [PRESENCE_UNKNOWN].
     */
    const val PRESENCE_INSTALLED = "installed"
    const val PRESENCE_GONE = "gone"
    const val PRESENCE_UNKNOWN = "unknown"

    /** The keys of the answer map. */
    const val KEY_PRESENCE = "presence"
    const val KEY_LABEL = "label"
    const val KEY_ICON = "icon"

    /**
     * The second question, and the one the presence tri-state cannot answer
     * (INB-13's 23 September 2026 correction).
     *
     * True when the package manager resolved a launcher intent for this package,
     * false when it did not, and absent -- null -- beside any presence but
     * [PRESENCE_INSTALLED], where there is no app to start and nothing was asked.
     *
     * It travels separately from [KEY_PRESENCE] because it is a separate fact.
     * `com.android.shell` is installed, resolvable and has no launcher activity,
     * and on the drill of 23 September 2026 the thread drew `Open Shell` over it
     * and answered every tap with "Could not open that app." The control was asking
     * "does this package exist" while meaning "can I open it".
     */
    const val KEY_LAUNCHABLE = "launchable"

    /**
     * The square an icon is rasterised into, in pixels.
     *
     * Fixed rather than taken from the device's density, so one row's icon costs
     * the same bytes on every phone and the channel's traffic does not depend on
     * the screen. INB-1 badges this onto an initials circle and INB-23 holds that
     * circle to a 48dp tap target, so 96px is ample at any density this ships to
     * -- a few kB of PNG per package, and the set of packages that can ever be
     * asked about is bounded by [mayAsk].
     */
    const val ICON_PX = 96

    /**
     * Whether the app is willing to ask the phone about [packageName] at all.
     *
     * The whole of "only ever asks about a package that has already sent the user
     * a notification", plus the six the manifest names by hand and the disclosure
     * shows before any of them has posted (PERM-3, INB-21).
     *
     * Public and separate from [lookup] so the rule can be read, cited and
     * asserted as itself rather than inferred from the shape of an answer.
     */
    fun mayAsk(packageName: String, hasPosted: (String) -> Boolean): Boolean =
        packageName in ShippedApps.PACKAGES || hasPosted(packageName)

    /** The same rule, for the caller that already holds a [PackageFacts]. */
    fun mayAsk(packageName: String, facts: PackageFacts): Boolean =
        mayAsk(packageName, facts::hasPosted)

    /**
     * The whole rule, with the package manager behind [facts] so a JVM test runs
     * this and not a copy of it.
     *
     * Never throws: a caller that has to decide between a row with an icon and a
     * row without one has no use for an exception, and every way this can fail
     * lands on [PRESENCE_UNKNOWN] rather than on a guess.
     */
    fun lookup(packageName: String, facts: PackageFacts): Map<String, Any?> {
        return try {
            // The gate, before anything is asked of the phone. A test asserts
            // that a package which has never posted leaves `faceOf` uncalled,
            // because "the app did not ask" is the promise, and an answer thrown
            // away after the asking would not be it.
            if (!mayAsk(packageName, facts)) return answer(PRESENCE_UNKNOWN)
            val face = facts.faceOf(packageName) ?: return answer(PRESENCE_GONE)
            answer(PRESENCE_INSTALLED, face.label, face.icon, face.launchable)
        } catch (e: Exception) {
            // INB-16: a lookup that failed for any reason other than "no such
            // package" is not evidence of anything, least of all of an
            // uninstall. The app says less instead. The gate is inside this
            // `try` for the same reason: a store that could not answer whether
            // the package has posted is not permission to ask anyway.
            CaptureLog.failure("could not read a source app's package entry", e)
            answer(PRESENCE_UNKNOWN)
        }
    }

    /** The real package manager and the real capture store, wrapped. */
    fun facts(context: Context): PackageFacts =
        SystemPackageFacts(context.packageManager, CaptureStore.of(context))

    /**
     * A label, an icon and a launchability only ever travel with
     * [PRESENCE_INSTALLED]: they are what the package manager resolved, so there is
     * nothing to send when it resolved nothing. A caller that finds a label beside
     * `gone` would be reading a leftover.
     *
     * Every key is present on every branch, carrying null where there is no answer.
     * A key missing on one branch and present on another is how a caller ends up
     * reading a stale value beside a presence it does not belong to
     * (SourceAppInfoTest).
     */
    private fun answer(
        presence: String,
        label: String? = null,
        icon: ByteArray? = null,
        launchable: Boolean? = null,
    ): Map<String, Any?> = mapOf(
        KEY_PRESENCE to presence,
        KEY_LABEL to label,
        KEY_ICON to icon,
        KEY_LAUNCHABLE to launchable,
    )
}

/**
 * What the package manager resolved for one package.
 *
 * [launchable] is not a property of the app's identity the way the other two are;
 * it is here because it is resolved in the same breath and about the same package,
 * and a second round trip to ask it would be a second moment the answer could
 * disagree with the label beside it.
 */
internal class PackageFace(
    val label: String,
    val icon: ByteArray?,
    /**
     * Whether `getLaunchIntentForPackage` resolved something to start (INB-13).
     *
     * Kept apart from "is this package installed" because the two are different
     * questions with different answers: a package can be installed, resolvable and
     * have no launcher activity at all, and then there is a label to draw and
     * nothing to open.
     */
    val launchable: Boolean,
)

/**
 * The two questions [SourceAppInfo.lookup] asks of the phone, in the order it
 * asks them.
 *
 * An interface because the stub android.jar on the unit-test classpath answers
 * null to every framework call (see build.gradle.kts), so the rule above could
 * not otherwise be executed at all -- and the rule is the part worth testing:
 * which packages are asked about, and which of the three answers each outcome
 * produces.
 *
 * Not a `fun interface` any more, and that is the point of this change: the
 * permission to ask and the asking are two calls, so a test can assert that the
 * second never happened.
 */
internal interface PackageFacts {

    /**
     * Whether this install has already seen [packageName] post a notification.
     *
     * The app's own record (`CaptureStore.everSeen`), never a question put to the
     * phone: asking Android whether a package exists is the thing this gate is
     * there to prevent, so a gate that asked would be circular.
     */
    fun hasPosted(packageName: String): Boolean

    /**
     * Null when the package manager says there is no such package.
     *
     * Throws when it could not say. The two are kept apart on purpose: INB-16
     * reads the first as "gone" and the second as "cannot tell", and a
     * implementation that swallowed its own failure into a null would put the
     * app back to claiming an uninstall it never observed.
     */
    fun faceOf(packageName: String): PackageFace?
}

/**
 * The real one.
 *
 * Holds a `PackageManager` and not a `Context`: it is built per call from the
 * application context, so there is nothing here to outlive an Activity. The
 * [CaptureStore] beside it is the process singleton and holds a `File`, not a
 * `Context`, for the same reason.
 */
internal class SystemPackageFacts(
    private val packageManager: PackageManager,
    private val store: CaptureStore,
) : PackageFacts {

    override fun hasPosted(packageName: String): Boolean = store.hasEverSeen(packageName)

    // getApplicationInfo(String, Int) is superseded by the ApplicationInfoFlags
    // overload at API 33; minSdk is 24, so the int form is the one that exists
    // everywhere this ships.
    @Suppress("DEPRECATION")
    override fun faceOf(packageName: String): PackageFace? {
        val info = try {
            packageManager.getApplicationInfo(packageName, 0)
        } catch (e: PackageManager.NameNotFoundException) {
            // Gone -- with the one residual SourceAppInfo's header states, which is
            // now only a package the phone withholds entirely: one that is
            // installed, has no launcher activity *and* is invisible here answers
            // exactly as an uninstalled one does (INB-16).
            return null
        }
        return PackageFace(
            label = packageManager.getApplicationLabel(info).toString(),
            icon = rasterise(packageManager.getApplicationIcon(info)),
            // The same call INB-13's `Open <app>` will make, made here instead of
            // being found out by a tap. The package manager can say whether there
            // is a launcher activity without the app having to start one and fail,
            // and asking it here is what makes the control's label true before it
            // is pressed rather than after.
            launchable = packageManager.getLaunchIntentForPackage(packageName) != null,
        )
    }

    /**
     * A drawable into PNG bytes the Dart side can hand straight to
     * `Image.memory`.
     *
     * Drawn onto a canvas rather than unwrapped to a bitmap: an adaptive icon
     * (API 26+) is a pair of layers with no bitmap to take, so unwrapping would
     * return nothing for most modern apps' icons.
     *
     * Null when the draw fails, which costs INB-1's fallback to the generic
     * source icon -- a plainer row, not a wrong one. It is never allowed to cost
     * the presence answer: the app being installed is a separate fact from its
     * icon being drawable, and losing the first because of the second would put a
     * "gone" line on a row for an app that is right there.
     */
    private fun rasterise(drawable: Drawable): ByteArray? = try {
        val bitmap = Bitmap.createBitmap(
            SourceAppInfo.ICON_PX,
            SourceAppInfo.ICON_PX,
            Bitmap.Config.ARGB_8888,
        )
        drawable.setBounds(0, 0, SourceAppInfo.ICON_PX, SourceAppInfo.ICON_PX)
        drawable.draw(Canvas(bitmap))
        val out = ByteArrayOutputStream()
        val compressed = bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        if (compressed) out.toByteArray() else null
    } catch (e: Exception) {
        CaptureLog.failure("could not draw a source app's icon", e)
        null
    }
}
