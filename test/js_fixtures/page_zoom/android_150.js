(function(){
  var SCALE=1.5;
  var PIN=true;
  var PORTRAIT=393;
  var LANDSCAPE=851;
  var measured=0;
  var measuredLandscape=false;
  function isLandscape(){
    try{
      if(window.matchMedia){ return !!window.matchMedia('(orientation: landscape)').matches; }
    }catch(e){}
    return false;
  }
  // One sample of the real box, taken before our meta lands: after that
  // innerWidth reports the visual viewport, which our own scale has moved.
  function captureOnce(){
    if(measured!==0) return;
    var w=0;
    try{ w=window.innerWidth||0; }catch(e){}
    measured=w>0?w:-1;
    measuredLandscape=isLandscape();
  }
  function baseWidth(){
    var landscape=isLandscape();
    var b=landscape?LANDSCAPE:PORTRAIT;
    if(!(b>0)){ b=landscape?PORTRAIT:LANDSCAPE; }
    // The sample only describes the orientation it was taken in; after a
    // rotation the view extents are the better answer.
    if(measured>0&&landscape===measuredLandscape){
      b=b>0?Math.min(b,measured):measured;
    }
    return b>0?b:0;
  }
  function layoutWidth(){
    var b=baseWidth();
    return b>0?Math.max(1,Math.floor(b/SCALE)):0;
  }
  function content(){
    if(!PIN) return 'initial-scale='+SCALE;
    var w=layoutWidth();
    return w?('width='+w+', initial-scale='+SCALE):('initial-scale='+SCALE);
  }
  function applyTo(m,c){
    try{ if(m.getAttribute('content')!==c){ m.setAttribute('content',c); } }catch(e){}
  }
  function ensure(){
    try{
      captureOnce();
      var c=content();
      var metas=document.querySelectorAll('meta[name="viewport" i]');
      if(metas.length===0){
        var m=document.createElement('meta');
        m.setAttribute('name','viewport');
        m.setAttribute('content',c);
        (document.head||document.documentElement).appendChild(m);
      } else {
        for(var i=0;i<metas.length;i++){ applyTo(metas[i],c); }
      }
    }catch(e){}
  }
  ensure();
  try{
    var mo=new MutationObserver(function(muts){
      for(var i=0;i<muts.length;i++){
        var added=muts[i].addedNodes; if(!added) continue;
        for(var j=0;j<added.length;j++){
          var n=added[j];
          if(n&&n.nodeType===1&&n.tagName==='META'){
            var nm=n.getAttribute&&n.getAttribute('name');
            if(nm&&nm.toLowerCase()==='viewport'){ applyTo(n,content()); }
          }
        }
      }
    });
    if(document.documentElement){ mo.observe(document.documentElement,{childList:true,subtree:true}); }
    else { document.addEventListener('DOMContentLoaded',function(){ ensure(); mo.observe(document.documentElement,{childList:true,subtree:true}); }); }
  }catch(e){}
  // Rotation swaps which view extent applies, so the meta is re-derived.
  // Nothing in that derivation reads a value our own scale has moved, so
  // re-running cannot compound; applyTo also skips an unchanged value.
  try{
    window.addEventListener('resize',ensure);
    window.addEventListener('orientationchange',ensure);
  }catch(e){}
})();