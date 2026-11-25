/* One little plow tends the lane between visits to the snow yard. */
(() => {
  'use strict';
  const scene = document.querySelector('#scene');
  const meadow = document.querySelector('#snow-playground');
  const panel = document.querySelector('#tools-panel');
  if (!scene || !meadow) return;
  const layer = document.createElement('div');
  layer.id = 'village-life';
  layer.setAttribute('aria-hidden', 'true');
  document.querySelector('#wallpaper').after(layer);
  const motion = matchMedia('(prefers-reduced-motion: reduce)');
  const clamp = (value, lo, hi) => Math.max(lo, Math.min(hi, value));
  let nextStop = null, trip = null, timer = 0, due = 0, widgetFrames = [];
  let backgroundTick = 0, arrivalTimer = 0;

  function resting() {
    return meadow.hidden || meadow.dataset.mode !== 'idle' || motion.matches ||
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
    meadow.classList.remove('plow-away');
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

  // Pick a nearby foreground lane whose tread and blade clear real windows,
  // village doors, planted friends and the painted activity signs.
  function destination(home, size, goal) {
    const width = scene.clientWidth, height = scene.clientHeight;
    const blocks = [...scene.querySelectorAll('.village-house,.wallpaper-cottage,.free-snow-figure,.free-snow-rival,.meadow-prop:not([data-art="truck"]),.scene-controls,#village-clock,#postal-counter')].map(el => el.getBoundingClientRect()).filter(r => r.width && r.height);
    for (const r of widgetFrames) blocks.push({left:r.x*width,right:(r.x+r.width)*width,top:r.y*height,bottom:(r.y+r.height)*height});
    const direction = goal ? Math.sign(goal.x * width - home.x) || 1 : 1;
    const reach = clamp(width * .19, 92, 240);
    const minY = Math.max(size, Math.min(height * .69, home.y - size * .72));
    const aim = goal ? {x:clamp(goal.x*width, home.x-reach, home.x+reach),
      y:clamp(goal.y*height+size*.35, minY, home.y)} : {x:home.x+reach, y:home.y-size*.44};
    let best = null, bestScore = -Infinity;
    for (const sign of [direction,-direction]) {
      for (const rise of [.42,.9,1.5,2.1]) {
        for (const length of [1,.68,.42]) {
          const p = {x:clamp(home.x+sign*reach*length, size*.54, width-size*.54),
            y:clamp(home.y-size*rise, minY, height-7)};
          const distance = Math.hypot(p.x-home.x,p.y-home.y);
          if (distance < size*.88) continue;
          let clear = true;
          for (let i=1; i<=10 && clear; i++) {
            const t=i/10, x=home.x+(p.x-home.x)*t, y=home.y+(p.y-home.y)*t;
            clear = !blocks.some(b => x+size*.32>b.left && x-size*.32<b.right && y>b.top && y-size*.33<b.bottom);
          }
          if (!clear) continue;
          const score = distance*.18 - Math.hypot(p.x-aim.x, p.y-aim.y);
          if (score>bestScore) { bestScore=score; best=p; }
        }
      }
    }
    return best;
  }

  function checkLane() {
    if (!due || trip || Date.now()+20 < due) return;
    clearTimeout(timer); due = 0;
    if (resting()) return;
    const free = window.FreeSnow?.state();
    if (free?.fightActive || free?.holding) { planAfter(3800); return; }
    const drawing = meadow.querySelector('[data-art="truck"] .main-sprite')?.getBoundingClientRect();
    if (!drawing?.height) { planAfter(5000); return; }
    const home = {x:drawing.left+drawing.width/2, y:drawing.bottom};
    const goal = nextStop;
    const end = destination(home, drawing.width, goal);
    if (!end) { nextStop = null; planAfter(28000); return; }
    nextStop = null;
    park();
    const dx=end.x-home.x, dy=end.y-home.y, sign=Math.sign(dx) || 1;
    const span=Math.hypot(dx,dy), angle=Math.atan2(dy,dx);
    const speed=clamp(2600+span*9, 3400, 5500);
    const duration=2*speed+1300;
    const track=part('span','plow-track',layer);
    Object.assign(track.style,{left:home.x+'px',top:(home.y-3)+'px',width:span+'px',
      transform:'rotate('+angle+'rad)'});
    const tread=part('span','plow-tread',track);
    const rolling=tread.animate([{transform:'scaleX(0)'},{transform:'scaleX(1)'}],
      {duration:speed,easing:'ease-in-out',fill:'both'});

    // The blade gathers a low windrow; it stays beside the tracks after the truck backs home.
    const pile=part('img','plow-windrow',layer,'yard-pile');
    Object.assign(pile.style,{left:(end.x+sign*drawing.width*.28)+'px',top:end.y+'px',width:drawing.width*.44+'px'});
    const gathering=pile.animate([{opacity:0,transform:'translate(-50%,-85%) scale(.2)'},{opacity:.9,transform:'translate(-50%,-85%) scale(1)'}],
      {delay:speed*.67,duration:speed*.32,easing:'ease-out',fill:'both'});

    const truck=part('div','plow-rig',layer);
    Object.assign(truck.style,{left:home.x+'px',top:home.y+'px',width:drawing.width+'px',height:drawing.height+'px'});
    const body=part('div','plow-body',truck);
    part('img','plow-paint',body,'plow');
    const plume=part('span','plow-spray',body);
    for (let i=0; i<3; i++) part('i','',plume);
    body.style.transform='scaleX('+sign+')';
    const placement=(x,y,depth) => 'translate(-50%,-100%) translate('+x+'px,'+y+'px) scale('+depth+')';
    const dock=placement(0,0,1), bank=placement(dx,dy,.87);
    const animation=truck.animate([{transform:dock,easing:'ease-in-out'},
      {offset:speed/duration,transform:bank},{offset:(speed+1300)/duration,transform:bank,easing:'ease-in-out'},
      {transform:dock}],{duration,fill:'both'});
    const spraying=plume.animate([{opacity:0},{opacity:.88,offset:.15},{opacity:.88,offset:.40},{opacity:0,offset:.47},{opacity:0}],
      {duration,fill:'both'});
    meadow.classList.add('plow-away');
    trip={truck,animation};
    const started=Date.now();
    let finished=false;
    const arrive=() => {
      if (finished || trip?.animation!==animation) return;
      finished=true; clearTimeout(backgroundTick); clearTimeout(arrivalTimer);
      trip=null; truck.remove(); meadow.classList.remove('plow-away');
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
    park();
    window.SnowPlayground.press('plow');
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
  changes.observe(meadow,{attributes:true,attributeFilter:['data-mode','hidden']});
  changes.observe(panel,{attributes:true,attributeFilter:['hidden']});
  scene.addEventListener('toggle',maintain,true);
  scene.addEventListener('close',maintain,true);
  maintain();
})();
