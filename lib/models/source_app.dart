import 'record.dart';

/// An app Replybox has seen a notification from (CAP-1, INB-20).
///
/// A row exists for two different reasons, and the difference matters. Either
/// the user included it and its messages are captured, or the listener saw it
/// post something, dropped the notification, and upserted this row and nothing
/// else — which is what makes the chooser's "other apps" list exist at all
/// (INB-20). `enabled` is the only thing that separates those two states, so
/// nothing else may be inferred from a row's existence.
class SourceApp {
  const SourceApp({
    required this.id,
    required this.package,
    required this.label,
    required this.enabled,
    required this.lastSeenAt,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  /// A new row for a package the listener just saw. [enabled] is the caller's
  /// decision, not this constructor's: CAP-1 sets it from the shipped list on
  /// a first sighting, and the chooser sets it from a tap.
  factory SourceApp.seen({
    required String package,
    required String label,
    required bool enabled,
    required DateTime at,
  }) => SourceApp(
    id: newId(),
    package: package,
    label: label,
    enabled: enabled,
    lastSeenAt: at,
    createdAt: at,
    updatedAt: at,
  );

  factory SourceApp.fromMap(Map<String, Object?> map) => SourceApp(
    id: map['id']! as String,
    package: map['package']! as String,
    label: map['label']! as String,
    enabled: boolFromDb(map['enabled']),
    lastSeenAt: timeFromDb(map['last_seen_at']),
    createdAt: timeFromDb(map['created_at']),
    updatedAt: timeFromDb(map['updated_at']),
    deletedAt: timeFromDbOrNull(map['deleted_at']),
  );

  final String id;

  /// The Android package name, exact. The natural key: unique among rows that
  /// are not deleted.
  final String package;

  /// The app's own display name as the package manager gave it. Stored rather
  /// than resolved on every read, so a row survives the app being uninstalled
  /// and the inbox can still say where a conversation came from (INB-1).
  final String label;

  /// Whether messages from this app are captured (CAP-1). False on a row the
  /// listener created only to record that the app exists.
  final bool enabled;

  /// The last time a notification from this package reached the listener,
  /// whether or not it was captured.
  final DateTime lastSeenAt;

  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'package': package,
    'label': label,
    'enabled': boolToDb(enabled),
    'last_seen_at': timeToDb(lastSeenAt),
    'created_at': timeToDb(createdAt),
    'updated_at': timeToDb(updatedAt),
    'deleted_at': deletedAt == null ? null : timeToDb(deletedAt!),
  };

  SourceApp copyWith({
    String? label,
    bool? enabled,
    DateTime? lastSeenAt,
    DateTime? updatedAt,
    Object? deletedAt = unset,
  }) => SourceApp(
    id: id,
    package: package,
    label: label ?? this.label,
    enabled: enabled ?? this.enabled,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: identical(deletedAt, unset)
        ? this.deletedAt
        : deletedAt as DateTime?,
  );

  @override
  String toString() => 'SourceApp($package, enabled: $enabled)';
}
