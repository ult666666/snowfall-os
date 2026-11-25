/* The real widget is drawn by macOS above this canvas. Only its outline reaches the wallpaper. */
(() => {
  'use strict';
  const canvas = document.querySelector('#widget-eaves');
  const demo = document.querySelector('#village-clock');
  const native = Boolean(window.snowfallNative);
  let rectangles = [];
  let pending = 0;
  const trim = new Image();
  trim.onload = schedule;
  trim.src = 'assets/widget-cottage.webp';

  function cottage(ctx, r, others) {
    // A nine-slice keeps the painted posts narrow and the berries round on large widgets.
    const inset = r.preview ? 0 : Math.min(7,r.w*.035);
    const x=r.x+inset, y=r.y+inset, w=r.w-inset*2, h=r.h-inset*2;
    if(w<28 || h<24 || !trim.naturalWidth) return;
    let headroom=y-(native ? 22 : 3);
    for(const other of others) {
      if(other===r || other.x>=x+w || other.x+other.w<=x) continue;
      const base=other.y+other.h;
      if(base<=y+3) headroom=Math.min(headroom,y-base+2);
    }
    const roof=Math.max(5,Math.min(headroom,w*.32,r.preview ? 58 : 55));
    const side=r.preview ? Math.min(26,w*.17) : Math.min(16,w*.075);
    const sill=Math.min(r.preview ? 24 : 13,h*.19);
    const sx=[0,145,848,1000],sy=[0,232,518,667];
    const dx=[x-side,x,x+w,x+w+side],dy=[y-roof,y,y+h,y+h+sill];
    for(let row=0;row<3;row++) {
      for(let col=0;col<3;col++) {
        if(row===1 && col===1) continue;
        ctx.drawImage(trim,sx[col],sy[row],sx[col+1]-sx[col],sy[row+1]-sy[row],
          dx[col],dy[row],dx[col+1]-dx[col]+.35,dy[row+1]-dy[row]+.35);
      }
    }
  }
  function paint() {
    pending=0;
    const w=canvas.clientWidth, h=canvas.clientHeight;
    if (!w || !h) return;
    let visible=[];
    if(native && document.documentElement.dataset.surface==='wallpaper') {
      visible=rectangles.map(r=>({x:r.x*w,y:r.y*h,w:r.width*w,h:r.height*h}));
    } else if(!native && demo.getClientRects().length) {
      const a=demo.getBoundingClientRect(), b=canvas.getBoundingClientRect();
      visible=[{x:a.x-b.x,y:a.y-b.y,w:a.width,h:a.height,preview:true}];
    }
    if(!visible.length) { canvas.width=1;canvas.height=1;return; }
    const scale=Math.min(window.devicePixelRatio || 1,2);
    const pixelsW=Math.round(w*scale),pixelsH=Math.round(h*scale);
    if(canvas.width!==pixelsW || canvas.height!==pixelsH) { canvas.width=pixelsW;canvas.height=pixelsH; }
    const ctx=canvas.getContext('2d'); if (!ctx) return;
    ctx.setTransform(scale,0,0,scale,0,0);ctx.clearRect(0,0,w,h);
    visible.forEach(r=>cottage(ctx,r,visible));
  }
  function schedule() { if(!pending) pending=requestAnimationFrame(paint); }
  window.addEventListener('snowfall-widget-frames',e=>{
    if(!native || !Array.isArray(e.detail))return;
    rectangles=e.detail.filter(r=>r && [r.x,r.y,r.width,r.height].every(Number.isFinite) && r.width>0 && r.height>0);
    schedule();
  });
  window.addEventListener('resize',schedule);
  window.addEventListener('snowfall-surface',schedule);
  new ResizeObserver(schedule).observe(demo);
  schedule();
})();
