// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';
import 'dart:math';

import 'package:analyzer/analyzer.dart';
import 'package:linter/src/analyzer.dart';

final int _pipeCodeUnit = '|'.codeUnitAt(0);
final int _slashCodeUnit = '\\'.codeUnitAt(0);

// Number of times to perform linting to get stable benchmarks.
const benchmarkRuns = 10;

String getLineContents(int lineNumber, AnalysisError error) {
  String path = error.source.fullName;
  File file = new File(path);
  String failureDetails;
  if (!file.existsSync()) {
    failureDetails = 'file at $path does not exist';
  } else {
    var lines = file.readAsLinesSync();
    var lineIndex = lineNumber - 1;
    if (lines.length > lineIndex) {
      return lines[lineIndex];
    }
    failureDetails =
        'line index ($lineIndex), outside of file line range (${lines.length})';
  }
  throw new StateError('Unable to get contents for line: $failureDetails');
}

String pluralize(String word, int count) =>
    "$count ${count == 1 ? '$word' : '${word}s'}";
String shorten(String fileRoot, String fullName) {
  if (fileRoot == null || !fullName.startsWith(fileRoot)) {
    return fullName;
  }
  return fullName.substring(fileRoot.length);
}

String _escapePipe(String input) {
  var result = new StringBuffer();
  for (var c in input.codeUnits) {
    if (c == _slashCodeUnit || c == _pipeCodeUnit) {
      result.write('\\');
    }
    result.writeCharCode(c);
  }
  return result.toString();
}

class DetailedReporter extends SimpleFormatter {
  DetailedReporter(
      Iterable<AnalysisErrorInfo> errors, LintFilter filter, IOSink out,
      {int fileCount,
      int elapsedMs,
      String fileRoot,
      bool showStatistics: false,
      bool machineOutput: false,
      quiet: false})
      : super(errors, filter, out,
            fileCount: fileCount,
            fileRoot: fileRoot,
            elapsedMs: elapsedMs,
            showStatistics: showStatistics,
            machineOutput: machineOutput,
            quiet: quiet);

  @override
  writeLint(AnalysisError error, {int offset, int line, int column}) {
    super.writeLint(error, offset: offset, column: column, line: line);

    if (!machineOutput) {
      var contents = getLineContents(line, error);
      out.writeln(contents);

      var spaces = column - 1;
      var arrows = max(1, min(error.length, contents.length - spaces));

      var result = '${" " * spaces}${"^" * arrows}';
      out.writeln(result);
    }
  }
}

abstract class ReportFormatter {
  factory ReportFormatter(
          Iterable<AnalysisErrorInfo> errors, LintFilter filter, IOSink out,
          {int fileCount,
          int elapsedMs,
          String fileRoot,
          bool showStatistics: false,
          bool machineOutput: false,
          bool quiet: false}) =>
      new DetailedReporter(errors, filter, out,
          fileCount: fileCount,
          fileRoot: fileRoot,
          elapsedMs: elapsedMs,
          showStatistics: showStatistics,
          machineOutput: machineOutput,
          quiet: quiet);

  write();
}

/// Simple formatter suitable for subclassing.
class SimpleFormatter implements ReportFormatter {
  final IOSink out;
  final Iterable<AnalysisErrorInfo> errors;
  final LintFilter filter;

  int errorCount = 0;
  int filteredLintCount = 0;

  final int fileCount;
  final int elapsedMs;
  final String fileRoot;
  final bool showStatistics;
  final bool machineOutput;
  final bool quiet;

  /// Cached for the purposes of statistics report formatting.
  int _summaryLength = 0;

  Map<String, int> stats = <String, int>{};

  SimpleFormatter(this.errors, this.filter, this.out,
      {this.fileCount,
      this.fileRoot,
      this.elapsedMs,
      this.showStatistics: false,
      this.quiet: false,
      this.machineOutput: false});

  /// Override to influence error sorting
  int compare(AnalysisError error1, AnalysisError error2) {
    // Severity
    int compare = error2.errorCode.errorSeverity
        .compareTo(error1.errorCode.errorSeverity);
    if (compare != 0) {
      return compare;
    }
    // Path
    compare = Comparable.compare(error1.source.fullName.toLowerCase(),
        error2.source.fullName.toLowerCase());
    if (compare != 0) {
      return compare;
    }
    // Offset
    return error1.offset - error2.offset;
  }

  @override
  write() {
    writeLints();
    writeSummary();
    if (showStatistics) {
      out.writeln('');
      writeStatistics();
    }
    out.writeln('');
  }

  void writeCounts() {
    var codes = stats.keys.toList()..sort();
    var largestCountGuess = 8;
    var longest =
        codes.fold(0, (int prev, element) => max(prev, element.length));
    var tableWidth = max(_summaryLength, longest + largestCountGuess);
    var pad = tableWidth - longest;
    var line = ''.padLeft(tableWidth, '-');
    out.writeln(line);
    out.writeln('Counts');
    out.writeln(line);
    codes.forEach((c) {
      out
        ..write('${c.padRight(longest)}')
        ..writeln('${stats[c].toString().padLeft(pad)}');
    });
    out.writeln(line);
  }

  void writeLint(AnalysisError error, {int offset, int line, int column}) {
    if (machineOutput) {
      //INFO|LINT|constant_identifier_names|test/engine_test.dart|91|22|3|Prefer using lowerCamelCase for constant names.
      out
        ..write(error.errorCode.errorSeverity)
        ..write('|')
        ..write(error.errorCode.type)
        ..write('|')
        ..write(error.errorCode.name)
        ..write('|')
        ..write(_escapePipe(error.source.fullName))
        ..write('|')
        ..write(line)
        ..write('|')
        ..write(column)
        ..write('|')
        ..write(error.length)
        ..write('|')
        ..writeln(_escapePipe(error.message));
    } else {
      // test/engine_test.dart 452:9 [lint] DO name types using UpperCamelCase.
      out
        ..write('${shorten(fileRoot, error.source.fullName)} ')
        ..write('$line:$column ')
        ..writeln('[${error.errorCode.type.displayName}] ${error.message}');
    }
  }

  void writeLints() {
    errors.forEach((info) => (info.errors.toList()..sort(compare)).forEach((e) {
          if (filter != null && filter.filter(e)) {
            filteredLintCount++;
          } else {
            ++errorCount;
            if (!quiet) {
              _writeLint(e, info.lineInfo);
            }
            _recordStats(e);
          }
        }));
    if (!quiet) {
      out.writeln();
    }
  }

  void writeStatistics() {
    writeCounts();
    writeTimings();
  }

  void writeSummary() {
    var summary = '${pluralize("file", fileCount)} analyzed, '
        '${pluralize("issue", errorCount)} found'
        "${filteredLintCount == 0 ? '' : ' ($filteredLintCount filtered)'}, in $elapsedMs ms.";
    out.writeln(summary);
    // Cache for output table sizing
    _summaryLength = summary.length;
  }

  void writeTimings() {
    Map<String, Stopwatch> timers = lintRegistry.timers;
    List<_Stat> timings = timers.keys
        .map((t) => new _Stat(t, timers[t].elapsedMilliseconds))
        .toList();
    _writeTimings(out, timings, _summaryLength);
  }

  void _recordStats(AnalysisError error) {
    var codeName = error.errorCode.name;
    stats.putIfAbsent(codeName, () => 0);
    stats[codeName]++;
  }

  void _writeLint(AnalysisError error, LineInfo lineInfo) {
    var offset = error.offset;
    var location = lineInfo.getLocation(offset);
    var line = location.lineNumber;
    var column = location.columnNumber;

    writeLint(error, offset: offset, column: column, line: line);
  }
}

writeBenchmarks(IOSink out, List<File> filesToLint, LinterOptions lintOptions) {
  Map<String, int> timings = <String, int>{};
  for (int i = 0; i < benchmarkRuns; ++i) {
    new DartLinter(lintOptions).lintFiles(filesToLint);
    lintRegistry.timers.forEach((n, t) {
      int timing = t.elapsedMilliseconds;
      int previous = timings[n];
      if (previous == null) {
        timings[n] = timing;
      } else {
        timings[n] = min(previous, timing);
      }
    });
  }

  List<_Stat> stats =
      timings.keys.map((t) => new _Stat(t, timings[t])).toList();
  _writeTimings(out, stats, 0);
}

void _writeTimings(IOSink out, List<_Stat> timings, int summaryLength) {
  List<String> names = timings.map((s) => s.name).toList();

  int longestName = names.fold(0, (prev, element) => max(prev, element.length));
  int longestTime = 8;
  int tableWidth = max(summaryLength, longestName + longestTime);
  int pad = tableWidth - longestName;
  String line = ''.padLeft(tableWidth, '-');

  out
    ..writeln()
    ..writeln(line)
    ..writeln('${'Timings'.padRight(longestName)}${'ms'.padLeft(pad)}')
    ..writeln(line);
  int totalTime = 0;

  timings.sort();
  for (_Stat stat in timings) {
    totalTime += stat.elapsed;
    // TODO: Shame timings slower than 100ms?
    // TODO: Present both total times and time per count?
    out.writeln(
        '${stat.name.padRight(longestName)}${stat.elapsed.toString().padLeft(pad)}');
  }
  out
    ..writeln(line)
    ..writeln(
        '${'Total'.padRight(longestName)}${totalTime.toString().padLeft(pad)}')
    ..writeln(line);
}

class _Stat implements Comparable<_Stat> {
  final String name;
  final int elapsed;

  _Stat(this.name, this.elapsed);

  @override
  int compareTo(_Stat other) => other.elapsed - elapsed;
}
