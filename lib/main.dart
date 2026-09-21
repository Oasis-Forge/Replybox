import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'db/db_helper.dart';
import 'db/repository.dart';
import 'l10n/app_localizations.dart';
import 'providers/inbox_provider.dart';
import 'services/noop_services.dart';
import 'services/services.dart';

/// The only place the real device services are ever built
/// (docs/STACK_NOTES.md). Everything below this line takes them as an
/// argument, which is what lets tests hand over fakes and an in-memory
/// database.
void main() {
  final DBHelper db = DBHelper();
  runApp(
    ReplyboxApp(
      repository: Repository(db),
      // Still the no-op set. The real implementations are the Kotlin listener
      // and its channels, which arrive with the Capture item — there is no
      // half-real version worth shipping before then, and a fake that claimed
      // access would make every screen lie.
      services: noopServices(),
    ),
  );
}

class ReplyboxApp extends StatelessWidget {
  const ReplyboxApp({
    required this.repository,
    required this.services,
    super.key,
  });

  final Repository repository;
  final DeviceServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: <SingleChildWidget>[
        ChangeNotifierProvider<InboxProvider>(
          create: (_) => InboxProvider(repository, services)..load(),
        ),
      ],
      child: MaterialApp(
        onGenerateTitle: (BuildContext context) =>
            AppLocalizations.of(context).appTitle,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
        ),
        home: const _Placeholder(),
      ),
    );
  }
}

/// What the app shows until the Inbox item ships its screens.
///
/// It deliberately uses the real empty-state message rather than a lorem
/// placeholder, so the string, the generation and the locale wiring are all
/// exercised by the widget test that covers this.
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.inboxEmptyNothingYet,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ),
    );
  }
}
