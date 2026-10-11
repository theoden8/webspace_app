// The generic cosmetic scanner (lib/js/generic_cosmetic.js) rescans only what
// its MutationObserver reported. Its earlier version walked the whole document
// on every mutation burst, so what that walk found is the oracle: after any
// run of DOM mutations, once the debounce has flushed, every class and id on
// an element in the document has been sent to the engine, and nothing that
// was never in the document at a flush has been.
//
// Seeded random mutation runs drive the page: subtrees appended, inserted,
// moved, replaced and removed, class and id changes through every API, markup
// through innerHTML and outerHTML, subtrees built detached and attached
// later, elements added and removed within one burst, and changes to <head>
// and to <html> beside <body>. The debounce timer is driven by hand, after the
// observer's microtask has run, as a browser orders a timer task after it.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, pageJs } = require('./helpers/load_shim');

const SCANNER = pageJs('generic_cosmetic');

function rng(seed) {
  let a = seed >>> 0;
  return function next() {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const TAGS = ['div', 'span', 'p', 'section', 'ul', 'li', 'a', 'article'];

function fuzzPage(seed) {
  const random = rng(seed);
  const int = (n) => Math.floor(random() * n);
  const pick = (list) => list[int(list.length)];
  let fresh = 0;
  const token = (prefix) => (random() < 0.3 ? `${prefix}n${seed}_${fresh++}` : `${prefix}${int(40)}`);
  const classList = () => Array.from({ length: int(4) }, () => token('c'));

  const dom = makeDom({
    html: '<!doctype html><html><head><meta class="h0"></head>' +
      '<body class="b0"><div id="root" class="app"><p class="c1">x</p></div></body></html>',
  });
  const { window } = dom;
  const { document } = window;
  const timers = new Map();
  let nextTimer = 1;
  window.setTimeout = (fn) => {
    timers.set(nextTimer, fn);
    return nextTimer++;
  };
  window.clearTimeout = (id) => timers.delete(id);
  const sent = { classes: new Set(), ids: new Set() };
  window.flutter_inappwebview = {
    callHandler(name, payload) {
      assert.equal(name, 'genericCosmeticScan');
      for (const c of payload.classes) sent.classes.add(c);
      for (const i of payload.ids) sent.ids.add(i);
      return Promise.resolve([]);
    },
  };

  function element() {
    const el = document.createElement(pick(TAGS));
    const cls = classList();
    if (cls.length) el.className = cls.join(' ');
    if (random() < 0.3) el.id = token('i');
    return el;
  }
  function subtree(depth) {
    const el = element();
    if (depth > 0) {
      for (let n = int(4); n > 0; n--) el.appendChild(subtree(depth - 1));
    }
    return el;
  }
  function markup(depth) {
    const tag = pick(TAGS);
    const cls = classList().join(' ');
    const id = random() < 0.3 ? ` id="${token('i')}"` : '';
    const inner = depth > 0 ? Array.from({ length: int(3) }, () => markup(depth - 1)).join('') : 't';
    return `<${tag} class="${cls}"${id}>${inner}</${tag}>`;
  }
  const isFixed = (el) =>
    el === document.documentElement || el === document.head || el === document.body;
  const inBody = () => [document.body, ...document.body.querySelectorAll('*')];
  const movable = () => inBody().filter((el) => !isFixed(el));
  const anyMovable = () => {
    const all = movable();
    return all.length ? pick(all) : null;
  };
  const target = () => {
    const r = random();
    if (r < 0.08) return document.head;
    if (r < 0.14) return document.documentElement;
    return pick(inBody());
  };

  const ops = [
    () => target().appendChild(subtree(int(3))),
    () => {
      const ref = anyMovable();
      if (ref) ref.parentNode.insertBefore(subtree(int(3)), ref);
    },
    () => anyMovable()?.remove(),
    () => {
      const el = anyMovable();
      const to = pick(inBody());
      if (el && to !== el && !el.contains(to)) to.appendChild(el);
    },
    () => {
      target().className = classList().join(' ');
    },
    () => target().classList.add(token('c')),
    () => {
      const el = target();
      if (el.classList.length) el.classList.remove(el.classList[int(el.classList.length)]);
    },
    () => target().classList.toggle(token('c')),
    () => target().setAttribute('class', classList().join(' ')),
    () => {
      target().id = token('i');
    },
    () => target().removeAttribute('id'),
    () => {
      const el = anyMovable();
      if (el) el.innerHTML = markup(2);
    },
    () => {
      const el = anyMovable();
      if (el) el.outerHTML = markup(2);
    },
    () => anyMovable()?.replaceWith(subtree(2)),
    () => {
      const el = anyMovable();
      if (el) el.textContent = 'x';
    },
    () => {
      // Built detached, changed while detached, then attached.
      const tree = subtree(2);
      for (const el of [tree, ...tree.querySelectorAll('*')]) {
        if (random() < 0.5) el.classList.add(token('c'));
        if (random() < 0.2) el.id = token('i');
      }
      target().appendChild(tree);
    },
    () => {
      // In and out within one burst.
      const tree = subtree(2);
      target().appendChild(tree);
      tree.remove();
    },
    () => {
      // Changed, taken out, put back elsewhere.
      const el = anyMovable();
      if (!el) return;
      el.classList.add(token('c'));
      el.remove();
      target().appendChild(el);
    },
  ];

  function present() {
    const classes = new Set();
    const ids = new Set();
    for (const el of [document.documentElement, ...document.documentElement.querySelectorAll('*')]) {
      if (el.id) ids.add(el.id);
      for (const c of el.classList) classes.add(c);
    }
    return { classes, ids };
  }

  // Seen at a flush: what the full walk would have sent by now.
  const oracle = { classes: new Set(), ids: new Set() };
  async function quiesce() {
    await new Promise((r) => setImmediate(r));
    const due = [...timers.values()];
    timers.clear();
    for (const fn of due) fn();
    const now = present();
    for (const c of now.classes) oracle.classes.add(c);
    for (const i of now.ids) oracle.ids.add(i);
  }

  return {
    async start() {
      runInDom(dom, SCANNER);
      await quiesce();
    },
    async burst() {
      for (let n = 1 + int(8); n > 0; n--) {
        pick(ops)();
        if (random() < 0.25) await new Promise((r) => setImmediate(r));
      }
      await quiesce();
    },
    sent,
    oracle,
  };
}

const sorted = (set) => [...set].sort();

test('generic scanner: random mutation runs send exactly what a full rescan would', async () => {
  for (let seed = 1; seed <= 60; seed++) {
    const page = fuzzPage(seed);
    await page.start();
    for (let step = 0; step < 80; step++) {
      await page.burst();
      assert.deepEqual(sorted(page.sent.classes), sorted(page.oracle.classes),
        `classes, seed ${seed} step ${step}`);
      assert.deepEqual(sorted(page.sent.ids), sorted(page.oracle.ids),
        `ids, seed ${seed} step ${step}`);
    }
  }
});
