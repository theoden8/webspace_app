// Content-blocker inputs shared by the jsdom and browser tiers: a stand-in
// for what a real ABP filter list produces, as the configs the app hands
// content_blocker_early_css.js and content_blocker_cosmetic.js.

const { pageJs } = require('./page_js');
const { scriptOf } = require('./script_of');

// Class selectors, attribute selectors, and a text-match rule that catches
// sponsor content whose markup carries no stable class.
const SAMPLE_SELECTORS = [
  '.ad-banner',
  '.sponsored',
  '#sidebar-ad',
  'div[data-ad-slot]',
  'a[href*="track.example.com"]',
];
const SAMPLE_TEXT_RULES = [
  { sel: 'div.article > p', pats: ['Sponsored content'] },
];

// A bad selector in the middle of the list, and two text rules, the first
// with several OR-matched patterns (CB-005).
const MULTI_SELECTORS = [
  '.batch1-a', '.batch1-b', '.batch1-c', '.batch1-d', '.batch1-e',
  '.batch1-f', '.batch1-g', '.batch1-h', '.batch1-i', '.batch1-j',
  '.batch1-k', '.batch1-l', '.batch1-m', '.batch1-n', '.batch1-o',
  '.batch1-p', '.batch1-q', '.batch1-r', '.batch1-s', '.batch1-t',
  '>>>invalid<<<',
  '.batch2-b', '.batch2-c', '.batch2-d', '.batch2-e',
];
const MULTI_TEXT_RULES = [
  { sel: 'p.notice', pats: ['Promoted', 'Sponsored'] },
  { sel: 'div.bio', pats: ['Editor'] },
];

const earlyCss = (selectors, styleRules = []) =>
  pageJs('content_blocker_early_css', { selectors, styleRules });
const cosmetic = (selectors, { textRules = [], styleRules = [] } = {}) =>
  pageJs('content_blocker_cosmetic', { selectors, styleRules, textRules });

const EARLY_CSS = earlyCss(SAMPLE_SELECTORS);
const COSMETIC = cosmetic(SAMPLE_SELECTORS, { textRules: SAMPLE_TEXT_RULES });
const COSMETIC_MULTI = cosmetic(MULTI_SELECTORS, { textRules: MULTI_TEXT_RULES });

// uBO `:style(...)` rules: the raw declarations go through the same early
// <style> tag, with no display:none for the same selector.
const STYLE_RULES = cosmetic(['.always-hidden'], {
  styleRules: [
    { selector: '.shrunk-banner', declarations: 'height: 1px !important' },
    { selector: '.faded-promo', declarations: 'opacity: 0.1 !important' },
  ],
});

// The wider ABP shapes the parser produces: `:-abp-has(...)` rewritten to
// standard `:has(...)` for the CSS path, and `:has-text(...)` /
// `:contains(...)` as text rules for the observer path.
const ABP_RULES = cosmetic(['div.post:has(.ad-tag)', '.banner'], {
  textRules: [
    { sel: 'p.notice', pats: ['Sponsored', 'Promoted'] },
    { sel: 'article', pats: ['Advertisement'] },
  ],
});

// The CSS-only cosmetic shape both equivalence tiers compare the shipped shim
// against: the same <style> injection, no runtime selector sweep, and an
// observer that only re-runs the text rules. Its selectors are the samples'
// with their element and host narrowed, as the old shape matched them.
function cosmeticCssOnly() {
  var ID = '_webspace_content_blocker_style';
  if (!document.getElementById(ID)) {
    var s = document.createElement('style');
    s.id = ID;
    s.textContent =
      '.ad-banner { display: none !important; } ' +
      '.sponsored { display: none !important; } ' +
      '#sidebar-ad { display: none !important; } ' +
      '[data-ad-slot] { display: none !important; } ' +
      'a[href*="track."] { display: none !important; } ';
    (document.head || document.documentElement).appendChild(s);
  }
  // Text rules (CSS can't match on text content): keep the observer,
  // scoped to whole-document re-scan on debounce. Same shape as the
  // shipped shim's hideText path.
  var TEXT_RULES = [{ sel: 'div.article > p', pats: ['Sponsored content'] }];
  function hideText() {
    for (var i = 0; i < TEXT_RULES.length; i++) {
      var r = TEXT_RULES[i];
      try {
        document.querySelectorAll(r.sel).forEach(function(el) {
          var text = el.textContent || '';
          for (var j = 0; j < r.pats.length; j++) {
            if (text.indexOf(r.pats[j]) !== -1) {
              el.style.display = 'none';
              break;
            }
          }
        });
      } catch (e) {}
    }
  }
  hideText();
  var t = null;
  var obs = new MutationObserver(function() {
    if (t) clearTimeout(t);
    t = setTimeout(hideText, 50);
  });
  if (document.body) {
    obs.observe(document.body, { childList: true, subtree: true });
  } else {
    document.addEventListener('DOMContentLoaded', function() {
      hideText();
      obs.observe(document.body, { childList: true, subtree: true });
    });
  }
}
const COSMETIC_CSS_ONLY = scriptOf(cosmeticCssOnly);

module.exports = {
  COSMETIC_CSS_ONLY,
  SAMPLE_SELECTORS,
  SAMPLE_TEXT_RULES,
  earlyCss,
  cosmetic,
  EARLY_CSS,
  COSMETIC,
  COSMETIC_MULTI,
  STYLE_RULES,
  ABP_RULES,
};
