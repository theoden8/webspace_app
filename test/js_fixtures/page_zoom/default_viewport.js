(function(){
  function normalize(meta){
    var c=(meta.getAttribute('content')||'').trim();
    if(/initial-scale/i.test(c))return;
    if(c===''){c='width=device-width, initial-scale=1';}
    else{
      c=c.replace(/\s*,?\s*$/,'')+', initial-scale=1';
      if(!/width\s*=/i.test(c)){c='width=device-width, '+c;}
    }
    meta.setAttribute('content',c);
  }
  function ensure(){
    var metas=document.querySelectorAll('meta[name="viewport" i]');
    if(!metas.length){
      var m=document.createElement('meta');
      m.setAttribute('name','viewport');
      m.setAttribute('content','width=device-width, initial-scale=1');
      (document.head||document.documentElement).appendChild(m);
      return;
    }
    for(var i=0;i<metas.length;i++){normalize(metas[i]);}
  }
  ensure();
  try{
    var mo=new MutationObserver(function(muts){
      for(var i=0;i<muts.length;i++){
        var mu=muts[i], tgt=mu.target;
        if(mu.type==='attributes'&&tgt&&tgt.tagName==='META'){
          var n=tgt.getAttribute&&tgt.getAttribute('name');
          if(n&&n.toLowerCase()==='viewport'){normalize(tgt);}
        }
        var add=mu.addedNodes;
        if(add){for(var j=0;j<add.length;j++){
          var el=add[j];
          if(el&&el.nodeType===1&&el.tagName==='META'){
            var n2=el.getAttribute&&el.getAttribute('name');
            if(n2&&n2.toLowerCase()==='viewport'){normalize(el);}
          }
        }}
      }
    });
    if(document.documentElement){
      mo.observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['content','name']});
    }
  }catch(e){}
  if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',ensure,{once:true});}
})();