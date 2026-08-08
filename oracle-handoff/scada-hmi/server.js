const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { randomUUID } = require('node:crypto');

const PORT = Number(process.env.PORT || 8080);
const PUBLIC_DIR = path.join(__dirname, 'public');
const clients = new Set();

const tags = {
  'TK-101.level': { value: 62.4, unit: '%', min: 0, max: 100, quality: 'GOOD', label: 'Tank 101 level' },
  'TK-102.level': { value: 41.8, unit: '%', min: 0, max: 100, quality: 'GOOD', label: 'Tank 102 level' },
  'FT-101.flow': { value: 128.0, unit: 'm³/h', min: 0, max: 200, quality: 'GOOD', label: 'Transfer flow' },
  'PT-101.pressure': { value: 4.2, unit: 'bar', min: 0, max: 8, quality: 'GOOD', label: 'Discharge pressure' },
  'AIT-101.ph': { value: 7.1, unit: 'pH', min: 0, max: 14, quality: 'GOOD', label: 'Process pH' },
  'TT-101.temperature': { value: 26.4, unit: '°C', min: 0, max: 80, quality: 'GOOD', label: 'Process temperature' },
  'P-101.run': { value: true, unit: '', min: 0, max: 1, quality: 'GOOD', label: 'Transfer pump status' },
  'XV-101.open': { value: true, unit: '', min: 0, max: 1, quality: 'GOOD', label: 'Inlet valve status' }
};

const system = {
  name: 'AquaPure Treatment Skid',
  site: 'North Utility Plant',
  mode: 'AUTO',
  state: 'RUNNING',
  connected: true,
  plc: 'PLC-01 / SIMULATED',
  scanMs: 1000,
  updatedAt: new Date().toISOString()
};

let alarms = [];
let events = [
  event('SYSTEM', 'HMI session started', 'INFO'),
  event('PLC-01', 'Communication healthy', 'INFO'),
  event('P-101', 'Transfer pump running', 'INFO')
];

function event(source, message, severity = 'INFO') {
  return { id: randomUUID(), time: new Date().toISOString(), source, message, severity };
}

function addEvent(source, message, severity = 'INFO') {
  events.unshift(event(source, message, severity));
  events = events.slice(0, 100);
}

function setTag(key, value) {
  if (!tags[key]) return;
  tags[key].value = value;
  tags[key].quality = system.connected ? 'GOOD' : 'BAD';
  if (!tags[key].history) tags[key].history = [];
  tags[key].history.push({ time: Date.now(), value: Number(value) || 0 });
  tags[key].history = tags[key].history.slice(-90);
}

function alarm(id, source, message, severity, condition) {
  const existing = alarms.find((item) => item.id === id);
  if (condition && !existing) {
    alarms.unshift({ id, source, message, severity, active: true, acknowledged: false, since: new Date().toISOString() });
    addEvent(source, message, severity);
  } else if (!condition && existing) {
    alarms = alarms.filter((item) => item.id !== id);
    addEvent(source, `${message} cleared`, 'INFO');
  }
}

function evaluateAlarms() {
  const tank1 = tags['TK-101.level'].value;
  const ph = tags['AIT-101.ph'].value;
  const pressure = tags['PT-101.pressure'].value;
  alarm('TK101-LOW', 'TK-101', 'Low tank level', tank1 < 30 ? 'WARNING' : 'INFO', tank1 < 30);
  alarm('TK101-HIGH', 'TK-101', 'High tank level', 'HIGH', tank1 > 85);
  alarm('AIT101-PH', 'AIT-101', 'pH outside operating band', 'WARNING', ph < 6.5 || ph > 8.5);
  alarm('PT101-HIGH', 'PT-101', 'Discharge pressure high', 'HIGH', pressure > 5.5);
}

function simulatorTick() {
  const pumpRunning = Boolean(tags['P-101.run'].value);
  const inletOpen = Boolean(tags['XV-101.open'].value);
  const t = Date.now() / 1000;
  const noise = (amount) => (Math.random() - 0.5) * amount;
  const flow = pumpRunning ? Math.max(0, 126 + Math.sin(t / 12) * 9 + noise(4)) : 0;
  const pressure = pumpRunning ? Math.max(0, 4.15 + flow / 140 * 0.35 + noise(0.12)) : 0;
  const tank1 = Math.max(0, Math.min(100, tags['TK-101.level'].value + (inletOpen ? 0.24 : -0.16) - (pumpRunning ? 0.34 : 0) + noise(0.12)));
  const tank2 = Math.max(0, Math.min(100, tags['TK-102.level'].value + (pumpRunning ? 0.18 : -0.05) + noise(0.08)));
  const ph = Math.max(0, Math.min(14, tags['AIT-101.ph'].value + Math.sin(t / 35) * 0.008 + noise(0.018)));
  const temp = Math.max(0, Math.min(80, tags['TT-101.temperature'].value + Math.sin(t / 40) * 0.02 + noise(0.03)));

  setTag('FT-101.flow', flow);
  setTag('PT-101.pressure', pressure);
  setTag('TK-101.level', tank1);
  setTag('TK-102.level', tank2);
  setTag('AIT-101.ph', ph);
  setTag('TT-101.temperature', temp);
  system.state = pumpRunning ? 'RUNNING' : 'STOPPED';
  system.updatedAt = new Date().toISOString();
  evaluateAlarms();
  broadcast();
}

function snapshot() {
  const serialTags = {};
  for (const [key, tag] of Object.entries(tags)) {
    serialTags[key] = { ...tag, history: tag.history || [] };
  }
  return { system, tags: serialTags, alarms, events };
}

function broadcast() {
  const payload = `event: state\ndata: ${JSON.stringify(snapshot())}\n\n`;
  for (const response of clients) response.write(payload);
}

function json(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(body));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = '';
    request.on('data', (chunk) => {
      body += chunk;
      if (body.length > 1_000_000) request.destroy(new Error('Request body too large'));
    });
    request.on('end', () => resolve(body));
    request.on('error', reject);
  });
}

function handleCommand(command) {
  const action = command && command.action;
  if (action === 'start') {
    setTag('P-101.run', true);
    addEvent('P-101', 'Start command accepted from HMI', 'INFO');
  } else if (action === 'stop') {
    setTag('P-101.run', false);
    addEvent('P-101', 'Stop command accepted from HMI', 'WARNING');
  } else if (action === 'open-inlet') {
    setTag('XV-101.open', true);
    addEvent('XV-101', 'Open command accepted from HMI', 'INFO');
  } else if (action === 'close-inlet') {
    setTag('XV-101.open', false);
    addEvent('XV-101', 'Close command accepted from HMI', 'WARNING');
  } else if (action === 'set-mode' && ['AUTO', 'MANUAL'].includes(command.mode)) {
    system.mode = command.mode;
    addEvent('SYSTEM', `Control mode changed to ${command.mode}`, 'INFO');
  } else if (action === 'ack-all') {
    alarms = alarms.map((item) => ({ ...item, acknowledged: true }));
    addEvent('OPERATOR', 'All active alarms acknowledged', 'INFO');
  } else {
    const error = new Error('Unsupported command');
    error.statusCode = 400;
    throw error;
  }
  system.updatedAt = new Date().toISOString();
  evaluateAlarms();
  broadcast();
  return { accepted: true, action };
}

function serveStatic(request, response, pathname) {
  const relative = pathname === '/' ? 'index.html' : pathname.slice(1);
  const filePath = path.resolve(PUBLIC_DIR, relative);
  if (!filePath.startsWith(PUBLIC_DIR + path.sep)) return json(response, 403, { error: 'Forbidden' });
  fs.stat(filePath, (statError, stats) => {
    if (statError || !stats.isFile()) return json(response, 404, { error: 'Not found' });
    const mime = {
      '.html': 'text/html; charset=utf-8',
      '.css': 'text/css; charset=utf-8',
      '.js': 'text/javascript; charset=utf-8',
      '.json': 'application/json; charset=utf-8',
      '.svg': 'image/svg+xml'
    }[path.extname(filePath)] || 'application/octet-stream';
    response.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'no-store' });
    fs.createReadStream(filePath).pipe(response);
  });
}

const server = http.createServer(async (request, response) => {
  const requestUrl = new URL(request.url, `http://${request.headers.host || 'localhost'}`);
  const pathname = requestUrl.pathname;
  try {
    if (request.method === 'GET' && pathname === '/api/state') return json(response, 200, snapshot());
    if (request.method === 'GET' && pathname === '/health') return json(response, 200, { ok: true, plc: system.plc });
    if (request.method === 'GET' && pathname === '/api/stream') {
      response.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive'
      });
      response.write(`event: state\ndata: ${JSON.stringify(snapshot())}\n\n`);
      clients.add(response);
      request.on('close', () => clients.delete(response));
      return;
    }
    if (request.method === 'POST' && pathname === '/api/command') {
      const body = await readBody(request);
      const command = body ? JSON.parse(body) : {};
      return json(response, 200, handleCommand(command));
    }
    if (request.method === 'GET') return serveStatic(request, response, pathname);
    return json(response, 405, { error: 'Method not allowed' });
  } catch (error) {
    return json(response, error.statusCode || 500, { error: error.message || 'Internal server error' });
  }
});

server.listen(PORT, () => {
  console.log(`SCADA HMI listening at http://localhost:${PORT}`);
});

setInterval(simulatorTick, system.scanMs);
