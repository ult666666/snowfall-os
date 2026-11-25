/* Small offline apps. Each view receives a host element and returns a cleanup function. */
(() => {
  'use strict';

  const prefix = 'snowfall-os.';
  const memory = new Map();
  const noop = () => {};

  function load(key, fallback) {
    if (memory.has(key)) return memory.get(key);
    try {
      const raw = window.localStorage.getItem(prefix + key);
      if (raw !== null) return JSON.parse(raw);
    } catch { /* Some browsers restrict storage for local files. */ }
    return fallback;
  }

  function save(key, value) {
    try {
      window.localStorage.setItem(prefix + key, JSON.stringify(value));
      memory.delete(key);
      return true;
    } catch {
      memory.set(key, value);
      return false;
    }
  }

  function button(text, className = '') {
    const element = document.createElement('button');
    element.type = 'button';
    element.textContent = text;
    element.className = className;
    return element;
  }

  function settings() {
    const saved = load('settings', {}) || {};
    const prefersReduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    return {
      snow: ['light', 'heavy', 'off'].includes(saved.snow) ? saved.snow : 'light',
      motion: typeof saved.motion === 'boolean' ? saved.motion : !prefersReduced,
    };
  }

  function broadcastSettings() {
    window.dispatchEvent(new CustomEvent('snow-settings', { detail: settings() }));
  }

  window.addEventListener('storage', event => {
    if (event.key === prefix + 'settings' || event.key === null) broadcastSettings();
  });

  function renderNotes(root) {
    root.innerHTML = `<label class="sa-editor"><span>My cabin notes</span>
      <textarea placeholder="Catch a thought before it drifts away…" spellcheck="true" rows="7"></textarea></label>
      <div class="sa-meta"><span class="sa-save" role="status"></span><span class="sa-count"></span></div>`;
    const editor = root.querySelector('textarea');
    const status = root.querySelector('.sa-save');
    const count = root.querySelector('.sa-count');
    const saved = load('notes', '');
    editor.value = typeof saved === 'string' ? saved : '';
    function update() {
      const words = editor.value.trim().split(/\s+/u).filter(Boolean).length;
      count.textContent = `${words} ${words === 1 ? 'word' : 'words'}`;
    }
    status.textContent = 'Private to this browser';
    update();
    editor.addEventListener('input', () => {
      const storageWorks = save('notes', editor.value);
      status.textContent = storageWorks ? 'Saved in this browser' : 'Kept until you close this page';
      update();
    });
    function sync(event) {
      if (event.key !== prefix + 'notes' && event.key !== null) return;
      const next = load('notes', '');
      if (typeof next === 'string' && editor.value !== next) {
        editor.value = next;
        status.textContent = 'Updated from another tab';
        update();
      }
    }
    window.addEventListener('storage', sync);
    return () => window.removeEventListener('storage', sync);
  }

  const durations = { focus: 25 * 60, break: 5 * 60 };

  function freshTimer(mode = 'focus') {
    return { mode, remaining: durations[mode], endsAt: null };
  }

  function readTimer() {
    const timer = load('timer', null);
    if (!timer || !Object.prototype.hasOwnProperty.call(durations, timer.mode) || !Number.isFinite(timer.remaining)
      || timer.remaining < 0 || timer.remaining > durations[timer.mode]
      || (timer.endsAt !== null && !Number.isFinite(timer.endsAt))) return freshTimer();
    return { ...timer };
  }

  function secondsLeft(timer) {
    if (timer.endsAt === null) return timer.remaining;
    return Math.max(0, Math.ceil((timer.endsAt - Date.now()) / 1000));
  }

  function renderFocus(root) {
    root.innerHTML = `<div class="sa-segment" role="group" aria-label="Timer length">
        <button type="button" data-mode="focus">Focus · 25 min</button><button type="button" data-mode="break">Break · 5 min</button>
      </div><div class="sa-face"><div role="timer" aria-label="Time remaining" class="sa-time"></div><p class="sa-timer-caption" role="status"></p></div>
      <div class="sa-actions"><button type="button" class="sa-primary sa-start"></button><button type="button" class="sa-reset">Reset</button></div>`;
    let timer = readTimer();
    const tabs = root.querySelectorAll('[data-mode]');
    const time = root.querySelector('.sa-time');
    const caption = root.querySelector('.sa-timer-caption');
    const start = root.querySelector('.sa-start');
    const reset = root.querySelector('.sa-reset');

    function draw() {
      const remaining = secondsLeft(timer);
      if (remaining === 0 && timer.endsAt !== null) {
        timer = { ...timer, remaining: 0, endsAt: null };
        save('timer', timer);
      }
      const running = timer.endsAt !== null;
      const modeName = timer.mode === 'break' ? 'break' : 'focus session';
      time.textContent = `${String(Math.floor(remaining / 60)).padStart(2, '0')}:${String(remaining % 60).padStart(2, '0')}`;
      const message = remaining === 0 ? `Your ${modeName} is complete.` : running ? 'The timer keeps going when you close this window.' : remaining < durations[timer.mode] ? 'Paused. Pick up when you’re ready.' : 'Ready when you are.';
      if (caption.textContent !== message) caption.textContent = message;
      const label = running ? 'Pause' : remaining === 0 ? 'Start again' : remaining < durations[timer.mode] ? 'Resume' : `Start ${timer.mode}`;
      if (start.textContent !== label) start.textContent = label;
      reset.disabled = !running && remaining === durations[timer.mode];
      tabs.forEach(tab => tab.setAttribute('aria-pressed', String(tab.dataset.mode === timer.mode)));
    }
    function persist() {
      save('timer', timer);
      draw();
    }
    tabs.forEach(tab => tab.addEventListener('click', () => {
      if (timer.mode === tab.dataset.mode) return;
      timer = freshTimer(tab.dataset.mode);
      persist();
    }));
    start.addEventListener('click', () => {
      const remaining = secondsLeft(timer);
      timer = timer.endsAt !== null && remaining > 0
        ? { ...timer, remaining, endsAt: null }
        : { ...timer, endsAt: Date.now() + (remaining || durations[timer.mode]) * 1000 };
      persist();
    });
    reset.addEventListener('click', () => { timer = freshTimer(timer.mode); persist(); });
    function sync(event) {
      if (event.key === prefix + 'timer' || event.key === null) { timer = readTimer(); draw(); }
    }
    draw();
    const ticker = window.setInterval(draw, 400);
    window.addEventListener('storage', sync);
    return () => { window.clearInterval(ticker); window.removeEventListener('storage', sync); };
  }

  const lessons = [
    { title: 'Choose the right job', body: 'A cabin visitor writes “finish my portfolio” in their notes. You want to help them start.', question: 'Which job would benefit from a language model?', choices: ['Count down exactly 25 minutes', 'Suggest a small first step'], correct: 1, reason: 'Turning an open-ended goal into a suggestion uses language understanding. A clock already handles exact timing reliably.', hint: 'A countdown has one exact answer. Look for the job where several helpful answers could fit.' },
    { title: 'Give the model context', body: 'Imagine adding a “Suggest a step” button beside a note. The visitor chooses to use it.', question: 'What should the app send?', choices: ['The selected goal and time available', 'Every note the visitor has written'], correct: 0, reason: 'The selected goal gives the task, and the time limit helps size the step. Both details directly shape the answer.', hint: 'The other notes might contain private thoughts. Which details actually change this suggestion?' },
    { title: 'Test the result', body: 'For “finish my portfolio,” the suggested first step is “write one sentence describing your latest project.”', question: 'How would you evaluate this feature?', choices: ['Count how many words it produces', 'Check whether people can start the step'], correct: 1, reason: 'Try several goals and time limits. Ask people to begin each suggestion, then note where it was too vague or too big.', hint: 'A long answer can still leave someone stuck. Measure the action the feature is supposed to help with.' },
  ];

  function renderGuide(root) {
    let step = 0;
    let choice = null;
    const heading = document.createElement('h3');
    heading.tabIndex = -1;
    function draw(moveFocus = false) {
      root.replaceChildren();
      const lesson = lessons[step];
      const meta = document.createElement('div');
      meta.className = 'sa-lesson-step';
      meta.textContent = `Lesson ${step + 1} of ${lessons.length}`;
      heading.textContent = lesson.title;
      const body = document.createElement('p');
      body.textContent = lesson.body;
      const question = document.createElement('p');
      question.className = 'sa-question';
      question.textContent = lesson.question;
      const choices = document.createElement('div');
      choices.className = 'sa-choices';
      const feedback = document.createElement('p');
      feedback.className = 'sa-feedback';
      feedback.setAttribute('role', 'status');
      const actions = document.createElement('div');
      actions.className = 'sa-actions';
      const back = button('Back');
      back.disabled = step === 0;
      back.addEventListener('click', () => { step -= 1; choice = null; draw(true); });
      const next = button(step === lessons.length - 1 ? 'Recap' : 'Next lesson', 'sa-primary');
      next.disabled = choice !== lesson.correct;
      next.addEventListener('click', () => {
        if (step === lessons.length - 1) return recap();
        step += 1; choice = null; draw(true);
      });
      lesson.choices.forEach((answer, index) => {
        const option = button(answer, 'sa-choice');
        option.setAttribute('aria-pressed', 'false');
        option.addEventListener('click', () => {
          choice = index;
          Array.from(choices.children).forEach((el, i) => el.setAttribute('aria-pressed', String(i === choice)));
          const correct = index === lesson.correct;
          feedback.textContent = correct ? `Yes. ${lesson.reason}` : `Try again. ${lesson.hint}`;
          feedback.classList.toggle('sa-correct', correct);
          next.disabled = !correct;
        });
        choices.append(option);
      });
      actions.append(back, next);
      root.append(meta, heading, body, question, choices, feedback, actions);
      if (moveFocus) heading.focus();
    }
    function recap() {
      root.innerHTML = `<div class="sa-lesson-step">Cabin field guide</div><h3 tabindex="-1">Your first product test</h3><p>Write down one goal and the time you have. Sketch the step you’d want a cabin helper to suggest. Give that step to a friend and see if they can begin.</p><p>The helper in these lessons is a design exercise. Flurry aims at your last position with a simple rule. A language model would earn its place by helping with a less predictable task.</p>`;
      const again = button('Read again', 'sa-primary');
      again.addEventListener('click', () => { step = 0; choice = null; draw(true); });
      root.append(again);
      root.querySelector('h3').focus();
    }
    draw();
    return noop;
  }

  function renderSettings(root) {
    root.innerHTML = `<fieldset class="sa-field"><legend>Snowfall</legend><div class="sa-segment" role="group" aria-label="Snow intensity">
      <button type="button" data-snow="off">Off</button><button type="button" data-snow="light">Light</button><button type="button" data-snow="heavy">Heavy</button>
      </div></fieldset><label class="sa-switch-row"><span><strong>Reduce motion</strong><small>Keep the desktop animations still.</small></span><input type="checkbox" role="switch"></label>
      <p class="sa-meta sa-preference-note" role="status">Preferences apply to this browser.</p>`;
    const buttons = root.querySelectorAll('[data-snow]');
    const reduce = root.querySelector('input');
    const status = root.querySelector('[role="status"]');
    function draw() {
      const current = settings();
      buttons.forEach(el => el.setAttribute('aria-pressed', String(el.dataset.snow === current.snow)));
      reduce.checked = !current.motion;
    }
    function change(partial) {
      const stored = save('settings', { ...settings(), ...partial });
      status.textContent = stored ? 'Saved in this browser.' : 'Applied for this visit.';
      broadcastSettings();
    }
    buttons.forEach(el => el.addEventListener('click', () => change({ snow: el.dataset.snow })));
    reduce.addEventListener('change', () => change({ motion: !reduce.checked }));
    draw();
    window.addEventListener('snow-settings', draw);
    return () => window.removeEventListener('snow-settings', draw);
  }

  const views = { notes: renderNotes, focus: renderFocus, guide: renderGuide, settings: renderSettings };
  const mounts = new WeakMap();
  function open(kind, container) {
    if (!Object.prototype.hasOwnProperty.call(views, kind)) throw new RangeError(`Unknown cabin app: ${kind}`);
    mounts.get(container)?.();
    const root = document.createElement('section');
    root.className = `snow-app sa-${kind}`;
    container.replaceChildren(root);
    const unmount = views[kind](root);
    const cleanup = () => {
      if (mounts.get(container) !== cleanup) return;
      unmount();
      mounts.delete(container);
    };
    mounts.set(container, cleanup);
    return cleanup;
  }

  window.SnowApps = Object.freeze({ open, settings });
})();
