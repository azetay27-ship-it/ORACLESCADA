const state = { snapshot: null, selectedTrend: 'FT-101.flow' };
const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

function tag(key) { return state.snapshot?.tags?.[key]; }
function fixed(key, digits = 1) { return Number(tag(key)?.value ?? 0).toFixed(digits); }
function timeOnly(iso) { return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }); }
function dateTime(iso) { return new Date(iso).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' }); }

function showToast(message) {
  const toast = $('#toast');
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => toast.classList.remove('show'), 2600);
}

function render() {
  if (!state.snapshot) return;
  const { system, alarms } = state.snapshot;
  $('#process-state').textContent = system.state;
  $('#state-dot').classList.toggle('stopped', system.state !== 'RUNNING');
  $('#plc-status').textContent = `${system.connected ? 'Healthy' : 'Offline'} · ${system.scanMs / 1000} s scan`;
  $('#last-update').textContent = `Updated ${timeOnly(system.updatedAt)}`;
  $('#metric-flow').textContent = fixed('FT-101.flow');
  $('#metric-pressure').textContent = fixed('PT-101.pressure', 2);
  $('#metric-ph').textContent = fixed('AIT-101.ph', 2);
  $('#metric-alarms').textContent = alarms.length;
  $('#alarm-count').textContent = alarms.length;
  $('#alarm-foot').textContent = alarms.length ? `● ${alarms.filter((a) => !a.acknowledged).length} unacknowledged` : '● All clear';
  $('#alarm-foot').className = alarms.length ? 'critical' : 'stable';

  const currentMode = system.mode;
  $$('.mode-button').forEach((button) => button.classList.toggle('selected', button.dataset.mode === currentMode));
  $('#tank1-fill').style.height = `${tag('TK-101.level').value}%`;
  $('#tank2-fill').style.height = `${tag('TK-102.level').value}%`;
  $('#tank1-level').textContent = `${fixed('TK-101.level')}%`;
  $('#tank2-level').textContent = `${fixed('TK-102.level')}%`;
  $('#tank1-foot').textContent = fixed('TK-101.level');
  $('#tank2-foot').textContent = fixed('TK-102.level');
  $('#mimic-flow').textContent = `${fixed('FT-101.flow')} m³/h`;
  $('#mimic-pressure').textContent = `${fixed('PT-101.pressure', 2)} bar`;
  const pumpRunning = Boolean(tag('P-101.run').value);
  const valveOpen = Boolean(tag('XV-101.open').value);
  $('#pump-glyph').className = `pump-glyph ${pumpRunning ? 'running' : 'stopped'}`;
  $('#pump-status').textContent = pumpRunning ? 'RUNNING' : 'STOPPED';
  $('#valve-glyph').className = `valve-glyph ${valveOpen ? 'open' : 'closed'}`;
  $('#valve-command').textContent = valveOpen ? 'CLOSE' : 'OPEN';
  $('#valve-command').dataset.command = valveOpen ? 'close-inlet' : 'open-inlet';
  renderAlarmPreview();
  renderAlarmTable();
  renderEvents();
  drawChart($('#trend-chart'), state.selectedTrend);
  drawChart($('#large-trend-chart'), state.selectedTrend);
}

function renderAlarmPreview() {
  const target = $('#alarm-preview-body');
  const list = state.snapshot.alarms.slice(0, 4);
  if (!list.length) { target.innerHTML = '<div class="empty-state">No active alarms. Process conditions are within normal limits.</div>'; return; }
  target.innerHTML = `<table class="data-table"><thead><tr><th>Priority</th><th>Source</th><th>Condition</th><th>Status</th></tr></thead><tbody>${list.map((alarm) => `<tr><td><span class="severity ${alarm.severity}">${alarm.severity}</span></td><td>${alarm.source}</td><td>${alarm.message}</td><td class="${alarm.acknowledged ? 'ack-state' : 'unack-state'}">${alarm.acknowledged ? 'Acknowledged' : 'Unacknowledged'}</td></tr>`).join('')}</tbody></table>`;
}

function renderAlarmTable() {
  const target = $('#alarm-table');
  const list = state.snapshot.alarms;
  if (!list.length) { target.innerHTML = '<div class="empty-state">No active alarms. New alarms will appear here in real time.</div>'; return; }
  target.innerHTML = `<table class="data-table"><thead><tr><th>Priority</th><th>Source</th><th>Condition</th><th>Since</th><th>Status</th></tr></thead><tbody>${list.map((alarm) => `<tr><td><span class="severity ${alarm.severity}">${alarm.severity}</span></td><td>${alarm.source}</td><td>${alarm.message}</td><td>${dateTime(alarm.since)}</td><td class="${alarm.acknowledged ? 'ack-state' : 'unack-state'}">${alarm.acknowledged ? 'Acknowledged' : 'Unacknowledged'}</td></tr>`).join('')}</tbody></table>`;
}

function renderEvents() {
  const events = state.snapshot.events || [];
  const html = events.slice(0, 6).map((item) => `<div class="event-item"><i class="event-pip"></i><span class="event-time">${timeOnly(item.time)}</span><span class="event-text"><span class="event-source">${item.source}</span>${item.message}</span></div>`).join('');
  $('#event-preview-body').innerHTML = html || '<div class="empty-state">No events in this session.</div>';
  $('#audit-table').innerHTML = events.length ? `<table class="data-table"><thead><tr><th>Time</th><th>Source</th><th>Severity</th><th>Event</th></tr></thead><tbody>${events.map((item) => `<tr><td>${dateTime(item.time)}</td><td>${item.source}</td><td><span class="severity ${item.severity}">${item.severity}</span></td><td>${item.message}</td></tr>`).join('')}</tbody></table>` : '<div class="empty-state">No events in this session.</div>';
}

function drawChart(canvas, key) {
  if (!canvas || !state.snapshot) return;
  const ctx = canvas.getContext('2d');
  const rect = canvas.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  const width = Math.max(250, rect.width || canvas.width);
  const height = Math.max(160, rect.height || canvas.height);
  canvas.width = width * dpr; canvas.height = height * dpr; ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, width, height);
  const history = (tag(key)?.history || []).slice(-90);
  const min = tag(key)?.min ?? 0; const max = tag(key)?.max ?? 100;
  const pad = { left: 36, right: 13, top: 14, bottom: 26 };
  const cw = width - pad.left - pad.right; const ch = height - pad.top - pad.bottom;
  ctx.font = '10px system-ui'; ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = pad.top + ch * i / 4;
    ctx.strokeStyle = '#1b3041'; ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(width - pad.right, y); ctx.stroke();
    ctx.fillStyle = '#63798b'; ctx.fillText((max - (max - min) * i / 4).toFixed(max > 20 ? 0 : 1), 4, y + 3);
  }
  if (history.length < 2) return;
  ctx.beginPath();
  history.forEach((point, index) => {
    const x = pad.left + cw * index / (history.length - 1);
    const y = pad.top + ch * (1 - (point.value - min) / (max - min));
    index ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
  });
  ctx.lineWidth = 2; ctx.strokeStyle = '#54a7ff'; ctx.shadowColor = 'rgba(84,167,255,.55)'; ctx.shadowBlur = 8; ctx.stroke(); ctx.shadowBlur = 0;
  const last = history[history.length - 1]; const x = width - pad.right; const y = pad.top + ch * (1 - (last.value - min) / (max - min));
  ctx.fillStyle = '#9dd3ff'; ctx.beginPath(); ctx.arc(x, y, 3, 0, Math.PI * 2); ctx.fill();
  if (canvas === $('#trend-chart')) { $('#trend-title').textContent = tag(key).label; $('#chart-unit').textContent = tag(key).unit || 'status'; }
}

async function command(action, extra = {}) {
  try {
    const response = await fetch('/api/command', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, ...extra }) });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Command rejected');
    showToast(`${action.replaceAll('-', ' ')} command accepted`);
  } catch (error) { showToast(error.message); }
}

function connect() {
  const source = new EventSource('/api/stream');
  source.addEventListener('state', (message) => { state.snapshot = JSON.parse(message.data); render(); });
  source.onerror = () => { $('#plc-status').textContent = 'Reconnecting…'; };
}

function showView(viewId) {
  $$('.view').forEach((view) => view.classList.toggle('active-view', view.id === viewId));
  $$('.nav-item').forEach((item) => item.classList.toggle('active', item.dataset.view === viewId));
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

$$('.nav-item, .text-button').forEach((button) => button.addEventListener('click', () => showView(button.dataset.view)));
$$('[data-command]').forEach((button) => button.addEventListener('click', () => command(button.dataset.command)));
$$('.mode-button').forEach((button) => button.addEventListener('click', () => command('set-mode', { mode: button.dataset.mode })));
$('#ack-all').addEventListener('click', () => command('ack-all'));
$('#trend-select').addEventListener('change', (event) => { state.selectedTrend = event.target.value; render(); });
$('#download-audit').addEventListener('click', () => {
  const blob = new Blob([JSON.stringify(state.snapshot.events, null, 2)], { type: 'application/json' });
  const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = 'aquapure-audit-log.json'; link.click(); URL.revokeObjectURL(link.href);
});
window.addEventListener('resize', () => { drawChart($('#trend-chart'), state.selectedTrend); drawChart($('#large-trend-chart'), state.selectedTrend); });
connect();
