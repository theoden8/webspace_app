// A stand-in for the engine's matchMedia, for jsdom tests of the scripts
// that wrap it. jsdom's own answers false to everything, so a wrapper that
// hands a query on cannot be told from one that answers it itself.
//
// It evaluates the Media Queries 3 grammar: a `,` list of queries, each an
// optional `not` or `only`, a media type or a feature, then `and` features.
// A feature is `(name: value)`, equal to the environment's value, or
// `(name)`, true unless that value is `0` or `none`; an unknown name is
// false. `set(name, value)` changes the environment and fires `change` on
// every list whose answer moved, as an engine does. `seen` is every query
// handed to it, in order.

function fakeMediaEngine(initial = {}) {
  const env = { type: 'screen', grid: '0', ...initial };
  const seen = [];
  const lists = [];

  const feature = (text) => {
    const m = /^\(\s*([a-z-]+)\s*(?::\s*([^()]+?)\s*)?\)$/.exec(text);
    if (!m) return false;
    const value = env[m[1]];
    if (value === undefined) return false;
    return m[2] === undefined ? !['0', 'none'].includes(value) : value === m[2];
  };
  const query = (text) => {
    let s = text.trim().toLowerCase();
    let negated = false;
    if (s.startsWith('not ')) {
      negated = true;
      s = s.slice(4);
    } else if (s.startsWith('only ')) {
      s = s.slice(5);
    }
    const holds = s.split(/\s+and\s+/).every((part) => {
      const p = part.trim();
      return p.startsWith('(') ? feature(p) : p === 'all' || p === env.type;
    });
    return negated !== holds;
  };
  const evaluate = (text) => text.split(',').some(query);

  function matchMedia(text) {
    seen.push(String(text));
    const listeners = new Set();
    const list = {
      media: String(text),
      get matches() { return evaluate(String(text)); },
      onchange: null,
      addEventListener(type, l) { if (type === 'change') listeners.add(l); },
      removeEventListener(type, l) { if (type === 'change') listeners.delete(l); },
      addListener(l) { listeners.add(l); },
      removeListener(l) { listeners.delete(l); },
    };
    lists.push({ list, listeners, last: list.matches });
    return list;
  }

  function set(name, value) {
    env[name] = value;
    for (const entry of lists) {
      const now = entry.list.matches;
      if (now === entry.last) continue;
      entry.last = now;
      for (const l of entry.listeners) l({ type: 'change', matches: now, media: entry.list.media });
    }
  }

  const listening = () => lists.reduce((n, e) => n + e.listeners.size, 0);

  return { matchMedia, set, seen, listening };
}

module.exports = { fakeMediaEngine };
