import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// The application's title.
  ///
  /// In en, this message translates to:
  /// **'Replybox'**
  String get appTitle;

  /// Body of the Nothing yet empty state where no app label resolves, so none can be named (INB-15, RUN-1).
  ///
  /// In en, this message translates to:
  /// **'Nothing yet. Messages from the apps you have included will appear here.'**
  String get inboxEmptyNothingYet;

  /// Body of the Nothing yet empty state, naming up to three included apps by label, most recently seen first, and a count of the rest (INB-15, RUN-1).
  ///
  /// In en, this message translates to:
  /// **'{othersCount, plural, =0{Messages from {apps} will appear here.} =1{Messages from {apps} and 1 more app will appear here.} other{Messages from {apps} and {othersCount} more apps will appear here.}}'**
  String inboxEmptyNothingYetApps(String apps, int othersCount);

  /// Shown on a conversation row whose notification arrived without a name (INB-2).
  ///
  /// In en, this message translates to:
  /// **'This conversation arrived without a name'**
  String get conversationUnnamed;

  /// The row's preview line where the conversation holds no message to preview — every message soft-deleted (DEL-1), or last_message_at sitting past everything stored. Said rather than left blank, so the gap has a name on it (INB-1, product principle 3).
  ///
  /// In en, this message translates to:
  /// **'No messages here'**
  String get conversationNoMessages;

  /// Shown in place of a message Android hid from the app (CAP-8, INB-3).
  ///
  /// In en, this message translates to:
  /// **'Your phone hid this message. Open it in the app it came from.'**
  String get messageHidden;

  /// Action on a row with no live reply action (INB-13, CAP-14).
  ///
  /// In en, this message translates to:
  /// **'Open in app'**
  String get openInApp;

  /// Title of the conversation list, which is the whole first screen in v1 (INB-19).
  ///
  /// In en, this message translates to:
  /// **'Inbox'**
  String get inboxTitle;

  /// Row preview for a group conversation, where the sender's name prefixes the message (INB-1). A one-to-one conversation shows the text alone.
  ///
  /// In en, this message translates to:
  /// **'{sender}: {text}'**
  String conversationPreviewWithSender(String sender, String text);

  /// Unread badge beyond 99; counts up to 99 are formatted as numbers by LANG-3 (INB-5).
  ///
  /// In en, this message translates to:
  /// **'99+'**
  String get unreadCountOverflow;

  /// The one control a swipe on a conversation row reveals (INB-6).
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteConversation;

  /// Snackbar shown for about five seconds after a swipe delete (INB-6, DEL-2).
  ///
  /// In en, this message translates to:
  /// **'Conversation deleted'**
  String get conversationDeleted;

  /// Shown in place of the list when the read failed and there is nothing to draw. Never the exception: repository.dart composes a message containing a sender and a message's text, and no screen may put that on a screen or into a crash report (INB-24).
  ///
  /// In en, this message translates to:
  /// **'Replybox could not read your messages.'**
  String get inboxLoadFailed;

  /// Shown in place of the thread when its read failed and there is nothing to draw. Never the exception (INB-24).
  ///
  /// In en, this message translates to:
  /// **'Replybox could not read this conversation.'**
  String get threadLoadFailed;

  /// Shown in place of the included-apps list when its read failed and there is nothing to draw. Never the exception (INB-24).
  ///
  /// In en, this message translates to:
  /// **'Replybox could not read your apps.'**
  String get includedAppsLoadFailed;

  /// Snackbar after a write that failed — a delete, an undo, or removing an app's stored messages. Says what happened without naming the conversation or quoting the exception (INB-24).
  ///
  /// In en, this message translates to:
  /// **'That did not save. Nothing changed.'**
  String get changeFailed;

  /// The one action beside a failure line: runs the read again.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get retry;

  /// Action on the delete snackbar, which restores the conversation and all its messages in one step (INB-6, CAP-16).
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// First row of every thread, above the oldest message: a standing notice, not dismissible (INB-10, CAP-26).
  ///
  /// In en, this message translates to:
  /// **'Replybox holds only what arrived as a notification. A message edited, unsent or deleted in the app it came from still reads here as it first arrived.'**
  String get threadHistoryNotice;

  /// Part of the standing thread notice naming the first date anything here could have been captured (INB-10, CAP-12). The date is formatted by LANG-3 and passed in as text.
  ///
  /// In en, this message translates to:
  /// **'The earliest it could have seen this conversation is {date}.'**
  String threadHistorySince(String date);

  /// Variant of the standing thread notice where no capture session existed before the first possible date (INB-10, CAP-12).
  ///
  /// In en, this message translates to:
  /// **'Notification access was off until {date}, so nothing from before then is here.'**
  String threadHistoryAccessOffUntil(String date);

  /// Part of the standing thread notice naming the most recent capture gap overlapping this thread and a count of the others; gaps under 60 seconds are not counted (INB-10, CAP-12).
  ///
  /// In en, this message translates to:
  /// **'{otherCount, plural, =0{Nothing could be captured here between {start} and {end}.} =1{Nothing could be captured here between {start} and {end}, and there is one other gap like it.} other{Nothing could be captured here between {start} and {end}, and there are {otherCount} other gaps like it.}}'**
  String threadHistoryGaps(String start, String end, int otherCount);

  /// Variant of the standing thread notice used instead of the first-possible date when a retention window is in force and is later than it (INB-10, area RET).
  ///
  /// In en, this message translates to:
  /// **'This thread reaches back to {date}. Older messages were here and Replybox removed them.'**
  String threadHistoryRetention(String date);

  /// INB-10: the standing notice owns what this thread does not hold, and the read is bounded — so the window is stated rather than paged, because INB-10 forbids the top of the thread implying more can be loaded.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{This thread shows its newest message only. Older ones are stored and are not shown here.} other{This thread shows its newest {count} messages. Older ones are stored and are not shown here.}}'**
  String threadWindowed(int count);

  /// INB-6, INB-22 and DEL-1: the conversation was deleted while its thread was open — swiped from the list, or removed with its app's stored messages. It may still be inside its five-second Undo window, so the line says it was deleted and never that it is gone for good. Names no title and no sender (INB-24).
  ///
  /// In en, this message translates to:
  /// **'This conversation was deleted. There is nothing to show here.'**
  String get threadConversationGone;

  /// Placeholder drawn in place of a message whose content_kind is image, in the thread and as the row preview (INB-11, CAP-9).
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get messageImage;

  /// Placeholder for a message whose content_kind is voice (INB-11, CAP-9).
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get messageVoice;

  /// Placeholder for a message whose content_kind is video (INB-11, CAP-9).
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get messageVideo;

  /// Placeholder for a message whose content_kind is file (INB-11, CAP-9).
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get messageFile;

  /// Placeholder for a message whose content_kind is other: the app says only that something arrived, never what (INB-11, CAP-9).
  ///
  /// In en, this message translates to:
  /// **'Something Replybox cannot show'**
  String get messageOther;

  /// Standing line above a raw conversation's messages, so it never reads like a chat (INB-12, CAP-21).
  ///
  /// In en, this message translates to:
  /// **'Replybox saw a notification from this app, but not a conversation. Each line below is the notification\'s own title and text, as the phone delivered them. Nothing was added and nothing was inferred.'**
  String get rawConversationNotice;

  /// Joins a raw notification's title and text, in the row preview and in the thread. Where only one of the two is non-empty it is shown alone and no separator is drawn (INB-12).
  ///
  /// In en, this message translates to:
  /// **'{title} — {text}'**
  String rawPreviewJoin(String title, String text);

  /// Shown where a raw notification carried a longer body than the line stored, so the app never claims the text is complete (INB-12, product principle 3).
  ///
  /// In en, this message translates to:
  /// **'Replybox kept what the notification showed. The rest of it is in {app}.'**
  String rawMessageIncomplete(String app);

  /// Bottom-bar control when the notification's own content intent is still held in this process (INB-13).
  ///
  /// In en, this message translates to:
  /// **'Open chat'**
  String get openChat;

  /// Bottom-bar control when only the package's launcher intent is available; the app claims nothing about where it lands (INB-13).
  ///
  /// In en, this message translates to:
  /// **'Open {app}'**
  String openApp(String app);

  /// Snackbar for about five seconds after a launch that threw or resolved to nothing; nothing else on screen changes (INB-13, INB-16).
  ///
  /// In en, this message translates to:
  /// **'Could not open that app.'**
  String get openAppFailed;

  /// Line beside the bottom-bar control while a conversation's newest message is hidden: a capability declined, not a platform limit (INB-3, decision 8).
  ///
  /// In en, this message translates to:
  /// **'Replybox will not answer a message it cannot show.'**
  String get hiddenNoReply;

  /// Heading of the empty state shown when nothing is stored (INB-15).
  ///
  /// In en, this message translates to:
  /// **'Nothing yet'**
  String get inboxEmptyNothingYetTitle;

  /// Second line of the Nothing yet empty state (INB-15, CAP-12).
  ///
  /// In en, this message translates to:
  /// **'Only messages that arrive from now on can appear. There is none from before Replybox was installed.'**
  String get inboxEmptyNothingYetNoHistory;

  /// Added to the Nothing yet empty state where a capture_sessions gap exists (INB-15, CAP-12).
  ///
  /// In en, this message translates to:
  /// **'Nothing was seen while notification access was off.'**
  String get inboxEmptyNothingYetAccessGap;

  /// The one action on the Nothing yet empty state; it opens the included-apps list (INB-15, INB-20).
  ///
  /// In en, this message translates to:
  /// **'See included apps'**
  String get inboxEmptyNothingYetAction;

  /// Heading of the empty state shown when a chip selection matches no conversation (INB-15).
  ///
  /// In en, this message translates to:
  /// **'Nothing in this filter'**
  String get inboxEmptyFilterTitle;

  /// Body of the filtered empty state, naming the selected apps (INB-15, INB-14).
  ///
  /// In en, this message translates to:
  /// **'No conversations from {apps}.'**
  String inboxEmptyFilter(String apps);

  /// The one action on the filtered empty state; it clears the chips back to All (INB-15, INB-14).
  ///
  /// In en, this message translates to:
  /// **'Show all'**
  String get inboxEmptyFilterAction;

  /// INB-15: no empty state is blank. The list's last conversation is inside INB-6's Undo window, so the list is empty for about five seconds; the one action is the Undo in the message below, so this line carries no button of its own.
  ///
  /// In en, this message translates to:
  /// **'That was the last conversation here. Undo is still open below.'**
  String get inboxEmptyPendingUndo;

  /// Heading of the empty state shown when a search returns nothing (INB-15).
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get inboxEmptyNoResultsTitle;

  /// Body of the no-results empty state, repeating the words searched, truncated to 60 characters with an ellipsis by the screen (INB-15, area SRCH).
  ///
  /// In en, this message translates to:
  /// **'Nothing matches “{query}”.'**
  String inboxEmptyNoResults(String query);

  /// Added to the no-results empty state to name a narrowing in force (INB-15).
  ///
  /// In en, this message translates to:
  /// **'Narrowed to {apps}.'**
  String inboxEmptyNoResultsNarrowedTo(String apps);

  /// The one action on the no-results empty state while a narrowing is in force; it removes the narrowing (INB-15).
  ///
  /// In en, this message translates to:
  /// **'Search all apps'**
  String get inboxEmptyNoResultsClearNarrowing;

  /// The one action on the no-results empty state when no narrowing is in force (INB-15).
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get inboxEmptyNoResultsClearSearch;

  /// Joins two app labels in an empty state or a filter line (INB-15, LANG-3).
  ///
  /// In en, this message translates to:
  /// **'{first} and {second}'**
  String listTwo(String first, String second);

  /// Joins three app labels in an empty state or a filter line (INB-15, LANG-3).
  ///
  /// In en, this message translates to:
  /// **'{first}, {second} and {third}'**
  String listThree(String first, String second, String third);

  /// Shown on a row whose source package is inside the manifest's queries declaration and is gone, in place of the bottom-bar control; the conversation and its messages stay (INB-16).
  ///
  /// In en, this message translates to:
  /// **'This app is no longer installed.'**
  String get sourceAppGone;

  /// Shown in the thread's bottom bar in place of INB-13's control, where nothing this process holds can open the source app and the package is outside the manifest's queries declaration: no launcher intent can resolve without the package visibility INB-20 refuses, so a control there could only ever fail. Says less rather than guessing, and names no uninstall (INB-16).
  ///
  /// In en, this message translates to:
  /// **'Replybox cannot open {app}.'**
  String sourceAppNotOpenable(String app);

  /// Shown in the thread's bottom bar in place of INB-13's control, where the package manager resolved the app and no launcher intent for it: it is installed and has no launcher activity, so there is nothing to start and a control there would fail on every tap. Names no uninstall — the app is there (INB-13, INB-16, 23 September 2026).
  ///
  /// In en, this message translates to:
  /// **'{app} has no screen to open.'**
  String sourceAppNoLauncher(String app);

  /// The chip pinned at the leading edge of the filter row, selected exactly when no app chip is (INB-14).
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// Title of the included-apps list in Settings (INB-20, INB-21).
  ///
  /// In en, this message translates to:
  /// **'Included apps'**
  String get includedAppsTitle;

  /// Subtitle of an included-apps row, giving the number of conversations stored from that app (INB-21).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 conversation} other{{count} conversations}}'**
  String includedAppsConversations(int count);

  /// Subtitle of an included-apps row for an app with nothing captured (INB-21).
  ///
  /// In en, this message translates to:
  /// **'Nothing has arrived yet'**
  String get includedAppsNothingYet;

  /// Subtitle of an included-apps row for an app that is gone; the switch still works (INB-21, INB-16).
  ///
  /// In en, this message translates to:
  /// **'No longer installed'**
  String get includedAppsNotInstalled;

  /// Hint of the search field, which appears once the included-apps list passes ten rows (INB-21).
  ///
  /// In en, this message translates to:
  /// **'Search apps'**
  String get includedAppsSearchHint;

  /// Permanent line at the bottom of the included-apps list, so an absent app reads as a stated limit rather than a bug (INB-21, INB-20, product principle 3).
  ///
  /// In en, this message translates to:
  /// **'An app is missing until it posts a notification. Replybox never lists the apps on your phone, so it learns about one the first time it posts.'**
  String get includedAppsMissingNote;

  /// Stated beside the switch, which is the whole confirmation of turning a row off (INB-22, CAP-1).
  ///
  /// In en, this message translates to:
  /// **'Off means the next notification this app posts is not stored. What is already here stays.'**
  String get includedAppsSwitchExplainer;

  /// INB-22: the row and the database moved but CAP-1's filter did not hear it, and the row was switched on — so the listener goes on dropping this package's notifications and those messages are lost rather than delayed. Drawn on the row it happened to. Never the exception (INB-24).
  ///
  /// In en, this message translates to:
  /// **'Saved here, but the notification listener has not been told yet. Messages from this app can still be missed until Replybox is opened again.'**
  String get includedAppsSwitchOnNotLive;

  /// INB-22: the same failure with the row switched off — the listener goes on capturing from this package until the next launch or resume re-mirrors. Drawn on the row it happened to. Never the exception (INB-24).
  ///
  /// In en, this message translates to:
  /// **'Saved here, but the notification listener has not been told yet. Messages from this app can still be stored until Replybox is opened again.'**
  String get includedAppsSwitchOffNotLive;

  /// The separate, explicit action on an included-apps row that soft-deletes that app's conversations and messages in one step (INB-22, CAP-16).
  ///
  /// In en, this message translates to:
  /// **'Remove stored messages'**
  String get includedAppsRemoveMessages;

  /// Snackbar shown for about five seconds after removing an app's stored messages, with Undo (INB-22, INB-6).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 conversation removed} other{{count} conversations removed}}'**
  String includedAppsRemoveMessagesDone(int count);

  /// Standing line in every thread from an app whose included-apps row is off, so a thread that stopped never reads as one that went quiet (INB-22, CAP-12).
  ///
  /// In en, this message translates to:
  /// **'{app} is switched off, so no further messages will arrive here until you switch it back on.'**
  String threadSourceAppOff(String app);

  /// Semantic label of a conversation row (INB-23, INB-1).
  ///
  /// In en, this message translates to:
  /// **'{title}, from {app}, {preview}, {time}'**
  String semanticsConversationRow(
    String title,
    String app,
    String preview,
    String time,
  );

  /// Semantic label of the trailing unread count on a conversation row (INB-23, INB-5).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 unread message} other{{count} unread messages}}'**
  String semanticsUnreadCount(int count);

  /// Joins a conversation row's semantic label to its unread count, so a reader who cannot see the badge is still told it is there (INB-23, INB-5). A join and not a concatenation in code: the punctuation between two read-aloud clauses belongs to the language (LANG-2).
  ///
  /// In en, this message translates to:
  /// **'{row}, {unread}'**
  String semanticsConversationRowUnread(String row, String unread);

  /// Semantic label of an app chip in the filter row (INB-23, INB-14).
  ///
  /// In en, this message translates to:
  /// **'Show only {app}'**
  String semanticsFilterChip(String app);

  /// Semantic label of the All chip (INB-23, INB-14).
  ///
  /// In en, this message translates to:
  /// **'Show every app'**
  String get semanticsFilterChipAll;

  /// Semantic label of the Delete control a swipe reveals (INB-23, INB-6).
  ///
  /// In en, this message translates to:
  /// **'Delete {title}'**
  String semanticsDeleteConversation(String title);

  /// Semantic label of the control in the inbox's app bar that opens the included-apps list (INB-23, INB-20).
  ///
  /// In en, this message translates to:
  /// **'Included apps'**
  String get semanticsIncludedApps;

  /// Semantic label of the thread's bottom-bar control on INB-13's launcher-intent path, whose visible label is openApp. The content-intent path has semanticsOpenChat (INB-23, INB-13).
  ///
  /// In en, this message translates to:
  /// **'Open this conversation in {app}'**
  String semanticsOpenInApp(String app);

  /// Semantic label of the thread's bottom-bar control on INB-13's content-intent path, whose visible label is openChat. Separate from semanticsOpenInApp because INB-13 says the label says which of the two launches will run, and one label for both left a screen-reader user unable to tell them apart (INB-23, INB-13).
  ///
  /// In en, this message translates to:
  /// **'Open this conversation where it arrived'**
  String get semanticsOpenChat;

  /// Semantic label of the switch on an included-apps row (INB-23, INB-21, INB-22).
  ///
  /// In en, this message translates to:
  /// **'Capture messages from {app}'**
  String semanticsAppSwitch(String app);

  /// Semantic label of the remove-stored-messages action on an included-apps row (INB-23, INB-22).
  ///
  /// In en, this message translates to:
  /// **'Remove stored messages from {app}'**
  String semanticsRemoveMessages(String app);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
