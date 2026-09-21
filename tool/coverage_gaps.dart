// Lists the lines no test runs in the Dart files this branch changed, so the
// pre-merge coverage check doesn't mean reading coverage/lcov.info.
//
//   flutter test --coverage -r failures-only
//   dart tool/coverage_gaps.dart [base]
//
// [base] defaults to origin/main. Uncommitted and new files count as changed;
// the generated localizations don't.
import 'dart:io';

void main(List<String> args) {
  final base = args.isEmpty ? 'origin/main' : args.first;
  final report = File('coverage/lcov.info');
  if (!report.existsSync()) {
    stderr.writeln('No coverage/lcov.info: run flutter test --coverage first.');
    exit(1);
  }
  final changed = changedFiles(base);
  if (changed.isEmpty) {
    stdout.writeln('No Dart files in lib/ changed since $base.');
    return;
  }
  final coverage = readLcov(report.readAsLinesSync());
  for (final file in changed) {
    final lines = coverage[file];
    if (lines == null) {
      stdout.writeln('$file: no test loads it');
      continue;
    }
    final missed = [
      for (final MapEntry(:key, :value) in lines.entries)
        if (value == 0) key,
    ]..sort();
    if (missed.isEmpty) {
      stdout.writeln('$file: 100%');
      continue;
    }
    final percent = (lines.length - missed.length) * 100 ~/ lines.length;
    stdout.writeln('$file: $percent%, missed ${ranges(missed)}');
  }
}

/// Dart files under lib/ that differ from where this branch left [base].
List<String> changedFiles(String base) {
  String git(List<String> args) {
    final result = Process.runSync('git', args);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      exit(1);
    }
    return result.stdout as String;
  }

  final mergeBase = git(['merge-base', base, 'HEAD']).trim();
  final paths = {
    ...git(['diff', '--name-only', '--diff-filter=d', mergeBase, '--', 'lib'])
        .split('\n'),
    ...git(['ls-files', '--others', '--exclude-standard', '--', 'lib'])
        .split('\n'),
  };
  return [
    for (final path in paths.map((p) => p.trim()))
      if (path.endsWith('.dart') &&
          !path.startsWith('lib/l10n/app_localizations'))
        path,
  ]..sort();
}

/// Hit counts by line number, for each file by its path from the project root.
Map<String, Map<int, int>> readLcov(List<String> lines) {
  final coverage = <String, Map<int, int>>{};
  Map<int, int>? file;
  for (final line in lines) {
    if (line.startsWith('SF:')) {
      var path = line.substring(3).replaceAll('\\', '/');
      final lib = path.indexOf('/lib/');
      if (!path.startsWith('lib/') && lib >= 0) path = path.substring(lib + 1);
      file = coverage.putIfAbsent(path, () => {});
    } else if (line.startsWith('DA:') && file != null) {
      final parts = line.substring(3).split(',');
      final number = int.parse(parts[0]);
      file[number] = (file[number] ?? 0) + int.parse(parts[1]);
    }
  }
  return coverage;
}

/// 3, 4, 5, 9 → "3-5, 9".
String ranges(List<int> lines) {
  final parts = <String>[];
  var start = lines.first, end = start;
  for (final line in lines.skip(1)) {
    if (line == end + 1) {
      end = line;
      continue;
    }
    parts.add(start == end ? '$start' : '$start-$end');
    start = end = line;
  }
  parts.add(start == end ? '$start' : '$start-$end');
  return parts.join(', ');
}
