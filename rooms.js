/* A folder's stable identifier ties its cottage, notebook and timer together across renames. */
(() => {
  'use strict';
  const samples = [
    {id:'sample-sketchbook', name:'Sketchbook', variant:1},
    {id:'sample-studio', name:'Studio', variant:3},
    {id:'sample-library', name:'Library', variant:5},
  ];
  const widgets = [
    {kind:'notes',name:'Notebook'},
    {kind:'focus',name:'Focus timer'},
    {kind:'radio',name:'Cabin radio'},
    {kind:'guide',name:'AI field guide'},
    {kind:'settings',name:'Snow settings'},
  ];
  const paths = {
    notes:'M6 3.5h11a1.5 1.5 0 0 1 1.5 1.5v15H6a2 2 0 0 1-2-2V5.5a2 2 0 0 1 2-2Zm1.5 0v16M11 8h4m-4 3h4',
    focus:'M6 3.5h12M6 20.5h12M7.5 4v2c0 2.4 1.8 4 4.5 6-2.7 2-4.5 3.6-4.5 6v2m9-16v2c0 2.4-1.8 4-4.5 6 2.7 2 4.5 3.6 4.5 6v2m-6.7-2h4.4',
    radio:'M5 8.5l12-6M4.5 8.5h15A1.5 1.5 0 0 1 21 10v8.5a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18.5V10a1.5 1.5 0 0 1 1.5-1.5ZM14 12h4m-4 3h4M10.8 14.5a2.8 2.8 0 1 1-5.6 0 2.8 2.8 0 0 1 5.6 0Z',
    guide:'M12 6c-2.6-2.2-6-2.4-9-1.3V18c3-1 6.4-.9 9 1.3m0-13.3c2.6-2.2 6-2.4 9-1.3V18c-3-1-6.4-.9-9 1.3Zm0 0v13',
    settings:'M12 2v20M3.4 7l17.2 10M3.4 17l17.2-10M9.6 3.8 12 6l2.4-2.2M9.6 20.2 12 18l2.4 2.2M3.9 9.7l3-.9-.6-3.1m11.4 12.6-.6-3.1 3-.9M3.9 14.3l3 .9-.6 3.1m11.4-12.6-.6 3.1 3 .9',
    folder:'M3 7V5.5A1.5 1.5 0 0 1 4.5 4H10l2 3h7.5A1.5 1.5 0 0 1 21 8.5V18a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18V7Z',
    back:'m14.5 5.5-6.5 6.5 6.5 6.5',
  };
  const mounts = new WeakMap();
  const el = (tag,cls,text) => {
    const node=document.createElement(tag);
    if (cls) node.className=cls;
    if (text!==undefined) node.textContent=text;
    return node;
  };
  function icon(name) {
    const ns='http://www.w3.org/2000/svg';
    const svg=document.createElementNS(ns,'svg'), path=document.createElementNS(ns,'path');
    svg.setAttribute('viewBox','0 0 24 24'); svg.setAttribute('aria-hidden','true');
    path.setAttribute('d',paths[name]); svg.append(path);
    return svg;
  }
  function button(cls,label,click,glyph) {
    const node=el('button',cls);
    node.type='button';
    if (glyph) node.append(icon(glyph));
    node.append(el('span','',label));
    node.addEventListener('click',click);
    return node;
  }
  const imgPath = variant => 'assets/houses/cottage-'+variant+'.png?v=4.0.1';
  function art(house) {
    const node=el('img','room-cottage');
    node.alt=''; node.draggable=false; node.src=imgPath(house.variant);
    return node;
  }
  function housesFrom(raw) {
    const result=new Map();
    if (!Array.isArray(raw)) return result;
    raw.forEach(house => {
      if (typeof house?.id !== 'string' || !house.id || typeof house.name !== 'string') return;
      const variant=Number(house.variant);
      result.set(house.id,{id:house.id,name:house.name,variant:Number.isInteger(variant) && variant>=1 && variant<=6 ? variant : 1});
    });
    return result;
  }

  function mount(host,options={}) {
    mounts.get(host)?.();
    const native=options.native===true;
    const bridge=typeof options.bridge === 'function' ? options.bridge : () => {};
    let catalog=housesFrom(native ? [] : samples), received=!native, enabled=false, error='';
    let pendingId=typeof options.houseId==='string' ? options.houseId : '';
    let selected=null, widget='', available=true, stopWidget=null;
    let heroName, heroImage, openFolder, backButton;
    const root=el('section','rooms-root');
    const top=el('div','room-nav'), body=el('div','room-body'), status=el('p','room-status');
    status.setAttribute('role','status'); root.setAttribute('aria-label','Cottage rooms');
    root.append(top,body,status); host.replaceChildren(root);

    function clear() {
      stopWidget?.(); stopWidget=null;
      top.replaceChildren(); body.replaceChildren(); status.textContent='';
      heroName=null; heroImage=null; openFolder=null; backButton=null;
    }
    function requestList() { if (native) bridge('houses'); }
    function picker() {
      clear(); selected=null; widget=''; pendingId=''; delete root.dataset.roomId;
      const heading=el('h2','',native ? 'Your folder houses' : 'Sample houses');
      top.append(heading);
      if (!native) body.append(el('p','room-description','Choose a cottage to open its widgets.'));
      else if (!received) body.append(el('p','room-description','Finding your folder houses…'));
      const list=el('div','room-list'); list.id='house-list';
      for (const house of catalog.values()) {
        const tile=button('room-house',house.name,() => showRoom(house));
        tile.prepend(art(house)); tile.dataset.houseId=house.id;
        list.append(tile);
      }
      body.append(list);
      if (!list.childElementCount && native && received && !error) {
        body.append(el('p','room-description',enabled ? 'Your Desktop folders will appear here.' : 'Style your Desktop folders to give each one a cottage and a room for its widgets.'));
      }
      if (native && received) {
        const row=el('div','room-management');
        row.append(button('room-link',enabled ? 'Restore folder icons' : 'Style folder icons',() => bridge(enabled ? 'restoreHouses' : 'styleHouses')));
        if (error) row.append(button('room-link','Refresh',requestList));
        body.append(row);
      }
      status.textContent=error;
    }
    function updateHeader() {
      if (!selected) return;
      if (heroName) { heroName.textContent=selected.name; heroName.title=selected.name; }
      if (heroImage) heroImage.src=imgPath(selected.variant);
      if (backButton && widget) backButton.querySelector('span').textContent=selected.name;
      if (openFolder) openFolder.disabled=!available;
      status.textContent=error || (!available ? 'This folder is unavailable. Its saved widgets are still here.' : '');
    }
    function backToRoom() {
      const previous=widget;
      showRoom(selected);
      Array.from(body.querySelectorAll('[data-widget]')).find(item=>item.dataset.widget===previous)?.focus();
    }
    function backToVillage() {
      const id=selected?.id;
      picker();
      Array.from(body.querySelectorAll('[data-house-id]')).find(item=>item.dataset.houseId===id)?.focus();
    }
    function nav() {
      backButton=button('room-back',widget ? selected.name : 'Village',widget ? backToRoom : backToVillage,'back');
      top.append(backButton);
      if (native) {
        openFolder=button('room-folder','Open folder',() => { if (available) bridge('openHouseFolder:'+selected.id); },'folder');
        top.append(openFolder);
      }
    }
    function showWidget(kind) {
      clear(); widget=kind;
      nav();
      const label=widgets.find(item=>item.kind===kind).name;
      const title=el('h2','room-widget-title',label); title.prepend(icon(kind)); title.tabIndex=-1;
      const content=el('div','room-widget');
      body.append(title,content);
      stopWidget=kind==='radio' ? window.CabinRadio.mount(content) : window.SnowApps.open(kind,content,{houseId:selected.id});
      updateHeader(); title.focus({preventScroll:true});
    }
    function showRoom(house) {
      clear(); selected=house; widget=''; pendingId=''; available=catalog.has(house.id); root.dataset.roomId=house.id;
      nav();
      const hero=el('div','room-hero');
      heroImage=art(house); heroName=el('h2','',house.name); heroName.tabIndex=-1;
      const title=el('div','room-identity');
      title.append(el('p','room-type',native ? 'Folder cottage' : 'Sample cottage'),heroName);
      hero.append(heroImage,title);
      const grid=el('div','room-widgets');
      widgets.forEach(({kind,name}) => {
        const tile=button('room-tool',name,()=>showWidget(kind),kind);
        tile.dataset.widget=kind; grid.append(tile);
      });
      body.append(hero,grid); updateHeader(); heroName.focus({preventScroll:true});
    }
    function route(id) {
      if (typeof id!=='string' || !id) return;
      if (catalog.has(id)) {
        pendingId='';
        if (id!==selected?.id) showRoom(catalog.get(id));
        return;
      }
      pendingId=id; requestList();
    }
    function onHouse(event) { route(typeof event.detail === 'string' ? event.detail : event.detail?.id); }
    function onHouses(event) {
      const data=event.detail;
      if (!native || !data || typeof data !== 'object') return;
      const previousCatalog=catalog, previousEnabled=enabled, previousError=error, wasReceived=received;
      received=true; enabled=!!data.enabled; error=typeof data.error==='string' ? data.error : '';
      if (Array.isArray(data.houses)) catalog=housesFrom(data.houses);
      if (pendingId && catalog.has(pendingId)) { showRoom(catalog.get(pendingId)); return; }
      if (selected) {
        available=catalog.has(selected.id);
        if (available) selected=catalog.get(selected.id);
        updateHeader(); return;
      }
      const changed=!wasReceived || previousError!==error || previousEnabled!==enabled || JSON.stringify([...previousCatalog])!==JSON.stringify([...catalog]);
      if (changed) {
        const requested=pendingId;
        const focusedId=document.activeElement?.dataset?.houseId;
        picker(); pendingId=requested;
        if (focusedId) Array.from(body.querySelectorAll('[data-house-id]')).find(item=>item.dataset.houseId===focusedId)?.focus();
      }
    }
    if (native) {
      window.addEventListener('snowfall-house',onHouse);
      window.addEventListener('snowfall-houses',onHouses);
    }
    const initial=pendingId;
    picker(); pendingId=initial;
    if (catalog.has(initial)) showRoom(catalog.get(initial)); else requestList();
    function cleanup() {
      if (mounts.get(host)!==cleanup) return;
      mounts.delete(host); stopWidget?.();
      window.removeEventListener('snowfall-house',onHouse); window.removeEventListener('snowfall-houses',onHouses);
    }
    mounts.set(host,cleanup);
    return cleanup;
  }
  window.SnowRooms=Object.freeze({mount});
})();
