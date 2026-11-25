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

  function footsteps(ctx, x, y, direction, size) {
    const stride = size * .135;
    for (let step = 0; step < 7; step++) {
      const t = step / 6;
      const px = x + direction * (size * .11 + step * stride);
      const py = y + size * (.05 + Math.sin(t * 1.9) * .27 + (step % 2) * .035);
      ctx.fillStyle = 'rgba(116,145,165,' + (.39 - t * .24) + ')';
      ctx.beginPath();
      ctx.ellipse(px, py, size * .037, size * .016, direction * -.24, 0, 2 * Math.PI);
      ctx.fill();
      ctx.fillStyle = 'rgba(255,251,234,.74)';
      ctx.fillRect(px - size * .024, py + size * .01, size * .046, Math.max(.6, size * .009));
    }
  }
  // Lay short lanes between nearby doorsteps. A cottage can meet at most two lanes.
  function lanes(ctx, width, height, plots) {
    if (plots.length < 2) return;
    const doors = plots.slice(0,128).map(p => ({x:p.x*width,y:p.y*height+p.size*.06,size:p.size}));
    const candidates=[];
    const groups=doors.map((_,i)=>i), degree=doors.map(()=>0);
    const maxDistance=Math.min(width*.36, Math.max(220,height*.62));
    for(let i=0;i<doors.length;i++) {
      for(let j=i+1;j<doors.length;j++) {
        const distance=Math.hypot(doors[i].x-doors[j].x,doors[i].y-doors[j].y);
        if(distance<maxDistance && distance>Math.min(doors[i].size,doors[j].size)*.83) candidates.push({i,j,distance});
      }
    }
    candidates.sort((a,b)=>a.distance-b.distance);
    function group(i) { while(groups[i]!==i) i=groups[i]; return i; }
    ctx.save();
    ctx.lineCap='round';
    for(const {i,j} of candidates) {
      const g1=group(i), g2=group(j);
      if(g1===g2 || degree[i]===2 || degree[j]===2) continue;
      groups[g1]=g2; degree[i]++; degree[j]++;
      let a=doors[i], b=doors[j];
      if(a.y>b.y) [a,b]=[b,a];
      const size=(a.size+b.size)/2;
      const dx=b.x-a.x, dy=b.y-a.y;
      const side=Math.abs(dx)<size*.4 ? (a.x<width*.55 ? -1 : 1) : Math.sign(dx);
      ctx.beginPath();
      ctx.moveTo(a.x,a.y);
      if(dy>Math.abs(dx)*.76) {
        const bend=b.x-side*b.size*.77;
        ctx.bezierCurveTo(a.x+side*size*.85,a.y+dy*.28,bend,a.y+dy*.45,bend,a.y+dy*.70);
        ctx.bezierCurveTo(bend,b.y+size*.17,b.x-side*size*.31,b.y+size*.13,b.x,b.y);
      } else {
        ctx.bezierCurveTo(a.x+dx*.30,a.y+size*.34,b.x-dx*.30,b.y+size*.32,b.x,b.y);
      }
      ctx.lineWidth=minmax(size*.118,4,13);
      ctx.strokeStyle='rgba(137,158,183,.15)'; ctx.stroke();
      ctx.lineWidth=Math.max(2,ctx.lineWidth-1.6);
      ctx.strokeStyle='rgba(252,240,218,.57)'; ctx.stroke();
    }
    ctx.restore();
  }
  function paint(ctx, width, height, list) {
    lanes(ctx,width,height,list);
    for (const {id, x, y, size} of list) {
      const px = x * width, py = y * height;
      const facing = parseInt(id.slice(-2), 16) % 2 === 0 ? -1 : 1;
      let direction = facing;
      if (px > width - size * 1.2) direction = -1;
      if (px < size * 1.2) direction = 1;
      ctx.save();
      ctx.translate(px, py);
      ctx.scale(size, size);
      const cast = ctx.createRadialGradient(0, 0, .10, 0, 0, .65);
      cast.addColorStop(0,'rgba(111,138,159,.25)');
      cast.addColorStop(.55,'rgba(153,174,192,.18)');
      cast.addColorStop(1,'rgba(170,190,205,0)');
      ctx.save();
      ctx.translate(.10, -.045);
      ctx.scale(1.48, .25);
      ctx.fillStyle = cast;
      ctx.fillRect(-.7,-.7,1.4,1.4);
      ctx.restore();
      // A low drift at the sill catches the same warm light as the village.
      ctx.fillStyle = 'rgba(251,246,231,.68)';
      ctx.beginPath();
      ctx.moveTo(-.42,-.025);
      ctx.bezierCurveTo(-.32,-.075,-.21,-.065,-.09,-.025);
      ctx.bezierCurveTo(-.19,-.004,-.34,.008,-.42,-.025);
      ctx.fill();
      ctx.restore();
      footsteps(ctx, px, py, direction, size);
    }
  }
  function samplePlot(button) {
    const box = button.querySelector('img').getBoundingClientRect();
    return {id: button.dataset.sample, x:(box.left + box.width / 2) / innerWidth,
      y:(box.top + box.height * .88) / innerHeight, size:box.width};
  }
  function showLocalHouses() {
    const nodes = document.createDocumentFragment();
    for (const plot of plots) {
      if (plot.drawHouse !== true || typeof plot.name !== 'string' ||
          !Number.isInteger(plot.variant) || plot.variant < 1 || plot.variant > 6) continue;
      const tile = document.createElement('div');
      tile.className = 'wallpaper-cottage';
      tile.style.left = plot.x*100 + '%';
      tile.style.top = plot.y*100 + '%';
      tile.style.width = plot.size + 'px';
      tile.style.marginTop = -plot.size*.88 + 'px';
      const picture = document.createElement('img');
      picture.src = 'assets/houses/cottage-' + plot.variant + '.png?v=4.0.1';
      picture.alt = '';
      const sign = document.createElement('span');
      sign.textContent = plot.name;
      tile.append(picture,sign);
      nodes.append(tile);
    }
    houses.replaceChildren(nodes);
  }
  function positionScenery() {
    if (native) return;
    const sceneArt = document.querySelector('#wallpaper');
    const width = sceneArt.clientWidth, height = sceneArt.clientHeight;
    const scale = Math.max(width/2560, height/1600);
    const narrow = matchMedia('(max-width:580px)').matches;
    const left = (width-2560*scale)*(narrow ? .49 : .57);
    const top = (height-1600*scale)*(narrow ? .5 : .56);
    for (const door of document.querySelectorAll('[data-scenery]')) {
      const bakery = door.dataset.scenery === 'bakery';
      const x = left + (bakery ? .2222 : .0967)*2560*scale;
      const y = top + (bakery ? .5285 : .5053)*1600*scale;
      const size = (bakery ? .12 : .0611)*2560*scale;
      door.hidden = x < 0 || x > width || y < 0 || y > height;
      door.style.left = x + 'px';
      door.style.top = y + 'px';
      door.style.width = size + 'px';
      door.style.height = size*.84 + 'px';
      const plot = {id:'scenery:'+door.dataset.scenery,x:x/width,
        y:Math.min(1,(y+size*.39)/height),size:Math.min(116,size)};
      scenicPlots.set(plot.id,plot);
      door.onclick = () => tap(plot);
    }
  }
  function visiblePlots() {
    if (native) return document.documentElement.dataset.surface === 'wallpaper' ? plots : [];
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
    if (status.textContent === round.bubble?.textContent) status.textContent = '';
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
  function actor(className, asset, x, y, size) {
    const el = document.createElement(asset ? 'img' : 'span');
    el.className = className;
    if (asset) { el.alt = ''; el.src = 'assets/props/' + asset + '.png?v=4.0.1'; }
    el.style.left = x + 'px';
    el.style.top = y + 'px';
    if (size) el.style.width = size + 'px';
    host.append(el);
    return el;
  }
  function animate(game, node, frames, duration) {
    if (game.still || !node.animate) return;
    node.animate(frames, {duration, easing:'linear'});
  }
  function spray(game, point) {
    for (let i = 0; i < (game.still ? 1 : 7); i++) {
      const dot = actor('porch-powder', null, point.x, point.y, 3 + i % 3);
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
    const ball = actor('porch-ball', null, from.x, from.y, game.ballSize);
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
    game.bubble.textContent = message;
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
      from:{x:flurryX+dir*size*.20,y:feet-size*.45}, to:{x:mittX, y:mittY-size*.21}};
    round = game;
    host.hidden = false;
    host.dataset.returns = '0';
    game.flurry = actor('porch-flurry', 'snowman', flurryX, feet, size);
    actor('porch-mitten', 'yard-mitten', mittX, mittY, size*.47);
    game.bubble = actor('porch-bubble', null, minmax((flurryX+mittX)/2,62,width-62), Math.max(24,feet - size*.99 - 5));
    say(game, 'Catch!');
    animate(game, game.flurry, [{transform:'translate(-50%,-92%) scale(.76)',opacity:.1},
      {transform:'translate(-50%,-102%) scale(1.03)',opacity:1,offset:.7},
      {transform:'translate(-50%,-100%)'}],240);
    schedule(game, still ? 40 : 230, () => lob(game, game.from, game.to, () => ready(game)));
    idleLimit(game);
  }
  function ready(game) {
    game.busy = false;
    say(game, 'Click house to throw');
    if (game.pending) { game.pending = false; reply(game); }
  }
  function reply(game) {
    if (game.returns === 3) return;
    if (game.busy) { game.pending = true; return; }
    game.busy = true;
    idleLimit(game);
    say(game, 'Your throw!');
    lob(game, game.to, game.from, () => {
      game.returns++;
      host.dataset.returns = String(game.returns);
      animate(game, game.flurry, [{transform:'translate(-50%,-100%) rotate(0)'},
        {transform:'translate(-50%,-103%) rotate(-8deg)',offset:.4},
        {transform:'translate(-50%,-100%) rotate(0)'}],270);
      if (game.returns === 3) {
        say(game, 'Three in a row!');
        schedule(game, 1900, stop);
      } else {
        say(game, game.returns + ' / 3');
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
  positionScenery();
  window.addEventListener('snowfall-surface', stop);
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
  window.SnowPorches = Object.freeze({visiblePlots, paint, samplePlot, tap, stop, invalidate});
})();
