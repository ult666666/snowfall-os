/* The Mac presents this same scene as a click-through wallpaper or an interactive window. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const scene = $('#scene');
  const panel = $('#tools-panel');
  const bridge = window.webkit?.messageHandlers?.snowfallWindow;
  const isMacApp = Boolean(window.snowfallNative && bridge);
  let surface = isMacApp ? window.snowfallSurface || 'wallpaper' : 'preview';
  let activeTool = null;
  let cleanupTool = null;
  let inYard = false;
  let idleTimer;

  const paths = {
    houses: '<path d="m2.5 10 9.5-7.5 9.5 7.5M5 8.6V21h14V8.6M9.2 21v-6.5a2.8 2.8 0 0 1 5.6 0V21"/>',
    snow: '<path d="M12 2v20M3.34 7l17.32 10M3.34 17 20.66 7M9 4l3 3 3-3m-6 16 3-3 3 3M3.8 10.5 8 9.7l-1-4m10 12.6-1-4 4.2-.8M7 18.3l1-4-4.2-.8m16.4-3L16 9.7l1-4"/>',
    sliders: '<path d="M3 6h3m6 0h9M3 17h11m6 0h1"/><circle cx="9" cy="6" r="3"/><circle cx="17" cy="17" r="3"/>',
    expand: '<path d="M8 4H4v4m12-4h4v4M4 16v4h4m12-4v4h-4"/>',
    close: '<path d="m6 6 12 12m0-12L6 18"/>', check: '<path d="m4.5 12.5 4.5 4.3L19.5 6.5"/>',
    back: '<path d="m14.5 5-7 7 7 7"/>', forward: '<path d="m9 5 7 7-7 7"/>',
    radio: '<rect x="3" y="8" width="18" height="13" rx="3"/><path d="m5 8 13-5M6 12h6m-6 4h3"/><circle cx="16" cy="15" r="2.3"/>',
    notes: '<path d="M6 3h10l3 3v14H6zM9 10h7m-7 3h7m-7 3h4"/>',
    focus: '<circle cx="12" cy="14" r="7.5"/><path d="M10 2h4m-2 1v3m0 4v4l2.8 1.8m3.7-8.3 1.5-1.5"/>',
    guide: '<path d="M12 6c-3-2-6-2-10-1v14c4-1 7-1 10 1 3-2 6-2 10-1V5c-4-1-7-1-10 1Zm0 0v14"/>',
    settings: '<path d="M3 16h11a3.4 3.4 0 0 0 .6-6.7 5.1 5.1 0 0 0-9.6 1.4 2.7 2.7 0 0 0-2 5.3ZM7 19h.01M11 21h.01M15 19h.01M19 5l1-1m-3-2v2"/>',
    external: '<path d="M13 4h7v7m-9 2 9-9M9 5H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4"/>',
    music: '<path d="M9 17V6l10-2v11M9 9l10-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="16" cy="16" rx="3" ry="2"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>'
  };
  function icon(name, className = '') {
    const span = document.createElement('span');
    span.dataset.icon = name;
    span.className = className;
    span.setAttribute('aria-hidden','true');
    span.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">'+paths[name]+'</svg>';
    return span;
  }
  for (const slot of document.querySelectorAll('[data-icon]')) slot.replaceWith(icon(slot.dataset.icon));
  panel.addEventListener('animationend',event => {
    if (event.target === panel && event.animationName === 'panel-in') panel.classList.remove('opening');
  });
  const tools = {
    radio:'Cabin Radio', notes:'Notebook', focus:'Focus timer', guide:'AI field guide', settings:'Snowfall settings'
  };

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  function weather() {
    const {snow, motion} = SnowApps.settings();
    const animated = motion && !reduceMotion.matches;
    scene.classList.toggle('reduce-motion',!animated);
    if (isMacApp) bridge.postMessage(animated && snow !== 'off' ? 'effectsOn' : 'effectsOff');
    const count = animated ? {light:30,heavy:82,off:0}[snow] : 0;
    const fragment = document.createDocumentFragment();
    const random = Math.random;
    for (let i = 0; i < count; i++) {
      const flake = document.createElement('i');
      const depth = random(), duration = 17 - depth*8 + random()*7;
      const values = { x: (random()*110-6)+'%', size: (1.5+depth*3.2)+'px', alpha: (.25+depth*.46).toFixed(2),
        duration: duration+'s', delay: -random()*duration+'s', mid: (8+random()*20)+'px', end: (19+random()*30)+'px' };
      for (const [key,value] of Object.entries(values)) flake.style.setProperty('--'+key,value);
      fragment.append(flake);
    }
    $('#snow').replaceChildren(fragment);
  }
  weather();
  window.addEventListener('snow-settings',weather);
  reduceMotion.addEventListener('change',weather);

  function wake() {
    clearTimeout(idleTimer);
    scene.classList.remove('quiet');
    if (surface === 'wallpaper' || !panel.hidden || inYard) return;
    idleTimer = setTimeout(() => {
      const controls = $('#surface-controls');
      if (!controls.contains(document.activeElement) && !controls.matches(':hover')) scene.classList.add('quiet');
    },5500);
  }
  scene.addEventListener('pointermove',wake,{passive:true});
  scene.addEventListener('pointerdown',wake,{passive:true});
  scene.addEventListener('focusin',wake);
  scene.addEventListener('pointerleave',wake);

  $('#demo-village').hidden = isMacApp;
  if (!isMacApp) {
    let twentyFour = false;
    try { twentyFour = localStorage.getItem('snowfall-os.clock24') === '1'; } catch {}
    const updateClock = () => {
      const now = new Date();
      $('#village-day').textContent = now.toLocaleDateString(undefined,{weekday:'short',month:'short',day:'numeric'});
      $('#village-time').textContent = now.toLocaleTimeString(undefined,{hour:'numeric',minute:'2-digit',hour12:!twentyFour});
      $('#village-time').dateTime = now.toISOString();
    };
    $('#village-clock').addEventListener('click',() => {
      twentyFour = !twentyFour;
      try { localStorage.setItem('snowfall-os.clock24',twentyFour ? '1' : '0'); } catch {}
      updateClock();
    });
    updateClock();
    setInterval(updateClock,15000);
    for(const button of document.querySelectorAll('[data-sample]')) {
      button.addEventListener('click', event => {
        if (event.detail < 2) SnowPorches.tap(SnowPorches.samplePlot(button));
      });
      button.addEventListener('dblclick', () => showTools('houses',button.dataset.sample));
    }
  }

  function cleanup() {
    if (cleanupTool) cleanupTool();
    cleanupTool = null;
    activeTool = null;
    scene.classList.remove('room-mode');
    delete panel.dataset.content;
    $('#panel-body').replaceChildren();
  }
  function closeTools(restoreFocus = false) {
    cleanup();
    panel.hidden = true;
    $('#tools').setAttribute('aria-expanded','false');
    $('#houses').setAttribute('aria-expanded','false');
    if (restoreFocus) $('#tools').focus({preventScroll:true});
    wake();
  }
  function showTools(kind = null,houseId = null) {
    if (surface === 'wallpaper') {
      if (isMacApp) bridge.postMessage(kind === 'houses' ? 'houseWidgets' : 'tools');
      return;
    }
    if (inYard) leaveYard();
    SnowPorches.stop();
    const wasClosed = panel.hidden;
    cleanup();
    panel.hidden = false;
    panel.classList.toggle('opening',wasClosed);
    $('#tools').setAttribute('aria-expanded',String(kind !== 'houses'));
    $('#houses').setAttribute('aria-expanded',String(kind === 'houses'));
    $('#panel-back').hidden = !kind;
    $('#panel-title').textContent = kind === 'houses' ? 'Folder houses' : kind ? tools[kind] : 'Cabin tools';
    const body = $('#panel-body');
    if (kind === 'houses') {
      activeTool = kind;
      panel.dataset.content = 'houses';
      scene.classList.toggle('room-mode',isMacApp);
      $('#panel-back').hidden = true;
      cleanupTool = SnowRooms.mount(body,{native:isMacApp,bridge:command=>bridge?.postMessage(command),houseId});
      if (!isMacApp && !houseId) body.querySelector('button')?.focus({preventScroll:true});
    } else if (kind) {
      activeTool = kind;
      cleanupTool = kind === 'radio' ? CabinRadio.mount(body) : SnowApps.open(kind,body);
      $('#panel-back').focus({preventScroll:true});
    } else {
      const list = document.createElement('div');
      list.className = 'tool-list';
      for (const [value,label] of Object.entries(tools)) {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'tool-row';
        button.dataset.open = value;
        button.append(icon(value,'tool-icon'),document.createTextNode(label),icon('forward'));
        button.addEventListener('click',() => showTools(value));
        list.append(button);
      }
      body.append(list);
      if (isMacApp) {
        const rule = document.createElement('hr');
        rule.className = 'list-divider';
        const subtitle = document.createElement('div');
        subtitle.className = 'mac-label';
        subtitle.textContent = 'Open on this Mac';
        const group = document.createElement('div');
        group.className = 'mac-shortcuts';
        for (const [module,label] of Object.entries({notes:'Notes',music:'Music',clock:'Clock'})) {
          const button = document.createElement('button');
          button.className = 'tool-row';
          button.type = 'button';
          button.append(icon(module),document.createTextNode(label));
          button.addEventListener('click',() => bridge.postMessage(module));
          group.append(button);
        }
        body.append(rule,subtitle,group);
      }
      list.querySelector('button').focus({preventScroll:true});
    }
    wake();
  }
  function leaveYard() {
    if (!inYard) return;
    SnowYard.exit();
    inYard = false;
    scene.classList.remove('yard-active');
    SnowPorches.invalidate();
    $('#back-to-desk').hidden = true;
    wake();
  }
  function openYard(activity = 'build') {
    if (surface === 'wallpaper') {
      if (isMacApp) bridge.postMessage('play');
      return;
    }
    closeTools();
    if (inYard) leaveYard();
    inYard = true;
    scene.classList.add('yard-active');
    SnowPorches.stop();
    SnowPorches.invalidate();
    $('#back-to-desk').hidden = false;
    SnowYard.enter(activity);
    $('#back-to-desk').focus({preventScroll:true});
  }
  function finishYard() {
    leaveYard();
    if (isMacApp) bridge.postMessage('wallpaper');
    else $('#play').focus({preventScroll:true});
  }
  function setSurface(next) {
    surface = next === 'wallpaper' ? 'wallpaper' : 'preview';
    document.documentElement.dataset.surface = surface;
    closeTools();
    leaveYard();
    SnowYard.refresh?.();
    wake();
  }
  function open(kind) {
    if (kind === 'yard') openYard();
    else if (kind === 'tools') showTools();
    else if (kind === 'houses') showTools('houses');
    else if (Object.prototype.hasOwnProperty.call(tools,kind)) showTools(kind);
  }
  window.SnowYard.init($('#yard-stage'),openYard);
  window.SnowScene = Object.freeze({open});
  let imageRevision = 0;
  const alpineDescription = $('#wallpaper').alt;
  async function applyImage(custom) {
    if (custom !== null && (typeof custom !== 'string' || !custom.startsWith('data:image/jpeg;base64,'))) return;
    const revision = ++imageRevision;
    const replacement = new Image();
    replacement.src = custom || 'assets/scene.jpg?v=4.1.0';
    try {
      await replacement.decode();
      if (revision !== imageRevision) return;
      const wallpaper = $('#wallpaper');
      wallpaper.src = replacement.src;
      wallpaper.alt = custom ? 'Your chosen wallpaper image' : alpineDescription;
      scene.classList.toggle('custom-image',Boolean(custom));
    } catch { $('#status').textContent = 'This wallpaper image could not be opened.'; }
  }
  window.addEventListener('snowfall-image',event => {
    if (isMacApp) window.snowfallImageReady = applyImage(event.detail);
  });
  window.addEventListener('snowfall-surface',e => setSurface(e.detail));
  window.addEventListener('snowfall-open',e => open(e.detail));
  window.addEventListener('snowfall-house',e => {
    if (!isMacApp || activeTool === 'houses') return;
    const id=typeof e.detail === 'string' ? e.detail : e.detail?.id;
    if(id) showTools('houses',id);
  });
  window.addEventListener('snowfall-action',e => {
    if (surface === 'wallpaper' && (e.detail === 'roll' || e.detail === 'plow')) SnowYard.ambient?.(e.detail);
  });
  window.addEventListener('focus',() => SnowYard.refresh?.());
  document.addEventListener('visibilitychange',() => {
    if (!document.hidden) SnowYard.refresh?.();
  });
  $('#houses').addEventListener('click',() => {
    if (isMacApp) bridge.postMessage('houseWidgets');
    else if (activeTool === 'houses') closeTools(true);
    else showTools('houses');
  });
  $('#tools').addEventListener('click',() => panel.hidden ? showTools() : closeTools(true));
  $('#play').addEventListener('click',() => openYard());
  $('#back-to-desk').addEventListener('click',finishYard);
  $('#panel-close').addEventListener('click',() => {
    if(isMacApp && activeTool === 'houses') bridge.postMessage('wallpaper');
    else closeTools(true);
  });
  $('#panel-back').addEventListener('click',() => showTools());
  scene.addEventListener('pointerdown',e => {
    if (!panel.hidden && !panel.contains(e.target) && !e.target.closest('#surface-controls')) closeTools();
  });
  window.addEventListener('keydown',e => {
    if (surface === 'wallpaper') return;
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      if (panel.hidden) showTools(); else closeTools(true);
    } else if (e.key === 'Escape') {
      SnowPorches.stop();
      if (!panel.hidden) { e.preventDefault(); if (activeTool) showTools(); else closeTools(true); }
      else if (inYard) { e.preventDefault(); finishYard(); }
      else if (isMacApp) bridge.postMessage('wallpaper');
      else wake();
    }
  });
  const fullButton = $('#fullscreen');
  function labelFull(on) {
    fullButton.title = on ? 'Exit full screen' : 'Enter full screen';
    fullButton.setAttribute('aria-label',fullButton.title);
  }
  if (!isMacApp && !scene.requestFullscreen && !scene.webkitRequestFullscreen) {
    fullButton.previousElementSibling.hidden = true;
    fullButton.hidden = true;
  }
  fullButton.addEventListener('click',async () => {
    if (isMacApp) { bridge.postMessage('fullscreen'); return; }
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else if (document.webkitFullscreenElement) document.webkitExitFullscreen();
      else if (scene.requestFullscreen) await scene.requestFullscreen();
      else scene.webkitRequestFullscreen();
    } catch { $('#status').textContent = 'Fullscreen is unavailable in this window.'; }
  });
  document.addEventListener('fullscreenchange',() => labelFull(Boolean(document.fullscreenElement)));
  document.addEventListener('webkitfullscreenchange',() => labelFull(Boolean(document.webkitFullscreenElement)));
  window.addEventListener('snowfall-native-fullscreen',e => labelFull(e.detail));
  setSurface(surface);
})();
