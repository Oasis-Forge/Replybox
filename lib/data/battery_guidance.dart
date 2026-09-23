/// PERM-14's battery steps, keyed by manufacturer — and empty, on purpose
/// (decision 11).
///
/// Modelled on `shipped_apps.dart`: a constant the rules point at, with the
/// reason for its shape here rather than in a screen. The difference is that
/// that list has six entries and this one has none, and the emptiness is the
/// decision rather than an unfinished job.
library;

import 'package:flutter/foundation.dart';

/// One manufacturer's verified battery steps (PERM-14, decision 11).
///
/// Message IDs, a date and a device — never rendered text (LANG-2, DATA-1). A
/// table that held English sentences would be the one place in the app that
/// cannot be translated, and PERM-14's page is shown in every language LANG-6
/// ships.
@immutable
class BatteryGuidanceEntry {
  const BatteryGuidanceEntry({
    required this.stepMessageIds,
    required this.verifiedOn,
    required this.verifiedDevice,
  });

  /// In the order they are performed.
  final List<String> stepMessageIds;

  /// The date the steps were run on a real phone. There is no entry without
  /// one, which is what makes this class unable to carry a guess: the field is
  /// required and non-nullable, so an entry written from a forum post has
  /// nowhere to put its missing date.
  final DateTime verifiedOn;

  /// The exact model they were run on. PERM-14 never states what a *make* does
  /// to this app, so an entry is a record of one device and is stamped as such.
  final String verifiedDevice;
}

/// Keyed by an exact match on `Build.MANUFACTURER`, lower-cased, trimmed.
///
/// **Empty, and shipping empty is the decision** (decision 11, PERM-14): the
/// 24-hour OEM survival check did not run (spike, 21 September 2026, check 3),
/// so any path in here today would be a claim about a named manufacturer that
/// the app cannot stand behind — inside an app whose one differentiator is not
/// doing that. Every phone therefore takes the generic branch and sees its own
/// manufacturer named, so an unlisted phone is visibly unlisted rather than
/// silently unsupported.
///
/// **No entry here ever says what a named manufacturer does to this app.** An
/// entry is a list of settings pages to look at on a phone of that make, dated
/// and stamped with the device it was verified on. It is not a statement that
/// this manufacturer kills this listener, or that following the steps stops it:
/// nobody has measured either, and `batteryGuidanceUnmeasured` says so on the
/// same screen.
const Map<String, BatteryGuidanceEntry> batteryGuidanceByManufacturer =
    <String, BatteryGuidanceEntry>{};

/// The entry for [manufacturer], or null for the generic branch.
///
/// Exact match on the lower-cased, trimmed value and nothing looser: no prefix
/// match, no contains, no alias list. A near-match is a phone this app has not
/// been tested on, and treating it as a listed one would be exactly the claim
/// the table above refuses to make — the user would read steps verified on
/// someone else's hardware as steps verified on theirs.
///
/// The lower-casing happens on a copy and never on the value the screen draws
/// (LANG-5): `SystemSettings.manufacturer` is printed as the device reported
/// it, and normalising it for display would be the app tidying up a fact it did
/// not author.
BatteryGuidanceEntry? batteryGuidanceFor(String? manufacturer) {
  if (manufacturer == null) return null;
  final String key = manufacturer.trim().toLowerCase();
  if (key.isEmpty) return null;
  return batteryGuidanceByManufacturer[key];
}
