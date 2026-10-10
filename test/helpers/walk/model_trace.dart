import 'dart:convert';
import 'dart:io';

/// A Dart engine's steps in the terms of the TLA+ module that models it, for
/// `formal/trace/check_walk.sh` to hold against the module's state graph:
/// every step must be a path the model allows, and every transition the
/// model has must be taken by some step or listed as uncovered with a reason.
final class ModelTrace {
  ModelTrace({required this.module, required this.config});

  /// The module under `formal/`, without `.tla`.
  final String module;

  /// The `.cfg` whose constants bound the graph, under `formal/`.
  final String config;

  final Set<String> _steps = {};

  /// One step: the observed variables went from [from] to [to], values in
  /// TLA+ syntax (`1`, `{1, 2}`, `"painted"`, `TRUE`), by a path whose action
  /// labels match [path]: space-separated names, each optionally `*` (any
  /// number) or `?` (at most one). An empty [path] is a stutter: the observed
  /// variables did not move.
  void step({
    required Map<String, String> from,
    required String path,
    required Map<String, String> to,
  }) {
    assert(
      from.keys.toSet().containsAll(to.keys) &&
          to.keys.toSet().containsAll(from.keys),
      'a step observes the same variables before and after',
    );
    _steps.add(jsonEncode({'from': from, 'path': path, 'to': to}));
  }

  /// Writes the trace to `$MODEL_WALK_DIR/<module>.json` when that is set,
  /// as CI sets it before `formal/trace/check_walk.sh` reads the directory.
  void writeIfAsked() {
    final dir = Platform.environment['MODEL_WALK_DIR'];
    if (dir == null || dir.isEmpty) return;
    Directory(dir).createSync(recursive: true);
    File('$dir/$module.json').writeAsStringSync(
      jsonEncode({
        'module': module,
        'config': config,
        'steps': [for (final s in _steps) jsonDecode(s)],
      }),
    );
  }
}

/// A TLA+ set of integers, as TLC prints one.
String tlaIntSet(Iterable<int> values) =>
    '{${(values.toList()..sort()).join(', ')}}';
