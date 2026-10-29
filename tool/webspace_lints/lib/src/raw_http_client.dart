import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';

/// LEAK-002: a connection the app opens goes through the outbound seam, so
/// the proxy a site or the app set is applied to it. In `lib/`, a client of
/// package:http or dart:io, or one of package:http's one-shot calls, is
/// made only inside an `OutboundHttpFactory`, the seam itself; anywhere else
/// it would reach the network on the device's own address.
class RawHttpClient extends AnalysisRule {
  static const code = LintCode(
    'raw_http_client',
    "'{0}' opens a connection outside the outbound seam, so no proxy is "
        'applied to it.',
    correctionMessage:
        'Take the client from outboundHttp.clientFor(route); a connection '
        'that must go direct says why in an ignore listed in '
        'test/js/lint_ignores.test.js.',
    severity: DiagnosticSeverity.ERROR,
  );

  RawHttpClient()
    : super(
        name: 'raw_http_client',
        description: 'A connection goes through the outbound seam.',
      );

  @override
  DiagnosticCode get diagnosticCode => code;

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    if (!context.isInLibDir) return;
    final visitor = _Visitor(rule: this);
    registry
      ..addInstanceCreationExpression(this, visitor)
      ..addMethodInvocation(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  _Visitor({required this.rule});

  final RawHttpClient rule;

  /// package:http's clients and dart:io's, which each open sockets.
  static const _clients = {
    'Client',
    'IOClient',
    'RetryClient',
    'BrowserClient',
    'HttpClient',
  };

  /// package:http's top-level calls, each on a client of its own.
  static const _calls = {
    'get',
    'post',
    'head',
    'put',
    'patch',
    'delete',
    'read',
    'readBytes',
  };

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final made = node.constructorName.element?.enclosingElement;
    if (made == null || !_clients.contains(made.name) || !_opensSockets(made)) {
      return;
    }
    if (_inSeam(node)) return;
    rule.reportAtNode(node, arguments: [made.name ?? 'Client']);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final called = node.methodName.element;
    if (called is! TopLevelFunctionElement ||
        !_calls.contains(called.name) ||
        !_inHttp(called)) {
      return;
    }
    if (_inSeam(node)) return;
    rule.reportAtNode(node.methodName, arguments: ['http.${called.name}']);
  }

  static bool _opensSockets(Element element) {
    final uri = element.library?.uri.toString() ?? '';
    return _inHttp(element) || uri == 'dart:io' || uri == 'dart:_http';
  }

  static bool _inHttp(Element element) =>
      element.library?.uri.toString().startsWith('package:http/') ?? false;

  /// Whether [node] is inside a class that implements `OutboundHttpFactory`.
  static bool _inSeam(AstNode node) {
    final owner = node
        .thisOrAncestorOfType<ClassDeclaration>()
        ?.declaredFragment
        ?.element;
    if (owner == null) return false;
    return owner.allSupertypes.any(
      (t) => t.element.name == 'OutboundHttpFactory',
    );
  }
}
