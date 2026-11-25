/* Finder owns the houses. The wallpaper draws their doorsteps and a short game around them. */
(() => {
  'use strict';
  const scene = document.querySelector('#scene');
  const host = document.querySelector('#porch-play');
  const houses = document.querySelector('#wallpaper-cottages');
  const status = document.querySelector('#status');
  const native = Boolean(window.snowfallNative);
  const minmax = (value, low, high) => Math.max(low, Math.min(high, value));
  let plots = [];
  let round = null;
  const scenicPlots = new Map();

  const samples = new Map();
  let streets = [], hoveredId = null;

  function camera() {
    const art = document.querySelector('#wallpaper'), width=art.clientWidth, height=art.clientHeight;
    const zoom=Math.max(width/2560,height/1600), narrow=width<=580;
    return {width,height,zoom,left:(width-2560*zoom)*(narrow?.49:.57),top:(height-1600*zoom)*(narrow?.5:.56)};
  }
  function project(x,y,view) {
    return {x:view.left+x*2560*view.zoom, y:view.top+y*1600*view.zoom};
  }
  // A lamp, path and shadow already belong to the painted street. A little compressed
  // powder and one set of boot prints cross the short gap between a live door and its lane.
  function paint(ctx,width,height,list) {
    for (const p of list) {
      ctx.save();ctx.translate(p.x*width,p.y*height);ctx.scale(p.size,p.size);
      const doorX=([2,4,6].includes(p.variant)?-.20:-.05);
      const shade=ctx.createLinearGradient(-.15,-.08,.55,.07);
      shade.addColorStop(0,'rgba(102,122,151,.24)'); shade.addColorStop(1,'rgba(133,154,180,0)');
      ctx.fillStyle=shade;ctx.beginPath();ctx.moveTo(-.43,-.025);
      ctx.bezierCurveTo(-.20,.015,.18,-.125,.41,-.11);
      ctx.bezierCurveTo(.55,-.08,.67,-.05,.66,-.012);
      ctx.bezierCurveTo(.48,.058,-.20,.065,-.43,-.025);ctx.fill();
      for (let step=0;step<4;step++) {
        const x=doorX+Math.sin(step*.50)*.082+step*.013+(step%2)*.026;
        const y=.018+step*.036;
        ctx.fillStyle='rgba(135,151,168,'+(.43-step*.045)+')';ctx.beginPath();
        ctx.ellipse(x,y,.016,.008,-.30,0,Math.PI*2);ctx.fill();
        ctx.fillStyle='#fff4e4';ctx.beginPath();ctx.ellipse(x-.003,y+.008,.013,.003,-.30,0,Math.PI*2);ctx.fill();
      }
      ctx.restore();
    }
  }
  function samplePlot(button) {
    const box = button.getBoundingClientRect();
    return {id:button.dataset.sample, variant:Number(button.dataset.variant),x:(box.left+box.width/2)/innerWidth,
      y:(box.top+box.height*.88)/innerHeight,size:box.width};
  }
  function facade(node,house) {
    const image = document.createElement('img');
    image.src='assets/houses/cottage-'+house.variant+'.png?v=6.0.0';
    image.alt='';image.draggable=false;
    const sign=document.createElement('span');sign.className='house-name';sign.textContent=house.name;
    const hint=document.createElement('small');
    hint.textContent=native ? 'Click to play · Double-click to open' : 'Click to play · Double-click for widgets';
    sign.append(hint);
    node.append(image,sign);
  }
  function place(node,x,y,size) {
    node.style.left=x+'px';node.style.top=y+'px';node.style.width=size+'px';
    node.style.zIndex=String(Math.round(y));
  }
  function identify(id) {
    hoveredId=id;
    for(const node of houses.children) node.classList.toggle('is-identified',node.dataset.houseId===id);
  }
  const localWindow = native && window.snowfallSurface === 'preview';
  if (localWindow) {
    document.documentElement.setAttribute('data-local-village','');
    houses.removeAttribute('aria-hidden');
    houses.setAttribute('aria-label','Your folder cottages');
  }
  const houseActions = document.createElement('div');
  houseActions.className = 'door-actions';
  houseActions.hidden = true;
  if (localWindow) scene.append(houseActions);

  function closeDoorActions() {
    houseActions.hidden = true;
    houseActions.replaceChildren();
  }
  function offerDoor(plot) {
    if (!localWindow) return;
    const bridge = window.webkit.messageHandlers.snowfallWindow;
    const name = document.createElement('strong');
    name.textContent = plot.name;
    const open = document.createElement('button');
    open.type = 'button'; open.textContent = 'Open folder';
    open.addEventListener('click', () => {
      closeDoorActions();
      bridge.postMessage('openHouseFolder:' + plot.id);
    });
    const room = document.createElement('button');
    room.type = 'button'; room.textContent = 'House widgets';
    room.addEventListener('click', () => {
      closeDoorActions();
      bridge.postMessage({action:'houseRoom',id:plot.id});
    });
    houseActions.replaceChildren(name, open, room);
    houseActions.hidden = false;
    const side = houseActions.offsetWidth / 2;
    houseActions.style.left = Math.max(side+6,Math.min(innerWidth-side-6,plot.x*innerWidth))+'px';
    const roof = plot.y*innerHeight-plot.size*.89;
    houseActions.style.top = (roof > houseActions.offsetHeight + 6 ?
      roof-houseActions.offsetHeight-4 : Math.min(innerHeight-houseActions.offsetHeight-4,plot.y*innerHeight+5))+'px';
  }
  if (localWindow) {
    scene.addEventListener('pointerdown',event => {
      if (!event.target.closest('.wallpaper-cottage,.door-actions,.porch-return')) closeDoorActions();
    });
    window.addEventListener('snowfall-surface',closeDoorActions);
    window.addEventListener('resize',closeDoorActions);
  }

  function showLocalHouses() {
    const nodes = document.createDocumentFragment();
    for (const plot of plots) {
      if (plot.drawHouse !== true || typeof plot.name !== 'string' ||
          !Number.isInteger(plot.variant) || plot.variant < 1 || plot.variant > 6) continue;
      const node = document.createElement(localWindow ? 'button' : 'div');
      node.className='wallpaper-cottage'; node.dataset.houseId=plot.id;
      if (localWindow) {
        node.type='button';
        node.setAttribute('aria-label',plot.name+' folder cottage');
        node.addEventListener('click', event => {
          if (event.detail > 1) return;
          tap(plot); offerDoor(plot);
        });
        node.addEventListener('dblclick', () => {
          stop(); closeDoorActions();
          window.webkit.messageHandlers.snowfallWindow.postMessage('openHouseFolder:'+plot.id);
        });
        node.addEventListener('contextmenu', event => { event.preventDefault(); offerDoor(plot); });
      }
      place(node,plot.x*innerWidth,plot.y*innerHeight,plot.size);facade(node,plot);nodes.append(node);
    }
    houses.replaceChildren(nodes);identify(hoveredId);
  }
  function populateSamples() {
    const village=document.querySelector('#demo-village');
    for(const house of SnowRooms.samples) {
      const button=document.createElement('button');button.type='button';button.className='village-house';
      button.dataset.sample=house.id;button.dataset.variant=house.variant;
      button.setAttribute('aria-label',house.name+' cottage. Play snowball catch');facade(button,house);
      village.append(button);samples.set(house.id,button);
    }
  }
  function positionSamples(view) {
    if (native) return;
    SnowRooms.samples.forEach((house,i)=>{
      const button=samples.get(house.id);
      const slot=streets[house.street]?.[house.lot];
      // A phone looks at a narrow slice of the illustration. In that camera, use the
      // visible parcels and keep the rest of the doors reachable in the Houses menu.
      if(slot) {
        const p=project(slot.x,slot.y,view),size=Math.max(28,slot.size*view.zoom);
        button.hidden=p.x-size*.29<0||p.x+size*.29>view.width||p.y<=25||p.y>view.height-12;
        if(!button.hidden)place(button,p.x,p.y,size);
      } else {
        // Directly opening index.html from disk can disable JSON requests. Preserve a playable village.
        const row=house.street,col=(i%3+.55)/3;
        place(button,view.width*(.36+col*.59),view.height*(.397+row*.145),Math.min(view.width*.14,view.height*(.064+row*.017)));
      }
    });
  }
  function positionScenery() {
    const view=camera();
    const clock=document.querySelector('#village-clock'),clockCenter=project(.09,.372,view);
    clock.style.left=clockCenter.x+'px';clock.style.top=clockCenter.y+'px';clock.style.width=42*1.6*view.zoom+'px';
    clock.style.fontSize=42*1.6*view.zoom+'px';
    clock.hidden=clockCenter.x<0||clockCenter.x>view.width||clockCenter.y<0||clockCenter.y>view.height;
    if(native) { showLocalHouses();return; }
    positionSamples(view);
    for (const door of document.querySelectorAll('[data-scenery]')) {
      const bakery=door.dataset.scenery==='bakery';
      const {x,y}=project(bakery?.2222:.0967,bakery?.5285:.5053,view);
      const size=(bakery?.12:.0611)*2560*view.zoom;
      door.hidden=x<0||x>view.width||y<0||y>view.height;
      door.style.left=x+'px';door.style.top=y+'px';door.style.width=size+'px';door.style.height=size*.84+'px';
      const plot={id:'scenery:'+door.dataset.scenery,x:x/view.width,y:Math.min(1,(y+size*.39)/view.height),size:Math.min(116,size)};
      scenicPlots.set(plot.id,plot);
      if(!bakery) door.onclick=()=>tap(plot);
    }
  }
  function visiblePlots() {
    if (native) return !scene.classList.contains('room-mode') && !scene.classList.contains('yard-active') ? plots : [];
    if (!document.querySelector('#demo-village').getClientRects().length) return [];
    return Array.from(document.querySelectorAll('[data-sample]'), samplePlot).filter(p => p.size > 0);
  }
  function valid(p) {
    return p && typeof p.id === 'string' && p.id.length > 0 && p.id.length <= 128 &&
      Number.isFinite(p.x) && p.x >= 0 && p.x <= 1 && Number.isFinite(p.y) && p.y >= 0 && p.y <= 1.03 &&
      Number.isFinite(p.size) && p.size >= 12 && p.size <= 260;
  }
  function stop() {
    if (!round) return;
    for (const timer of round.timers) clearTimeout(timer);
    if (status.textContent === round.message) status.textContent = '';
    if (round.sweep) window.removeEventListener('pointermove', round.sweep);
    if (host.contains(document.activeElement) && round.opener?.isConnected) round.opener.focus({preventScroll:true});
    round = null;
    host.replaceChildren();
    host.hidden = true;
    host.style.transform = '';
    delete host.dataset.returns;
  }
  function schedule(game, delay, task) {
    const token = setTimeout(() => {
      game.timers.delete(token);
      if (round === game) task();
    }, delay);
    game.timers.add(token);
    return token;
  }
  function idleLimit(game) {
    clearTimeout(game.idle);
    game.timers.delete(game.idle);
    game.idle = schedule(game, 7800, stop);
  }
  function actor(className, x, y, size) {
    const el = document.createElement('span');
    el.setAttribute('aria-hidden', 'true');
    el.className = className;
    el.style.left = x + 'px';
    el.style.top = y + 'px';
    el.style.width = size + 'px';
    host.append(el);
    return el;
  }
  function returnTarget(game, asset, className, label, x, feet, width) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'porch-return';
    button.setAttribute('aria-label', label);
    button.style.left = x + 'px';
    button.style.top = feet + 'px';
    button.style.setProperty('--figure-width', width + 'px');
    const image = document.createElement('img');
    image.src = 'assets/props/' + asset + '.png?v=6.0.0';
    image.className = className;
    image.alt = '';
    image.draggable = false;
    button.append(image);
    button.addEventListener('click', () => reply(game));
    host.append(button);
    return button;
  }
  function watchMitten(game) {
    if (!matchMedia('(hover:hover) and (pointer:fine)').matches) return;
    let previous = null;
    game.sweep = event => {
      if (event.pointerType !== 'mouse' || event.buttons) { previous = null; return; }
      const inside = game.mitt.contains(event.target);
      if (previous && !previous.inside && inside && !game.busy &&
          Math.hypot(event.clientX-previous.x,event.clientY-previous.y) > 1) reply(game);
      previous = {inside, x:event.clientX, y:event.clientY};
    };
    window.addEventListener('pointermove', game.sweep, {passive:true});
  }
  function animate(game, node, frames, duration) {
    if (game.still || !node.animate) return;
    node.animate(frames, {duration, easing:'linear'});
  }
  function spray(game, point) {
    for (let i = 0; i < (game.still ? 1 : 7); i++) {
      const dot = actor('porch-powder', point.x, point.y, 3 + i % 3);
      const dx = Math.cos(i * 2.29) * (8 + i * 2.5), dy = -8 - (i % 4) * 4;
      animate(game, dot, [
        {transform:'translate(-50%,-50%)', opacity:.95},
        {transform:'translate(' + dx + 'px,' + dy + 'px)', opacity:.85, offset:.45},
        {transform:'translate(' + (dx*1.22) + 'px,' + (dy+14) + 'px)', opacity:0}
      ], 420);
      schedule(game, game.still ? 150 : 415, () => dot.remove());
    }
  }
  function lob(game, from, to, done) {
    const ball = actor('porch-ball', from.x, from.y, game.ballSize);
    if (to === game.to) {
      ball.classList.add('incoming');
      ball.addEventListener('pointerdown', event => {
        if (event.button === 0 && event.isPrimary) {
          event.preventDefault();
          reply(game);
        }
      });
    }
    const flight = game.still ? 110 : 545;
    if (game.still) { ball.style.left = to.x + 'px'; ball.style.top = to.y + 'px'; }
    else {
      const frames = Array.from({length:19}, (_, n) => {
        const t = n / 18;
        const dx = (to.x-from.x)*t;
        const dy = (to.y-from.y)*t - 4*game.arc*t*(1-t);
        return {transform:'translate(-50%,-50%) translate(' + dx + 'px,' + dy + 'px) scale(' + (1 + .22 * Math.sin(Math.PI*t)) + ')'};
      });
      animate(game, ball, frames, flight);
    }
    schedule(game, flight, () => { ball.remove(); spray(game,to); done(); });
  }
  function say(game, message) {
    game.message = message;
    status.textContent = message;
  }
  function create(p) {
    const width = innerWidth, height = innerHeight;
    const size = minmax(p.size * .68, 34, 76);
    const edge = Math.max(size*.57, 23);
    const x = p.x * width, y = p.y * height;
    const dir = x > width / 2 ? -1 : 1;
    const limitX = value => minmax(value, edge, width - edge);
    const feet = minmax(y - p.size * .03, size + 25, height - 12);
    const flurryX = limitX(x + dir*(p.size*.45 + size*.50));
    const mittX = limitX(flurryX + dir * Math.min(96, Math.max(59, p.size*.91)));
    const mittY = minmax(feet + size*.12, 35, height-10);
    const still = scene.classList.contains('reduce-motion') || matchMedia('(prefers-reduced-motion: reduce)').matches;
    const game = {id:p.id, x:p.x, y:p.y, startX:x, startY:y, busy:true, pending:false, returns:0, timers:new Set(), still,
      ballSize:minmax(size*.17,7,12), arc:Math.min(size*.72,feet-size*.47-3),
      from:{x:flurryX+dir*size*.20,y:feet-size*.45}, to:{x:mittX-size*.07, y:mittY-size*.46}, opener:document.activeElement};
    round = game;
    host.hidden = false;
    host.dataset.returns = '0';
    game.flurry = returnTarget(game, 'snowman', 'porch-flurry', 'Toss a snowball to Flurry', flurryX, feet, size).firstElementChild;
    game.mitt = returnTarget(game, 'yard-mitten', 'porch-mitten', 'Return the snowball', mittX, mittY, size*.47);
    watchMitten(game);
    say(game, 'Flurry tosses you a snowball.');
    animate(game, game.flurry, [{transform:'translateY(8%) scale(.76)',opacity:.1},
      {transform:'translateY(-2%) scale(1.03)',opacity:1,offset:.7},
      {transform:'none'}],240);
    schedule(game, still ? 40 : 230, () => lob(game, game.from, game.to, () => ready(game)));
    idleLimit(game);
  }
  function ready(game) {
    game.busy = false;
    game.held = actor('porch-ball porch-held', game.to.x, game.to.y, game.ballSize);
    game.mitt.dataset.loaded = '';
    say(game, 'Snowball caught. Your turn.');
    if (game.pending) { game.pending = false; reply(game); }
  }
  function reply(game) {
    if (game.returns === 3) return;
    if (game.busy) { game.pending = true; return; }
    game.busy = true;
    idleLimit(game);
    game.held?.remove();
    delete game.mitt.dataset.loaded;
    say(game, 'You throw the snowball back.');
    lob(game, game.to, game.from, () => {
      game.returns++;
      host.dataset.returns = String(game.returns);
      animate(game, game.flurry, [{transform:'none'},
        {transform:'translateY(-3%) rotate(-8deg)',offset:.4},
        {transform:'none'}],270);
      if (game.returns === 3) {
        say(game, 'Three in a row!');
        schedule(game, 1900, stop);
      } else {
        say(game, game.returns + ' of 3 returned.');
        schedule(game, 490, () => lob(game, game.from, game.to, () => ready(game)));
      }
    });
  }
  function tap(p) {
    if (!valid(p) || scene.classList.contains('yard-active') || scene.classList.contains('room-mode')) return;
    if (round && round.id === p.id && Math.abs(round.x-p.x)*innerWidth < 8 && Math.abs(round.y-p.y)*innerHeight < 8) reply(round);
    else { stop(); create(p); }
  }
  function invalidate() { window.dispatchEvent(new Event('snowfall-porches-changed')); }
  window.addEventListener('snowfall-house-plots', e => {
    if (!native || !Array.isArray(e.detail)) return;
    plots = e.detail.filter(valid);
    showLocalHouses();
    if (round && !plots.some(p => p.id === round.id && Math.abs(p.x-round.x)*innerWidth < 8 && Math.abs(p.y-round.y)*innerHeight < 8)) stop();
    invalidate();
  });
  window.addEventListener('snowfall-house-tap', e => { if (native) tap(e.detail); });
  window.addEventListener('resize', () => {
    positionScenery();
    if (!round) return;
    const p = scenicPlots.get(round.id) || visiblePlots().find(plot => plot.id === round.id);
    if (!p) { stop(); return; }
    round.x = p.x;
    round.y = p.y;
    host.style.transform = 'translate(' + (p.x*innerWidth-round.startX) + 'px,' + (p.y*innerHeight-round.startY) + 'px)';
  });
  if(!native) {
    populateSamples();
    // Native plots arrive from the same artwork manifest via snowfall-house-plots.
    if(location.protocol!=='file:') fetch('assets/village-plan.json?v=6.0.0').then(r=>{
      if(!r.ok)throw new Error('Village layout unavailable');return r.json();
    }).then(plan=>{if(Array.isArray(plan.streets)){streets=plan.streets;positionScenery();invalidate();}}).catch(()=>{});
  }
  window.addEventListener('snowfall-house-hover',e=>{if(native)identify(e.detail?.id || null);});
  positionScenery();
  window.addEventListener('snowfall-surface',()=>{stop();identify(null);});
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
  window.SnowPorches = Object.freeze({visiblePlots, paint, samplePlot, tap, stop, invalidate});
})();
