  // One <style> element with `id` holding `css`, re-applied by id so a
  // same-document navigation keeps it.
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
