/// The messaging apps Replybox captures from before the user chooses anything
/// (decision 9, CAP-1, INB-20).
///
/// Six, and exactly the six the spike's check 1 is defined over, so no
/// default-on app rests on behaviour nobody will verify on hardware. Every one
/// of them has to be listed in full on the permission disclosure (PERM-3) at
/// 1.3x text, so the length of this list is both the size of the privacy cost
/// and a layout constraint — it is not a place to be generous.
///
/// This is the single source that CAP-1's filter, INB-21's chooser, PERM-3's
/// disclosure and the manifest's `<queries>` all read. A test asserts this
/// constant and the manifest entries are one set, so the app can never
/// pre-enable a package whose label and icon the build cannot resolve.
library;

/// Package names, exact. Adding one here does **not** switch it on for an
/// install that already exists (decision 9): that user's bargain was struck at
/// their first run, and enabling an app they never saw would be a grant they
/// never gave (PERM-5).
const List<String> shippedMessagingApps = <String>[
  'com.whatsapp',
  'com.facebook.orca', // Messenger
  'com.instagram.android',
  'org.telegram.messenger',
  'org.thoughtcrime.securesms', // Signal
  'com.google.android.apps.messaging', // Google Messages
];

/// Whether a package is captured by default on a fresh install (CAP-1).
bool isShippedMessagingApp(String package) =>
    shippedMessagingApps.contains(package);
