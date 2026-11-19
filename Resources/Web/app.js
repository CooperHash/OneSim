const statusText = document.getElementById('status');
const access = document.getElementById('access');
const code = document.getElementById('code');
const needsKey = document.body.dataset.access === 'lan';
const workspace = document.getElementById('workspace');
const deviceNav = document.getElementById('devices');
const template = document.getElementById('device');
let key = new URLSearchParams(location.hash.slice(1)).get('key') || sessionStorage.getItem('simlabKey') || '';
if (location.hash) history.replaceState(null, '', location.pathname);
let socket;
let preferVideo = false;
const names = ['Android', 'iPhone 16 Pro', 'iPhone Duo'];
const common = [['home', 'Home'], ['apps', 'Apps'], ['rotate', 'Rotate']];
const commands = [[['back', 'Back'], ...common], common, [...common, ['fold', 'Fold / Unfold']]];
const dpi = Intl.NumberFormat();
const panels = names.map(makePanel);

function button(label, action) {
  const element = document.createElement('button');
  element.type = 'button';
  element.textContent = label;
  element.onclick = action;
  return element;
}

function send(panel, action, data = {}) {
  if (socket?.readyState !== WebSocket.OPEN ||
      ((action === 'move' || data.interactive) && socket.bufferedAmount > 2048)) return;
  socket.send(JSON.stringify({ panel, action, ...data }));
}

function makePanel(name, index) {
  const card = template.content.firstElementChild.cloneNode(true);
  const stage = card.querySelector('.stage');
  const shell = card.querySelector('.shell');
  const screen = card.querySelector('.screen');
  const chrome = card.querySelector('.chrome');
  chrome.addEventListener('load', () => {
    chrome.hidden = false;
    shell.classList.add('artwork');
  });
  chrome.addEventListener('error', () => {
    chrome.hidden = true;
    shell.classList.remove('artwork');
  });
  const context = screen.getContext('2d', { alpha: false });
  const detail = card.querySelector('.detail');
  card.querySelector('h2').textContent = name;
  card.querySelector('.platform').textContent = index === 0 ? 'ANDROID' : 'APPLE';
  screen.setAttribute('aria-label', name + ' live display');
  screen.setAttribute('role', 'img');
  if (index === 0) shell.classList.add('android');
  if (index === 1) chrome.src = '/assets/chrome/phone12.png?v=2';
  const controls = card.querySelector('.controls');
  const zoom = card.querySelector('.zoom input');
  const reset = card.querySelector('.zoom-reset');
  const setZoom = () => {
    stage.parentElement.style.setProperty('--zoom', Number(zoom.value) / 100);
    reset.textContent = zoom.value + '%';
  };
  zoom.oninput = setZoom;
  reset.onclick = () => { zoom.value = 100; setZoom(); };
  commands[index].forEach(([action, label]) => controls.append(button(label, () => send(index, action))));
  const form = card.querySelector('.typing');
  const text = form.querySelector('input');
  form.onsubmit = event => {
    event.preventDefault();
    if (/^[ -~]{1,80}$/.test(text.value)) {
      send(index, 'text', { text: text.value });
      text.value = '';
    } else if (text.value) {
      statusText.textContent = 'Use the simulator keyboard for non-ASCII text.';
    }
  };
  const panel = { index, stage, shell, screen, chrome, context, detail, state: {}, token: 0 };
  if (index === 2) {
    const hingeControl = document.createElement('details');
    const summary = document.createElement('summary');
    summary.textContent = 'Hinge';
    const hinge = document.createElement('div');
    hinge.className = 'hinge';
    hingeControl.append(summary, hinge);
    const slider = document.createElement('input');
    slider.type = 'range';
    slider.min = 0;
    slider.max = 180;
    slider.value = 180;
    slider.setAttribute('aria-label', 'Duo hinge angle');
    const output = document.createElement('output');
    output.className = 'hinge-output';
    let lastSent = 0;
    slider.oninput = () => {
      const angle = Number(slider.value);
      output.textContent = angle + '°';
      panel.model?.setPose({ ...panel.state, angle }, true);
      if (performance.now() - lastSent > 32) {
        lastSent = performance.now();
        send(index, 'hinge', { angle, interactive: true });
      }
    };
    slider.onchange = () => send(index, 'hinge', { angle: Number(slider.value), interactive: true });
    panel.slider = slider;
    panel.output = output;
    for (const [label, angle] of [['Closed', 0], ['135°', 135], ['Open', 180]]) {
      hinge.append(button(label, () => send(index, 'hinge', { angle })));
    }
    hinge.append(slider, output);
    controls.after(hingeControl);
    if (document.body.dataset.duoModel === 'available') import('/duo.js').then(({ DuoModel }) => DuoModel.load(stage, panel)).then(model => {
      panel.model = model;
      if (panel.displayRevision === panel.state.revision && panel.displayRevision) {
        const turns = panel.state.rotation || 0;
        const sideways = turns % 2 === 1;
        model.setFrame(screen, panel.state.activeDisplay, sideways ? screen.height : screen.width,
          sideways ? screen.width : screen.height, turns);
      }
      installInput(model.canvas, panel, event => model.pick(event));
      model.setPose(panel.state, true);
    }).catch(() => {});
  }
  installInput(screen, panel, event => {
    const rect = screen.getBoundingClientRect();
    return { x: clamp((event.clientX - rect.left) / rect.width),
             y: clamp((event.clientY - rect.top) / rect.height) };
  });
  deviceNav.append(button(name, () => workspace.scrollTo({ left: card.offsetLeft - workspace.offsetLeft, behavior: 'smooth' })));
  workspace.append(card);
  return panel;
}

function clamp(value) { return Math.max(0, Math.min(1, value)); }

function installInput(element, panel, point) {
  let drag;
  let wheel;
  let lastMove = 0;
  function transmit(action, delta) { send(panel.index, action, delta); }
  function data(event) {
    const position = point(event);
    if (!position || !panel.displayRevision || panel.displayRevision !== panel.state.revision) return;
    return { ...position, revision: panel.displayRevision, digitizer: element !== panel.screen };
  }
  element.addEventListener('pointerdown', event => {
    if (event.button !== 0 || drag || wheel) return;
    const position = data(event);
    if (!position || socket?.readyState !== WebSocket.OPEN) return;
    element.setPointerCapture(event.pointerId);
    drag = { id: event.pointerId, position };
    transmit('down', position);
  });
  element.addEventListener('pointermove', event => {
    if (drag?.id !== event.pointerId || performance.now() - lastMove < 16) return;
    const position = data(event);
    if (!position || position.revision !== drag.position.revision) return;
    lastMove = performance.now();
    drag.position = position;
    transmit('move', position);
  });
  function end(event, action) {
    if (drag?.id !== event.pointerId) return;
    const position = data(event);
    transmit(action, position?.revision === drag.position.revision ? position : drag.position);
    drag = null;
  }
  element.addEventListener('pointerup', event => end(event, 'up'));
  element.addEventListener('pointercancel', event => end(event, 'cancel'));
  element.addEventListener('lostpointercapture', event => end(event, 'cancel'));
  element.addEventListener('wheel', event => {
    if (drag || socket?.readyState !== WebSocket.OPEN) return;
    const position = data(event);
    if (!position) return;
    event.preventDefault();
    if (!wheel) {
      wheel = position;
      transmit('down', wheel);
    } else if (position.revision !== wheel.revision) return;
    clearTimeout(wheel.timer);
    if (element !== panel.screen) {
      const next = data({ clientX: event.clientX - event.deltaX, clientY: event.clientY - event.deltaY });
      if (next) Object.assign(wheel, next);
    } else {
      wheel.y = clamp(wheel.y - event.deltaY / element.clientHeight);
      wheel.x = clamp(wheel.x - event.deltaX / element.clientWidth);
    }
    const delta = { x: wheel.x, y: wheel.y, revision: wheel.revision, digitizer: wheel.digitizer };
    if (performance.now() - lastMove >= 16) {
      lastMove = performance.now();
      transmit('move', delta);
    }
    wheel.timer = setTimeout(() => { transmit('up', delta); wheel = null; }, 100);
  }, { passive: false });
}

function updateState(panel, next) {
  const previous = panel.state;
  panel.state = next;
  if (previous.unavailableReason !== next.unavailableReason) {
    const message = panel.stage.querySelector('.unavailable');
    message.textContent = next.unavailableReason || '';
    message.hidden = !next.unavailableReason;
    panel.shell.hidden = !!next.unavailableReason;
    const section = panel.stage.parentElement;
    section.querySelectorAll('button, input').forEach(control => { control.disabled = !!next.unavailableReason; });
    if (next.unavailableReason) panel.model?.setPose({ angle: 180 }, true);
  }
  const turns = next.rotation || 0;
  const shellTurns = panel.index === 0 ? next.orientation || 0 : turns;
  const sideways = turns % 2 === 1;
  const width = sideways ? next.height : next.width;
  const height = sideways ? next.width : next.height;
  panel.shell.classList.remove('r0', 'r1', 'r2', 'r3');
  panel.shell.classList.add('r' + shellTurns);
  panel.shell.classList.toggle('sideways', shellTurns % 2 === 1);
  panel.shell.style.setProperty('--turn', shellTurns * 90 + 'deg');
  if (width && height) {
    for (const node of [panel.shell, panel.stage]) {
      node.style.setProperty('--width', width);
      node.style.setProperty('--height', height);
    }
  }
  if (next.density) panel.shell.style.setProperty('--density', next.density);
  if (panel.index === 2) {
    const outer = next.activeDisplay === 'outer';
    if (previous.activeDisplay !== next.activeDisplay && next.activeDisplay) {
      panel.chrome.src = outer ? '/assets/chrome/phone15.png?v=2' : '/assets/chrome/phone14.png?v=2';
      panel.shell.classList.toggle('cover', outer);
    }
    if (Number.isFinite(next.angle)) {
      if (!panel.slider.matches(':active')) panel.slider.value = next.angle;
      panel.output.textContent = next.angle + '°';
      if (previous.angle !== next.angle || previous.orientation !== next.orientation ||
          previous.activeDisplay !== next.activeDisplay) panel.model?.setPose(next);
    }
  }
  panel.detail.textContent = width && height
    ? `${next.activeDisplay ? (next.activeDisplay === 'inner' ? 'Inner display' : 'Outer display') + ' · ' + next.angle + '° · ' : ''}${dpi.format(width)} × ${dpi.format(height)}`
    : next.unavailableReason ? 'Unavailable' : 'Waiting for live display';
}

function paint(panel, image, revision) {
  if ((panel.state.revision || 0) !== revision) return;
  const turns = panel.state.rotation || 0;
  const w = image.displayWidth || image.width;
  const h = image.displayHeight || image.height;
  const width = turns % 2 ? h : w;
  const height = turns % 2 ? w : h;
  if (panel.screen.width !== width) panel.screen.width = width;
  if (panel.screen.height !== height) panel.screen.height = height;
  const context = panel.context;
  context.setTransform(1, 0, 0, 1, width / 2, height / 2);
  context.rotate(turns * Math.PI / 2);
  context.drawImage(image, -w / 2, -h / 2, w, h);
  panel.displayRevision = revision;
  panel.model?.setFrame(image, panel.state.activeDisplay, w, h);
}

async function decodeJPEG(panel) {
  if (panel.decoding) return;
  panel.decoding = true;
  while (panel.pending) {
    const { payload, revision, token } = panel.pending;
    panel.pending = null;
    try {
      const image = await createImageBitmap(new Blob([payload], { type: 'image/jpeg' }));
      try {
        if (token === panel.token) paint(panel, image, revision);
      } finally { image.close(); }
    } catch { /* A damaged frame can be skipped independently. */ }
  }
  panel.decoding = false;
}

function decodeVideo(panel, frame, data) {
  if (data.byteLength < 18) return;
  const revision = frame.getUint32(1);
  const isKey = frame.getUint8(5) === 1;
  const sequence = frame.getUint32(6);
  if ((panel.state.revision || 0) !== revision) return;
  if (!panel.decoder || panel.videoRevision !== revision ||
      (!isKey && sequence !== panel.videoSequence + 1) || panel.decoder.decodeQueueSize > 3) {
    if (panel.decoder?.state !== 'closed') panel.decoder?.close();
    panel.decoder = null;
    if (!isKey) {
      if (!panel.awaitingKey) {
        send(panel.index, 'refreshVideo');
        panel.awaitingKey = true;
      }
      return;
    }
    const codec = 'avc1.' + [15, 16, 17].map(offset => frame.getUint8(offset).toString(16).padStart(2, '0')).join('');
    try {
      const decoder = new VideoDecoder({
        output(image) {
          try { if (panel.decoder === decoder) paint(panel, image, revision); }
          finally { image.close(); }
        },
        error() { retryWithoutVideo(); }
      });
      decoder.configure({ codec, optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware' });
      panel.decoder = decoder;
      panel.videoRevision = revision;
    } catch {
      retryWithoutVideo();
      return;
    }
  }
  if (isKey) panel.awaitingKey = false;
  panel.videoSequence = sequence;
  try {
    panel.decoder.decode(new EncodedVideoChunk({
      type: isKey ? 'key' : 'delta', timestamp: sequence * 16_667, data: data.slice(10)
    }));
  } catch { retryWithoutVideo(); }
}

function retryWithoutVideo() {
  if (!preferVideo) return;
  preferVideo = false;
  socket?.close();
  resetDecoders();
  connect();
}

function resetDecoders() {
  for (const panel of panels) {
    if (panel.decoder?.state !== 'closed') panel.decoder?.close();
    panel.decoder = null;
    panel.token += 1;
    panel.awaitingKey = false;
    panel.displayRevision = 0;
    panel.pending = null;
  }
}

function connect() {
  if (needsKey && !/^[a-fA-F0-9]{32}$/.test(key)) {
    access.hidden = false;
    statusText.textContent = 'Enter the LAN key or open the link copied from SimLab.';
    return;
  }
  access.hidden = true;
  statusText.textContent = 'Connecting…';
  const protocols = needsKey ? ['simlab', 'key.' + key] : ['simlab'];
  if (preferVideo) protocols.push('simlab.avc');
  const ws = new WebSocket('ws://' + location.host + '/stream', protocols);
  socket = ws;
  ws.binaryType = 'arraybuffer';
  let opened = false;
  ws.onopen = () => {
    opened = true;
    if (needsKey) sessionStorage.setItem('simlabKey', key);
    statusText.textContent = 'Connected · control enabled';
  };
  ws.onclose = () => {
    if (socket !== ws) return;
    resetDecoders();
    if (needsKey) access.hidden = false;
    statusText.textContent = opened ? 'Disconnected. Reload to reconnect.'
      : 'Could not connect. Check the service and the current LAN key.';
  };
  ws.onmessage = ({ data }) => {
    if (typeof data === 'string') {
      const state = JSON.parse(data);
      if (panels[state.panel]) updateState(panels[state.panel], state);
      return;
    }
    if (!(data instanceof ArrayBuffer) || data.byteLength < 6) return;
    const frame = new DataView(data);
    const marker = frame.getUint8(0);
    const panel = panels[marker & 0x7f];
    if (!panel) return;
    if (marker & 0x80) {
      decodeVideo(panel, frame, data);
      return;
    }
    panel.pending = { payload: data.slice(5), revision: frame.getUint32(1), token: panel.token };
    decodeJPEG(panel);
  };
}

access.addEventListener('submit', event => {
  event.preventDefault();
  key = code.value.trim();
  code.value = '';
  connect();
});
if (window.isSecureContext && typeof VideoDecoder !== 'undefined') {
  VideoDecoder.isConfigSupported({ codec: 'avc1.42e01f' }).then(result => {
    preferVideo = result.supported;
  }).catch(() => {}).finally(connect);
} else {
  connect();
}
