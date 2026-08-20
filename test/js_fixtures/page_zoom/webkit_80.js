(function(){
  var SCALE=0.8;
  var PIN=false;
  var PORTRAIT=393;
  var LANDSCAPE=851;
  var measured=0;
  var measuredLandscape=false;
  var pinned=0;
  var corrections=0;
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
    if(pinned>0) return pinned;
    var b=baseWidth();
    return b>0?Math.max(1,Math.floor(b/SCALE)):0;
  }
  // Every width available before first layout describes the view, not the
  // WebView's own box — letterbox mode resizes that box, and so does split
  // screen. Once the meta is live the engine reports the box itself: at
  // our scale the visual viewport IS the layout width that exactly fills
  // it, so a layout viewport that disagrees is a pin that overshot (the
  // page hangs off the right edge) or undershot. Snap to it, bounded, and
  // only in the frame that owns the viewport.
  function correct(){
    if(!PIN||corrections>=3) return;
    try{
      if(window.top!==window) return;
      var vv=window.visualViewport;
      var d=document.documentElement;
      if(!vv||!d||!(vv.width>0)) return;
      var want=Math.max(1,Math.floor(vv.width));
      if(Math.abs(d.clientWidth-want)<=1) return;
      corrections++;
      pinned=want;
      ensure();
    }catch(e){}
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
  function reset(){ pinned=0; corrections=0; ensure(); correct(); }
  try{
    window.addEventListener('resize',reset);
    window.addEventListener('orientationchange',reset);
  }catch(e){}
  // The correction needs a laid-out page. Run it as soon as one exists and
  // once more after the load settles, in case the first pass raced it.
  try{
    if(document.readyState==='complete'){ correct(); }
    else { window.addEventListener('load',correct); }
    document.addEventListener('DOMContentLoaded',correct);
    setTimeout(correct,500);
  }catch(e){}
})();