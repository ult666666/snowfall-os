/* The desktop arranges app windows. Each mini-app owns its own data and behavior. */
(() => {
  'use strict';
  const $ = selector => document.querySelector(selector);
  const scene = $('#desktop');
  const apps = {
    radio: { title: 'Cabin Radio', icon: 'radio' },
    notes: { title: 'Field notes', icon: 'notes' },
    focus: { title: 'Focus timer', icon: 'focus' },
    yard: { title: 'Snow yard', icon: 'snowman' },
    guide: { title: 'Field guide', icon: 'guide' },
    settings: { title: 'Settings', icon: 'settings' }
  };
  const paths = {
    snow: '<path d="M12 2v20M3.35 7l17.3 10M3.35 17l17.3-10M9 4.5l3 2.7 3-2.7M9 19.5l3-2.7 3 2.7M4.1 10.8l3.8-1.3-.7-3.8m9.6 12.6-.7-3.8 3.8-1.3M7.2 18.3l.7-3.8-3.8-1.3m15.8-2.4-3.8-1.3.7-3.8"/>',
    expand: '<path d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>', minus: '<path d="M5 16h14"/>',
    eye: '<path d="M2 12s3.8-7 10-7 10 7 10 7-3.8 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="2.6"/>',
    search: '<circle cx="10.4" cy="10.4" r="6.9"/><path d="m16 16 5 5"/>'
  };
  function glyph(name) {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + paths[name] + '</svg>';
  }
  function addGlyphs(parent) {
    parent.querySelectorAll('[data-glyph]').forEach(node => { node.innerHTML = glyph(node.dataset.glyph); });
  }
  function sprite(name) {
    const img = new Image();
    img.src = 'assets/icons/' + name + '.png';
    img.alt = '';
    img.draggable = false;
    return img;
  }
  function appButton(kind, className, showLabel) {
    const def = apps[kind];
    const button = document.createElement('button');
    button.type = 'button';
    button.className = className;
    button.dataset.open = kind;
    button.dataset.label = def.title;
    button.setAttribute('aria-label', def.title);
    button.append(sprite(def.icon));
    if (showLabel) {
      const span = document.createElement('span');
      span.textContent = def.title;
      button.append(span);
    }
    return button;
  }
  for (const kind of ['notes', 'focus', 'yard']) $('#shortcuts').append(appButton(kind, 'shortcut', true));
  for (const kind of Object.keys(apps)) {
    if (kind === 'guide') {
      const rule = document.createElement('span');
      rule.className = 'dock-divider';
      $('#dock').append(rule);
    }
    $('#dock').append(appButton(kind, 'dock-item', false));
  }
  addGlyphs(document);

  const dateFormat = new Intl.DateTimeFormat('en', { weekday: 'long', month: 'long', day: 'numeric' });
  function clockTick() {
    const now = new Date();
    $('#clock').textContent = (now.getHours() % 12 || 12) + ':' + String(now.getMinutes()).padStart(2, '0');
    $('#clock').dateTime = now.toISOString();
    $('#meridiem').textContent = now.getHours() >= 12 ? 'PM' : 'AM';
    $('#calendar').textContent = dateFormat.format(now);
    setTimeout(clockTick, 60000 - (now.getTime() % 60000) + 40);
  }
  clockTick();

  function weather({snow, motion}) {
    scene.classList.toggle('reduce-motion', !motion);
    scene.classList.toggle('motion-enabled', motion);
    $('#weather-text').textContent = { off: 'Clear sky', light: 'Light snow', heavy: 'Heavy snow' }[snow];
    const flakes = document.createDocumentFragment();
    const count = motion ? {off:0, light:32, heavy:85}[snow] : 0;
    for (let index = 0; index < count; index++) {
      const flake = document.createElement('i');
      flake.className = 'flake';
      const rand = Math.random;
      const values = { x: rand()*100+'%', s: 1+Math.floor(rand()*3)+'px', o: (.22+rand()*.5).toFixed(2),
        t: 10+rand()*10+'s', d: -rand()*22+'s', drift: 12+rand()*45+'px' };
      for (const [key,value] of Object.entries(values)) flake.style.setProperty('--'+key, value);
      flakes.append(flake);
    }
    $('#flakes').replaceChildren(flakes);
  }
  weather(window.SnowApps.settings());
  window.addEventListener('snow-settings', event => weather(event.detail));

  const windows = new Map();
  let front = 1;
  const topMargin = () => $('.menubar').offsetHeight + 8;
  function bound(value, low, high) { return Math.max(low, Math.min(high, value)); }
  function place(panel, x, y) {
    panel.style.left = bound(x, 7, scene.clientWidth - panel.offsetWidth - 7) + 'px';
    panel.style.top = bound(y, topMargin(), scene.clientHeight - panel.offsetHeight - 7) + 'px';
  }
  function defaultPlace(panel, kind) {
    const w = scene.clientWidth, h = scene.clientHeight;
    const left = w <= 500 ? 15 : Math.max(25, w * .0455);
    const radioTop = Math.max(topMargin()+90, h * (w <= 500 ? .388 : .36));
    if (kind === 'radio') { place(panel, left, radioTop); return; }
    const offset = (windows.size-1) % 4 * 18;
    place(panel, w < 650 ? 15 : Math.max(left + 35, w * .49 - panel.offsetWidth/2 + offset),
      w < 650 ? topMargin() + 52 : Math.max(topMargin()+30, h * .23 + offset));
  }
  function raise(panel) {
    panel.style.zIndex = String(++front);
  }
  function attachDrag(panel, head) {
    let drag = null;
    head.addEventListener('pointerdown', event => {
      if (event.button !== 0 || event.target.closest('button')) return;
      drag = { x: event.clientX-panel.offsetLeft, y: event.clientY-panel.offsetTop, id:event.pointerId };
      head.setPointerCapture(event.pointerId);
      event.preventDefault();
    });
    head.addEventListener('pointermove', event => {
      if (drag?.id === event.pointerId) {
        panel.dataset.dragged = 'true';
        place(panel, event.clientX-drag.x, event.clientY-drag.y);
      }
    });
    const finish = () => { drag = null; };
    head.addEventListener('pointerup', finish);
    head.addEventListener('lostpointercapture', finish);
    head.addEventListener('pointercancel', finish);
  }
  function showWindow(kind, focusTitle = true) {
    const entry = windows.get(kind);
    if (entry) {
      entry.panel.hidden = false;
      place(entry.panel, parseFloat(entry.panel.style.left), parseFloat(entry.panel.style.top));
      raise(entry.panel);
      if (focusTitle) entry.panel.focus({preventScroll:true});
      return;
    }
    const panel = document.createElement('section');
    const def = apps[kind];
    panel.className = 'app-window';
    panel.dataset.kind = kind;
    panel.tabIndex = -1;
    panel.setAttribute('aria-label', def.title);
    panel.innerHTML = '<div class="window-head"><h2></h2><div class="window-buttons">' +
      '<button class="frame-btn minimize" type="button"><span data-glyph="minus"></span></button>' +
      '<button class="frame-btn close" type="button"><span data-glyph="close"></span></button></div></div><div class="window-body"></div>';
    const head = panel.querySelector('.window-head');
    head.prepend(sprite(def.icon));
    head.querySelector('h2').textContent = def.title;
    const dockButton = $('#dock [data-open="'+kind+'"]');
    const min = panel.querySelector('.minimize'), close = panel.querySelector('.close');
    min.title = 'Minimize '+def.title;
    close.title = 'Close '+def.title;
    min.setAttribute('aria-label',min.title);
    close.setAttribute('aria-label',close.title);
    addGlyphs(panel);
    $('#windows').append(panel);
    const body = panel.querySelector('.window-body');
    const cleanup = kind === 'radio' ? window.CabinRadio.mount(body) : window.SnowApps.open(kind, body);
    windows.set(kind, {panel, cleanup});
    dockButton.classList.add('is-open');
    panel.addEventListener('pointerdown', () => raise(panel));
    panel.addEventListener('focusin', () => raise(panel));
    min.addEventListener('click', () => { panel.hidden = true; dockButton.focus({preventScroll:true}); });
    close.addEventListener('click', () => {
      if (cleanup) cleanup();
      panel.remove();
      windows.delete(kind);
      dockButton.classList.remove('is-open');
      dockButton.focus({preventScroll:true});
    });
    attachDrag(panel, head);
    defaultPlace(panel,kind);
    raise(panel);
    if (focusTitle) panel.focus({preventScroll:true});
  }

  let lastLauncherFocus;
  function showResults() {
    const query = $('#app-search').value.trim().toLowerCase();
    const results = $('#results');
    results.replaceChildren();
    for (const [kind,def] of Object.entries(apps)) {
      if (def.title.toLowerCase().includes(query)) results.append(appButton(kind,'result',true));
    }
    if (!results.childElementCount) {
      const hint = document.createElement('p');
      hint.className = 'empty-results';
      hint.textContent = 'No matching apps.';
      results.append(hint);
    }
  }
  function closeLauncher() {
    const dialog = $('#launcher-backdrop');
    if (dialog.hidden) return;
    dialog.hidden = true;
    if (lastLauncherFocus?.isConnected) lastLauncherFocus.focus({preventScroll:true});
  }
  function openLauncher() {
    const dialog = $('#launcher-backdrop');
    if (!dialog.hidden) { closeLauncher(); return; }
    lastLauncherFocus = document.activeElement;
    dialog.hidden = false;
    $('#app-search').value = '';
    showResults();
    $('#app-search').focus();
  }
  function setZen(on) {
    scene.classList.toggle('zen-mode',on);
    $('#scene-label').textContent = on ? 'Show desktop' : 'Hide desktop';
    $('#scene-hint').setAttribute('aria-label', on ? 'Show desktop' : 'Hide desktop');
    $('#scene-hint').title = $('#scene-label').textContent;
  }
  function setYard(on, activity = 'build') {
    if (scene.classList.contains('yard-mode') === on) return;
    scene.classList.toggle('yard-mode', on);
    $('#back-to-desk').hidden = !on;
    if (on) { setZen(false); window.SnowYard.enter(activity); $('#back-to-desk').focus({preventScroll:true}); }
    else { window.SnowYard.exit(); $('#dock [data-open="yard"]').focus({preventScroll:true}); }
  }
  function openApp(kind, focusTitle = true, activity = 'build') {
    if (!apps[kind]) return;
    closeLauncher();
    setZen(false);
    if (kind === 'yard') { setYard(true,activity); return; }
    setYard(false);
    showWindow(kind,focusTitle);
  }
  window.SnowYard.init($('#yard-stage'),activity => openApp('yard',true,activity));
  $('#back-to-desk').addEventListener('click',() => setYard(false));
  document.addEventListener('click',event => {
    const launch = event.target.closest('[data-open]');
    if (launch) openApp(launch.dataset.open);
  });
  $('#app-search').addEventListener('input',showResults);
  $('#desktop-menu').addEventListener('click',openLauncher);
  $('#launch-hint').addEventListener('click',openLauncher);
  $('#close-launcher').addEventListener('click',closeLauncher);
  $('#launcher-backdrop').addEventListener('click',e => { if(e.target === e.currentTarget) closeLauncher(); });
  $('#scene-hint').addEventListener('click',() => setZen(!scene.classList.contains('zen-mode')));
  window.addEventListener('keydown',event => {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault(); openLauncher(); return;
    }
    if (!$('#launcher-backdrop').hidden) {
      if (event.key === 'Escape') { event.preventDefault(); closeLauncher(); return; }
      const input = $('#app-search'), buttons = [...$('#results').querySelectorAll('button')];
      if (event.key === 'Enter' && document.activeElement === input && buttons.length) {
        event.preventDefault(); buttons[0].click(); return;
      }
      if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && buttons.length) {
        event.preventDefault();
        const at = buttons.indexOf(document.activeElement), diff = event.key === 'ArrowDown' ? 1 : -1;
        buttons[at < 0 ? (diff > 0 ? 0 : buttons.length-1) : (at+diff+buttons.length)%buttons.length].focus();
      }
      if (event.key === 'Tab') {
        const items = [$('#close-launcher'),input,...buttons];
        if ((!event.shiftKey && document.activeElement === items[items.length-1]) ||
            (event.shiftKey && document.activeElement === items[0])) {
          event.preventDefault(); items[event.shiftKey ? items.length-1 : 0].focus();
        }
      }
      return;
    }
    if (event.key === 'Escape') {
      if (scene.classList.contains('yard-mode')) setYard(false);
      else if (scene.classList.contains('zen-mode')) setZen(false);
    }
  });
  let resizeFrame;
  window.addEventListener('resize',() => {
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => {
      if (scene.clientWidth < 120 || scene.clientHeight < 120) return;
      for (const [kind, {panel}] of windows) {
        if (panel.hidden || !panel.offsetWidth) continue;
        if (panel.dataset.dragged) place(panel, parseFloat(panel.style.left), parseFloat(panel.style.top));
        else defaultPlace(panel, kind);
      }
    });
  });

  const phrases = ['Got a carrot?', 'Snow day!', 'Meet me in the yard!', 'Look at those stars.', 'Cocoa weather!', 'Hi, neighbor!'];
  let phrase = 0, hopTimer;
  $('#pip').addEventListener('click', () => {
    const line = phrases[phrase++ % phrases.length];
    $('#pip-bubble').textContent = line;
    $('#announcer').textContent = 'Pip says '+line;
    const pip = $('#pip');
    clearTimeout(hopTimer);
    pip.classList.remove('hopping');
    void pip.offsetWidth;
    pip.classList.add('hopping');
    hopTimer = setTimeout(()=>pip.classList.remove('hopping'),560);
  });
  const fullButton = $('#fullscreen');
  function fullLabel(active) {
    fullButton.title = active ? 'Exit full screen' : 'Enter full screen';
    fullButton.setAttribute('aria-label',fullButton.title);
  }
  fullButton.addEventListener('click', async () => {
    const native = window.webkit?.messageHandlers?.snowfallWindow;
    if (native) { native.postMessage('fullscreen'); return; }
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else if (document.webkitFullscreenElement) document.webkitExitFullscreen();
      else if (scene.requestFullscreen) await scene.requestFullscreen();
      else if (scene.webkitRequestFullscreen) scene.webkitRequestFullscreen();
      else setZen(!scene.classList.contains('zen-mode'));
    } catch { setZen(true); }
  });
  document.addEventListener('fullscreenchange',()=>fullLabel(Boolean(document.fullscreenElement)));
  document.addEventListener('webkitfullscreenchange',()=>fullLabel(Boolean(document.webkitFullscreenElement)));
  window.addEventListener('snowfall-native-fullscreen',event=>fullLabel(event.detail));
  openApp('radio',false);
})();
