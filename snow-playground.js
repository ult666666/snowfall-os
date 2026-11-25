/* The same little field is played through DOM buttons or the Mac's native hit targets. */
(() => {
  'use strict';
  const field = document.querySelector('#snow-playground');
  const scene = document.querySelector('#scene');
  if (!field || !scene) return;
  const native = Boolean(window.snowfallNative);
  const bridge = window.webkit?.messageHandlers?.snowfallWindow;
  const storageKey = 'snowfall-os.snowman';
  const steps = ['yard-ball', 'yard-snow-base', 'yard-snow-middle', 'snowman'];
  const clamp = (number, low, high) => Math.max(low, Math.min(high, number));
  function readStage(fallback = 0) {
    try {
      const value = Number(localStorage.getItem(storageKey));
      return Number.isInteger(value) && value >= 0 && value <= 3 ? value : fallback;
    } catch { return fallback; }
  }
  let stage = readStage(), mode = 'idle', player = 0, flurry = 0, throws = 0, dodges = 0;
  let lane = 0, aim = null, readyAt = 0, enemyAt = 0, side = 0, dragX = null;
  let phaseTimer, noteTimer, lastPayload = '', site = null, nativeSafe = null, scheduled = false;
  let cleared = new Set();
  let note = '';
  function make(tag, cls, parent) {
    const node = document.createElement(tag);
    node.className = cls; if (parent) parent.append(node);
    return node;
  }
  function prop(name, cls, parent) {
    const image = make('img',cls,parent);
    image.src = 'assets/props/'+name+'.png'; image.alt = ''; image.draggable = false;
    return image;
  }
  const ground = make('div','meadow-ground',field);
  ground.setAttribute('aria-hidden','true');
  for (const direction of ['left','right']) make('i','meadow-track '+direction,ground);
  const pennants = make('div','meadow-flags',ground);
  for (let i=0;i<5;i++) make('i','',pennants);
  const message = make('span','meadow-note',field); message.setAttribute('role','status');
  const score = make('span','meadow-score',field);
  const topButton = make('button','meadow-back',field);
  topButton.type = 'button'; topButton.dataset.action = 'back'; topButton.textContent = '‹  Back';
  topButton.setAttribute('aria-label','Back to the three snow activities');
  topButton.addEventListener('click', () => press('back'));
  const row = make('div','meadow-props',field);
  const effects = make('div','meadow-effects',field); effects.setAttribute('aria-hidden','true');
  const mitten = prop('yard-mitten','meadow-player',effects);
  const slots = Array.from({length:3}, () => {
    const button = make('button','meadow-prop',row); button.type = 'button';
    const art = make('span','meadow-sprite',button); art.setAttribute('aria-hidden','true');
    const sign = make('span','meadow-sign',button);
    button.addEventListener('click', () => {
      if (button.dataset.dragged === 'yes') { delete button.dataset.dragged; return; }
      press(button.dataset.action);
    });
    return {button,art,sign};
  });

  function quietMotion() {
    return matchMedia('(prefers-reduced-motion: reduce)').matches || scene.classList.contains('reduce-motion');
  }
  function state() { return {stage,mode,player,flurry,throws,dodges,passes:cleared.size,incoming:aim!==null && mode==='fight'}; }
  function config(index, id, title, image, style='', label=title) {
    const {button,art,sign} = slots[index];
    const token = image+'|'+style;
    if (art.dataset.token !== token) {
      art.dataset.token = token; art.replaceChildren();
      if (style === 'starter' || style === 'built') make('i','packing-spade',art);
      if (style === 'starter') {
        prop('yard-ball','starter-small',art); prop('yard-ball','starter-middle',art);
      }
      prop(image,'main-sprite',art);
    }
    button.dataset.action=id; button.dataset.art=style;
    button.setAttribute('aria-label',label); sign.textContent=title;
  }
  function render() {
    field.dataset.mode = mode;
    field.dataset.stage = String(stage);
    field.classList.toggle('cleared-left',cleared.has(-1));
    field.classList.toggle('cleared-right',cleared.has(1));
    field.classList.toggle('incoming',aim !== null && mode === 'fight');
    topButton.hidden = mode === 'idle';
    score.hidden = mode === 'idle';
    message.hidden = !note; message.textContent = note;
    mitten.hidden = mode !== 'fight';
    if (mode === 'idle') {
      config(0,stage<3 ? 'build':'reset',['Build snowman','Stack belly · 1/3','Add head · 2/3','Start over'][stage],
        steps[stage],stage===0?'starter':'built',stage<3?'Build snowman, '+stage+' of 3 snowballs stacked':'Start building a new snowman');
      config(1,'fight','Snowball fight','snowman','rival','Start a snowball fight with Flurry');
      config(2,'plow','Drive plow','plow','truck','Drive the snowplow');
    } else if (mode === 'fight') {
      config(0,'dodge-left','‹  Dodge left','yard-pile','bank','Dodge left behind the snowbank');
      config(1,'throw','Throw at Flurry','snowman','rival');
      config(2,'dodge-right','Dodge right  ›','yard-pile','bank','Dodge right behind the snowbank');
      score.textContent = 'You '+player+' · '+flurry+' Flurry';
    } else if (mode === 'plow') {
      config(0,'plow-left',cleared.has(-1)?'West bank':'Clear west','yard-pile',cleared.has(-1)?'cleared':'bank','Drive to the west snowbank');
      config(1,'plow',cleared.size===2?'Fresh snow':'Drive or drag','plow','truck',
        cleared.size===2?'Start a fresh plow route':'Drive the plow or drag it to a bank');
      config(2,'plow-right',cleared.has(1)?'East bank':'Clear east','yard-pile',cleared.has(1)?'cleared':'bank','Drive to the east snowbank');
      score.textContent = cleared.size+' / 2 banks';
    } else {
      config(0,'back','Back to town','yard-pile','bank');
      config(1,'replay','Play again','snowman','rival','Play another snowball fight');
      config(2,'plow','Drive plow','plow','truck');
      topButton.hidden = true;
      score.textContent = (player>=3?'You win! ':'Flurry wins! ')+player+' – '+flurry;
    }
    field.style.setProperty('--mitten-x', (50+30*lane)+'%');
    field.style.setProperty('--truck-offset', ((dragX ?? side)*55)+'%');
    field.classList.toggle('truck-west',(dragX ?? side)<0);
    publish();
  }
  function announce(text, ms=1500) {
    clearTimeout(noteTimer); note=text;
    if (ms) noteTimer=setTimeout(()=>{note='';render();},ms);
  }
  function arc(from,to,away=false) {
    if (quietMotion()) return;
    const ball=prop('yard-ball','meadow-ball',effects);
    const x0=from[0]*field.clientWidth, y0=from[1]*field.clientHeight;
    const x1=to[0]*field.clientWidth, y1=to[1]*field.clientHeight;
    const at=(x,y,s)=>'translate('+x+'px,'+y+'px) translate(-50%,-50%) scale('+s+')';
    const anim=ball.animate([{transform:at(x0,y0,1)},{transform:at((x0+x1)/2,Math.min(y0,y1)-field.clientHeight*.23,1.1),offset:.48},
      {transform:at(x1,y1,away?.75:1),opacity:.65}],{duration:away?450:580,easing:'ease-in-out',fill:'both'});
    anim.onfinish=()=>ball.remove(); anim.oncancel=()=>ball.remove();
  }
  function scheduleEnemy(at) {
    clearTimeout(phaseTimer); enemyAt=at;
    if (mode==='fight') phaseTimer=setTimeout(()=>{
      if(Date.now()<at)scheduleEnemy(at);else advance();
    },Math.max(0,at-Date.now()));
  }
  function finish() {
    clearTimeout(phaseTimer); clearTimeout(noteTimer); aim=null;note='';mode='results';render();
  }
  function advance() {
    if (mode !== 'fight' || Date.now()<enemyAt) return;
    if (aim === null) {
      aim=lane; announce('Incoming! Dodge',0);
      arc([.50,.44],[.50+.30*aim,.75]); scheduleEnemy(Date.now()+1200);
    } else {
      if (lane===aim) { flurry++; announce('Snowball hit!',950); }
      else { dodges++; announce('Dodged!',950); }
      aim=null;
      if (flurry>=3) { finish();return; }
      scheduleEnemy(Date.now()+1550);
    }
    render();
  }
  function fight() {
    mode='fight'; player=0; flurry=0; throws=0; dodges=0; lane=0; aim=null; readyAt=0;
    announce('First to 3 hits',1100);
    scheduleEnemy(Date.now()+1550);
  }
  function drive(direction) {
    side=direction; dragX=null; cleared.add(direction);
    announce(cleared.size===2?'Path cleared!':direction<0?'West path cleared':'East path cleared',1350);
  }
  function park() {
    clearTimeout(phaseTimer); clearTimeout(noteTimer); aim=null; note='';dragX=null;
    mode='idle';stage=readStage(stage);render();
  }
  function press(id) {
    if (field.hidden || ![...field.querySelectorAll('button[data-action]')].some(b=>!b.hidden&&b.dataset.action===id)) return;
    if (mode==='fight') advance();
    const enteringPlow = id==='plow' && mode!=='plow';
    switch (id) {
      case 'build':
      case 'reset': {
        stage = id==='reset'?0:Math.min(3,readStage(stage)+1);
        try {localStorage.setItem(storageKey,String(stage));} catch {}
        window.SnowYard?.refresh();
        announce(['Fresh powder','Base packed','Belly stacked','Snowman built!'][stage]);
        if(stage)arc([.06,.69],[.16,.57-stage*.08],true);
        break;
      }
      case 'fight': case 'replay': fight(); break;
      case 'throw':
        if(mode!=='fight'||Date.now()<readyAt)return;
        readyAt=Date.now()+700; throws++; player++;
        arc([.50+.30*lane,.75],[.50,.43],true);
        if (player>=3) {finish();return;}
        if(aim===null)announce('Hit!',650);
        break;
      case 'dodge-left': case 'dodge-right':
        if(mode!=='fight')return;
        lane=id==='dodge-left'?-1:1; break;
      case 'plow':
        if(mode!=='plow') {mode='plow';side=0;cleared=new Set();announce('Pick a snowbank',1700);}
        else if(cleared.size===2){side=0;cleared.clear();announce('Fresh snow',1100);}
        else drive(cleared.has(-1)?1:-1);
        break;
      case 'plow-left':case 'plow-right': drive(id==='plow-left'?-1:1);break;
      case 'back':park();return;
      default:return;
    }
    render();
    if(enteringPlow&&!quietMotion()) {
      const truck=slots[1].art;
      truck.animate([{transform:'translateX('+Math.round(field.clientWidth*.27)+'px)'},{transform:'translateX(0)'}],
        {duration:650,easing:'cubic-bezier(.23,.5,.35,1)'});
    }
  }
  function drag(id,x,phase) {
    if(id!=='plow'||mode!=='plow'||!Number.isFinite(x))return;
    const box=field.getBoundingClientRect();
    dragX=clamp((x*innerWidth-box.left-box.width*.5)/(box.width*.30),-1,1);
    if(phase==='end'){if(Math.abs(dragX)>.18)drive(Math.sign(dragX));else dragX=null;}
    render();
  }
  for (const {button} of slots) {
    let start=null;
    button.addEventListener('pointerdown',e=>{
      delete button.dataset.dragged;
      if(button.dataset.action!=='plow'||mode!=='plow'||e.button!==0)return;
      start=e.clientX; button.setPointerCapture(e.pointerId);
    });
    button.addEventListener('pointermove',e=>{
      if(start===null||Math.abs(e.clientX-start)<4&&button.dataset.dragged!=='yes')return;
      button.dataset.dragged='yes';drag('plow',e.clientX/innerWidth,'drag');
    });
    button.addEventListener('pointerup',e=>{
      if(start!==null&&button.dataset.dragged==='yes')drag('plow',e.clientX/innerWidth,'end');
      start=null;
    });
    button.addEventListener('pointercancel',()=>{start=null;dragX=null;render();});
  }
  field.addEventListener('keydown',event=>{
    if(mode!=='fight'||event.ctrlKey||event.metaKey||event.altKey)return;
    const id=({'ArrowLeft':'dodge-left','ArrowRight':'dodge-right',Escape:'back'})[event.key];
    if(id){event.preventDefault();event.stopPropagation();press(id);}
  });

  function publish() {
    if(!native || !bridge || window.snowfallSurface!=='wallpaper')return;
    const targets=[];
    if(!field.hidden && innerWidth>0 && innerHeight>0) {
      for(const button of field.querySelectorAll('button[data-action]')) {
        if(button.hidden)continue;
        const b=button.getBoundingClientRect();
        if(b.width<1||b.height<1)continue;
        targets.push({id:button.dataset.action,label:button.getAttribute('aria-label')||button.textContent,
          x:b.left/innerWidth,y:b.top/innerHeight,width:b.width/innerWidth,height:b.height/innerHeight});
      }
    }
    const payload={action:'playgroundLayout',targets,state:state()};
    const next=JSON.stringify(payload);
    if(next!==lastPayload){lastPayload=next;bridge.postMessage(payload);}
  }
  function useBox(box) {
    return box && [box.x,box.y,box.width,box.height].every(Number.isFinite) && box.width>0 && box.height>0;
  }
  function layout(force=true) {
    const w=innerWidth,h=innerHeight;
    if(!w||!h)return;
    const hide=scene.classList.contains('yard-active') || scene.classList.contains('room-mode') ||
      scene.classList.contains('custom-image');
    if(hide && !field.hidden)park();
    const tooSmall=site && (site.width*w<205 || site.height*h<65);
    field.hidden=Boolean(hide||tooSmall);
    scene.classList.toggle('has-meadow',!field.hidden);
    const small=w<750;
    const fieldW=Math.min(w-20,clamp(w*.36,304,465));
    const fieldH=Math.min(clamp(h*.128,90,123),h*.33);
    let rect={x:(w-fieldW)/2,y:h-fieldH-(small?70:10),w:fieldW,h:fieldH};
    if(native && site){
      rect={x:site.x*w,y:site.y*h,w:site.width*w,h:site.height*h};
    } else if(native && nativeSafe){
      rect.y=Math.min(rect.y,(nativeSafe.y+nativeSafe.height)*h-fieldH-8);
      rect.x=clamp(rect.x,nativeSafe.x*w,(nativeSafe.x+nativeSafe.width)*w-fieldW);
    }
    Object.assign(field.style,{left:rect.x+'px',top:rect.y+'px',width:rect.w+'px',height:rect.h+'px'});
    if(force)lastPayload='';
    publish();
  }
  function relayout(){ if(scheduled)return;scheduled=true;queueMicrotask(()=>{scheduled=false;layout(false);}); }
  window.addEventListener('snowfall-playground-input',({detail})=>{
    if(!detail||typeof detail.id!=='string')return;
    if(detail.phase==='activate')press(detail.id);else if(detail.phase==='drag'||detail.phase==='end')drag(detail.id,detail.x,detail.phase);
  });
  window.addEventListener('snowfall-playground-safe-area',({detail})=>{
    if(!native||!useBox(detail))return;
    nativeSafe=detail;site=detail.site && !useBox(detail.site) ? {x:0,y:0,width:0,height:0} : detail.site || null;relayout();
  });
  window.addEventListener('snowfall-playground-clock',advance);
  window.addEventListener('snowfall-playground-measure',()=>layout());
  window.addEventListener('resize',relayout);
  window.addEventListener('snowfall-surface',()=>{stage=readStage(stage);layout();render();});
  window.addEventListener('storage',e=>{if(!e.key||e.key===storageKey){stage=readStage(stage);render();}});
  let previousClasses='';
  new MutationObserver(()=>{
    const next=['yard-active','room-mode','custom-image'].map(c=>scene.classList.contains(c)).join();
    if(next!==previousClasses){previousClasses=next;stage=readStage(stage);render();relayout();}
  }).observe(scene,{attributes:true,attributeFilter:['class']});
  const originalYard=document.querySelector('.snow-yard');
  if(originalYard)new MutationObserver(()=>{
    if(!originalYard.dataset.ambientRunning && mode==='idle'){stage=readStage(stage);render();}
  }).observe(originalYard,{attributes:true,attributeFilter:['data-ambient-running']});
  document.addEventListener('visibilitychange',()=>{if(!native&&document.hidden&&mode==='fight')park();});
  window.SnowPlayground=Object.freeze({state,layout,press,drag});
  layout();render();
})();
