// Expires every cookie the document's script can see (`document.cookie`), at
// path /. Evaluated once the nested browser's controller is created.
(function() {
  var cookies = document.cookie.split("; ");
  for (var i = 0; i < cookies.length; i++) {
    var cookie = cookies[i];
    var cookieName = cookie.split("=")[0];
    document.cookie = cookieName + "=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/;";
  }
})();
