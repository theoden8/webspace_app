(function() {
  var RULES;
  try { RULES = JSON.parse('[{"selector":[{"type":"css-selector","arg":"div.fp_probe_proc_remove:has-text(REMOVE-ME)"}],"action":"remove"},{"selector":[{"type":"css-selector","arg":"div.fp_probe_proc_upward:has-text(LEAF):upward(1)"}],"action":"remove"},{"selector":[{"type":"css-selector","arg":"div.fp_probe_proc_style:has-text(Sponsored)"}],"action":{"type":"style","arg":"outline: 2px solid red !important"}},{"selector":[{"type":"css-selector","arg":"div.fp_probe_proc_remove_attr[data-tracker]"}],"action":{"type":"remove-attr","arg":"data-tracker"}},{"selector":[{"type":"css-selector","arg":"div.fp_probe_proc_remove_class.fp_probe_remove_me"}],"action":{"type":"remove-class","arg":"fp_probe_remove_me"}}]'); } catch (e) { return; }
  if (!RULES || !RULES.length) return;

  // adblock-rust emits the `selector` chain with procedural pseudos
  // embedded INSIDE the css-selector arg, not split into separate
  // operators. e.g. `##div.foo:has-text(X):upward(2):remove()` comes
  // back as `selector=[{type:"css-selector", arg:"div.foo:has-text(X)
  // :upward(2)"}], action:"remove"`. Native querySelectorAll throws
  // on `:has-text(` (it's a uBO extension, not standard CSS), so
  // without this splitter the whole rule is dropped at runtime.
  //
  // Returns `{css: pureCssPrefix, ops: [{type, arg}, ...]}`. The
  // pure-CSS prefix (possibly "*" if no CSS portion exists) is queried
  // first; each subsequent op is applied as a filter.
  var ABP_PSEUDOS = ['has-text', 'contains', '-abp-has-text',
      '-abp-contains', 'upward', 'nth-ancestor'];
  function splitAbpPseudos(sel) {
    var ops = [];
    var css = sel;
    while (true) {
      var earliest = -1;
      var earliestPseudo = null;
      for (var pi = 0; pi < ABP_PSEUDOS.length; pi++) {
        var token = ':' + ABP_PSEUDOS[pi] + '(';
        var i = css.indexOf(token);
        if (i >= 0 && (earliest < 0 || i < earliest)) {
          earliest = i;
          earliestPseudo = ABP_PSEUDOS[pi];
        }
      }
      if (earliest < 0) break;
      var startArg = earliest + (':' + earliestPseudo + '(').length;
      var depth = 1;
      var j = startArg;
      while (j < css.length && depth > 0) {
        if (css.charAt(j) === '(') depth++;
        else if (css.charAt(j) === ')') depth--;
        j++;
      }
      if (depth !== 0) break; // unbalanced — give up, treat as CSS
      var arg = css.substring(startArg, j - 1);
      // Normalise aliases.
      var opType = earliestPseudo;
      if (opType === 'contains' || opType === '-abp-contains' ||
          opType === '-abp-has-text') opType = 'has-text';
      if (opType === 'nth-ancestor') opType = 'upward';
      ops.push({type: opType, arg: arg});
      css = css.substring(0, earliest) + css.substring(j);
    }
    return {css: css || '*', ops: ops};
  }

  // Apply one operator to a candidate element set. Returns the
  // (possibly narrowed) array; or null when the operator isn't
  // supported, which skips the whole rule.
  function applyOp(elements, op) {
    var type = op && op.type;
    var arg = op && op.arg;
    if (type === 'css-selector') {
      // adblock-rust ships ABP pseudos embedded in this arg. Split
      // them out so the pure CSS portion goes through
      // querySelectorAll and each pseudo runs as its own filter step.
      var split = splitAbpPseudos(arg);
      var base;
      if (elements === null) {
        try { base = Array.from(document.querySelectorAll(split.css)); }
        catch (_) { return null; }
      } else {
        base = [];
        for (var i = 0; i < elements.length; i++) {
          try {
            var found = elements[i].querySelectorAll(split.css);
            for (var j = 0; j < found.length; j++) base.push(found[j]);
          } catch (_) {}
        }
      }
      var result = base;
      for (var k = 0; k < split.ops.length; k++) {
        result = applyOp(result, split.ops[k]);
        if (result === null) return null;
      }
      return result;
    }
    if (type === 'has-text') {
      if (elements === null) return null;
      // arg may be /regex/ or plain text; uBO supports both.
      var re = null;
      if (typeof arg === 'string' && arg.length > 2 &&
          arg.charAt(0) === '/' && arg.charAt(arg.length - 1) === '/') {
        try { re = new RegExp(arg.slice(1, -1)); } catch (_) { return null; }
      }
      return elements.filter(function(el) {
        var t = el.textContent || '';
        return re ? re.test(t) : t.indexOf(arg) >= 0;
      });
    }
    if (type === 'upward') {
      if (elements === null) return null;
      // Numeric arg = walk N parents. String arg = walk until ancestor
      // matches the CSS selector. uBO supports both; the engine's
      // string-typed arg disambiguates by digit check.
      var asInt = parseInt(arg, 10);
      var isInt = !isNaN(asInt) && /^\d+$/.test(arg);
      return elements.map(function(el) {
        if (isInt) {
          var p = el;
          for (var n = 0; n < asInt && p; n++) p = p.parentElement;
          return p;
        }
        var cur = el.parentElement;
        while (cur) {
          try { if (cur.matches(arg)) return cur; } catch (_) { return null; }
          cur = cur.parentElement;
        }
        return null;
      }).filter(function(el) { return el != null; });
    }
    if (type === 'min-text-length') {
      if (elements === null) return null;
      var n = parseInt(arg, 10);
      if (isNaN(n)) return null;
      return elements.filter(function(el) {
        return (el.textContent || '').length >= n;
      });
    }
    if (type === 'matches-path') {
      if (elements === null) return null;
      // Engine only includes the rule when the page URL matches, but
      // we still honour the operator here for safety. arg may be a
      // string or /regex/ literal (same as has-text).
      var path = location.pathname + location.search;
      var ok = false;
      if (typeof arg === 'string' && arg.length > 2 &&
          arg.charAt(0) === '/' && arg.charAt(arg.length - 1) === '/') {
        try { ok = new RegExp(arg.slice(1, -1)).test(path); } catch (_) {}
      } else {
        ok = path.indexOf(arg) >= 0;
      }
      return ok ? elements : [];
    }
    // matches-css / matches-css-before / matches-css-after / matches-attr
    // / xpath: unsupported. Drop the rule rather than ship a partial
    // match that might over-block.
    return null;
  }

  function applyAction(el, action) {
    // Default action (no `action` key) = hide.
    if (!action) {
      el.style.setProperty('display', 'none', 'important');
      return;
    }
    if (action === 'remove' || (action && action.type === 'remove')) {
      try { el.remove(); } catch (_) {}
      return;
    }
    if (action && action.type === 'style' && typeof action.arg === 'string') {
      try {
        var cur = el.getAttribute('style') || '';
        el.setAttribute('style', cur + ';' + action.arg);
      } catch (_) {}
      return;
    }
    if (action && action.type === 'remove-attr' &&
        typeof action.arg === 'string') {
      try { el.removeAttribute(action.arg); } catch (_) {}
      return;
    }
    if (action && action.type === 'remove-class' &&
        typeof action.arg === 'string') {
      try { el.classList.remove(action.arg); } catch (_) {}
      return;
    }
  }

  function runRule(rule) {
    var ops = rule.selector;
    if (!ops || !ops.length) return;
    var elements = null;
    for (var i = 0; i < ops.length; i++) {
      elements = applyOp(elements, ops[i]);
      if (elements === null) return;  // unsupported op → skip
      if (elements.length === 0) return;  // narrowed to empty
    }
    for (var k = 0; k < elements.length; k++) {
      applyAction(elements[k], rule.action);
    }
  }

  function runAll() {
    for (var i = 0; i < RULES.length; i++) {
      try { runRule(RULES[i]); } catch (_) {}
    }
  }

  // Debounced re-run on DOM bursts (SPA route changes, infinite
  // scroll). Same envelope the generic cosmetic shim uses so the
  // observer overhead stays predictable.
  var pending = false;
  function schedule() {
    if (pending) return;
    pending = true;
    setTimeout(function() {
      pending = false;
      runAll();
    }, 50);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      runAll();
      try {
        new MutationObserver(schedule).observe(document.body, {
          childList: true,
          subtree: true,
        });
      } catch (_) {}
    });
  } else {
    runAll();
    try {
      new MutationObserver(schedule).observe(document.body, {
        childList: true,
        subtree: true,
      });
    } catch (_) {}
  }
})();
