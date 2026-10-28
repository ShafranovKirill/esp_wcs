import { Terminal } from '/assets/xterm/xterm.mjs';
import { FitAddon } from '/assets/xterm/addon-fit.mjs';

const BAUDS = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600];
const FORMATS = ['8N1', '8N2', '8E1', '8O1', '7N1', '7E1', '7O1'];
const PARITY = { N: 'none', E: 'even', O: 'odd' };
const PARITY_LETTER = { none: 'N', even: 'E', odd: 'O' };
const SEND_CHUNK = 1024;
const PING_MS = 60000;
const RETRY_MIN_MS = 1000;
const RETRY_MAX_MS = 10000;

const $ = (id) => document.getElementById(id);
const dark = window.matchMedia('(prefers-color-scheme: dark)');
const themes = {
  dark: { background: '#0b0f14', foreground: '#d6deeb', cursor: '#82aaff' },
  light: { background: '#fafafa', foreground: '#1f2328', cursor: '#0969da' }
};

const term = new Terminal({
  cursorBlink: true,
  fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace',
  fontSize: 14,
  scrollback: 5000,
  theme: dark.matches ? themes.dark : themes.light
});
const fit = new FitAddon();
term.loadAddon(fit);
term.open($('terminal'));
fit.fit();
new ResizeObserver(() => fit.fit()).observe($('terminal'));
dark.addEventListener('change', () => { term.options.theme = dark.matches ? themes.dark : themes.light; });

const encoder = new TextEncoder();
let ws = null;
let owner = false;
let line = null;
let retryMs = RETRY_MIN_MS;
let pingTimer = null;

function setLink(text, cls) {
  $('link').textContent = text;
  $('link').className = 'badge ' + (cls || '');
}

function showMessage(text, cls) {
  $('message').textContent = text;
  $('message').className = 'message ' + (cls || '');
  $('message').hidden = !text;
  if (text) setTimeout(() => { if ($('message').textContent === text) $('message').hidden = true; }, 4000);
}

function setControls(enabled) {
  $('baud').disabled = !enabled;
  $('format').disabled = !enabled;
  $('break').disabled = !enabled;
}

function fillSelect(select, values, current, label) {
  const list = values.includes(current) ? values : [...values, current].sort((a, b) => (a > b ? 1 : -1));
  select.replaceChildren(...list.map((v) => {
    const opt = document.createElement('option');
    opt.value = String(v);
    opt.textContent = label ? label(v) : String(v);
    opt.selected = v === current;
    return opt;
  }));
}

function formatOf(l) {
  return `${l.data_bits}${PARITY_LETTER[l.parity]}${l.stop_bits}`;
}

function showLine(l) {
  line = l;
  fillSelect($('baud'), BAUDS, l.baud);
  fillSelect($('format'), FORMATS, formatOf(l));
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function setOwner(isOwner, title, text) {
  owner = isOwner;
  setControls(isOwner);
  $('busy').hidden = isOwner;
  if (!isOwner) {
    $('busy-title').textContent = title;
    $('busy-text').textContent = text;
  } else {
    term.focus();
  }
}

function onText(msg) {
  switch (msg.t) {
    case 'state':
      if (!owner) {
        term.reset();
      }
      setOwner(true);
      showLine(msg.line);
      setLink(`${msg.line.baud} ${formatOf(msg.line)}`, 'ok');
      break;
    case 'busy':
      setOwner(false, 'Устройство занято', 'Консолью сейчас управляют в другой вкладке или с другого ноутбука.');
      setLink('Занято', 'warn');
      break;
    case 'taken':
      setOwner(false, 'Консоль забрали', 'Управление перешло в другую вкладку или на другой ноутбук.');
      setLink('Занято', 'warn');
      break;
    case 'break_done':
      showMessage('BREAK отправлен');
      break;
    case 'error':
      if (line) showLine(line);
      showMessage(msg.error === 'invalid_line' ? 'Такие параметры порта не поддерживаются' : 'Не удалось выполнить команду', 'error');
      break;
    case 'logout':
      location.href = '/login';
      break;
  }
}

function connect() {
  setLink('Подключение…');
  let opened = false;
  ws = new WebSocket(`wss://${location.host}/ws/console`);
  ws.binaryType = 'arraybuffer';

  ws.onopen = () => {
    opened = true;
    retryMs = RETRY_MIN_MS;
    send({ t: 'hello' });
    pingTimer = setInterval(() => send({ t: 'ping' }), PING_MS);
  };

  ws.onmessage = (ev) => {
    if (typeof ev.data === 'string') {
      onText(JSON.parse(ev.data));
    } else if (owner) {
      term.write(new Uint8Array(ev.data));
    }
  };

  ws.onclose = () => {
    clearInterval(pingTimer);
    owner = false;
    setControls(false);
    setLink('Нет связи', 'error');
    fetch('/api/status', { credentials: 'same-origin' }).then((r) => {
      if (r.status === 401) {
        location.href = '/login';
        return;
      }
      setTimeout(connect, opened ? RETRY_MIN_MS : retryMs);
      retryMs = Math.min(retryMs * 2, RETRY_MAX_MS);
    }).catch(() => {
      setTimeout(connect, retryMs);
      retryMs = Math.min(retryMs * 2, RETRY_MAX_MS);
    });
  };
}

term.onData((data) => {
  if (!owner || !ws || ws.readyState !== WebSocket.OPEN) return;
  const bytes = encoder.encode(data);
  for (let off = 0; off < bytes.length; off += SEND_CHUNK) {
    ws.send(bytes.subarray(off, off + SEND_CHUNK));
  }
});

term.onBinary((data) => {
  if (!owner || !ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(Uint8Array.from(data, (c) => c.charCodeAt(0)));
});

function sendLine() {
  const f = $('format').value;
  send({
    t: 'line',
    baud: Number($('baud').value),
    data_bits: Number(f[0]),
    parity: PARITY[f[1]],
    stop_bits: Number(f[2])
  });
}

$('baud').addEventListener('change', sendLine);
$('format').addEventListener('change', sendLine);
$('break').addEventListener('click', () => send({ t: 'break' }));
$('take').addEventListener('click', () => send({ t: 'take' }));

connect();
