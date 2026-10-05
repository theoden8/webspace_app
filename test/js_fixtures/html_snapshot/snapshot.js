(function () {
  var d = document;
  var root = d.documentElement;
  if (!root) return null;
  var inert = d.implementation.createHTMLDocument('');
  var clone = inert.importNode(root, true);

  function rulesText(sheet) {
    var rules = sheet && !sheet.disabled ? sheet.cssRules : null;
    if (!rules || !rules.length) return null;
    var out = [];
    for (var i = 0; i < rules.length; i++) out.push(rules[i].cssText);
    return out.join('\n');
  }

  var live = d.querySelectorAll('style');
  var copies = clone.querySelectorAll('style');
  for (var i = 0; i < live.length && i < copies.length; i++) {
    if (/\S/.test(live[i].textContent)) continue;
    var text = rulesText(live[i].sheet);
    if (text) copies[i].textContent = text;
  }

  var adopted = d.adoptedStyleSheets || [];
  var body = clone.querySelector('body') || clone;
  for (var j = 0; j < adopted.length; j++) {
    var css = rulesText(adopted[j]);
    if (!css) continue;
    var el = inert.createElement('style');
    var media = adopted[j].media && adopted[j].media.mediaText;
    if (media) el.setAttribute('media', media);
    el.textContent = css;
    body.appendChild(el);
  }

  var nav = performance.getEntriesByType ?
      performance.getEntriesByType('navigation')[0] : null;
  var served = nav && /^https?:/.test(nav.name) ? nav.name : d.baseURI;
  var head = clone.querySelector('head');
  if (head && !d.querySelector('base[href]') && /^https?:/.test(served)) {
    var base = inert.createElement('base');
    base.setAttribute('href', served);
    head.insertBefore(base, head.firstChild);
  }

  var dt = d.doctype;
  var doctype = '';
  if (dt) {
    doctype = '<!DOCTYPE ' + dt.name +
        (dt.publicId ? ' PUBLIC "' + dt.publicId + '"' :
            (dt.systemId ? ' SYSTEM' : '')) +
        (dt.systemId ? ' "' + dt.systemId + '"' : '') + '>';
  }
  return doctype + clone.outerHTML;
})()
