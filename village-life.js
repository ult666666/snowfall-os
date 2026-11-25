/* One little plow tends the lane between visits to the snow yard. */
(() => {
  'use strict';
  const scene = document.querySelector('#scene');
  const panel = document.querySelector('#tools-panel');
  if (!scene || !panel) return;
  const layer = document.createElement('div');
  layer.id = 'village-life';
  layer.setAttribute('aria-hidden', 'true');
  document.querySelector('#wallpaper').after(layer);
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  const clamp = (value, lo, hi) => Math.max(lo, Math.min(hi, value));
  let nextStop = null, trip = null, timer = 0, due = 0, widgetFrames = [];
  let backgroundTick = 0, arrivalTimer = 0, enterFromWest = false;

  function resting() {
    return motion.matches ||
      scene.matches('.reduce-motion,.room-mode,.yard-active,.custom-image') ||
      !panel.hidden || document.querySelector('dialog[open]') ||
      (document.hidden && window.snowfallSurface !== 'wallpaper');
  }
  function planAfter(delay) {
    clearTimeout(timer);
    due = 0;
    if (resting()) return;
    due = Date.now() + delay;
    timer = setTimeout(checkLane, delay);
  }
  function park() {
    clearTimeout(backgroundTick); clearTimeout(arrivalTimer);
    if (trip) {
      trip.animation.onfinish = null;
      trip.animation.cancel();
      trip = null;
    }
    layer.replaceChildren();
  }
  function maintain() {
    if (resting()) {
      clearTimeout(timer); due = 0; nextStop = null; park();
    } else if (!due && !trip) planAfter(8500);
  }
  function part(tag, cls, parent, src) {
    const el = document.createElement(tag);
    el.className = cls;
    if (src) { el.src = 'assets/props/' + src + '.png'; el.alt = ''; }
    parent.append(el);
    return el;
  }

  // Routes start offscreen and stay in the snow below the village skyline.
  // Score clear stretches of lane close to the latest freshly packed snow.
  function obstacles() {
    const width=scene.clientWidth, height=scene.clientHeight;
    const blocks=[...scene.querySelectorAll('.village-house,.wallpaper-cottage,.house-name,.free-snow-figure,.free-snow-rival,#surface-controls button,#village-clock,#postal-counter')]
      .map(el=>el.getBoundingClientRect()).filter(r=>r.width && r.height);
    for (const r of widgetFrames) blocks.push({left:r.x*width,right:(r.x+r.width)*width,top:r.y*height,bottom:(r.y+r.height)*height});
    return blocks;
  }
  function lane(home,size,aim,blocks,exit=home) {
    const width=scene.clientWidth, height=scene.clientHeight;
    const direction=Math.sign(aim.x-home.x) || 1;
    const reach=clamp(Math.abs(aim.x-home.x),size*1.4,width*.66);
    let best=null, bestScore=-Infinity;
    for (const length of [1,.74,.49]) {
      for (const shift of [0,-.08,.08,-.16,.16]) {
        const p={x:clamp(home.x+direction*reach*length,size*.54,width-size*.54),
          y:clamp(aim.y+height*shift,height*.54,height*.94)};
        if (Math.hypot(p.x-home.x,p.y-home.y)<size*.56) continue;
        const clear=[home,exit].every(start=>{
          const steps=Math.max(3,Math.ceil(Math.hypot(p.x-start.x,p.y-start.y)/(size*.31)));
          for (let i=1;i<=steps;i++) {
            const x=start.x+(p.x-start.x)*i/steps, y=start.y+(p.y-start.y)*i/steps;
            if (blocks.some(b=>x+size*.34>b.left && x-size*.34<b.right && y>b.top && y-size*.32<b.bottom)) return false;
          }
          return true;
        });
        const score=-Math.hypot(p.x-aim.x,p.y-aim.y);
        if (clear && score>bestScore) { best=p;bestScore=score; }
      }
    }
    return best;
  }
  function checkLane() {
    if (!due || trip || Date.now()+20<due) return;
    clearTimeout(timer);due=0;
    if (resting()) return;
    const free=window.FreeSnow?.state();
    if (free?.fightActive || free?.holding) { planAfter(3800);return; }
    const width=scene.clientWidth, height=scene.clientHeight;
    const size=clamp(Math.min(width*.115,height*.105),42,90);
    const goal=nextStop, west=goal ? goal.x<.5 : enterFromWest;
    const focusX=goal?.x ?? (west ? .32 : .68);
    const focusY=goal ? goal.y+.05 : (west ? .70 : .81);
    const aim={x:width*focusX,y:height*clamp(focusY,.55,.91)};
    const blocks=obstacles();
    for (const left of [west,!west]) {
      for (const offset of [0,.10,-.10,.18,-.18]) {
        const home={x:left?-size*.56:width+size*.56,y:clamp(aim.y+height*offset,height*.54,height*.94)};
        const end=lane(home,size,aim,blocks);
        if (!end) continue;
        enterFromWest=!left;nextStop=null;
        drive(home,end,home,size);
        return;
      }
    }
    nextStop=null;planAfter(28000);
  }
  function drive(home,end,exit,size) {
    park();
    const dx=end.x-home.x, dy=end.y-home.y, sign=Math.sign(dx) || 1;
    const span=Math.hypot(dx,dy), angle=Math.atan2(dy,dx);
    const speed=clamp(2600+span*9, 3400, 5500);
    const returnTime=clamp(2500+Math.hypot(end.x-exit.x,end.y-exit.y)*9,2800,6500);
    const duration=speed+1300+returnTime;
    const track=part('span','plow-track',layer);
    Object.assign(track.style,{left:home.x+'px',top:(home.y-3)+'px',width:span+'px',
      transform:'rotate('+angle+'rad)'});
    const tread=part('span','plow-tread',track);
    const rolling=tread.animate([{transform:'scaleX(0)'},{transform:'scaleX(1)'}],
      {duration:speed,easing:'ease-in-out',fill:'both'});

    // The blade gathers a low windrow; it stays beside the tracks after the truck backs home.
    const pile=part('img','plow-windrow',layer,'yard-pile');
    Object.assign(pile.style,{left:(end.x+sign*size*.28)+'px',top:end.y+'px',width:size*.44+'px'});
    const gathering=pile.animate([{opacity:0,transform:'translate(-50%,-85%) scale(.2)'},{opacity:.9,transform:'translate(-50%,-85%) scale(1)'}],
      {delay:speed*.67,duration:speed*.32,easing:'ease-out',fill:'both'});

    const truck=part('div','plow-rig',layer);
    Object.assign(truck.style,{left:home.x+'px',top:home.y+'px',width:size+'px',height:(size*175/256)+'px'});
    const body=part('div','plow-body',truck);
    part('img','plow-paint',body,'plow');
    const plume=part('span','plow-spray',body);
    for (let i=0; i<3; i++) part('i','',plume);
    body.style.transform='scaleX('+sign+')';
    const placement=(x,y,depth) => 'translate(-50%,-100%) translate('+x+'px,'+y+'px) scale('+depth+')';
    const dock=placement(0,0,1), bank=placement(dx,dy,.87);
    const animation=truck.animate([{transform:dock,easing:'ease-in-out'},
      {offset:speed/duration,transform:bank},{offset:(speed+1300)/duration,transform:bank,easing:'ease-in-out'},
      {transform:placement(exit.x-home.x,exit.y-home.y,1)}],{duration,fill:'both'});
    const spraying=plume.animate([{opacity:0},{opacity:.88,offset:.15},{opacity:.88,offset:.40},{opacity:0,offset:.47},{opacity:0}],
      {duration,fill:'both'});
    trip={truck,animation,exit};
    const started=Date.now();
    let finished=false;
    const arrive=() => {
      if (finished || trip?.animation!==animation) return;
      finished=true; clearTimeout(backgroundTick); clearTimeout(arrivalTimer);
      trip=null; truck.remove();
      for (const el of [track,pile]) {
        const melt=el.animate([{opacity:1},{opacity:0}],{delay:4800,duration:4600,fill:'forwards'});
        melt.onfinish=()=>el.remove();
      }
      planAfter(nextStop ? 600 : 46000+Math.random()*22000);
    };
    animation.onfinish=arrive;
    arrivalTimer=setTimeout(arrive,duration+160);
    // Desktop-level WebKit sometimes freezes its document timeline while macOS
    // still composites the village. Seek the current trip by elapsed wall time.
    if (window.snowfallSurface==='wallpaper' && document.hidden) {
      const animations=[animation,rolling,gathering,spraying];
      for (const a of animations) a.pause();
      const followClock=()=>{
        if (trip?.animation!==animation) return;
        const elapsed=Date.now()-started;
        if (elapsed>=duration) { arrive(); return; }
        for (const a of animations) a.currentTime=elapsed;
        backgroundTick=setTimeout(followClock,180);
      };
      followClock();
    }
  }
  function takeWheel(x,y) {
    if (!trip || resting()) return false;
    const hit=trip.truck.getBoundingClientRect(), px=x*scene.clientWidth, py=y*scene.clientHeight;
    if (px<hit.left || px>hit.right || py<hit.top || py>hit.bottom) return false;
    const home={x:hit.left+hit.width/2,y:hit.bottom};
    const direction=px<home.x ? -1 : 1;
    const aim={x:home.x+direction*clamp(scene.clientWidth*.22,95,250),
      y:clamp(home.y-hit.width*.40,scene.clientHeight*.54,scene.clientHeight*.93)};
    const end=lane(home,hit.width,aim,obstacles(),trip.exit);
    if (end) drive(home,end,trip.exit,hit.width);
    else {
      // A covered lane can still be requested for the next trip.
      nextStop={x:clamp(aim.x/scene.clientWidth,0,1),y:aim.y/scene.clientHeight};
      trip.truck.querySelector('.plow-paint').animate(
        [{transform:'rotate(0deg)'},{transform:'rotate(-4deg)'},{transform:'rotate(0deg)'}],{duration:340});
    }
    return true;
  }
  window.VillageLife=Object.freeze({takeWheel});
  window.addEventListener('snowfall-planted',({detail})=>{
    if (!detail || !Number.isFinite(detail.x) || !Number.isFinite(detail.y) || resting()) return;
    nextStop={x:detail.x,y:detail.y};
    if (!trip) planAfter(700);
  });
  window.addEventListener('snowfall-widget-frames',({detail})=>{
    widgetFrames=Array.isArray(detail) ? detail.filter(r=>[r?.x,r?.y,r?.width,r?.height].every(Number.isFinite)) : [];
  });
  window.addEventListener('snowfall-clock-tick',checkLane);
  window.addEventListener('resize',()=>{park();planAfter(5400);});
  document.addEventListener('visibilitychange',maintain);
  motion.addEventListener('change',maintain);
  const changes=new MutationObserver(maintain);
  changes.observe(scene,{attributes:true,attributeFilter:['class']});
  changes.observe(panel,{attributes:true,attributeFilter:['hidden']});
  scene.addEventListener('toggle',maintain,true);
  scene.addEventListener('close',maintain,true);
  maintain();
})();
