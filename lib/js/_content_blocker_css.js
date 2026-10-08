// The stylesheet that hides each selector and applies each uBO `:style()`
// rule's own declarations instead of `display: none`.
function contentBlockerCss(selectors, styleRules) {
  var css = '';
  for (var i = 0; i < selectors.length; i++) {
    css += selectors[i] + ' { display: none !important; } ';
  }
  for (var j = 0; j < styleRules.length; j++) {
    css += styleRules[j].selector + ' { ' + styleRules[j].declarations + ' } ';
  }
  return css;
}
