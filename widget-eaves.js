/* The real widget is drawn by macOS above this canvas. Only its outline reaches the wallpaper. */
(() => {
  'use strict';
  const canvas = document.querySelector('#widget-eaves');
  const native = Boolean(window.snowfallNative);
  let rectangles = [];
  let pending = 0;
  const trim = new Image();
  trim.onload = schedule;
  trim.src = 'assets/widget-cottage.webp?v=5.0.0';

  // Two adjacent modules share a station roof and foundation. macOS still draws each live pane.
  function buildings(windows) {
    const sites=windows.map(box=>({...box}));
    for(let i=0;i<sites.length;i++) {
      for(let j=i+1;j<sites.length;j++) {
        const a=sites[i],b=sites[j], horizontal=Math.max(a.x,b.x)-Math.min(a.x+a.w,b.x+b.w),
          vertical=Math.max(a.y,b.y)-Math.min(a.y+a.h,b.y+b.h);
        const sameRow=Math.abs(a.y-b.y)<14 && Math.abs(a.h-b.h)<20;
        const sameColumn=Math.abs(a.x-b.x)<14 && Math.abs(a.w-b.w)<20;
        if(!((sameRow&&horizontal<30&&vertical<0)||(sameColumn&&vertical<28&&horizontal<0)))continue;
        const x=Math.min(a.x,b.x),y=Math.min(a.y,b.y);
        sites[i]={x,y,w:Math.max(a.x+a.w,b.x+b.w)-x,h:Math.max(a.y+a.h,b.y+b.h)-y};
        sites.splice(j,1);j=i;
      }
    }
    return sites;
  }
  function silhouette(ctx,fill,run) { ctx.fillStyle=fill;ctx.beginPath();run();ctx.closePath();ctx.fill(); }
  function architecture(ctx,box,sites,height) {
    const {x,y,w,h}=box, side=Math.min(14,w*.072), edge=x+w, bottom=y+h;
    if(w<28||h<24||!trim.naturalWidth)return;
    let headroom=y-2;
    for(const other of sites) {
      if(other===box||other.x>=edge||other.x+other.w<=x) continue;
      const gap=y-other.y-other.h;if(gap>=0)headroom=Math.min(headroom,gap);
    }
    const roof=Math.max(4,Math.min(headroom,w*.31,65)), sill=Math.min(10,h*.06);
    // A high widget gets a second storey down to the hillside. A low widget gets a short stone footing.
    const ground=Math.min(height-3,Math.max(bottom+sill+side*1.55,Math.min(height*.38,bottom+w*.72)));
    const left=x-side*.58,right=edge+side*.4,wing=Math.max(7,Math.min(21,w*.075));
    ctx.save();
    const shadow=ctx.createRadialGradient(0,0,w*.09,0,0,w*.65);
    shadow.addColorStop(0,'rgba(93,113,145,.28)'); shadow.addColorStop(1,'rgba(128,150,172,0)');
    ctx.save();ctx.translate(x+w*.56,ground+3);ctx.scale(1,.115);ctx.fillStyle=shadow;
    ctx.fillRect(-w*.68,-w*.68,w*1.36,w*1.36);ctx.restore();
    // Side return, warm plaster below the widget, and an individually coursed stone plinth.
    silhouette(ctx,'#a28572',()=>{ctx.moveTo(right,y-4);ctx.lineTo(right+wing,y-11);ctx.lineTo(right+wing,ground-6);ctx.lineTo(right,ground+2);});
    const plaster=ctx.createLinearGradient(left,y,right,ground);
    plaster.addColorStop(0,'#f3d5a7');plaster.addColorStop(1,'#cba77f');
    ctx.fillStyle=plaster;ctx.fillRect(left,y-4,right-left,ground-y+4);
    ctx.fillStyle='#a98970';ctx.fillRect(left+2,bottom,3,ground-bottom);ctx.fillRect(right-5,bottom,3,ground-bottom);
    ctx.fillStyle='#ac9987';ctx.fillRect(left-1,ground-6,right-left+2,7);
    ctx.strokeStyle='#ccbeac';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(left,ground-3);ctx.lineTo(right,ground-3);
    for(let at=left+5;at<right-2;at+=13) {ctx.moveTo(at,ground-5);ctx.lineTo(at+1,ground-3);ctx.moveTo(at+5,ground-3);ctx.lineTo(at+4,ground);}
    ctx.stroke();
    const level=ground-bottom-sill;
    if(level>21) {
      const doorH=Math.min(level*.85,w*.30),doorW=Math.max(9,doorH*.53),doorX=x+w*.31;
      // Recess the door and two lit windows into the wall under the live panes.
      function arch(ax,base,aw,ah,c) {
        silhouette(ctx,c,()=>{ctx.moveTo(ax,base);ctx.lineTo(ax,base-ah+aw*.50);ctx.quadraticCurveTo(ax,base-ah,ax+aw*.50,base-ah);
          ctx.quadraticCurveTo(ax+aw,base-ah,ax+aw,base-ah+aw*.5);ctx.lineTo(ax+aw,base);});
      }
      arch(doorX,ground-3,doorW,doorH,'#96775f');arch(doorX+2,ground-3,doorW-4,doorH-2,'#698677');
      ctx.fillStyle='#e7c487';ctx.beginPath();ctx.arc(doorX+doorW*.76,ground-3-doorH*.42,1.25,0,Math.PI*2);ctx.fill();
      for(const pos of [.13,.68,.85]) {
        const wx=x+w*pos,wy=ground-doorH*.32,ww=Math.min(doorW*.74,15),wh=ww*1.22;
        arch(wx,wy,ww,wh,'#96765e');arch(wx+1.5,wy-1.5,ww-3,wh-3,'#f7d38c');
        ctx.fillStyle='#987962';ctx.fillRect(wx+ww*.47,wy-wh+2,1,wh-2);ctx.fillRect(wx,wy-wh*.43,ww,1);
      }
    }
    // The painted roof is stretched only through its centre. Its corners and snow-covered posts retain their shape.
    const sx=[0,145,848,1000],sy=[0,232,518,667],dx=[x-side,x,edge,edge+side],dy=[y-roof,y,bottom,bottom+sill];
    for(let row=0;row<3;row++)for(let col=0;col<3;col++) {
      if(row===1&&col===1)continue;
      ctx.drawImage(trim,sx[col],sy[row],sx[col+1]-sx[col],sy[row+1]-sy[row],
        dx[col],dy[row],dx[col+1]-dx[col]+.3,dy[row+1]-dy[row]+.3);
    }
    // Snowbanks rise in front of the plinth and join the house to the ground plane.
    for(const [cx,width] of [[left+5,side*1.8],[right-2,side*2.2]]) {
      silhouette(ctx,'#bdceda',()=>{ctx.ellipse(cx,ground+1,width,3.7,0,0,Math.PI*2);});
      silhouette(ctx,'#f6f0e7',()=>{ctx.moveTo(cx-width,ground);ctx.quadraticCurveTo(cx-width*.60,ground-6,cx-width*.25,ground-4);
        ctx.quadraticCurveTo(cx+width*.32,ground-11,cx+width*.55,ground-5);ctx.quadraticCurveTo(cx+width*.86,ground-6,cx+width,ground);
        ctx.quadraticCurveTo(cx,ground+5,cx-width,ground);});
    }
    ctx.restore();
  }
  function paint() {
    pending=0;
    const w=canvas.clientWidth, h=canvas.clientHeight;
    if (!w || !h) return;
    let visible=[];
    if(native && document.documentElement.dataset.surface==='wallpaper') {
      visible=rectangles.map(r=>({x:r.x*w,y:r.y*h,w:r.width*w,h:r.height*h}));
    }
    const porches = SnowPorches.visiblePlots();
    if(!visible.length && !porches.length) { canvas.width=1;canvas.height=1;return; }
    const scale=Math.min(window.devicePixelRatio || 1,2);
    const pixelsW=Math.round(w*scale),pixelsH=Math.round(h*scale);
    if(canvas.width!==pixelsW || canvas.height!==pixelsH) { canvas.width=pixelsW;canvas.height=pixelsH; }
    const ctx=canvas.getContext('2d'); if (!ctx) return;
    ctx.setTransform(scale,0,0,scale,0,0);ctx.clearRect(0,0,w,h);
    SnowPorches.paint(ctx,w,h,porches);
    const sites=buildings(visible);
    sites.forEach(site=>architecture(ctx,site,sites,h));
  }
  function schedule() {
    if(pending)return;
    pending=1;
    // AppKit can report the desktop web view as occluded while its content is still needed
    // for a desktop capture. Geometry changes are rare and can paint immediately there.
    if(native)queueMicrotask(paint); else requestAnimationFrame(paint);
  }
  window.addEventListener('snowfall-widget-frames',e=>{
    if(!native || !Array.isArray(e.detail))return;
    rectangles=e.detail.filter(r=>r && [r.x,r.y,r.width,r.height].every(Number.isFinite) && r.width>0 && r.height>0);
    schedule();
  });
  window.addEventListener('resize',schedule);
  window.addEventListener('snowfall-porches-changed',schedule);
  for (const image of document.querySelectorAll('[data-sample] img')) new ResizeObserver(schedule).observe(image);
  window.addEventListener('snowfall-surface',schedule);

  schedule();
})();
