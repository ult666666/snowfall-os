/* All yard coordinates are percentages of the scene. Objects follow the landscape on resize. */
(() => {
  'use strict';
  const sprites = 'assets/props/';
  const snowStages = ['', 'yard-snow-base', 'yard-snow-middle', 'snowman'];
  const buildSite = { x: 68, y: 85 };
  const parking = { x: 20, y: 89 };
  const pileSpots = [{ x: 35, y: 87 }, { x: 54, y: 92 }, { x: 79, y: 84 }];
  const positions = [{ x: 67, y: 81 }, { x: 43, y: 86 }, { x: 77, y: 87 }, { x: 54, y: 81 }];
  const lanes = [28, 50, 72];
  const storageKey = 'snowfall-os.snowman';
  const titles = { build: 'Build a snowman', plow: 'Clear the path', fight: 'Snowball fight' };
  let host, shell, field, props, effects, control, message, modeTabs, onEnter;
  let desktopSnowman, parked, ambientLayer;
  let ambientOperation = null;
  const ambientQueue = [];
  let plowVisited = false;
  let localStageOnly = false;
  let active = false;
  let mode = 'build';
  let snowmanLevel = 0;
  let plow = { at: parking, cleared: [], trails: [] };
  let pendingAction = false;
  let duel;
  let serial = 0;
  const jobs = new Set();
  let mediaQuery;

  function element(tag, className, text) {
    const result = document.createElement(tag);
    if (className) result.className = className;
    if (text !== undefined) result.textContent = text;
    return result;
  }
  function action(text, handler, className = '') {
    const result = element('button', className, text);
    result.type = 'button';
    result.addEventListener('click', handler);
    return result;
  }
  function sprite(name) {
    const img = element('img', 'yard-sprite');
    img.src = sprites + name + '.png?v=4.0.1';
    img.alt = '';
    img.draggable = false;
    return img;
  }
  function place(node, point) {
    node.style.left = point.x + '%';
    node.style.top = point.y + '%';
    return node;
  }
  function prop(name, point, className, label, handler, layer = props) {
    const object = handler ? action('', handler) : element('div');
    object.className = 'yard-prop ' + className;
    object.append(sprite(name));
    if (label && handler) {
      object.setAttribute('aria-label', label);
      object.title = label;
    }
    layer.append(place(object, point));
    return object;
  }
  function later(handler, delay) {
    const token = window.setTimeout(() => { jobs.delete(token); handler(); }, delay);
    jobs.add(token);
  }
  function clearJobs() {
    jobs.forEach(id => window.clearTimeout(id));
    jobs.clear();
    pendingAction = false;
    effects?.replaceChildren();
  }
  function reduced() {
    return !!mediaQuery?.matches || (window.SnowApps?.settings ? !window.SnowApps.settings().motion : false);
  }
  function applyMotion() { shell?.classList.toggle('yard-still', reduced()); }
  function loadLevel() {
    if (localStageOnly) return snowmanLevel;
    try {
      const raw = Number(window.localStorage.getItem(storageKey));
      if (Number.isInteger(raw) && raw >= 0 && raw <= 3) return raw;
    } catch { /* Use the current visit when storage is unavailable. */ }
    return snowmanLevel;
  }
  function saveLevel() {
    try { window.localStorage.setItem(storageKey, String(snowmanLevel)); localStageOnly = false; } catch { localStageOnly = true; }
  }
  function say(text) { message.textContent = text; }
  function puff(at, text) {
    const particle = element('div', 'yard-puff', text);
    effects.append(place(particle, at));
    later(() => particle.remove(), 900);
  }
  function travel(node, points, duration, anchor = '-100%') {
    const end = points[points.length - 1];
    place(node,end);
    if (!node.animate || reduced()) return;
    const bounds = shell.getBoundingClientRect();
    const frames = points.map(point => {
      const dx = (point.x - end.x) * bounds.width / 100;
      const dy = (point.y - end.y) * bounds.height / 100;
      const transform = 'translate(-50%,' + anchor + ') translate3d(' + dx + 'px,' + dy + 'px,0) rotate(' + (point.angle || 0) + 'deg) scale(' + (point.size || 1) + ',' + (point.height || point.size || 1) + ')';
      return point.offset === undefined ? {transform} : {transform,offset:point.offset};
    });
    node.getAnimations?.().forEach(animation => animation.cancel());
    node.animate(frames, {duration, easing:'cubic-bezier(.33,.02,.23,1)', fill:'none'});
  }
  function move(node, end, duration) {
    travel(node,[{x:parseFloat(node.style.left),y:parseFloat(node.style.top)},end],duration);
  }
  function rollMotion(ball, start, level, ms) {
    const height = Math.min(140, shell.clientWidth * .087) / Math.max(shell.clientHeight,1) * 100;
    const targetY = buildSite.y - height * [.10,.35,.58][level];
    travel(ball,[{...start, size:.7}, {x:buildSite.x-9,y:buildSite.y+1,angle:206,size:1.04,offset:.68},
      {x:buildSite.x-2,y:targetY-1.5,angle:295}, {x:buildSite.x,y:targetY,angle:326}],ms);
  }
  function resetScene() {
    clearJobs();
    props.replaceChildren();
    control.replaceChildren();
    field.classList.remove('yard-aiming');
    field.removeAttribute('tabindex');
    field.removeAttribute('aria-label');
  }

  function build() {
    props.replaceChildren();
    control.replaceChildren();
    const level = snowmanLevel;
    if (level) prop(snowStages[level], buildSite, 'yard-snowman', null);
    if (level === 3) {
      say('Flurry is ready for a snowball fight.');
      control.append(action('Challenge Flurry', () => choose('fight', true), 'yard-accent'),
        action('Build again', () => {
          // Keep the finished snowman until the next build actually starts.
          say('Start a fresh snowman here?');
          control.replaceChildren(action('Start fresh', () => { snowmanLevel = 0; saveLevel(); build(); }, 'yard-accent'),
            action('Keep Flurry', build));
        }));
      return;
    }
    const parts = ['base', 'middle', 'head'];
    const start = { x: 31 + level * 4, y: 87 + level };
    say(['Roll a big snowball for Flurry’s base.', 'Stack a second snowball for Flurry’s belly.', 'One last snowball for Flurry’s head.'][level]);
    const ball = prop('yard-ball', start, 'yard-build-ball', 'Roll and stack the ' + parts[level], roll);
    const count = element('span', 'yard-count', level + ' / 3 stacked');
    const rollButton = action('Roll & stack', roll, 'yard-accent');
    control.append(rollButton, count);
    function roll() {
      if (pendingAction) return;
      pendingAction = true;
      rollButton.disabled = true;
      ball.disabled = true;
      const ms = reduced() ? 140 : 1150;
      say('Rolling the ' + parts[level] + ' into place…');
      const lastY = buildSite.y - 1 - level * 2.8;
      rollMotion(ball,start,level,ms);
      later(() => {
        pendingAction = false;
        snowmanLevel = Math.max(loadLevel(),level + 1);
        saveLevel(); build();
        puff({x:buildSite.x,y:lastY-5}, level === 2 ? 'Flurry!' : '+1 stacked');
      }, ms);
    }
  }

  function tracks(layer = props) {
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('class', 'yard-tracks'); svg.setAttribute('viewBox', '0 0 100 100');
    svg.setAttribute('preserveAspectRatio', 'none'); svg.setAttribute('aria-hidden', 'true');
    for (const {start,end} of plow.trails) {
      const add = (style, y) => {
        const line = document.createElementNS(ns, 'line');
        line.setAttribute('x1', start.x); line.setAttribute('y1', start.y + y);
        line.setAttribute('x2', end.x); line.setAttribute('y2', end.y + y);
        line.setAttribute('class', style);
        svg.append(line);
      };
      add('yard-clearing', -.3); add('yard-tread', -.64); add('yard-tread', .04);
    }
    layer.append(svg);
  }
  function renderPlow() {
    props.replaceChildren(); control.replaceChildren(); tracks();
    const vehicle = prop('plow', plow.at, 'yard-plow', null);
    if (plow.trails.length && plow.trails[plow.trails.length - 1].start.x > plow.at.x) vehicle.classList.add('yard-left');
    if (snowmanLevel) prop(snowStages[snowmanLevel], {x:65,y:72}, 'yard-snowman yard-distant', null);
    const buttons = [];
    pileSpots.forEach((at, index) => {
      const route = plow.trails.find(trail => trail.index === index);
      if (route) {
        prop('yard-pile', route.bank, 'yard-bank', null);
        return;
      }
      const button = prop('yard-pile', at, 'yard-pile', 'Plow snow pile ' + (index+1), () => drive(index, button));
      buttons.push(button);
    });
    const count = element('span','yard-count',plow.cleared.length + ' / 3 cleared');
    if (buttons.length) {
      say('Choose a snow pile to send the plow.');
      const next = action('Plow next pile', () => buttons[0]?.click(), 'yard-accent');
      control.append(next, count);
    } else {
      say('Path cleared. The cabin is easy to reach again.');
      control.append(action('Fresh snowfall', () => { plow = {at:parking, cleared:[], trails:[]}; renderPlow(); }, 'yard-accent'), count);
    }
    function drive(index, pile) {
      if (pendingAction) return;
      pendingAction = true;
      const start = plow.at, end = pileSpots[index];
      const direction = Math.sign(end.x - start.x) || 1;
      const bank = {x: end.x + direction * 5, y: end.y - .8};
      const ms = reduced() ? 150 : Math.round(550 + Math.abs(end.x - start.x) * 13);
      Array.from(props.querySelectorAll('button')).forEach(b => { b.disabled=true; });
      control.querySelector('button').disabled = true;
      say('Plowing the path…');
      driveMotion(vehicle,pile,start,end,bank,ms);
      later(() => {
        pendingAction = false;
        completeDrive(index,start,end,bank);
        renderPlow(); puff({x:end.x,y:end.y-6}, 'Cleared!');
      }, ms);
    }
  }


  function driveMotion(vehicle,pile,start,end,bank,ms) {
    vehicle.classList.toggle('yard-left',start.x > end.x);
    travel(vehicle,[start,end],ms);
    travel(pile,[end,{...end,offset:.68},{...bank,size:.7,height:.55}],ms);
  }
  function completeDrive(index,start,end,bank) {
    plowVisited = true;
    plow.cleared.push(index);
    plow.trails.push({index,start,end,bank});
    plow.at = end;
  }

  function readyFight() {
    props.replaceChildren(); control.replaceChildren();
    prop('snowman', positions[0], 'yard-snowman', null);
    prop('yard-mitten', {x:50,y:97}, 'yard-mitten', null);
    say('First to three hits. Aim at Flurry and dodge the return throws.');
    control.append(action('Start round', startFight, 'yard-accent'));
  }
  function startFight() {
    resetScene();
    const myRound = ++serial;
    duel = { me:0, flurry:0, lane:1, target:0, locked:false, running:true, round:myRound };
    const target = prop('snowman', positions[0], 'yard-snowman yard-rival', 'Throw at Flurry', shootTarget);
    const glove = prop('yard-mitten', {x:lanes[1],y:97}, 'yard-mitten', null);
    const score = element('span', 'yard-score');
    const throwButton = action('Throw', shootTarget, 'yard-accent');
    const left = action('←', () => dodge(-1)); left.setAttribute('aria-label','Dodge left');
    const right = action('→', () => dodge(1)); right.setAttribute('aria-label','Dodge right');
    control.append(score, left, throwButton, right);
    field.classList.add('yard-aiming');
    field.tabIndex = 0;
    field.setAttribute('aria-label','Snowball field. Use left and right arrows to dodge and Space to throw at Flurry.');
    say('Click Flurry to throw. Use the arrows to dodge.');
    const updateScore = () => { score.textContent = 'You ' + duel.me + ' · ' + duel.flurry + ' Flurry'; };
    updateScore();
    function alive() { return active && duel?.running && duel.round === myRound; }
    function targetPoint() {
      const parent = field.getBoundingClientRect(), rect = target.getBoundingClientRect();
      if (!parent.width || !parent.height || !rect.width) return { x:positions[duel.target].x, y:positions[duel.target].y - 4 };
      return {x:(rect.left+rect.width*.5-parent.left)/parent.width*100, y:(rect.top+rect.height*.52-parent.top)/parent.height*100};
    }
    function toss(start,end,ms,hostile=false) {
      const ball = element('div', 'yard-shot' + (hostile ? ' yard-incoming' : ''));
      ball.append(sprite('yard-ball')); effects.append(place(ball, start));
      travel(ball,[start,{x:(start.x+end.x)/2,y:Math.min(start.y,end.y)-6,offset:.5},end],ms,'-50%');
      later(() => ball.remove(),ms);
    }
    function finish() {
      duel.running = false; clearJobs();
      const won = duel.me >= 3;
      control.replaceChildren(score, action('Play again', startFight, 'yard-accent'));
      target.disabled = true; field.classList.remove('yard-aiming');
      say(won ? 'You won! Flurry tips his hat.' : 'Flurry wins! Catch him in a rematch.');
    }
    function throwAt(end, hit) {
      if (!alive() || duel.locked) return;
      duel.locked = true; throwButton.disabled = true;
      toss({x:lanes[duel.lane],y:90},end,330);
      later(() => {
        if (!alive()) return;
        if (hit) {
          duel.me++; updateScore(); puff(end,'Hit!');
          if (duel.me >= 3) return finish();
          duel.target = (duel.target + 1) % positions.length;
          move(target,positions[duel.target],320);
        } else puff(end,'Miss');
      },330);
      later(()=>{ if(alive()) { duel.locked=false; throwButton.disabled=false; } },1150);
    }
    function shootTarget() { if (alive()) throwAt(targetPoint(),true); }
    function dodge(direction) {
      if (!alive()) return;
      duel.lane = Math.max(0,Math.min(lanes.length-1,duel.lane+direction));
      move(glove,{x:lanes[duel.lane],y:97},155);
    }
    function enemyThrow() {
      if (!alive()) return;
      const aimedLane = duel.lane;
      const end = {x:lanes[aimedLane],y:94};
      const warning = element('div','yard-warning','Dodge!'); effects.append(place(warning,end));
      say('Incoming! Move away from the marked spot.');
      later(() => { if(alive()) toss(targetPoint(),end,550,true); },440);
      later(() => {
        if (!alive()) return;
        warning.remove();
        if (duel.lane === aimedLane) { duel.flurry++; updateScore(); puff({x:end.x,y:88}, 'Snow hit!'); }
        else puff({x:end.x,y:88}, 'Dodged!');
        if (duel.flurry >= 3) return finish();
        say('Aim at Flurry for your next throw.');
        later(enemyThrow,950);
      },990);
    }
    duel.dodge = dodge; duel.shoot = shootTarget; duel.throwAt = throwAt;
    later(enemyThrow,650);
  }

  function fieldClick(event) {
    if (!duel?.running || mode !== 'fight' || event.target.closest('button')) return;
    const rect = field.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    const point = { x:(event.clientX-rect.left)/rect.width*100, y:(event.clientY-rect.top)/rect.height*100 };
    duel.throwAt(point,false);
  }
  function key(event) {
    if (!active || mode !== 'fight' || !duel?.running || event.altKey || event.ctrlKey || event.metaKey || event.defaultPrevented) return;
    const launcher = document.getElementById('launcher-backdrop');
    if (launcher && !launcher.hidden || event.target.closest?.('input,textarea,[role=dialog]')) return;
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault(); if (!event.repeat) duel.dodge(event.key === 'ArrowLeft' ? -1 : 1);
    } else if (event.code === 'Space' && !event.target.closest?.('button, input, textarea, select, a')) {
      event.preventDefault(); if (!event.repeat) duel.shoot();
    }
  }
  function choose(next, startImmediately=false) {
    resetScene(); duel=null; mode=next;
    modeTabs.forEach(tab => tab.setAttribute('aria-pressed',String(tab.dataset.mode === mode)));
    if (mode === 'build') build();
    else if (mode === 'plow') renderPlow();
    else if (startImmediately) startFight();
    else readyFight();
  }
  function requestActivity(next) {
    if (onEnter) onEnter(next); else enter(next);
  }
  function showDesktopSnowman() {
    desktopSnowman.hidden = snowmanLevel === 0 || active;
    if (desktopSnowman.hidden) return;
    desktopSnowman.replaceChildren(sprite(snowStages[snowmanLevel]));
    const label = snowmanLevel === 3 ? 'Challenge Flurry to a snowball fight' : 'Keep building your snowman';
    desktopSnowman.title = label;
    desktopSnowman.setAttribute('aria-label',label);
  }
  function drawAmbient() {
    ambientLayer.replaceChildren();
    const isPlowing = ambientOperation?.kind === 'plow';
    parked.hidden = active || isPlowing || !plowVisited;
    place(parked,plow.at);
    const lastTrail = plow.trails[plow.trails.length-1];
    parked.classList.toggle('yard-left',!!lastTrail && lastTrail.start.x > lastTrail.end.x);
    showDesktopSnowman();
    if (active || !plow.trails.length) return;
    tracks(ambientLayer);
    plow.trails.forEach(trail => prop('yard-pile',trail.bank,'yard-bank',null,null,ambientLayer));
  }

  function refresh() {
    if (!shell || ambientOperation) return;
    const previous = snowmanLevel;
    snowmanLevel = loadLevel();
    if (active && mode === 'build' && !pendingAction && previous !== snowmanLevel) build();
    if (!active) drawAmbient();
  }
  function finishAmbientNow() {
    // If a visitor opens the yard during a wallpaper animation, retain every accepted action.
    while (ambientOperation || ambientQueue.length) {
      if (!ambientOperation) { beginAmbient(); continue; }
      window.clearTimeout(ambientOperation.timer);
      ambientOperation.commit();
      ambientOperation = null;
    }
    shell.dataset.ambientRunning = '';
    drawAmbient();
  }
  function returnToss() {
    const start = {x:buildSite.x-1, y:buildSite.y-3};
    const landing = {x:buildSite.x-12, y:94};
    const ball = element('div','yard-shot yard-return');
    ball.append(sprite('yard-ball'));
    const powder = element('div','yard-powder');
    ambientLayer.append(place(ball,start),place(powder,landing));
    if (reduced() || !ball.animate) {
      ball.hidden = true;
      powder.style.opacity = '.85';
      return 440;
    }
    const flight = 830, duration = flight+380;
    travel(ball,[{...start,size:.3}, {x:start.x-4,y:start.y-7,size:.66,offset:.45}, {...landing,size:1.12}],flight,'-50%');
    const impact = flight/duration;
    ball.animate([{opacity:1}, {opacity:1,offset:impact-.015}, {opacity:0,offset:impact}, {opacity:0}],
      {duration,fill:'forwards'});
    powder.animate([{opacity:0,transform:'translate(-50%,-50%) scale(.3)'}, {opacity:0,offset:impact-.01},
      {opacity:.86,transform:'translate(-50%,-50%) scale(.85)',offset:impact+.05},
      {opacity:0,transform:'translate(-50%,-65%) scale(1.5)'}], {duration,fill:'forwards'});
    return duration;
  }
  function beginAmbient() {
    if (!ambientQueue.length || active || ambientOperation) return;
    const kind = ambientQueue.shift();
    snowmanLevel = loadLevel();
    if (kind === 'plow' && plow.cleared.length === pileSpots.length) plow = {at:parking,cleared:[],trails:[]};
    const op = {kind,timer:0,commit:null};
    ambientOperation = op;
    shell.dataset.ambientRunning = kind;
    drawAmbient();
    let duration;
    if (kind === 'roll' && snowmanLevel === 3) {
      duration = returnToss();
      op.commit = () => {};
    } else if (kind === 'roll') {
      const level = snowmanLevel, start = {x:47+level*2,y:91};
      const ball = prop('yard-ball',start,'yard-build-ball',null,null,ambientLayer);
      duration = reduced() ? 140 : 1500;
      rollMotion(ball,start,level,duration);
      op.commit = () => { snowmanLevel = Math.max(loadLevel(),level+1); saveLevel(); };
    } else {
      const index = pileSpots.findIndex((_,i) => !plow.cleared.includes(i));
      const start = plow.at, end = pileSpots[index];
      const bank = {x:end.x+(Math.sign(end.x-start.x)||1)*5,y:end.y-.8};
      const vehicle = prop('plow',start,'yard-plow',null,null,ambientLayer);
      const pile = prop('yard-pile',end,'yard-pile',null,null,ambientLayer);
      duration = reduced() ? 150 : 760+Math.abs(end.x-start.x)*27;
      driveMotion(vehicle,pile,start,end,bank,duration);
      op.commit = () => completeDrive(index,start,end,bank);
    }
    op.timer = window.setTimeout(() => {
      op.commit(); ambientOperation=null; shell.dataset.ambientRunning='';
      refresh(); beginAmbient();
    },duration);
  }
  function ambient(kind) {
    if (!shell || active || !['roll','plow'].includes(kind) || ambientQueue.length >= 6) return false;
    ambientQueue.push(kind); beginAmbient();
    return true;
  }
  function syncStage(event) {
    if (event.key === storageKey || event.key === null) refresh();
  }
  function enter(next = 'build') {
    if (!shell || active) return;
    finishAmbientNow();
    active = true;
    ambientLayer.hidden = true;
    shell.classList.add('yard-open');
    field.hidden = false; shell.querySelector('.yard-panel').hidden=false;
    shell.querySelector('.yard-parked').hidden=true;
    snowmanLevel = loadLevel();
    showDesktopSnowman();
    choose(next, next === 'fight');
  }
  function exit() {
    if (!shell || !active) return;
    active=false; duel=null; resetScene();
    shell.classList.remove('yard-open');
    field.hidden = true; shell.querySelector('.yard-panel').hidden=true;
    ambientLayer.hidden=false;
    refresh();
  }
  function init(stageElement, onEnterRequest) {
    if (shell) { if (!active) finishAmbientNow(); exit(); shell.remove(); }
    host = stageElement; onEnter = onEnterRequest;
    shell = element('div','snow-yard');
    parked = action('',() => requestActivity('plow'),'yard-parked');
    ambientLayer = element('div','yard-ambient');
    ambientLayer.setAttribute('aria-hidden','true');
    shell.dataset.ambientRunning='';
    snowmanLevel = loadLevel();
    desktopSnowman = action('', () => requestActivity(snowmanLevel === 3 ? 'fight' : 'build'), 'yard-prop yard-snowman yard-desktop-snowman');
    place(desktopSnowman,buildSite);
    showDesktopSnowman();
    parked.append(sprite('plow')); parked.title='Enter Snow Yard'; parked.setAttribute('aria-label','Enter Snow Yard with the snowplow');
    field = element('div','yard-field'); field.hidden=true;
    props = element('div','yard-props'); effects=element('div','yard-effects'); effects.setAttribute('aria-hidden','true');
    field.append(props,effects); field.addEventListener('click',fieldClick);
    const panel=element('section','yard-panel'); panel.hidden=true; panel.setAttribute('aria-label','Snow Yard controls');
    const title=element('div','yard-panel-title'); title.append(sprite('plow'),element('strong','','Snow Yard'));
    const nav=element('div','yard-tabs'); nav.setAttribute('role','group'); nav.setAttribute('aria-label','Yard activity');
    modeTabs = ['build','plow','fight'].map((name,i) => {
      const tab=action(['Build','Plow','Snowball fight'][i],()=>{if(name!==mode) choose(name);});
      tab.dataset.mode=name; tab.title=titles[name]; nav.append(tab); return tab;
    });
    message=element('p','yard-message'); message.setAttribute('role','status');
    control=element('div','yard-controls'); panel.append(title,nav,message,control);
    shell.append(ambientLayer,parked,desktopSnowman,field,panel); host.append(shell);
    drawAmbient();
    window.removeEventListener('storage',syncStage); window.addEventListener('storage',syncStage);
    window.removeEventListener('keydown',key); window.addEventListener('keydown',key);
    mediaQuery=window.matchMedia?.('(prefers-reduced-motion: reduce)');
    window.removeEventListener('snow-settings',applyMotion); window.addEventListener('snow-settings',applyMotion);
    applyMotion();
  }
  window.SnowYard=Object.freeze({init,enter,exit,ambient,refresh});
})();
