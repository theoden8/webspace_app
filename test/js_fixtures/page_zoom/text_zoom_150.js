(function(){
  var id='__webspace_text_zoom__';
  var css='html{-webkit-text-size-adjust:150% !important;}';
  function apply(){
    var el=document.getElementById(id);
    if(!el){
      el=document.createElement('style');
      el.id=id;
      (document.head||document.documentElement).appendChild(el);
    }
    el.textContent=css;
  }
  if(document.documentElement){apply();}
  else{document.addEventListener('DOMContentLoaded',apply);}
})();