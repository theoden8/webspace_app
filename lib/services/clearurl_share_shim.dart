/// Cleans tracking parameters out of a URL the page copies or shares
/// (`navigator.clipboard.writeText`, `navigator.share`, `execCommand('copy')`)
/// before it leaves the webview, through the `clearUrl` handler's ClearURLs
/// rules.
const String clearUrlShareScript = r'''
(function() {
  const URL_RE = /^https?:\/\//i;

  // Intercept navigator.clipboard.writeText
  if (navigator.clipboard && navigator.clipboard.writeText) {
    const origWriteText = navigator.clipboard.writeText.bind(navigator.clipboard);
    navigator.clipboard.writeText = async function(text) {
      if (typeof text === 'string' && URL_RE.test(text.trim())) {
        try {
          const cleaned = await window.flutter_inappwebview.callHandler('clearUrl', text.trim());
          if (typeof cleaned === 'string' && cleaned.length > 0) {
            text = cleaned;
          }
        } catch (e) {}
      }
      return origWriteText(text);
    };
  }

  // Intercept navigator.share (Web Share API)
  if (navigator.share) {
    const origShare = navigator.share.bind(navigator);
    navigator.share = async function(data) {
      if (data && typeof data === 'object') {
        const cleaned = Object.assign({}, data);
        if (typeof cleaned.url === 'string' && URL_RE.test(cleaned.url)) {
          try {
            const r = await window.flutter_inappwebview.callHandler('clearUrl', cleaned.url);
            if (typeof r === 'string' && r.length > 0) cleaned.url = r;
          } catch (e) {}
        }
        if (typeof cleaned.text === 'string' && URL_RE.test(cleaned.text.trim())) {
          try {
            const r = await window.flutter_inappwebview.callHandler('clearUrl', cleaned.text.trim());
            if (typeof r === 'string' && r.length > 0) cleaned.text = r;
          } catch (e) {}
        }
        return origShare(cleaned);
      }
      return origShare(data);
    };
  }

  // Intercept document.execCommand('copy') by cleaning selected text if it's a URL
  const origExecCommand = document.execCommand.bind(document);
  document.execCommand = function(command, showUI, value) {
    if (command === 'copy') {
      const selection = window.getSelection();
      if (selection && selection.toString) {
        const text = selection.toString().trim();
        if (URL_RE.test(text)) {
          // Use async clipboard API to write the cleaned URL instead
          window.flutter_inappwebview.callHandler('clearUrl', text).then(function(cleaned) {
            if (typeof cleaned === 'string' && cleaned.length > 0 && cleaned !== text) {
              navigator.clipboard.writeText(cleaned).catch(function() {});
            }
          }).catch(function() {});
        }
      }
    }
    return origExecCommand(command, showUI, value);
  };
})();
''';
