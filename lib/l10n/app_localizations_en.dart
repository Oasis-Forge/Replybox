// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Replybox';

  @override
  String get inboxEmptyNothingYet =>
      'Nothing yet. Messages from the apps you\'ve included will appear here.';

  @override
  String get conversationUnnamed => 'This conversation arrived without a name';

  @override
  String get messageHidden =>
      'Your phone hid this message. Open it in the app it came from.';

  @override
  String get openInApp => 'Open in app';
}
