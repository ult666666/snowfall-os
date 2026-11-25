/* Open scenery is a play surface. Native desktop events and browser pointers
   enter the same gesture model in normalized, top-left scene coordinates. */
(() => {
  'use strict';
  const scene = document.querySelector('#scene');
  const layer = document.querySelector('#free-snow');
  const meadow = document.querySelector('#snow-playground');
  const panel = document.querySelector('#tools-panel');
  const bridge = window.webkit?.messageHandlers?.snowfallWindow;
  const keyPrefix = 'snowfall-os.free-snow.v1.';
  let saveKey = keyPrefix+(window.snowfallGroundDisplay || 'demo');
  const stages = ['', 'yard-snow-base', 'yard-snow-middle', 'snowman'];
  const packTimes = [360, 790, 1260];
  const maxFigures = 12;
  const clamp = (v, min, max) => Math.max(min, Math.min(max, v));
  const distance = (a, b) => Math.hypot((a.x-b.x)*scene.clientWidth, (a.y-b.y)*scene.clientHeight);
  const validPoint = p => p && Number.isFinite(p.x) && Number.isFinite(p.y) &&
    p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1;

  function create(tag, cls, parent = layer) {
    const node = document.createElement(tag);
    node.className = cls;
    parent.append(node);
    return node;
  }
  function place(node, p) {
    node.style.left = p.x*100+'%';
    node.style.top = p.y*100+'%';
  }
  function readFigures(fallback = []) {
    try {
      const data = JSON.parse(localStorage.getItem(saveKey));
      if (Array.isArray(data)) return data.filter(p => validPoint(p) && typeof p.id === 'string' &&
        Number.isInteger(p.stage) && p.stage >= 1 && p.stage <= 3).slice(-maxFigures);
    } catch { return fallback; }
    return [];
  }

  const friends = create('div','free-snow-friends');
  const cursor = create('i','free-snow-cursor');
  const packingRing = create('i','free-snow-packing');
  const marker = create('i','free-snow-aim');
  const caption = create('span','free-snow-caption');
  const live = create('span','sr-only');
  live.setAttribute('role','status');
  const hint = create('span','free-snow-hint',meadow);
  hint.textContent = 'Click snow to throw · Hold to build';
  marker.hidden = cursor.hidden = caption.hidden = packingRing.hidden = true;
  let widgetFrames = [];
  let figures = readFigures(), held = null, round = null, last = {x:.5,y:.65};
  let totals = {shots:0, returns:0, dodges:0, player:0, flurry:0};
  let timer, captionTimer, captionRival = null, learnedBuild = false, learnedThrow = false;
  let published = '', pointerId = null, keyboardHeld = false;

  function enabled() {
    return !scene.matches('.yard-active,.room-mode,.custom-image') &&
      panel.hidden && !document.querySelector('dialog[open]') &&
      (!meadow.dataset.mode || meadow.dataset.mode === 'idle');
  }
  function state() {
    return {snowmen:figures.length, holding:Boolean(held), holdStage:held?.stage || 0,
      fightActive:Boolean(round), plantedRival:Boolean(round?.friendId), incoming:Boolean(round?.aim), groundActive:enabled(),
      lastX:last.x, lastY:last.y, ...totals};
  }
  function publish() {
    scene.classList.toggle('free-snow-playing', Boolean(round || held));
    packingRing.hidden = !held;
    hint.hidden = !enabled() || Boolean(round || held) || (learnedBuild && learnedThrow);
    if (!bridge || window.snowfallSurface !== 'wallpaper') return;
    const snapshot = state(), signature = JSON.stringify(snapshot);
    if (signature === published) return;
    published = signature;
    bridge.postMessage({action:'freeSnowState',state:snapshot});
  }
  function updateFigure(node, p) {
    const size = Math.round((40 + 61*p.y)*clamp(scene.clientWidth/1120, .76, 1.22));
    const half = Math.max(1,size/2);
    const pixelX = p.x*scene.clientWidth, pixelY = p.y*scene.clientHeight;
    node.style.setProperty('--figure-size',size+'px');
    if (pixelX > scene.clientWidth-half) node.style.setProperty('--lean-x',(scene.clientWidth-half-pixelX)+'px');
    else if (pixelX < half) node.style.setProperty('--lean-x',(half-pixelX)+'px');
    else node.style.setProperty('--lean-x','0px');
    node.style.setProperty('--lean-y',Math.max(0, size-pixelY)+'px');
    place(node,p);
    node.dataset.x = String(p.x); node.dataset.y = String(p.y);
    if (node.dataset.stage !== String(p.stage)) {
      node.dataset.stage = String(p.stage);
      node.hidden = !p.stage;
      if (p.stage) node.firstElementChild.src = 'assets/props/'+stages[p.stage]+'.png';
    }
  }
  function figure(p, cls, parent) {
    const node = create('span','free-snow-figure '+cls,parent);
    const art = create('img','',node);
    art.draggable = false; art.alt = '';
    updateFigure(node,p);
    return node;
  }
  function drawFriends() {
    friends.replaceChildren();
    for (const p of figures) {
      if (held?.progress && held.id === p.id) continue;
      const node = figure(p,'free-snow-planted',friends);
      node.dataset.friendId = p.id;
      if (round?.friendId === p.id) node.classList.add('free-snow-rival');
    }
  }
  function label(text, p, lifetime = 1200) {
    clearTimeout(captionTimer);
    caption.textContent = text; caption.hidden = false; live.textContent = text;
    const margin = Math.min(.46, 102/scene.clientWidth);
    const figureHeight = (40+61*p.y)*clamp(scene.clientWidth/1120,.76,1.22);
    const gap = (p.y*scene.clientHeight < figureHeight+34 ? figureHeight+36 : -figureHeight-4)/scene.clientHeight;
    place(caption,{x:clamp(p.x,margin,1-margin),y:clamp(p.y+gap,.055,.97)});
    if (lifetime) captionTimer = setTimeout(() => {
      caption.hidden = true; captionRival?.remove(); captionRival = null;
    },lifetime);
  }
  function softMotion() {
    return scene.classList.contains('reduce-motion') || matchMedia('(prefers-reduced-motion: reduce)').matches;
  }
  function ball(a,b,duration = 420) {
    if (softMotion()) return;
    const node = create('img','free-snow-ball');
    node.src = 'assets/props/yard-ball.png'; node.alt = ''; node.draggable = false;
    const w = scene.clientWidth, h = scene.clientHeight;
    const transform = (x,y,scale) => 'translate('+x+'px,'+y+'px) translate(-50%,-50%) scale('+scale+')';
    const midY = Math.min(a.y,b.y)*h - clamp(distance(a,b)*.26,17,70);
    const arc = node.animate([
      {transform:transform(a.x*w,a.y*h,1)},
      {transform:transform((a.x+b.x)*w/2,midY,1.18),offset:.46},
      {transform:transform(b.x*w,b.y*h,.72)}
    ],{duration,easing:'ease-in-out',fill:'both'});
    arc.oncancel = arc.onfinish = () => node.remove();
  }
  function plant() {
    const p = {id:held.id, x:held.x, y:held.y, stage:held.stage};
    const other = readFigures(figures).filter(v => v.id !== p.id);
    if (p.stage > 0) other.push(p);
    figures = other.slice(-maxFigures);
    try { localStorage.setItem(saveKey,JSON.stringify(figures)); } catch {}
    learnedBuild = true;
    label(['Swept away','A snowball!','Two snowballs!','A new snow friend!'][p.stage],p);
    if (!held.brushing) {
      window.dispatchEvent(new CustomEvent('snowfall-planted',{detail:{x:p.x,y:p.y,stage:p.stage}}));
    }
  }
  function hitFriend(p) {
    const x=p.x*scene.clientWidth, y=p.y*scene.clientHeight;
    const nodes = [...friends.children].reverse();
    const found = nodes.find(node => {
      const box=node.getBoundingClientRect();
      return x>=box.left+box.width*.12 && x<=box.right-box.width*.12 &&
        y>=box.top+box.height*(node.dataset.stage==='1' ? .50 : .12) && y<=box.bottom+6;
    });
    return found ? figures.find(f => f.id===found.dataset.friendId) :
      [...figures].reverse().find(f => distance(p,f) < 17);
  }
  function dismissRound(keepRival = false) {
    if (round?.friendId) {
      for (const node of friends.children) node.classList.remove('free-snow-rival');
    } else if (round) {
      if (keepRival) captionRival = round.node; else round.node.remove();
    }
    round = null; marker.hidden = true;
  }
  function clearPlay() {
    clearTimeout(timer); clearTimeout(captionTimer);
    held?.node?.remove(); held = null; pointerId = null; keyboardHeld = false;
    dismissRound(); captionRival?.remove(); captionRival = null;
    caption.hidden = true; cursor.hidden = true;
    drawFriends(); publish();
  }
  function chooseRival(p) {
    const w = scene.clientWidth, h = scene.clientHeight;
    const dx = clamp(w*.10,68,146)/w, dy = clamp(h*.055,24,57)/h;
    const side = p.x < .5 ? 1 : -1;
    const obstacles = [...scene.querySelectorAll(
      '.village-house,.wallpaper-cottage,#village-clock,.scenery-door,#postal-counter,#snow-playground,#surface-controls nav'
    )].map(node => node.getBoundingClientRect()).filter(rect => rect.width && rect.height);
    for (const rect of widgetFrames) {
      obstacles.push({left:rect.x*w,top:rect.y*h,right:(rect.x+rect.width)*w,bottom:(rect.y+rect.height)*h});
    }
    const sites = [[side,-1],[-side,-1],[side,1],[-side,1],[0,2.6],[0,-2.6]].map(([x,y]) =>
      ({x:clamp(p.x+x*dx,.055,.945),y:clamp(p.y+y*dy,.12,.98),stage:3}));
    return sites.find(pt => !obstacles.some(rect => pt.x*w > rect.left-20 && pt.x*w < rect.right+20 &&
      pt.y*h > rect.top-4 && pt.y*h < rect.bottom+38)) || sites[0];
  }
  function throwBall(p, now) {
    if (!round) {
      captionRival?.remove(); captionRival = null;
      const friend = hitFriend(p);
      const rival = friend || chooseRival(p);
      const node = friend ? null : figure(rival,'free-snow-rival',layer);
      round = {rival,node,friendId:friend?.id,next:now+1250,lastShot:0,aim:null};
      if (friend) drawFriends();
      totals = {shots:0,returns:0,dodges:0,player:0,flurry:0};
    }
    if (now - round.lastShot < 500) return;
    learnedThrow = true; round.lastShot = now; totals.shots++; totals.player++;
    ball(p,{x:round.rival.x,y:round.rival.y-.028});
    if (totals.player === 3) {
      label('You win!  3 · '+totals.flurry,round.rival,1550); dismissRound(true);
    } else {
      label('You '+totals.player+' · '+totals.flurry+' Flurry',round.rival,1100);
    }
  }
  function tick(now = Date.now()) {
    clearTimeout(timer);
    if (held) {
      const added = packTimes.filter(ms => now-held.at >= ms).length;
      const stage = held.brushing ? 3-added : Math.min(3,held.startStage+added);
      if (added && added !== held.progress) {
        held.progress = added; held.stage = stage;
        if (!held.node) {
          dismissRound(); captionRival?.remove(); captionRival = null;
          held.node = figure(held,'free-snow-growing',layer);
          drawFriends();
        }
        updateFigure(held.node,held);
        const words = held.brushing ? ['Release to clear','Brushing the base…','Brushing off snow…'] :
          ['','Packing the base…','Stacking the belly…','Release to plant'];
        label(words[stage],held,0);
      }
    }
    if (round && now >= round.next) {
      if (!round.aim) {
        round.aim = {...last}; round.next = now + 1050; totals.returns++;
        place(marker,round.aim); marker.hidden = false;
        ball({x:round.rival.x,y:round.rival.y-.028},round.aim,1050);
        label('Incoming! Move to dodge',round.rival,950);
      } else {
        if (distance(last,round.aim) >= 26) totals.dodges++; else totals.flurry++;
        marker.hidden = true; round.aim = null; round.next = now+1500;
        if (totals.flurry === 3) {
          label('Flurry wins!  '+totals.player+' · 3',round.rival,1550); dismissRound(true);
        } else {
          label('You '+totals.player+' · '+totals.flurry+' Flurry',round.rival,1050);
        }
      }
    }
    if (held || round) {
      const nextPack = held && held.progress<3 ? packTimes.find(ms => now-held.at<ms) : null;
      const packAt = nextPack == null ? Infinity : held.at+nextPack;
      const due = Math.min(packAt, round?.next ?? Infinity);
      if (Number.isFinite(due)) timer = setTimeout(() => tick(),Math.max(1,due-Date.now()));
    }
    publish();
  }
  function begin(p) {
    if (held || !enabled()) return false;
    if (window.VillageLife?.takeWheel(p.x,p.y)) { clearPlay(); return false; }
    last = p; place(packingRing,p);
    const existing = hitFriend(p);
    held = {x:existing?.x ?? p.x,y:existing?.y ?? p.y,start:p,at:Date.now(),
      id:existing?.id || Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,8),
      startStage:existing?.stage || 0,brushing:existing?.stage===3,progress:0,stage:0,node:null};
    tick(); return true;
  }
  function move(p) {
    if (!held && !round) return;
    last = p;
    if (held && distance(p,held.start)>12) {
      held.node?.remove(); held = null;
      if (!round) caption.hidden = true;
      drawFriends(); tick();
    }
  }
  function end(p) {
    if (!held) return;
    move(p);
    if (!held) return;
    const now = Date.now(); tick(now);
    if (held.progress) plant(); else throwBall(p,now);
    held.node?.remove(); held = null; drawFriends(); tick();
  }
  const point = e => ({x:clamp(e.clientX/scene.clientWidth,0,1),y:clamp(e.clientY/scene.clientHeight,0,1)});
  const control = 'button,a,input,select,textarea,[contenteditable=true],nav,dialog,#tools-panel,#snow-playground,#postal-counter,#porch-play,.door-actions';
  scene.addEventListener('pointerdown',e => {
    if (!e.isPrimary || e.metaKey || e.ctrlKey || e.altKey || e.shiftKey || e.button !== 0) return;
    if (e.target.closest(control)) { if (round || held) clearPlay(); return; }
    // The first outside click belongs to the open cottage interaction.
    if (scene.classList.contains('door-actions-open') || !document.querySelector('#porch-play').hidden) return;
    if (begin(point(e))) {pointerId = e.pointerId; cursor.hidden = true;}
  },{capture:true});
  window.addEventListener('pointermove',e => {
    if (e.isPrimary && (pointerId === e.pointerId || round)) move(point(e));
  },{passive:true});
  window.addEventListener('pointerup',e => {
    if (pointerId !== e.pointerId) return;
    pointerId = null; end(point(e));
  });
  window.addEventListener('pointercancel',e => { if (pointerId === e.pointerId) clearPlay(); });
  window.addEventListener('blur',() => { if (held || round) clearPlay(); });
  window.addEventListener('keydown',e => {
    if (e.key==='Escape' && (held || round) && enabled()) {
      e.preventDefault(); e.stopImmediatePropagation(); clearPlay(); return;
    }
    if (document.activeElement!==scene || !enabled() || e.metaKey || e.ctrlKey || e.altKey) return;
    const arrows = {ArrowLeft:[-1,0],ArrowRight:[1,0],ArrowUp:[0,-1],ArrowDown:[0,1]};
    if (arrows[e.key]) {
      const [dx,dy] = arrows[e.key];
      const p = {x:clamp(last.x+dx*44/scene.clientWidth,.025,.975),y:clamp(last.y+dy*44/scene.clientHeight,.04,.98)};
      move(p); last=p; place(cursor,p);cursor.hidden=false;e.preventDefault();
    } else if (e.code==='Space') {
      e.preventDefault();
      if (!e.repeat && begin({...last})) keyboardHeld=true;
    }
  },{capture:true});
  window.addEventListener('keyup',e => {
    if (e.code==='Space' && keyboardHeld) {keyboardHeld=false;e.preventDefault();end({...last});}
  });
  scene.addEventListener('focus',() => { place(cursor,last);cursor.hidden=false; });
  scene.addEventListener('blur',() => {cursor.hidden=true;if (keyboardHeld) clearPlay();});
  window.addEventListener('snowfall-ground-input',({detail:d}) => {
    if (!d || window.snowfallSurface!=='wallpaper') return;
    if (d.phase==='cancel') {clearPlay();return;}
    if (!validPoint(d) || !enabled()) return;
    const p = {x:d.x,y:d.y};
    if (d.phase==='down') begin(p); else if (d.phase==='up') end(p); else if (d.phase==='move') move(p);
  });
  window.addEventListener('snowfall-widget-frames',({detail}) => {
    if (Array.isArray(detail)) widgetFrames = detail.filter(r => r &&
      [r.x,r.y,r.width,r.height].every(Number.isFinite) && r.width>0 && r.height>0);
  });
  window.addEventListener('snowfall-ground-clock',() => {if (held || round) tick();});
  window.addEventListener('snowfall-ground-display',({detail:id}) => {
    if (!window.snowfallNative || window.snowfallSurface!=='preview' || typeof id!=='string' ||
        !/^[A-Za-z0-9-]{1,64}$/.test(id) || saveKey === keyPrefix+id) return;
    window.snowfallGroundDisplay = id;
    saveKey = keyPrefix+id;
    figures = readFigures();
    clearPlay();
  });
  window.addEventListener('storage',e => {
    if (!e.key || e.key===saveKey) {figures=readFigures();drawFriends();publish();}
  });
  window.addEventListener('resize',() => {
    drawFriends();
    if (held?.node) updateFigure(held.node,held);
    if (round?.node) updateFigure(round.node,round.rival);
  });
  window.addEventListener('snowfall-surface',clearPlay);
  document.addEventListener('visibilitychange',() => {
    if (document.hidden && window.snowfallSurface!=='wallpaper') clearPlay();
  });
  const checkMode = () => {
    if (!enabled() && (held || round)) clearPlay(); else publish();
  };
  new MutationObserver(checkMode).observe(scene,{attributes:true,attributeFilter:['class']});
  new MutationObserver(checkMode).observe(meadow,{attributes:true,attributeFilter:['data-mode']});
  new MutationObserver(checkMode).observe(panel,{attributes:true,attributeFilter:['hidden']});
  window.FreeSnow = Object.freeze({state});
  drawFriends(); publish();
})();
