import 'dart:convert';
import 'dart:io';

import 'package:webspace/services/model_names.dart';

/// One marked step: the `formal/activation.tla` action it is, the flow
/// that took it (counted from 1, as the model numbers its inputs), the
/// branch it took, the site it chose (0 for none), and the projected state
/// after it.
typedef StepMark = ({
  String action,
  int flow,
  String outcome,
  int site,
  Map<String, Object> state,
});

/// The marked steps of every schedule a test ran, merged into one trie per
/// model configuration, for `formal/trace/check_steps.sh` to replay against
/// `formal/activation.tla`, step for step.
final class StepTraces {
  StepTraces._();

  static final StepTraces instance = StepTraces._();

  final Map<String, _Trie> _tries = {};

  /// Whether a run asked for the traces (`MODEL_STEPS_DIR`), so a world
  /// records nothing it would throw away.
  bool get asked => (Platform.environment['MODEL_STEPS_DIR'] ?? '').isNotEmpty;

  /// One schedule's run under the model configuration named [config]
  /// with its [constants], from [start].
  void add({
    required String config,
    required TraceConstants constants,
    required Map<String, Object> start,
    required List<StepMark> steps,
  }) {
    final trie = _tries[config] ??= _Trie(constants);
    assert(
      jsonEncode(_Trie.fixed(trie.constants)) ==
          jsonEncode(_Trie.fixed(constants)),
      'two configurations of the model are named $config',
    );
    var node = trie.node(
      parent: -1,
      label: ['start', 0, '', 0],
      state: trie.state(start),
    );
    for (final m in steps) {
      node = trie.node(
        parent: node,
        label: [m.action, m.flow, m.outcome, m.site],
        state: trie.state(m.state),
      );
    }
  }

  /// Writes `$MODEL_STEPS_DIR/<config>.json` for each configuration.
  void writeIfAsked() {
    final dir = Platform.environment['MODEL_STEPS_DIR'];
    if (dir == null || dir.isEmpty) return;
    Directory(dir).createSync(recursive: true);
    for (final MapEntry(key: config, value: trie) in _tries.entries) {
      File('$dir/$config.json').writeAsStringSync(jsonEncode(trie.toJson()));
    }
  }
}

/// What a configuration of the model fixes for a page: the shape the
/// replay projects the state to (how many sites, whether their tabs and
/// containers are followed), and the value of each of the model's
/// constants the page sets, as TLA+ text by the constant's name; one the
/// base module's definition gives is left out.
typedef TraceConstants = ({
  int sites,
  bool tabbed,
  bool boxed,
  Map<ModelConst, String> tla,
});

final class _Trie {
  _Trie(this.constants);

  final TraceConstants constants;
  final Map<String, int> _states = {};
  final Map<String, int> _nodes = {};
  final List<List<Object>> _rows = [];

  int state(Map<String, Object> s) =>
      _states.putIfAbsent(jsonEncode(s), () => _states.length);

  int node({
    required int parent,
    required List<Object> label,
    required int state,
  }) {
    final row = [parent, ...label, state];
    return _nodes.putIfAbsent(jsonEncode(row), () {
      _rows.add(row);
      return _rows.length - 1;
    });
  }

  static Map<String, Object> fixed(TraceConstants c) => {
    'sites': c.sites,
    'tabbed': c.tabbed,
    'boxed': c.boxed,
    'constants': {
      for (final MapEntry(key: k, value: v) in c.tla.entries) k.tla: v,
    },
  };

  Map<String, Object> toJson() => {
    ...fixed(constants),
    'states': [for (final s in _states.keys) jsonDecode(s)],
    'nodes': _rows,
  };
}
