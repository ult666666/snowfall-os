/* The Mac supplies local item metadata. The public village has its own fictional mail. */
(() => {
  'use strict';
  const scene = document.querySelector('#scene');
  const officeDoor = document.querySelector('[data-scenery="bakery"]');
  if (!scene || !officeDoor) return;
  const native = Boolean(window.snowfallNative);
  const bridge = window.webkit?.messageHandlers?.snowfallWindow;
  const samples = [
    {id:'trail-notes', name:'First snow.txt', kind:'document', url:'assets/first-snow.txt'},
    {id:'ridge-postcard', name:'Frostpine postcard.jpg', kind:'image', url:'assets/scene.jpg'},
    {id:'seed-parcel', name:'Winter seed parcel', kind:'package'}
  ];
  let items = [];
  const counter = document.createElement('div');
  counter.id = 'postal-counter';
  counter.setAttribute('aria-label', 'Letters at the village post office');
  scene.append(counter);
  const desk = document.createElement('dialog');
  desk.id = 'sorting-desk';
  desk.setAttribute('aria-labelledby', 'sorting-title');
  desk.innerHTML = '<header><h2 id="sorting-title">Village post office</h2><button type="button" aria-label="Close post office">×</button></header><div class="sorting-content"></div>';
  scene.append(desk);
  const content = desk.querySelector('.sorting-content');
  let opener = officeDoor;

  function closeDesk() {
    if (desk.open && desk.close) desk.close();
    else if (desk.hasAttribute('open')) { desk.removeAttribute('open'); opener?.focus(); }
  }
  desk.querySelector('header button').addEventListener('click', closeDesk);
  desk.addEventListener('close', () => opener?.isConnected && opener.focus({preventScroll:true}));
  desk.addEventListener('click', event => { if (event.target === desk) {
    const rect = desk.getBoundingClientRect();
    if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) closeDesk();
  } });
  function showDesk(title) {
    document.querySelector('#sorting-title').textContent = title;
    content.replaceChildren();
    if (!desk.open) {
      opener = document.activeElement;
      if (desk.showModal) desk.showModal(); else desk.setAttribute('open', '');
    }
  }
  function listMail() {
    if (native) { bridge?.postMessage({action:'postOffice'}); return; }
    showDesk('Village post office');
    const list = document.createElement('ul');
    list.className = 'sorting-list';
    for (const item of items) {
      const row = document.createElement('li');
      const button = document.createElement('button');
      button.type = 'button';
      const label = document.createElement('span');
      label.textContent = item.name;
      button.append(paper(item.kind), label);
      button.addEventListener('click', () => openItem(item));
      row.append(button); list.append(row);
    }
    content.append(list);
  }
  function openItem(item) {
    if (native) { bridge?.postMessage({action:'openLetter', id:item.id}); return; }
    showDesk(item.name);
    if (item.kind === 'image') {
      const image = document.createElement('img');
      image.className = 'sorting-postcard'; image.alt = 'The snow-covered streets of Frostpine Hollow';
      image.src = item.url; content.append(image);
    } else {
      const body = document.createElement('p');
      body.className = 'sorting-letter';
      body.textContent = item.kind === 'package' ? 'Packed for spring: three paper packets of poppy, lupine and forget-me-not seeds.' :
        'First snow, Tuesday morning. The fox crossed the footbridge before the post office opened. I counted six little prints in the drift.';
      content.append(body);
    }
    const actions = document.createElement('footer');
    const back = document.createElement('button'); back.type = 'button'; back.textContent = 'All mail';
    back.addEventListener('click', listMail); actions.append(back);
    if (item.url) {
      const save = document.createElement('a'); save.href = item.url; save.download = item.name;
      save.textContent = 'Save a copy'; actions.append(save);
    }
    content.append(actions);
  }
  function paper(kind) {
    const sheet = document.createElement('i');
    sheet.className = 'postal-paper ' + (kind === 'image' ? 'picture' : kind === 'package' ? 'parcel' : 'letter');
    sheet.setAttribute('aria-hidden','true');
    return sheet;
  }
  function place() {
    const rect = scene.getBoundingClientRect();
    const width = rect.width, height = rect.height, narrow = width <= 580;
    const scale = Math.max(width / 2560, height / 1600);
    const cx = (width - 2560*scale) * (narrow ? .49 : .57) + 2560*scale*.2222;
    const cy = (height - 1600*scale) * (narrow ? .50 : .56) + 1600*scale*.5285;
    const w = 2560*scale*.12, h = w*.84;
    Object.assign(counter.style, {left:(cx-w/2)+'px', top:(cy-h/2)+'px', width:w+'px', height:h+'px'});
  }
  function compose(newItems) {
    if (!Array.isArray(newItems)) return;
    items = newItems.filter(i => i && typeof i.name === 'string' && typeof i.id === 'string');
    const fragment = document.createDocumentFragment();
    if (native) {
      const door = document.createElement('button');
      door.type = 'button'; door.className = 'counter-door';
      door.setAttribute('aria-label','Open the village post office');
      door.addEventListener('click', listMail); fragment.append(door);
    }
    for (const item of items.slice(0,2)) {
      const button = document.createElement('button');
      button.type = 'button'; button.className = 'counter-mail';
      button.title = item.name; button.setAttribute('aria-label','Open '+item.name);
      const label = document.createElement('span'); label.textContent = item.name;
      button.append(paper(item.kind), label);
      button.addEventListener('click', () => openItem(item)); fragment.append(button);
    }
    const plaque = document.createElement('span');
    plaque.className = 'post-office-plaque';
    plaque.setAttribute('aria-hidden','true');
    plaque.textContent = 'Post office';
    fragment.append(plaque);
    counter.replaceChildren(fragment);
    officeDoor.title = items.length === 1 ? 'Post office · 1 item' : 'Post office · '+items.length+' items';
    place();
  }
  officeDoor.addEventListener('click', listMail);
  window.composePostOffice = compose;
  compose(native ? window.postOfficeItems || [] : samples);
  new ResizeObserver(place).observe(scene);
  window.addEventListener('snowfall-surface', () => { closeDesk(); place(); });
})();
