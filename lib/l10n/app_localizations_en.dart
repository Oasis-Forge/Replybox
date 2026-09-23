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
      'Nothing yet. Messages from the apps you have included will appear here.';

  @override
  String inboxEmptyNothingYetApps(String apps, int othersCount) {
    String _temp0 = intl.Intl.pluralLogic(
      othersCount,
      locale: localeName,
      other: 'Messages from $apps and $othersCount more apps will appear here.',
      one: 'Messages from $apps and 1 more app will appear here.',
      zero: 'Messages from $apps will appear here.',
    );
    return '$_temp0';
  }

  @override
  String get conversationUnnamed => 'This conversation arrived without a name';

  @override
  String get conversationNoMessages => 'No messages here';

  @override
  String get messageHidden =>
      'Your phone hid this message. Open it in the app it came from.';

  @override
  String get openInApp => 'Open in app';

  @override
  String get inboxTitle => 'Inbox';

  @override
  String conversationPreviewWithSender(String sender, String text) {
    return '$sender: $text';
  }

  @override
  String get unreadCountOverflow => '99+';

  @override
  String get deleteConversation => 'Delete';

  @override
  String get conversationDeleted => 'Conversation deleted';

  @override
  String get inboxLoadFailed => 'Replybox could not read your messages.';

  @override
  String get threadLoadFailed => 'Replybox could not read this conversation.';

  @override
  String get includedAppsLoadFailed => 'Replybox could not read your apps.';

  @override
  String get changeFailed => 'That did not save. Nothing changed.';

  @override
  String get retry => 'Try again';

  @override
  String get undo => 'Undo';

  @override
  String get threadHistoryNotice =>
      'Replybox holds only what arrived as a notification. A message edited, unsent or deleted in the app it came from still reads here as it first arrived.';

  @override
  String threadHistorySince(String date) {
    return 'The earliest it could have seen this conversation is $date.';
  }

  @override
  String threadHistoryAccessOffUntil(String date) {
    return 'Notification access was off until $date, so nothing from before then is here.';
  }

  @override
  String threadHistoryGaps(String start, String end, int otherCount) {
    String _temp0 = intl.Intl.pluralLogic(
      otherCount,
      locale: localeName,
      other:
          'Nothing could be captured here between $start and $end, and there are $otherCount other gaps like it.',
      one:
          'Nothing could be captured here between $start and $end, and there is one other gap like it.',
      zero: 'Nothing could be captured here between $start and $end.',
    );
    return '$_temp0';
  }

  @override
  String threadHistoryRetention(String date) {
    return 'This thread reaches back to $date. Older messages were here and Replybox removed them.';
  }

  @override
  String threadWindowed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'This thread shows its newest $count messages. Older ones are stored and are not shown here.',
      one:
          'This thread shows its newest message only. Older ones are stored and are not shown here.',
    );
    return '$_temp0';
  }

  @override
  String get threadConversationGone =>
      'This conversation was deleted. There is nothing to show here.';

  @override
  String get messageImage => 'Photo';

  @override
  String get messageVoice => 'Voice message';

  @override
  String get messageVideo => 'Video';

  @override
  String get messageFile => 'File';

  @override
  String get messageOther => 'Something Replybox cannot show';

  @override
  String get rawConversationNotice =>
      'Replybox saw a notification from this app, but not a conversation. Each line below is the notification\'s own title and text, as the phone delivered them. Nothing was added and nothing was inferred.';

  @override
  String rawPreviewJoin(String title, String text) {
    return '$title — $text';
  }

  @override
  String rawMessageIncomplete(String app) {
    return 'Replybox kept what the notification showed. The rest of it is in $app.';
  }

  @override
  String get openChat => 'Open chat';

  @override
  String openApp(String app) {
    return 'Open $app';
  }

  @override
  String get openAppFailed => 'Could not open that app.';

  @override
  String get hiddenNoReply =>
      'Replybox will not answer a message it cannot show.';

  @override
  String get inboxEmptyNothingYetTitle => 'Nothing yet';

  @override
  String get inboxEmptyNothingYetNoHistory =>
      'Only messages that arrive from now on can appear. There is none from before Replybox was installed.';

  @override
  String get inboxEmptyNothingYetAccessGap =>
      'Nothing was seen while notification access was off.';

  @override
  String get inboxEmptyNothingYetAction => 'See included apps';

  @override
  String get inboxEmptyFilterTitle => 'Nothing in this filter';

  @override
  String inboxEmptyFilter(String apps) {
    return 'No conversations from $apps.';
  }

  @override
  String get inboxEmptyFilterAction => 'Show all';

  @override
  String get inboxEmptyPendingUndo =>
      'That was the last conversation here. Undo is still open below.';

  @override
  String get inboxEmptyNoResultsTitle => 'No results';

  @override
  String inboxEmptyNoResults(String query) {
    return 'Nothing matches “$query”.';
  }

  @override
  String inboxEmptyNoResultsNarrowedTo(String apps) {
    return 'Narrowed to $apps.';
  }

  @override
  String get inboxEmptyNoResultsClearNarrowing => 'Search all apps';

  @override
  String get inboxEmptyNoResultsClearSearch => 'Clear search';

  @override
  String listTwo(String first, String second) {
    return '$first and $second';
  }

  @override
  String listThree(String first, String second, String third) {
    return '$first, $second and $third';
  }

  @override
  String get sourceAppGone => 'This app is no longer installed.';

  @override
  String sourceAppNotOpenable(String app) {
    return 'Replybox cannot open $app.';
  }

  @override
  String sourceAppNoLauncher(String app) {
    return '$app has no screen to open.';
  }

  @override
  String get filterAll => 'All';

  @override
  String get includedAppsTitle => 'Included apps';

  @override
  String includedAppsConversations(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count conversations',
      one: '1 conversation',
    );
    return '$_temp0';
  }

  @override
  String get includedAppsNothingYet => 'Nothing has arrived yet';

  @override
  String get includedAppsNotInstalled => 'No longer installed';

  @override
  String get includedAppsSearchHint => 'Search apps';

  @override
  String get includedAppsMissingNote =>
      'An app is missing until it posts a notification. Replybox never lists the apps on your phone, so it learns about one the first time it posts.';

  @override
  String get includedAppsSwitchExplainer =>
      'Off means the next notification this app posts is not stored. What is already here stays.';

  @override
  String get includedAppsSwitchOnNotLive =>
      'Saved here, but the notification listener has not been told yet. Messages from this app can still be missed until Replybox is opened again.';

  @override
  String get includedAppsSwitchOffNotLive =>
      'Saved here, but the notification listener has not been told yet. Messages from this app can still be stored until Replybox is opened again.';

  @override
  String get includedAppsRemoveMessages => 'Remove stored messages';

  @override
  String includedAppsRemoveMessagesDone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count conversations removed',
      one: '1 conversation removed',
    );
    return '$_temp0';
  }

  @override
  String threadSourceAppOff(String app) {
    return '$app is switched off, so no further messages will arrive here until you switch it back on.';
  }

  @override
  String semanticsConversationRow(
    String title,
    String app,
    String preview,
    String time,
  ) {
    return '$title, from $app, $preview, $time';
  }

  @override
  String semanticsUnreadCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count unread messages',
      one: '1 unread message',
    );
    return '$_temp0';
  }

  @override
  String semanticsConversationRowUnread(String row, String unread) {
    return '$row, $unread';
  }

  @override
  String semanticsFilterChip(String app) {
    return 'Show only $app';
  }

  @override
  String get semanticsFilterChipAll => 'Show every app';

  @override
  String semanticsDeleteConversation(String title) {
    return 'Delete $title';
  }

  @override
  String get semanticsIncludedApps => 'Included apps';

  @override
  String semanticsOpenInApp(String app) {
    return 'Open this conversation in $app';
  }

  @override
  String get semanticsOpenChat => 'Open this conversation where it arrived';

  @override
  String semanticsAppSwitch(String app) {
    return 'Capture messages from $app';
  }

  @override
  String semanticsRemoveMessages(String app) {
    return 'Remove stored messages from $app';
  }
}
