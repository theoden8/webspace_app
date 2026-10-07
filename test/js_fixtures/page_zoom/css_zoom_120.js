(function(){
  var id='__webspace_page_zoom__';
  var css='html{zoom:120% !important;}';
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
  function relayout(){
    apply();
    try{void document.documentElement.offsetHeight;}catch(e){}
    try{window.dispatchEvent(new Event('resize'));}catch(e){}
  }
  window.addEventListener('DOMContentLoaded',relayout);
  window.addEventListener('load',relayout);
})();