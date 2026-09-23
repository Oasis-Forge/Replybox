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

  @override
  String get permissionsDisclosureTitle =>
      'Before you turn on notification access';

  @override
  String get permissionsDisclosureReads =>
      'Replybox reads the notifications the apps below post: who sent a message, what it says, when it arrived, and which conversation it belongs to.';

  @override
  String get permissionsDisclosureUses =>
      'It puts them in one inbox and answers them there, using the reply field the notification itself carries.';

  @override
  String get permissionsDisclosureStaysHere =>
      'Everything stays on this phone. There is no account, no server and no analytics, and this build has no internet permission at all.';

  @override
  String get permissionsDisclosureWithdraw =>
      'You can turn notification access off again in your phone\'s settings at any time. Replybox keeps what it already stored and captures nothing new.';

  @override
  String get permissionsDisclosureLimitsTitle =>
      'What Replybox still cannot see';

  @override
  String get permissionsDisclosureLimitBeforeInstall =>
      'Nothing from before you installed Replybox.';

  @override
  String get permissionsDisclosureLimitAccessOff =>
      'Nothing from while notification access was off.';

  @override
  String get permissionsDisclosureLimitAppOff =>
      'Nothing from an app you switched off in Included apps.';

  @override
  String get permissionsDisclosureLimitEdits =>
      'If a message is edited, unsent or deleted in the app it came from, Replybox is never told, so the copy here stays as it arrived.';

  @override
  String get permissionsDisclosureLimitHidden =>
      'Your phone hides some messages from every notification listener, and no setting in Replybox can turn that off.';

  @override
  String get permissionsDisclosureLimitOpenInApp =>
      'A conversation whose notification this run is no longer holding opens in the app it came from instead of answering here.';

  @override
  String get permissionsDisclosureLimitWorkProfile =>
      'Replybox has not been tried with a work profile. Nobody has measured whether work notifications reach it, or whether a reply sent from here arrives.';

  @override
  String get permissionsDisclosureAppsTitle =>
      'Apps Replybox captures without you choosing them';

  @override
  String get permissionsDisclosureAppsExplainer =>
      'These apps are captured as soon as they post a notification, without you naming them. Included apps turns any of them off.';

  @override
  String get permissionsDisclosureAppNotInstalled =>
      'Not installed on this phone';

  @override
  String get permissionsDisclosureTurnOn => 'Turn on notification access';

  @override
  String get permissionsDisclosureDecline => 'Continue without it';

  @override
  String get permissionsDisclosureContinue => 'Continue';

  @override
  String get permissionsDisclosureStillOff =>
      'Notification access is still off, so nothing has been captured.';

  @override
  String get permissionsDisclosureNoSettingsPage =>
      'Replybox cannot open that page on this phone. Open Settings, find the notification access list, and switch Replybox on there.';

  @override
  String captureOffSince(String time) {
    return 'Capture is off. Nothing has been stored since $time.';
  }

  @override
  String captureOffSinceAtLeast(String time) {
    return 'Capture is off. Nothing has been stored since at least $time.';
  }

  @override
  String captureNeverOn(String date) {
    return 'Capture has never been on. Replybox has stored nothing since it was installed on $date.';
  }

  @override
  String get captureOffAction => 'How to turn it on';

  @override
  String get captureNotRunning => 'Capture is not running right now.';

  @override
  String captureQuietSince(String time) {
    return 'Nothing has arrived since $time. That may be perfectly normal.';
  }

  @override
  String get captureGuidanceAction => 'Why this happens';

  @override
  String get captureQuietDismiss => 'Dismiss';

  @override
  String get batteryGuidanceTitle => 'Battery and background limits';

  @override
  String get batteryGuidanceAndroid =>
      'Android stops background services to save battery, and some phones stop them harder than Android does. Replybox cannot change any of those settings for itself.';

  @override
  String get batteryGuidanceUnmeasured =>
      'Nobody has yet measured whether any of these settings keeps Replybox\'s listener alive on any phone. This is a place to look, not a fix Replybox promises.';

  @override
  String batteryGuidanceManufacturer(String manufacturer) {
    return 'This phone reports its manufacturer as $manufacturer.';
  }

  @override
  String get batteryGuidanceManufacturerUnknown =>
      'This phone did not report a manufacturer.';

  @override
  String get batteryGuidanceNoVerifiedSteps =>
      'Replybox has no steps verified on this phone, so the two Android pages below are what it can offer. It does not guess what a phone does to it.';

  @override
  String get batteryGuidanceBatteryPage => 'Open battery optimisation settings';

  @override
  String get batteryGuidanceBatteryPagePath =>
      'Open Settings, find Replybox in the list of apps, and look for its battery setting. Where that sits differs from phone to phone.';

  @override
  String get batteryGuidanceAppInfoPage => 'Open Replybox app info';

  @override
  String get batteryGuidanceAppInfoPagePath =>
      'Open Settings, find Replybox in the list of apps, and open it.';

  @override
  String get batteryGuidanceCannotOpen =>
      'Replybox cannot open that page on this phone.';

  @override
  String get privacyPolicyTitle => 'Privacy policy';

  @override
  String get privacyPolicyStoredTitle => 'What is stored';

  @override
  String get privacyPolicyStoredWhere =>
      'All of it is in one database on this phone, in Replybox\'s own storage. No copy is made anywhere else.';

  @override
  String get privacyPolicyPackagesTitle =>
      'What Replybox asks your phone about';

  @override
  String get privacyPolicyPackages =>
      'Replybox can see which apps on this phone can be opened. It only ever asks about an app that has already sent you a notification, or one of the apps it names on the permission screen, and it never asks for a list of what you have installed.';

  @override
  String get privacyPolicyLeavesTitle => 'What leaves this phone';

  @override
  String get privacyPolicyLeaves =>
      'Nothing. The release build has no internet permission, so it could not send anything even if it tried, and reading this page inside Replybox makes no network request at all.';

  @override
  String get privacyPolicyDeleting =>
      'Deleting a conversation here removes it from this phone and nowhere else, because there is nowhere else.';

  @override
  String privacyPolicyHostedAddress(String url) {
    return 'The same page is published at $url';
  }

  @override
  String get privacyPolicyOpenHosted =>
      'Open in your browser (this leaves your phone)';
}
