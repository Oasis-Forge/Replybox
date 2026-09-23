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

  /// Title of the disclosure screen, which is the only route inside the app to the system notification-access page (PERM-1).
  ///
  /// In en, this message translates to:
  /// **'Before you turn on notification access'**
  String get permissionsDisclosureTitle;

  /// PERM-2's first line — what is read. Quoted by the in-app privacy policy, which holds this claim once rather than restating it (PERM-16).
  ///
  /// In en, this message translates to:
  /// **'Replybox reads the notifications the apps below post: who sent a message, what it says, when it arrived, and which conversation it belongs to.'**
  String get permissionsDisclosureReads;

  /// PERM-2's second line — what is done with them (CAP-14).
  ///
  /// In en, this message translates to:
  /// **'It puts them in one inbox and answers them there, using the reply field the notification itself carries.'**
  String get permissionsDisclosureUses;

  /// PERM-2's third line — product principle 1. Quoted by the in-app privacy policy (PERM-16).
  ///
  /// In en, this message translates to:
  /// **'Everything stays on this phone. There is no account, no server and no analytics, and this build has no internet permission at all.'**
  String get permissionsDisclosureStaysHere;

  /// PERM-2's fifth line — the grant can be withdrawn, and what happens then (PERM-8).
  ///
  /// In en, this message translates to:
  /// **'You can turn notification access off again in your phone\'s settings at any time. Replybox keeps what it already stored and captures nothing new.'**
  String get permissionsDisclosureWithdraw;

  /// PERM-2's fourth line, as a heading over the seven clauses below (CAP-12, product principle 3).
  ///
  /// In en, this message translates to:
  /// **'What Replybox still cannot see'**
  String get permissionsDisclosureLimitsTitle;

  /// CAP-12's first absence, in CAP-12's order (PERM-2).
  ///
  /// In en, this message translates to:
  /// **'Nothing from before you installed Replybox.'**
  String get permissionsDisclosureLimitBeforeInstall;

  /// CAP-12's second absence (PERM-2, PERM-8).
  ///
  /// In en, this message translates to:
  /// **'Nothing from while notification access was off.'**
  String get permissionsDisclosureLimitAccessOff;

  /// CAP-12's third absence (PERM-2, CAP-1, INB-22).
  ///
  /// In en, this message translates to:
  /// **'Nothing from an app you switched off in Included apps.'**
  String get permissionsDisclosureLimitAppOff;

  /// CAP-12's fourth absence (PERM-2, CAP-26).
  ///
  /// In en, this message translates to:
  /// **'If a message is edited, unsent or deleted in the app it came from, Replybox is never told, so the copy here stays as it arrived.'**
  String get permissionsDisclosureLimitEdits;

  /// The first absence this area meets before CAP-12 does (PERM-2, CAP-8).
  ///
  /// In en, this message translates to:
  /// **'Your phone hides some messages from every notification listener, and no setting in Replybox can turn that off.'**
  String get permissionsDisclosureLimitHidden;

  /// The second (PERM-2, CAP-14, INB-13).
  ///
  /// In en, this message translates to:
  /// **'A conversation whose notification this run is no longer holding opens in the app it came from instead of answering here.'**
  String get permissionsDisclosureLimitOpenInApp;

  /// The third (PERM-2, PERM-17). Provisional and says so; it claims nothing in either direction, which is why it does not say Replybox cannot speak for a work profile — that would be a measurement nobody has made.
  ///
  /// In en, this message translates to:
  /// **'Replybox has not been tried with a work profile. Nobody has measured whether work notifications reach it, or whether a reply sent from here arrives.'**
  String get permissionsDisclosureLimitWorkProfile;

  /// Heading over PERM-3's list, which shows every shipped-list app in full — no truncation and no "and others" (decision 6, decision 9).
  ///
  /// In en, this message translates to:
  /// **'Apps Replybox captures without you choosing them'**
  String get permissionsDisclosureAppsTitle;

  /// PERM-3's sentence beside the list (INB-20, INB-22). Quoted by the in-app privacy policy (PERM-16).
  ///
  /// In en, this message translates to:
  /// **'These apps are captured as soon as they post a notification, without you naming them. Included apps turns any of them off.'**
  String get permissionsDisclosureAppsExplainer;

  /// Marker beside a shipped-list app the package manager cannot find, so a user can switch it off before it ever posts (PERM-3, INB-16).
  ///
  /// In en, this message translates to:
  /// **'Not installed on this phone'**
  String get permissionsDisclosureAppNotInstalled;

  /// The disclosure's one primary button, which opens the system page (PERM-1, PERM-7).
  ///
  /// In en, this message translates to:
  /// **'Turn on notification access'**
  String get permissionsDisclosureTurnOn;

  /// The one-tap decline. The app stays whole afterwards: nothing is greyed out and no screen is replaced (PERM-4).
  ///
  /// In en, this message translates to:
  /// **'Continue without it'**
  String get permissionsDisclosureDecline;

  /// Closes the disclosure where access is already on and it is being shown as information (PERM-5).
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get permissionsDisclosureContinue;

  /// The one extra line on a return from the system page with access still missing (PERM-6).
  ///
  /// In en, this message translates to:
  /// **'Notification access is still off, so nothing has been captured.'**
  String get permissionsDisclosureStillOff;

  /// Replaces the primary button where neither of PERM-7's intents starts, rather than leaving a button that does nothing (PERM-7).
  ///
  /// In en, this message translates to:
  /// **'Replybox cannot open that page on this phone. Open Settings, find the notification access list, and switch Replybox on there.'**
  String get permissionsDisclosureNoSettingsPage;

  /// PERM-8's banner where the newest capture window was closed on a reported disconnection, so the end is exact (PERM-9).
  ///
  /// In en, this message translates to:
  /// **'Capture is off. Nothing has been stored since {time}.'**
  String captureOffSince(String time);

  /// PERM-8's banner where the window was closed on a later discovery: Replybox is not told when access is taken away, so this is the last moment it can prove and never the moment it noticed (PERM-9, product principle 3).
  ///
  /// In en, this message translates to:
  /// **'Capture is off. Nothing has been stored since at least {time}.'**
  String captureOffSinceAtLeast(String time);

  /// PERM-8's banner where no window has ever been closed because access has never been granted since install; it names installed_at rather than a time the app does not hold (CAP-12).
  ///
  /// In en, this message translates to:
  /// **'Capture has never been on. Replybox has stored nothing since it was installed on {date}.'**
  String captureNeverOn(String date);

  /// The banner's one action. It opens the disclosure and never the system page directly (PERM-1, PERM-8).
  ///
  /// In en, this message translates to:
  /// **'How to turn it on'**
  String get captureOffAction;

  /// PERM-10's line: access is granted and this app's listener reported itself disconnected, a rebind was asked for, and ten seconds later it still is. Provisional — the ten seconds are design, not a measurement (CAP-25).
  ///
  /// In en, this message translates to:
  /// **'Capture is not running right now.'**
  String get captureNotRunning;

  /// PERM-11's dismissible line. It says when something last arrived and never that capture is working, because silence and a dead listener are indistinguishable (product principle 3).
  ///
  /// In en, this message translates to:
  /// **'Nothing has arrived since {time}. That may be perfectly normal.'**
  String captureQuietSince(String time);

  /// The action on both PERM-10's line and PERM-11's line; both open the battery guidance (PERM-14).
  ///
  /// In en, this message translates to:
  /// **'Why this happens'**
  String get captureGuidanceAction;

  /// Dismisses PERM-11's line, which is the only one of the three that can be dismissed: the other two report a state that does not go away on being tapped (PERM-8, PERM-13).
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get captureQuietDismiss;

  /// Title of the battery-guidance screen, reachable from Included apps and from PERM-10's and PERM-11's lines (PERM-14).
  ///
  /// In en, this message translates to:
  /// **'Battery and background limits'**
  String get batteryGuidanceTitle;

  /// PERM-14's first two claims: what happens, and that this app cannot change it.
  ///
  /// In en, this message translates to:
  /// **'Android stops background services to save battery, and some phones stop them harder than Android does. Replybox cannot change any of those settings for itself.'**
  String get batteryGuidanceAndroid;

  /// PERM-14's honesty clause: the 24-hour OEM survival check has not run (spike, 21 September 2026, check 3; CAP-25, decision 11).
  ///
  /// In en, this message translates to:
  /// **'Nobody has yet measured whether any of these settings keeps Replybox\'s listener alive on any phone. This is a place to look, not a fix Replybox promises.'**
  String get batteryGuidanceUnmeasured;

  /// Shows Build.MANUFACTURER exactly as the device reported it, left to right inside a right-to-left layout, so an unlisted phone is visibly unlisted rather than silently generic (PERM-14, LANG-5).
  ///
  /// In en, this message translates to:
  /// **'This phone reports its manufacturer as {manufacturer}.'**
  String batteryGuidanceManufacturer(String manufacturer);

  /// Shown where Build.MANUFACTURER could not be read, rather than printing a name the device never gave (PERM-14).
  ///
  /// In en, this message translates to:
  /// **'This phone did not report a manufacturer.'**
  String get batteryGuidanceManufacturerUnknown;

  /// The generic branch, which every phone takes today because an entry with no verified date does not ship (PERM-14, decision 11). It names no manufacturer and states nothing about one.
  ///
  /// In en, this message translates to:
  /// **'Replybox has no steps verified on this phone, so the two Android pages below are what it can offer. It does not guess what a phone does to it.'**
  String get batteryGuidanceNoVerifiedSteps;

  /// Opens the system's battery-optimisation list page, which needs no permission (PERM-14, PERM-15).
  ///
  /// In en, this message translates to:
  /// **'Open battery optimisation settings'**
  String get batteryGuidanceBatteryPage;

  /// The written path, shown in place of the control where that page does not open on this phone, rather than leaving a button that does nothing (PERM-14, PERM-7). It does not spell out a fixed menu path: on the one phone that reaches this text the app has just failed to open the page, which is the worst place to assert what that phone's Settings look like.
  ///
  /// In en, this message translates to:
  /// **'Open Settings, find Replybox in the list of apps, and look for its battery setting. Where that sits differs from phone to phone.'**
  String get batteryGuidanceBatteryPagePath;

  /// Opens this app's own app-info page, which needs no permission (PERM-14, PERM-15).
  ///
  /// In en, this message translates to:
  /// **'Open Replybox app info'**
  String get batteryGuidanceAppInfoPage;

  /// The written path for the same page, for the same reason (PERM-14, PERM-7). Named apps and not a menu path, for the reason batteryGuidanceBatteryPagePath gives.
  ///
  /// In en, this message translates to:
  /// **'Open Settings, find Replybox in the list of apps, and open it.'**
  String get batteryGuidanceAppInfoPagePath;

  /// Said once beside whichever written path replaced a control, so a page that will not open is a stated limit rather than a dead button (PERM-14, PERM-7).
  ///
  /// In en, this message translates to:
  /// **'Replybox cannot open that page on this phone.'**
  String get batteryGuidanceCannotOpen;

  /// Title of the in-app privacy policy, which ships inside the app and is translated with every other string, so reading it makes no network request (PERM-16, LANG-2).
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get privacyPolicyTitle;

  /// Heading. The three claims under it are PERM-2's and PERM-3's own message IDs, quoted rather than restated, so the disclosure and the policy cannot drift (PERM-16).
  ///
  /// In en, this message translates to:
  /// **'What is stored'**
  String get privacyPolicyStoredTitle;

  /// Where the captured messages live (PERM-16, product principle 1).
  ///
  /// In en, this message translates to:
  /// **'All of it is in one database on this phone, in Replybox\'s own storage. No copy is made anywhere else.'**
  String get privacyPolicyStoredWhere;

  /// Heading over the package-visibility claim that decision 13 made a merge condition (PERM-16, INB-20).
  ///
  /// In en, this message translates to:
  /// **'What Replybox asks your phone about'**
  String get privacyPolicyPackagesTitle;

  /// The claim decision 13 bought back as a rule rather than a manifest, stated in the app's own words and held by a test (INB-20, PERM-16).
  ///
  /// In en, this message translates to:
  /// **'Replybox can see which apps on this phone can be opened. It only ever asks about an app that has already sent you a notification, or one of the apps it names on the permission screen, and it never asks for a list of what you have installed.'**
  String get privacyPolicyPackages;

  /// Heading (PERM-16).
  ///
  /// In en, this message translates to:
  /// **'What leaves this phone'**
  String get privacyPolicyLeavesTitle;

  /// Product principle 1 (PERM-16). It names no control: nothing in the app opens a browser today, and the earlier wording pointed at a link below it that is not drawn. Where a control does ship, its own label is what says it leaves the phone (privacyPolicyOpenHosted).
  ///
  /// In en, this message translates to:
  /// **'Nothing. The release build has no internet permission, so it could not send anything even if it tried, and reading this page inside Replybox makes no network request at all.'**
  String get privacyPolicyLeaves;

  /// What a delete means (DEL-1, PERM-16).
  ///
  /// In en, this message translates to:
  /// **'Deleting a conversation here removes it from this phone and nowhere else, because there is nowhere else.'**
  String get privacyPolicyDeleting;

  /// The hosted copy's address, shown as text beside the page rather than only as a link (PERM-16).
  ///
  /// In en, this message translates to:
  /// **'The same page is published at {url}'**
  String privacyPolicyHostedAddress(String url);

  /// The label for a control that opens the hosted policy in a browser, saying so in the label itself (PERM-16). Written and translated ahead of the control: nothing in the app opens a browser today, PrivacyPolicyScreen.onOpenHosted is null at every call site in lib/, and so this string is drawn nowhere. Kept because PERM-16's condition is about the wording, and a label that has to be written in every language the day someone wires a launcher is a label written in a hurry. Do not read it as evidence the control exists — PERM-16's correction of 23 September 2026 says 'the only thing in the app that does' names nothing.
  ///
  /// In en, this message translates to:
  /// **'Open in your browser (this leaves your phone)'**
  String get privacyPolicyOpenHosted;
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
