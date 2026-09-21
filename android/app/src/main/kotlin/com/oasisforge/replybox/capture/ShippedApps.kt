package com.oasisforge.replybox.capture

/**
 * Decision 9, CAP-1, INB-20: the six apps captured before the user chooses
 * anything.
 *
 * A fourth copy of a list that already exists in lib/data/shipped_apps.dart, in
 * the manifest's `queries` element and on PERM-3's disclosure -- and it cannot be
 * avoided, because CAP-1's filter has to run before any Dart has ever executed on
 * this install. PERM-3 fails if any package can start enabled whose label the
 * disclosure never showed, so the copies have to be one set.
 *
 * This constant therefore lives alone, in its own file, in a shape a test outside
 * Kotlin can read without a parser: every double-quoted string in this file is a
 * package name and nothing else is quoted. Add a package here and to the three
 * other places at once, and keep any note about it comment text with no quotes in
 * it -- a quoted word anywhere in this file reads as a seventh package.
 */
object ShippedApps {

    /** Package names, exact. One per line; nothing else in this file is quoted. */
    val PACKAGES: Set<String> = setOf(
        "com.whatsapp",
        "com.facebook.orca", // Messenger
        "com.instagram.android",
        "org.telegram.messenger",
        "org.thoughtcrime.securesms", // Signal
        "com.google.android.apps.messaging", // Google Messages
    )
}
