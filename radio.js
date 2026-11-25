// Cabin Radio is a tiny sequencer. Each score describes a chord progression,
// a tempo, and a melody in eighth notes. All sound is synthesized on device.
(() => {
  'use strict';

  const tracks = [
    {
      title: 'Snowfall Serenade', artist: 'The Hearthside Trio', bpm: 80, bars: 48,
      chords: [[50, 54, 57, 61], [47, 50, 54, 57], [43, 47, 50, 54], [45, 49, 52, 59]],
      tune: [[78, 0, 0, 76, 73, 0, 69, 0], [74, 0, 0, 73, 71, 0, 0, 0],
        [71, 0, 74, 0, 78, 0, 76, 0], [73, 0, 0, 69, 71, 0, 0, 0]],
      tone: 'sine', echo: 0.16
    },
    {
      title: 'Lanterns on the Lake', artist: 'Juniper & Pine', bpm: 66, bars: 32,
      chords: [[48, 52, 55, 59], [45, 48, 52, 55], [41, 45, 48, 52], [43, 47, 50, 57]],
      tune: [[72, 0, 0, 0, 76, 0, 79, 0], [76, 0, 0, 72, 69, 0, 0, 0],
        [69, 0, 72, 0, 76, 0, 0, 0], [74, 0, 71, 0, 67, 0, 0, 0]],
      tone: 'triangle', echo: 0.23
    },
    {
      title: 'Ember Glow', artist: 'The Velvet Pines', bpm: 92, bars: 48,
      chords: [[51, 55, 58, 62], [48, 51, 55, 58], [44, 48, 51, 55], [46, 50, 53, 60]],
      tune: [[79, 0, 77, 0, 74, 75, 0, 0], [75, 0, 0, 72, 70, 0, 67, 0],
        [72, 0, 75, 0, 79, 0, 0, 75], [77, 0, 74, 0, 70, 0, 0, 0]],
      tone: 'sine', echo: 0.12
    }
  ];
  const subscribers = new Set();
  const mounts = new WeakMap();
  let trackIndex = 0, offset = 0, origin = 0, nextStep = 0, timer;
  let playing = false, pending = false, volume = 0.55, muted = false, message = '';
  let context, master, bus;
  let favorites = [];
  try {
    const saved = JSON.parse(localStorage.getItem('snowfall.radio.favorites'));
    if (Array.isArray(saved)) favorites = saved;
  } catch { /* The player also works with storage disabled. */ }

  const track = () => tracks[trackIndex];
  const stepLength = () => 30 / track().bpm;
  const duration = () => track().bars * 8 * stepLength();
  const position = () => Math.min(duration(), playing ? Math.max(0, context.currentTime - origin) : offset);
  const formatTime = (v) => Math.floor(v / 60) + ':' + String(Math.floor(v % 60)).padStart(2, '0');
  const render = () => subscribers.forEach(update => update());

  function setLevel() {
    if (master) master.gain.setTargetAtTime(muted ? 0 : volume * 0.8, context.currentTime, 0.015);
  }

  function fadeBus() {
    if (!bus) return;
    const old = bus;
    old.gain.setTargetAtTime(0, context.currentTime, 0.012);
    window.setTimeout(() => old.disconnect(), 100);
    bus = null;
  }

  function startFrom(seconds) {
    fadeBus();
    bus = context.createGain();
    bus.connect(master);
    origin = context.currentTime + 0.025 - seconds;
    nextStep = Math.ceil(seconds / stepLength());
    tick();
  }

  function note(midi, start, length, strength, wave, attack = 0.014) {
    const oscillator = context.createOscillator(), envelope = context.createGain();
    oscillator.type = wave;
    oscillator.frequency.value = 440 * 2 ** ((midi - 69) / 12);
    envelope.gain.setValueAtTime(0.0001, start);
    envelope.gain.exponentialRampToValueAtTime(strength, start + attack);
    envelope.gain.exponentialRampToValueAtTime(0.0001, start + length);
    oscillator.connect(envelope).connect(bus);
    oscillator.onended = () => { oscillator.disconnect(); envelope.disconnect(); };
    oscillator.start(start);
    oscillator.stop(start + length + 0.02);
  }

  function playStep(step, when) {
    const song = track(), bar = Math.floor(step / 8), beat = step % 8;
    const phrase = bar % 4, chord = song.chords[phrase], unit = stepLength();
    if (beat === 0) {
      note(chord[0] - 12, when, unit * 6, 0.2, 'sine', 0.025);
      chord.forEach((pitch, index) => note(pitch + 12, when + index * 0.023, unit * 5.5, 0.043, 'sine', 0.045));
    }
    if (beat % 2 === 1 && (trackIndex === 2 || beat === 3 || beat === 7)) {
      note(chord[(bar + beat) % 4] + 12, when, unit * 1.8, 0.055, 'triangle');
    }
    const pitch = song.tune[phrase][beat];
    if (pitch && (bar % 8 !== 7 || beat < 4)) {
      const octave = bar % 16 >= 12 && beat === 0 ? 12 : 0;
      note(pitch + octave, when, unit * 2.8, 0.125, song.tone);
      note(pitch + octave, when + unit * 1.5, unit * 2, 0.125 * song.echo, 'sine');
    }
  }

  function tick() {
    if (position() >= duration()) { changeTrack(1); return; }
    const unit = stepLength(), now = context.currentTime;
    // After a background-tab suspension, resume at the current musical phrase.
    nextStep = Math.max(nextStep, Math.ceil((now - origin - 0.06) / unit));
    while (nextStep < track().bars * 8 && origin + nextStep * unit <= now + 1.4) {
      playStep(nextStep, Math.max(now + 0.002, origin + nextStep * unit));
      nextStep++;
    }
    render();
  }

  async function toggle() {
    if (pending) return;
    if (playing) {
      offset = position();
      playing = false;
      clearInterval(timer);
      fadeBus();
      render();
      return;
    }
    pending = true;
    try {
      if (!context) {
        const Audio = window.AudioContext || window.webkitAudioContext;
        context = new Audio();
        master = context.createGain();
        master.connect(context.destination);
        setLevel();
      }
      if (context.state !== 'running') await context.resume();
      playing = true;
      message = '';
      startFrom(offset >= duration() ? 0 : offset);
      timer = window.setInterval(tick, 100);
    } catch {
      playing = false;
      message = 'Audio unavailable';
    } finally {
      pending = false;
      render();
    }
  }

  function changeTrack(delta) {
    trackIndex = (trackIndex + delta + tracks.length) % tracks.length;
    offset = 0;
    if (playing) startFrom(0);
    render();
  }

  function seek(value) {
    offset = Math.min(duration(), Math.max(0, value));
    if (playing) startFrom(offset);
    render();
  }

  const paths = {
    previous: '<path d="M5 5v14M18 5l-9 7 9 7z" fill="currentColor"/>',
    next: '<path d="M19 5v14M6 5l9 7-9 7z" fill="currentColor"/>',
    play: '<path d="m8 4 12 8-12 8z" fill="currentColor"/>',
    pause: '<path d="M7 5v14m10-14v14" stroke-width="4"/>',
    heart: '<path d="M20.8 5.8c-2.2-2.2-5.4-1.6-7.2.4L12 8l-1.6-1.8c-1.8-2-5-2.6-7.2-.4-2.1 2.2-1.6 5.4.4 7.5L12 21l8.4-7.7c2-2.1 2.5-5.3.4-7.5z"/>',
    volume: '<path d="M4 10h4l5-5v14l-5-5H4zM16.5 8.5a5.5 5.5 0 0 1 0 7m3-10a9.5 9.5 0 0 1 0 13"/>',
    muted: '<path d="M4 10h4l5-5v14l-5-5H4zM17 9l5 6m0-6-5 6"/>'
  };
  const icon = (name) => '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + paths[name] + '</svg>';
  const button = (name, label, iconName) => '<button type="button" data-radio="' + name + '" aria-label="' + label + '" title="' + label + '">' + icon(iconName) + '</button>';

  function mount(container) {
    mounts.get(container)?.();
    container.innerHTML = '<div class="cabin-player"><div class="radio-song"><div class="radio-cover" aria-hidden="true"></div><div class="radio-meta"><span class="radio-air"></span><h2></h2><p></p></div></div>' +
      '<div class="radio-progress"><input type="range" min="0" step="0.1" aria-label="Track position"><div class="radio-time"><span></span><span></span></div></div>' +
      '<div class="radio-controls">' + button('favorite', 'Favorite track', 'heart') + '<div class="radio-transport">' +
      button('previous', 'Previous track', 'previous') + button('toggle', 'Play', 'play') + button('next', 'Next track', 'next') + '</div><div class="radio-volume">' +
      button('volume', 'Volume controls', 'volume') + '<div class="radio-volume-pop" hidden>' + button('mute', 'Mute', 'volume') +
      '<input type="range" min="0" max="1" step="0.01" aria-label="Volume"></div></div></div></div>';
    const root = container.firstElementChild;
    const el = (sel) => root.querySelector(sel);
    const control = (id) => el('[data-radio="' + id + '"]');
    const slider = el('.radio-progress input'), vol = el('.radio-volume-pop input');
    const popover = el('.radio-volume-pop'), toggleButton = control('toggle');
    const volumeButton = control('volume'), favoriteButton = control('favorite');
    let lastSong, lastPlay, lastMute;
    function update() {
      const song = track(), current = position(), length = duration();
      if (lastSong !== song) {
        el('.radio-meta h2').textContent = song.title;
        el('.radio-meta p').textContent = song.artist;
        el('.radio-cover').dataset.track = String(trackIndex);
        el('.radio-time span:last-child').textContent = formatTime(length);
        slider.max = String(length);
        lastSong = song;
      }
      if (lastPlay !== playing) {
        const label = playing ? 'Pause' : 'Play';
        toggleButton.innerHTML = icon(playing ? 'pause' : 'play');
        toggleButton.title = label;
        toggleButton.setAttribute('aria-label', label);
        root.classList.toggle('is-playing', playing);
        lastPlay = playing;
      }
      if (lastMute !== (muted || volume === 0)) {
        lastMute = muted || volume === 0;
        volumeButton.innerHTML = icon(lastMute ? 'muted' : 'volume');
        control('mute').innerHTML = icon(lastMute ? 'muted' : 'volume');
        control('mute').setAttribute('aria-label', lastMute ? 'Unmute' : 'Mute');
        control('mute').title = lastMute ? 'Unmute' : 'Mute';
      }
      el('.radio-air').textContent = message || (playing ? 'ON AIR' : 'OFF AIR');
      favoriteButton.setAttribute('aria-pressed', String(favorites.includes(song.title)));
      slider.value = String(current);
      slider.setAttribute('aria-valuetext', formatTime(current) + ' of ' + formatTime(length));
      slider.style.setProperty('--progress', current / length * 100 + '%');
      el('.radio-time span').textContent = formatTime(current);
      vol.value = String(muted ? 0 : volume);
    }
    function closeVolume() {
      popover.hidden = true;
      volumeButton.setAttribute('aria-expanded', 'false');
    }
    closeVolume();
    root.addEventListener('click', event => {
      const id = event.target.closest('button')?.dataset.radio;
      if (id === 'toggle') toggle();
      if (id === 'previous' || id === 'next') changeTrack(id === 'next' ? 1 : -1);
      if (id === 'favorite') {
        const name = track().title;
        favorites = favorites.includes(name) ? favorites.filter(title => title !== name) : [...favorites, name];
        try { localStorage.setItem('snowfall.radio.favorites', JSON.stringify(favorites)); } catch {}
        render();
      }
      if (id === 'volume') {
        popover.hidden = !popover.hidden;
        volumeButton.setAttribute('aria-expanded', String(!popover.hidden));
      }
      if (id === 'mute') {
        if (volume === 0) { volume = 0.55; muted = false; }
        else muted = !muted;
        setLevel(); render();
      }
    });
    root.addEventListener('keydown', event => {
      if (event.key === 'Escape' && !popover.hidden) {
        event.stopPropagation();
        closeVolume();
        volumeButton.focus();
      }
    });
    const outside = event => { if (!el('.radio-volume').contains(event.target)) closeVolume(); };
    document.addEventListener('pointerdown', outside);
    slider.addEventListener('input', () => seek(Number(slider.value)));
    vol.addEventListener('input', () => { muted = false; volume = Number(vol.value); setLevel(); render(); });
    subscribers.add(update);
    update();
    const cleanup = () => {
      subscribers.delete(update);
      document.removeEventListener('pointerdown', outside);
      root.remove();
      if (mounts.get(container) === cleanup) mounts.delete(container);
    };
    mounts.set(container, cleanup);
    return cleanup;
  }

  window.CabinRadio = { mount, toggle };
})();
