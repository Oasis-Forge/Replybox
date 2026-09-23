/// INB-1's identity chain for a source app: the one place it is resolved and
/// the widgets that draw it.
///
/// One place, because the chain is a rule and not a detail: the label and the
/// icon of a package inside INB-16's `<queries>` declaration come from the
/// package manager, for any other package they come from the label the listener
/// stored on the `apps` row (INB-20), and where neither resolves the row shows a
/// generic source icon and the package name. A second copy of that in the chip
/// row would be a second place for it to be one branch out of date — and for
/// one release there were four, each missing a different branch: the chip row
/// had the whole chain, the thread had no presence gate, the swipe's Delete
/// control had neither the package manager nor the emptiness check, and
/// INB-15's empty states had no package manager either. Every surface that
/// names a source app calls [sourceAppLabel] and nothing else does the work.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/source_app.dart';
import '../services/services.dart';
import '../theme.dart';

/// INB-1's label chain, resolved.
///
/// [identity] is what the package manager said, or null where nothing has been
/// asked yet; [app] is the `apps` row, null where the listener never wrote one.
/// The package name is the last fallback and is never empty, so this always
/// returns something a row can draw.
String sourceAppLabel({
  required String package,
  SourceAppIdentity? identity,
  SourceApp? app,
}) {
  final String? fromPackageManager =
      identity?.presence == PackagePresence.installed ? identity?.label : null;
  if (fromPackageManager != null && fromPackageManager.isNotEmpty) {
    return fromPackageManager;
  }
  final String stored = app?.label ?? '';
  if (stored.isNotEmpty) return stored;
  return package;
}

/// The package manager seam, or null where nothing put [DeviceServices] in the
/// tree.
///
/// Null is a supported state and not an error: [sourceAppLabel] already ends in
/// the label the listener stored and then the package name, and INB-16 says the
/// app never claims an app is gone unless it can see that it is — so a widget
/// with no way to ask simply says less. It is what lets one of INB-15's states
/// be drawn on its own, outside the app's own tree.
PackageInfoService? sourceAppPackages(BuildContext context) {
  try {
    return Provider.of<DeviceServices>(context, listen: false).packages;
  } on ProviderNotFoundException {
    return null;
  }
}

/// Resolves a set of packages' identities and rebuilds when the answers arrive.
///
/// [PackageInfoService.lookupCached] answers synchronously for a package
/// already resolved, which is what keeps a scrolled list from flashing the
/// generic icon on every row it re-creates; only a package nobody has asked
/// about yet costs a frame.
///
/// One resolver for every surface that names a source app, for the same reason
/// [sourceAppLabel] is one chain: a second one would be a second place to
/// forget the resume below.
class SourceAppFaces extends StatefulWidget {
  const SourceAppFaces({
    required this.packages,
    required this.builder,
    super.key,
  });

  final List<String> packages;

  /// A package missing from [identities] is one nothing has been asked about
  /// yet — which is not `unknown`, and a caller that drew INB-16's
  /// `sourceAppGone` line on it would be stating an uninstall it has not seen.
  final Widget Function(
    BuildContext context,
    Map<String, SourceAppIdentity> identities,
  )
  builder;

  @override
  State<SourceAppFaces> createState() => _SourceAppFacesState();
}

class _SourceAppFacesState extends State<SourceAppFaces>
    with WidgetsBindingObserver {
  final Map<String, SourceAppIdentity> _identities =
      <String, SourceAppIdentity>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resolve(widget.packages);
  }

  @override
  void didUpdateWidget(SourceAppFaces oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A recycled row can be handed a different package between frames, and an
    // empty state's sentence can be handed a different set.
    if (listEquals(oldWidget.packages, widget.packages)) return;
    _identities.removeWhere(
      (String package, _) => !widget.packages.contains(package),
    );
    _resolve(widget.packages);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// INB-16: an app can be uninstalled while Replybox is in the background and
  /// nothing tells it, so the answers are asked again on resume rather than
  /// watched for. Without this a row kept the icon and the name of an app that
  /// is gone, and never grew the `sourceAppGone` line, for the whole of the
  /// next foreground — the app's entry point drops what the package manager
  /// said on the same resume, and nothing here was listening for it.
  ///
  /// Through a microtask rather than straight away, and that is the whole of
  /// why it works: every lifecycle observer is notified in one synchronous
  /// pass, so a microtask scheduled from inside it runs after the *last* of
  /// them. The entry point's `forgetAll` has therefore happened by the time
  /// this asks, whatever order the observers were registered in — which is an
  /// ordering this file would otherwise be depending on silently.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    scheduleMicrotask(() {
      if (mounted) _resolve(widget.packages, fromCache: false);
    });
  }

  /// Asks about exactly [packages] and nothing else (INB-20: the app never
  /// enumerates installed packages).
  ///
  /// [fromCache] is false on a resume, where the held answer is the stale one
  /// this is being called to replace. The old identity stays on screen until
  /// the new one lands, so a resume never flashes the generic icon down a list
  /// that is about to draw the same icons again.
  void _resolve(List<String> packages, {bool fromCache = true}) {
    if (packages.isEmpty) return;
    final PackageInfoService? service = sourceAppPackages(context);
    if (service == null) return;
    for (final String package in packages) {
      if (fromCache) {
        if (_identities.containsKey(package)) continue;
        final SourceAppIdentity? cached = service.lookupCached(package);
        if (cached != null) {
          _identities[package] = cached;
          continue;
        }
      }
      // `lookup` never throws (INB-16 turns every failure into `unknown`), so
      // there is no error branch to write and nothing to swallow.
      service.lookup(package).then((SourceAppIdentity identity) {
        if (!mounted || !widget.packages.contains(identity.package)) return;
        setState(() => _identities[identity.package] = identity);
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _identities);
}

/// [SourceAppFaces] for the one package a row, a chip or a control is about.
///
/// A wrapper and not a second implementation: the resume, the cache and
/// INB-20's "ask about these and nothing else" are written once, above.
class SourceAppFace extends StatelessWidget {
  const SourceAppFace({
    required this.package,
    required this.builder,
    super.key,
  });

  final String package;

  /// [identity] is null until the first answer arrives. Null is not `unknown`:
  /// it means nothing has been asked, and a caller that drew INB-16's
  /// `sourceAppGone` line on it would be stating an uninstall it has not seen.
  final Widget Function(BuildContext context, SourceAppIdentity? identity)
  builder;

  @override
  Widget build(BuildContext context) => SourceAppFaces(
    packages: <String>[package],
    builder:
        (BuildContext context, Map<String, SourceAppIdentity> identities) =>
            builder(context, identities[package]),
  );
}

/// The source app's icon, at [size], with INB-1's generic fallback.
///
/// Decorative by default: in a conversation row the whole row carries one
/// semantic label (INB-23), and an icon that announced itself separately would
/// make a screen reader read the app's name twice.
class SourceAppIconImage extends StatelessWidget {
  const SourceAppIconImage({
    required this.identity,
    required this.size,
    this.semanticLabel,
    super.key,
  });

  final SourceAppIdentity? identity;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Uint8List? icon = identity?.icon;
    final Widget image = icon == null
        ? Icon(
            // INB-1's generic source icon, and INB-16's fallback for an app
            // that is gone: a notification, which is the only thing the app
            // ever actually saw from this package.
            Icons.notifications_outlined,
            size: size * 0.72,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          )
        : Image.memory(
            icon,
            width: size,
            height: size,
            // The same `Uint8List` instance comes back for every row from one
            // app, so this decodes once per app and not once per row.
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (BuildContext context, Object _, StackTrace? _) =>
                Icon(Icons.notifications_outlined, size: size * 0.72),
          );
    final Widget sized = SizedBox(
      width: size,
      height: size,
      child: Center(child: image),
    );
    if (semanticLabel == null) {
      return ExcludeSemantics(child: sized);
    }
    return Semantics(label: semanticLabel, image: true, child: sized);
  }
}

/// INB-1's leading circle: up to two initials, badged with the source app's
/// icon — or the app icon alone where the row has no name to take initials from
/// (INB-2, INB-12).
///
/// Decoration, not a control, and excluded from the semantic tree on purpose
/// (INB-23's correction of 22 September 2026). Both halves restate what the
/// row's own label already says — the title the initials came from, and the app
/// the badge stands for — so giving them nodes of their own would make a reader
/// hear one row as three, and sizing an 18dp badge up to a 48dp target would
/// put a tap area over a decoration that does nothing.
class SourceAppAvatar extends StatelessWidget {
  const SourceAppAvatar({
    required this.identity,
    required this.initials,
    super.key,
  });

  final SourceAppIdentity? identity;

  /// Empty where the circle is the app icon alone (INB-2, INB-12).
  final String initials;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    if (initials.isEmpty) {
      // INB-2 and INB-12: the app icon alone, with no initials. Drawn at the
      // full circle size rather than as a badge on an empty circle, so an
      // unnamed conversation reads as "from this app" and not as a name the
      // app failed to draw.
      return ExcludeSemantics(
        child: SizedBox(
          width: Metrics.avatar,
          height: Metrics.avatar,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: SourceAppIconImage(
                identity: identity,
                size: Metrics.avatar * 0.6,
              ),
            ),
          ),
        ),
      );
    }

    return ExcludeSemantics(
      child: SizedBox(
        width: Metrics.avatar,
        height: Metrics.avatar,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    initials,
                    // Not scaled with the text scale: the circle is a fixed
                    // size and two initials at 1.3x would spill out of it.
                    textScaler: TextScaler.noScaling,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            // Mirrors with the language (INB-23, LANG-5).
            PositionedDirectional(
              bottom: -2,
              end: -2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: SourceAppIconImage(
                    identity: identity,
                    size: Metrics.appBadge,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
