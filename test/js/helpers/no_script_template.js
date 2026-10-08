// ESLint rule: a multi-line template literal that parses as JavaScript is a
// script the linter cannot read. Write it as a function and pass that
// (`page.evaluate(fn)`, `scriptOf(fn, ...args)`) so it is linted with the rest.
// An HTML page keeps its script tags, and a sample in another language (Dart,
// Kotlin) does not parse. A gate over source text (rung 5): nothing in the type
// of a string says it is not JavaScript.

const vm = require('node:vm');

// A statement list, or a function body (a fragment that returns).
function parses(text) {
  for (const source of [text, `(function () {\n${text}\n})`]) {
    try {
      new vm.Script(source);
      return true;
    } catch (e) {
      if (!(e instanceof SyntaxError)) throw e;
    }
  }
  return false;
}

module.exports = {
  meta: {
    type: 'problem',
    schema: [],
    messages: {
      script: 'This template is a script ESLint cannot read: write it as a function '
        + 'and pass that, or serialize it with scriptOf (test/js/helpers/script_of.js).',
    },
  },
  create(context) {
    return {
      TemplateLiteral(node) {
        if (node.loc.start.line === node.loc.end.line) return;
        const text = node.quasis.map((q) => q.value.raw).join('__x');
        if (/^\s*</.test(text) || !/[;({=]/.test(text) || !parses(text)) return;
        context.report({ node, messageId: 'script' });
      },
    };
  },
};
