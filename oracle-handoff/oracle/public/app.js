/* Oracle NILIT SCADA runtime HMI.
 * The browser is a view and command client only. The backend owns process state,
 * permissions, interlocks, alarm lifecycle, and the authoritative state snapshot.
 */

const state = {
  user: null,
  snapshot: null,
  selectedTrend: 'FT-101.flow',
  view: 'overview',
  source: null,
  reconnectTimer: null,
  staleTimer: null,
  reconnectAttempts: 0,
  lastValidAt: 0,
  stale: true,
  connection: 'offline',
  pending: new Map(),
  sessionExpired: false,
  editorLoadStarted: false,
  lastAlarmIds: new Set()
};

const $ = (id) => document.getElementById(id);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

class ApiError extends Error {
  constructor(message, status = 0, code = '', payload = null) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.payload = payload;
  }
}

const api = {
  async request(path, options = {}) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), options.timeoutMs || 10000);
    const headers = new Headers(options.headers || {});
    if (options.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
    let response;
    try {
      response = await fetch(path, { ...options, headers, credentials: 'include', signal: controller.signal });
    } catch (error) {
      clearTimeout(timeout);
      if (error.name === 'AbortError') throw new ApiError('Oracle service request timed out.', 0, 'TIMEOUT');
      throw new ApiError('Oracle service is unreachable.', 0, 'NETWORK_ERROR');
    }
    clearTimeout(timeout);
    const raw = await response.text();
    let payload = {};
    if (raw) {
      try { payload = JSON.parse(raw); } catch { payload = { message: raw }; }
    }
    if (!response.ok) {
      const message = payload.message || payload.error || response.statusText || 'Request rejected.';
      throw new ApiError(message, response.status, payload.code || payload.reasonCode || '', payload);
    }
    return payload;
  },
  login(username, password) {
    return this.request('/api/auth/login', { method: 'POST', body: JSON.stringify({ username, password }) });
  },
  logout() {
    return this.request('/api/auth/logout', { method: 'POST', body: JSON.stringify({}) });
  },
  me() {
    return this.request('/api/me');
  },
  snapshot() {
    return this.request('/api/state');
  },
  command(action, extra = {}) {
    const clientCommandId = (window.crypto && typeof window.crypto.randomUUID === 'function')
      ? window.crypto.randomUUID()
      : `oracle-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    return this.request('/api/commands', {
      method: 'POST',
      body: JSON.stringify({ action, clientCommandId, ...extra })
    });
  }
};

function safeText(value, fallback = '—') {
  return value === null || value === undefined || value === '' ? fallback : String(value);
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function getTag(key) {
  return state.snapshot?.tags?.[key] || null;
}

function qualityIsUsable(tag) {
  return Boolean(tag) && (!tag.quality || ['GOOD', 'UNCERTAIN'].includes(String(tag.quality).toUpperCase()));
}

function tagValue(key, digits = 1) {
  const item = getTag(key);
  const value = finiteNumber(item?.value);
  if (value === null || !qualityIsUsable(item)) return '—';
  return value.toFixed(digits);
}

function tagUnit(key, fallback = '') {
  return safeText(getTag(key)?.unit, fallback);
}

function isoDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '—' : date;
}

function timeOnly(value) {
  const date = isoDate(value);
  return date === '—' ? '—' : date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function dateTime(value) {
  const date = isoDate(value);
  return date === '—' ? '—' : date.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function setText(id, value) {
  const element = $(id);
  if (element) element.textContent = safeText(value);
}

function setClass(id, className) {
  const element = $(id);
  if (element) element.className = className;
}

function clear(element) {
  while (element && element.firstChild) element.removeChild(element.firstChild);
}

function appendCell(row, value, className = '') {
  const cell = document.createElement('td');
  if (value instanceof Node) cell.appendChild(value);
  else cell.textContent = safeText(value);
  if (className) cell.className = className;
  row.appendChild(cell);
  return cell;
}

function makeTable(headers, rows, testId = '') {
  const table = document.createElement('table');
  table.className = 'data-table';
  if (testId) table.dataset.testid = testId;
  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  headers.forEach((header) => {
    const cell = document.createElement('th');
    cell.scope = 'col';
    cell.textContent = header;
    headRow.appendChild(cell);
  });
  thead.appendChild(headRow);
  table.appendChild(thead);
  const tbody = document.createElement('tbody');
  rows.forEach((values) => {
    const row = document.createElement('tr');
    values.forEach((value) => appendCell(row, value));
    tbody.appendChild(row);
  });
  table.appendChild(tbody);
  return table;
}

function emptyState(message) {
  const element = document.createElement('div');
  element.className = 'empty-state';
  element.textContent = message;
  return element;
}

function severityElement(severity) {
  const element = document.createElement('span');
  const normalized = safeText(severity, 'INFO').toUpperCase();
  element.className = `severity ${normalized}`;
  element.textContent = normalized;
  return element;
}

function statusElement(text, className) {
  const element = document.createElement('span');
  element.className = className;
  element.textContent = text;
  return element;
}

function showToast(message, kind = '') {
  const toast = $('toast');
  if (!toast) return;
  toast.textContent = safeText(message, 'Oracle update');
  toast.className = `toast show ${kind}`.trim();
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { toast.className = 'toast'; }, 3200);
}

function announce(message) {
  const announcer = $('aria-announcer');
  if (!announcer) return;
  announcer.textContent = '';
  window.setTimeout(() => { announcer.textContent = message; }, 30);
}

function currentSystem() {
  return state.snapshot?.system || {};
}

function canOperate() {
  return Boolean(state.user && state.snapshot && !state.stale && state.connection === 'connected' && currentSystem().connected !== false);
}

function isSupervisor() {
  return state.user?.role === 'supervisor';
}

function commandPending(action) {
  return state.pending.has(action);
}

function markSnapshot(snapshot) {
  if (!snapshot || typeof snapshot !== 'object' || !snapshot.system || !snapshot.tags) return;
  const previousAlarmIds = new Set((state.snapshot?.alarms || []).filter((alarm) => alarm.active !== false).map((alarm) => alarm.id));
  state.snapshot = snapshot;
  state.lastValidAt = Date.now();
  state.stale = false;
  if (state.connection === 'offline' || state.connection === 'stale') state.connection = 'connected';

  const activeAlarms = (snapshot.alarms || []).filter((alarm) => alarm.active !== false);
  activeAlarms.forEach((alarm) => {
    if (!previousAlarmIds.has(alarm.id) && alarm.severity === 'HIGH') {
      showToast(`HIGH alarm: ${safeText(alarm.message, alarm.id)}`, 'alarm-toast');
      announce(`High alarm active: ${safeText(alarm.message, alarm.id)}`);
    }
  });
  state.lastAlarmIds = new Set(activeAlarms.map((alarm) => alarm.id));

  const snapshotVersion = Number(snapshot.stateVersion || 0);
  for (const [action, pending] of state.pending.entries()) {
    if (snapshotVersion >= pending.awaitStateVersion) state.pending.delete(action);
  }
  render();
}

function renderUser() {
  if (!state.user) return;
  const label = safeText(state.user.displayName || state.user.username, 'Operator');
  const initials = label.split(/\s+/).map((part) => part[0]).join('').slice(0, 2).toUpperCase() || 'OP';
  setText('user-name', label);
  setText('user-role', `${safeText(state.user.role, 'operator')} session`);
  setText('user-avatar', initials);
  setText('top-avatar', initials);
  const permission = $('editor-permission');
  if (permission) {
    permission.textContent = isSupervisor() ? 'Supervisor authoring' : 'Read-only runtime · supervisor required';
    permission.className = `permission-pill ${isSupervisor() ? 'supervisor' : 'operator'}`;
  }
  const editorCopy = $('editor-entry-copy');
  if (editorCopy) editorCopy.textContent = isSupervisor()
    ? 'Open the editor workspace to design, bind, validate, and publish reusable NILIT process screens.'
    : 'Published screens are available for runtime viewing. Screen editing and publishing require a supervisor session.';
}

function renderConnection() {
  const hmi = $('hmi-status');
  const plc = $('plc-status');
  const hmiDot = $('hmi-dot');
  const plcDot = $('plc-dot');
  const top = $('top-hmi-status');
  let hmiText = 'Offline';
  let statusClass = 'warning';
  if (state.connection === 'connected' && !state.stale) { hmiText = 'Connected'; statusClass = 'healthy'; }
  else if (state.connection === 'reconnecting') { hmiText = 'Reconnecting…'; statusClass = 'warning'; }
  else if (state.connection === 'stale') { hmiText = 'Stale data · controls locked'; statusClass = 'danger'; }
  else if (state.connection === 'connecting') { hmiText = 'Connecting…'; statusClass = 'warning'; }
  else if (state.connection === 'session-expired') { hmiText = 'Session expired'; statusClass = 'danger'; }
  if (hmi) hmi.textContent = hmiText;
  if (hmiDot) hmiDot.className = `status-dot ${statusClass}`;
  if (top) { top.textContent = `HMI ${hmiText}`; top.className = `top-status ${statusClass}`; }

  const system = currentSystem();
  const plcHealthy = system.connected !== false && Boolean(state.snapshot);
  const scanSeconds = Math.max(0.1, Number(system.scanMs || 1000) / 1000);
  if (plc) plc.textContent = `${plcHealthy ? 'Healthy' : 'Offline'} · ${scanSeconds.toFixed(scanSeconds < 1 ? 1 : 0)} s scan`;
  if (plcDot) plcDot.className = `status-dot ${plcHealthy ? 'healthy' : 'danger'}`;
  document.body.classList.toggle('data-stale', state.stale || state.connection !== 'connected');
}

function renderControls() {
  const system = currentSystem();
  const operationReady = canOperate();
  const roleRestricted = !isSupervisor();
  const mode = system.mode || 'MANUAL';
  $$('.mode-button').forEach((button) => {
    button.classList.toggle('selected', button.dataset.mode === mode);
    button.disabled = roleRestricted || !operationReady || commandPending('set-mode');
    button.title = roleRestricted ? 'Supervisor permission required' : (!operationReady ? 'Controls are locked until live data is available' : `Set control mode to ${button.dataset.mode}`);
    button.setAttribute('aria-pressed', button.dataset.mode === mode ? 'true' : 'false');
  });
  const modeLock = $('mode-lock');
  if (modeLock) modeLock.hidden = !roleRestricted;

  const reset = $('reset-simulator');
  if (reset) {
    reset.hidden = roleRestricted;
    reset.disabled = !operationReady || commandPending('reset-simulator');
  }
  const start = $('start-button');
  const stop = $('stop-button');
  if (start) { start.disabled = !operationReady || commandPending('start'); start.setAttribute('aria-busy', commandPending('start') ? 'true' : 'false'); }
  if (stop) { stop.disabled = !operationReady || commandPending('stop'); stop.setAttribute('aria-busy', commandPending('stop') ? 'true' : 'false'); }

  const valve = $('valve-command');
  if (valve) {
    const open = Boolean(getTag('XV-101.open')?.value);
    const action = open ? 'close-inlet' : 'open-inlet';
    valve.dataset.command = action;
    valve.textContent = commandPending(action) ? 'PENDING…' : (open ? 'CLOSE' : 'OPEN');
    valve.disabled = !operationReady || commandPending(action);
    valve.title = operationReady ? (open ? 'Close inlet valve' : 'Open inlet valve') : 'Controls are locked until live data is available';
    valve.setAttribute('aria-label', `${open ? 'Close' : 'Open'} XV-101 inlet valve`);
  }
  const ack = $('ack-all');
  const unacknowledged = (state.snapshot?.alarms || []).some((alarm) => alarm.active !== false && !alarm.acknowledged);
  if (ack) { ack.disabled = !operationReady || !unacknowledged || commandPending('ack-all'); ack.setAttribute('aria-busy', commandPending('ack-all') ? 'true' : 'false'); }
}

function renderProcess() {
  const system = currentSystem();
  const processState = safeText(system.state, 'STOPPED').toUpperCase();
  setText('process-state', processState);
  setClass('state-dot', `state-dot ${processState === 'RUNNING' ? '' : processState === 'FAULT' ? 'fault' : 'stopped'}`.trim());
  setText('last-update', state.snapshot?.emittedAt || system.updatedAt ? `Updated ${timeOnly(state.snapshot?.emittedAt || system.updatedAt)}${state.stale ? ' · stale' : ''}` : 'Waiting for state');
  setText('state-version', `State v${safeText(state.snapshot?.stateVersion, '—')}`);
  setText('metric-flow', tagValue('FT-101.flow', 1));
  setText('metric-pressure', tagValue('PT-101.pressure', 2));
  setText('metric-ph', tagValue('AIT-101.ph', 2));
  setText('metric-flow-unit', tagUnit('FT-101.flow', 'm³/h'));
  setText('metric-pressure-unit', tagUnit('PT-101.pressure', 'bar'));
  setText('mimic-flow', `${tagValue('FT-101.flow', 1)} ${tagUnit('FT-101.flow', 'm³/h')}`);
  setText('mimic-pressure', `${tagValue('PT-101.pressure', 2)} ${tagUnit('PT-101.pressure', 'bar')}`);
  setText('tank1-level', `${tagValue('TK-101.level', 1)}%`);
  setText('tank2-level', `${tagValue('TK-102.level', 1)}%`);
  setText('tank1-foot', tagValue('TK-101.level', 1));
  setText('tank2-foot', tagValue('TK-102.level', 1));
  setText('pump-status', Boolean(getTag('P-101.run')?.value) ? 'RUNNING' : 'STOPPED');
  setClass('pump-glyph', `pump-glyph ${Boolean(getTag('P-101.run')?.value) ? 'running' : 'stopped'}`);
  setClass('valve-glyph', `valve-glyph ${Boolean(getTag('XV-101.open')?.value) ? 'open' : 'closed'}`);
  ['TK-101.level', 'TK-102.level'].forEach((key, index) => {
    const value = finiteNumber(getTag(key)?.value);
    const fill = $(`tank${index + 1}-fill`);
    if (fill) fill.style.height = `${Math.max(0, Math.min(100, value ?? 0))}%`;
  });
  const mimicStatus = $('mimic-status');
  if (mimicStatus) mimicStatus.textContent = state.stale ? 'Live state is stale. Commands are locked until Oracle reconnects.' : `${safeText(system.state, 'STOPPED')} · ${safeText(system.mode, 'MANUAL')} mode · ${safeText(system.plc, 'PLC-01 / SIMULATED')}`;

  [['FT-101.flow', 'flow-quality'], ['PT-101.pressure', 'pressure-quality'], ['AIT-101.ph', 'ph-quality']].forEach(([key, id]) => {
    const item = getTag(key);
    const element = $(id);
    if (!element) return;
    const quality = safeText(item?.quality, 'UNKNOWN').toUpperCase();
    element.textContent = quality === 'GOOD' ? 'Good quality' : `${quality} quality`;
    element.className = quality === 'GOOD' ? 'stable' : 'critical';
  });
}

function severityRank(value) {
  return ({ CRITICAL: 0, HIGH: 1, WARNING: 2, INFO: 3 }[String(value).toUpperCase()] ?? 4);
}

function activeAlarms() {
  return (state.snapshot?.alarms || []).filter((alarm) => alarm.active !== false).sort((a, b) => severityRank(a.severity) - severityRank(b.severity) || new Date(a.since || 0) - new Date(b.since || 0));
}

function renderAlarms() {
  const list = activeAlarms();
  const unack = list.filter((alarm) => !alarm.acknowledged).length;
  setText('metric-alarms', list.length);
  setText('alarm-count', list.length);
  const foot = $('alarm-foot');
  if (foot) { foot.textContent = list.length ? `${unack} unacknowledged` : 'All clear'; foot.className = list.length ? 'critical' : 'stable'; }

  const preview = $('alarm-preview-body');
  const table = $('alarm-table');
  if (!list.length) {
    if (preview) { clear(preview); preview.appendChild(emptyState('No active alarms. Process conditions are within normal limits.')); }
    if (table) { clear(table); table.appendChild(emptyState('No active alarms. New alarms will appear here in real time.')); }
    return;
  }
  const rows = list.map((alarm) => [severityElement(alarm.severity), safeText(alarm.source, alarm.id), safeText(alarm.message, 'Process alarm'), dateTime(alarm.since), statusElement(alarm.acknowledged ? 'Acknowledged' : 'Unacknowledged', alarm.acknowledged ? 'ack-state' : 'unack-state')]);
  if (preview) {
    clear(preview);
    const previewRows = list.slice(0, 4).map((alarm) => [severityElement(alarm.severity), safeText(alarm.source, alarm.id), safeText(alarm.message, 'Process alarm'), statusElement(alarm.acknowledged ? 'Acknowledged' : 'Unacknowledged', alarm.acknowledged ? 'ack-state' : 'unack-state')]);
    preview.appendChild(makeTable(['Priority', 'Source', 'Condition', 'Status'], previewRows, 'alarm-preview-table'));
  }
  if (table) { clear(table); table.appendChild(makeTable(['Priority', 'Source', 'Condition', 'Since', 'Status'], rows, 'alarm-table-content')); }
}

function renderEvents() {
  const events = (state.snapshot?.events || []).slice(0, 100);
  const preview = $('event-preview-body');
  if (preview) {
    clear(preview);
    if (!events.length) preview.appendChild(emptyState('No events in this session.'));
    events.slice(0, 6).forEach((item) => {
      const row = document.createElement('div');
      row.className = 'event-item';
      const pip = document.createElement('i'); pip.className = `event-pip ${String(item.severity || '').toLowerCase()}`;
      const time = document.createElement('span'); time.className = 'event-time'; time.textContent = timeOnly(item.time);
      const text = document.createElement('span'); text.className = 'event-text';
      const source = document.createElement('span'); source.className = 'event-source'; source.textContent = safeText(item.source, 'SYSTEM');
      text.appendChild(source); text.appendChild(document.createTextNode(safeText(item.message, 'Event')));
      row.append(pip, time, text); preview.appendChild(row);
    });
  }
  const audit = $('audit-table');
  if (audit) {
    clear(audit);
    if (!events.length) audit.appendChild(emptyState('No events in this session.'));
    else audit.appendChild(makeTable(['Time', 'Source', 'Severity', 'Event', 'Actor'], events.map((item) => [dateTime(item.time), safeText(item.source, 'SYSTEM'), severityElement(item.severity), safeText(item.message, 'Event'), safeText(item.actor, '—')]), 'audit-table-content'));
  }
}

function renderTrendSelectors() {
  const tag = getTag(state.selectedTrend);
  const label = safeText(tag?.label, state.selectedTrend);
  ['trend-select', 'trend-select-large'].forEach((id) => {
    const select = $(id);
    if (!select) return;
    const option = Array.from(select.options).find((item) => item.value === state.selectedTrend);
    if (option) option.textContent = label;
    select.value = state.selectedTrend;
  });
}

function drawChart(canvas, key) {
  if (!canvas) return;
  const context = canvas.getContext('2d');
  if (!context) return;
  const rect = canvas.getBoundingClientRect();
  const dpr = Math.max(1, window.devicePixelRatio || 1);
  const width = Math.max(250, rect.width || canvas.clientWidth || 780);
  const height = Math.max(170, rect.height || canvas.clientHeight || 280);
  canvas.width = Math.floor(width * dpr);
  canvas.height = Math.floor(height * dpr);
  context.setTransform(dpr, 0, 0, dpr, 0, 0);
  context.clearRect(0, 0, width, height);
  const item = getTag(key);
  const summaryTargets = canvas.id === 'trend-chart' ? ['chart-summary'] : ['large-chart-summary'];
  const unavailable = !item || !qualityIsUsable(item);
  const history = unavailable ? [] : (Array.isArray(item.history) ? item.history : []).filter((point) => finiteNumber(point.value) !== null).slice(-90);
  const min = finiteNumber(item?.min) ?? 0;
  const maxCandidate = finiteNumber(item?.max) ?? 100;
  const max = maxCandidate === min ? min + 1 : maxCandidate;
  const pad = { left: 40, right: 16, top: 16, bottom: 28 };
  const chartWidth = width - pad.left - pad.right;
  const chartHeight = height - pad.top - pad.bottom;
  context.font = '10px system-ui, sans-serif';
  context.lineWidth = 1;
  for (let index = 0; index <= 4; index += 1) {
    const y = pad.top + chartHeight * index / 4;
    context.strokeStyle = '#1b3041'; context.beginPath(); context.moveTo(pad.left, y); context.lineTo(width - pad.right, y); context.stroke();
    context.fillStyle = '#63798b'; context.fillText((max - (max - min) * index / 4).toFixed(max > 20 ? 0 : 1), 4, y + 3);
  }
  if (history.length < 2 || chartWidth <= 0 || chartHeight <= 0) {
    context.fillStyle = '#63798b'; context.textAlign = 'center'; context.fillText(unavailable ? 'Data quality unavailable' : 'Waiting for trend samples…', width / 2, height / 2); context.textAlign = 'start';
    summaryTargets.forEach((id) => setText(id, unavailable ? `${safeText(item?.label, key)} · ${safeText(item?.quality, 'BAD')} quality` : `Waiting for ${safeText(item?.label, key)} samples.`));
    return;
  }
  context.beginPath();
  history.forEach((point, index) => {
    const value = finiteNumber(point.value) ?? min;
    const x = pad.left + chartWidth * index / (history.length - 1);
    const y = pad.top + chartHeight * (1 - Math.max(0, Math.min(1, (value - min) / (max - min))));
    index ? context.lineTo(x, y) : context.moveTo(x, y);
  });
  context.lineWidth = 2; context.strokeStyle = '#54a7ff'; context.shadowColor = 'rgba(84,167,255,.55)'; context.shadowBlur = 8; context.stroke(); context.shadowBlur = 0;
  const last = history[history.length - 1];
  const lastValue = finiteNumber(last.value) ?? min;
  const lastY = pad.top + chartHeight * (1 - Math.max(0, Math.min(1, (lastValue - min) / (max - min))));
  context.fillStyle = '#9dd3ff'; context.beginPath(); context.arc(width - pad.right, lastY, 3, 0, Math.PI * 2); context.fill();
  const label = safeText(item.label, key);
  setText('trend-title', label);
  setText('chart-unit', safeText(item.unit, 'status'));
  summaryTargets.forEach((id) => setText(id, `${label}: ${lastValue.toFixed(max > 20 ? 1 : 2)} ${safeText(item.unit, '')} · ${history.length} samples · ${safeText(item.quality, 'GOOD')} quality`));
}

function redrawCharts() {
  drawChart($('trend-chart'), state.selectedTrend);
  drawChart($('large-trend-chart'), state.selectedTrend);
}

function render() {
  if (!state.user) return;
  renderUser();
  renderConnection();
  renderProcess();
  renderControls();
  renderAlarms();
  renderEvents();
  renderTrendSelectors();
  redrawCharts();
}

function showView(viewId) {
  const valid = ['overview', 'alarms', 'trends', 'audit', 'screen-editor'];
  const next = valid.includes(viewId) ? viewId : 'overview';
  state.view = next;
  $$('.view').forEach((view) => view.classList.toggle('active-view', view.id === next));
  $$('.nav-item').forEach((item) => {
    const active = item.dataset.view === next;
    item.classList.toggle('active', active);
    if (active) item.setAttribute('aria-current', 'page'); else item.removeAttribute('aria-current');
  });
  const labels = { overview: 'NILIT Line 1', alarms: 'Alarm management', trends: 'Historian trends', audit: 'Audit log', 'screen-editor': 'Screen Editor' };
  setText('page-title', labels[next]);
  const sidebar = $('sidebar');
  if (sidebar) sidebar.classList.remove('mobile-open');
  const toggle = $('mobile-nav-toggle');
  if (toggle) { toggle.setAttribute('aria-expanded', 'false'); toggle.setAttribute('aria-label', 'Open navigation'); }
  window.scrollTo({ top: 0, behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  redrawCharts();
}

function errorMessage(error) {
  if (error instanceof ApiError) {
    if (error.code) return `${error.message} (${error.code})`;
    return error.message;
  }
  return error?.message || 'Oracle request failed.';
}

function showLogin(message = '') {
  disconnectStream();
  state.user = null;
  state.snapshot = null;
  state.pending.clear();
  state.stale = true;
  state.connection = 'offline';
  state.sessionExpired = false;
  $('session-expired')?.classList.add('is-hidden');
  $('app-shell')?.classList.add('is-hidden');
  $('app-shell')?.setAttribute('aria-hidden', 'true');
  $('login-screen')?.classList.remove('is-hidden');
  $('login-error').textContent = message;
  const password = $('login-password');
  if (password) { password.value = ''; window.setTimeout(() => password.focus(), 0); }
}

function openApp() {
  $('login-screen')?.classList.add('is-hidden');
  $('app-shell')?.classList.remove('is-hidden');
  $('app-shell')?.setAttribute('aria-hidden', 'false');
  renderUser();
  $('main-content')?.focus({ preventScroll: true });
}

function handleSessionExpired() {
  if (state.sessionExpired || !state.user) return;
  state.sessionExpired = true;
  state.stale = true;
  state.connection = 'session-expired';
  disconnectStream();
  renderConnection();
  $('session-expired')?.classList.remove('is-hidden');
}

function scheduleReconnect() {
  if (!state.user || state.reconnectTimer || state.sessionExpired) return;
  const delays = [1000, 2000, 4000, 8000, 15000, 30000];
  const delay = delays[Math.min(state.reconnectAttempts, delays.length - 1)];
  state.reconnectAttempts += 1;
  state.connection = 'reconnecting';
  renderConnection();
  state.reconnectTimer = window.setTimeout(async () => {
    state.reconnectTimer = null;
    await connectStream(true);
  }, delay);
}

function disconnectStream() {
  if (state.source) { state.source.close(); state.source = null; }
  if (state.reconnectTimer) { clearTimeout(state.reconnectTimer); state.reconnectTimer = null; }
}

function handleStreamState(event) {
  try { markSnapshot(JSON.parse(event.data)); }
  catch { showToast('Oracle received an invalid state update.', 'error'); }
}

async function connectStream(refreshState = false) {
  if (!state.user || state.sessionExpired) return;
  if (refreshState) {
    try { markSnapshot(await api.snapshot()); }
    catch (error) {
      if (error.status === 401) { handleSessionExpired(); return; }
      state.stale = true; state.connection = 'reconnecting'; renderConnection(); scheduleReconnect(); return;
    }
  }
  disconnectStream();
  state.connection = 'connecting';
  renderConnection();
  try {
    const source = new EventSource('/api/stream', { withCredentials: true });
    state.source = source;
    source.addEventListener('open', () => {
      state.connection = 'connected';
      state.reconnectAttempts = 0;
      renderConnection();
    });
    source.addEventListener('state', handleStreamState);
    source.onmessage = handleStreamState;
    source.addEventListener('heartbeat', () => { if (state.connection !== 'connected') { state.connection = 'connected'; renderConnection(); } });
    source.addEventListener('error', (event) => {
      if (event?.data) {
        try {
          const payload = JSON.parse(event.data);
          if (payload.code === 'SESSION_EXPIRED') { handleSessionExpired(); return; }
        } catch { /* Native EventSource error has no JSON payload. */ }
      }
    });
    source.onerror = () => {
      if (state.source !== source) return;
      source.close(); state.source = null;
      state.stale = true; state.connection = 'reconnecting'; renderConnection(); scheduleReconnect();
    };
  } catch {
    state.stale = true; state.connection = 'reconnecting'; renderConnection(); scheduleReconnect();
  }
}

function startStaleMonitor() {
  clearInterval(state.staleTimer);
  state.staleTimer = window.setInterval(() => {
    if (!state.user || !state.lastValidAt) return;
    const scanMs = Math.max(1000, Number(currentSystem().scanMs || 1000));
    const threshold = Math.max(scanMs * 3, 5000);
    if (Date.now() - state.lastValidAt > threshold && !state.stale) {
      state.stale = true;
      state.connection = state.connection === 'connected' ? 'stale' : state.connection;
      renderConnection(); renderControls();
      announce('Oracle data is stale. Operator controls are locked.');
    }
  }, 1000);
}

async function sendCommand(action, extra = {}) {
  if (!state.user) return;
  if (!canOperate()) { showToast('Controls are locked while Oracle is offline or data is stale.', 'error'); return; }
  if (state.pending.has(action)) return;
  if ((action === 'set-mode' || action === 'reset-simulator') && !isSupervisor()) { showToast('Supervisor permission required.', 'error'); return; }
  const baseline = Number(state.snapshot?.stateVersion || 0);
  state.pending.set(action, { awaitStateVersion: baseline + 1 });
  renderControls();
  try {
    const result = await api.command(action, extra);
    if (result.accepted === false || result.status === 'REJECTED' || result.status === 'FAILED') {
      state.pending.delete(action); renderControls();
      showToast(result.message || result.reason || 'Command rejected.', 'error');
      return;
    }
    const resultVersion = Number(result.stateVersion || 0);
    const pending = state.pending.get(action);
    if (pending) {
      pending.awaitStateVersion = Math.max(baseline + 1, resultVersion || baseline + 1);
      if (result.status === 'NOOP' || (resultVersion && resultVersion <= baseline)) state.pending.delete(action);
    }
    renderControls();
    showToast(`${action.replaceAll('-', ' ')} command accepted`);
  } catch (error) {
    state.pending.delete(action); renderControls();
    if (error.status === 401) handleSessionExpired();
    else if (error.status === 403) showToast('Supervisor permission required.', 'error');
    else showToast(errorMessage(error), 'error');
  }
}

function downloadAudit() {
  const events = state.snapshot?.events || [];
  const date = new Date().toISOString().slice(0, 10).replaceAll('-', '');
  const payload = { exportedAt: new Date().toISOString(), application: 'Oracle', site: 'NILIT', processLine: 'NILIT Line 1', user: state.user, events };
  const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a'); link.href = url; link.download = `oracle-audit-${date}.json`; link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
  showToast('Oracle audit export prepared.');
}

async function loadEditorModule() {
  const root = $('screen-editor-root');
  if (!root || state.editorLoadStarted) return;
  state.editorLoadStarted = true;
  const copy = $('editor-entry-copy');
  try {
    const module = await import('/editor/editor.js');
    const init = module.default || module.init || module.initialize;
    if (typeof init === 'function') init({ root, user: state.user, getState: () => state.snapshot, command: sendCommand });
    root.dataset.editorLoaded = 'true';
    if (copy && !root.querySelector('[data-editor-owned]')) copy.textContent = isSupervisor() ? 'Editor workspace loaded.' : 'Runtime view loaded. Editing remains supervisor-only.';
  } catch {
    root.dataset.editorLoaded = 'false';
    if (copy) copy.textContent = isSupervisor() ? 'The editor module is not available in this deployment yet.' : 'The editor module is not available. Published runtime screens remain read-only.';
    const retry = $('editor-retry');
    if (retry) retry.hidden = false;
  }
}

async function openAuthenticatedSession(user) {
  state.user = user;
  state.sessionExpired = false;
  state.connection = 'connecting';
  state.stale = true;
  openApp();
  renderUser();
  try {
    markSnapshot(await api.snapshot());
    await connectStream(false);
  } catch (error) {
    if (error.status === 401) { showLogin('Your login session is no longer valid.'); return; }
    state.connection = 'reconnecting'; state.stale = true; renderConnection(); showToast(errorMessage(error), 'error'); scheduleReconnect();
  }
}

async function handleLogin(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const submit = $('login-submit');
  const username = $('login-username').value;
  const password = $('login-password').value;
  const errorElement = $('login-error');
  errorElement.textContent = '';
  if (!password) { errorElement.textContent = 'Enter your Oracle password.'; $('login-password').focus(); return; }
  submit.disabled = true; submit.textContent = 'Authenticating…';
  try {
    const result = await api.login(username, password);
    const user = result.user || (await api.me()).user;
    await openAuthenticatedSession(user);
    form.reset(); $('login-username').value = username;
  } catch (error) {
    errorElement.textContent = error.status === 401 ? 'Invalid Oracle credentials.' : errorMessage(error);
  } finally {
    submit.disabled = false; submit.textContent = 'Open HMI session';
  }
}

async function handleLogout() {
  try { await api.logout(); } catch { /* Session may already be gone; local cleanup is still required. */ }
  showLogin();
}

function bindEvents() {
  $('login-form')?.addEventListener('submit', handleLogin);
  $('logout-button')?.addEventListener('click', handleLogout);
  $('session-login')?.addEventListener('click', () => showLogin());
  $('mobile-nav-toggle')?.addEventListener('click', () => {
    const sidebar = $('sidebar'); const open = sidebar.classList.toggle('mobile-open');
    $('mobile-nav-toggle').setAttribute('aria-expanded', String(open));
    $('mobile-nav-toggle').setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
  });
  $$('.nav-item, .text-button').forEach((button) => button.addEventListener('click', () => showView(button.dataset.view)));
  $$('[data-command]').forEach((button) => button.addEventListener('click', () => sendCommand(button.dataset.command)));
  $$('.mode-button').forEach((button) => button.addEventListener('click', () => sendCommand('set-mode', { mode: button.dataset.mode })));
  $('reset-simulator')?.addEventListener('click', () => sendCommand('reset-simulator'));
  $('ack-all')?.addEventListener('click', () => sendCommand('ack-all'));
  $('download-audit')?.addEventListener('click', downloadAudit);
  $('trend-select')?.addEventListener('change', (event) => { state.selectedTrend = event.target.value; renderTrendSelectors(); redrawCharts(); });
  $('trend-select-large')?.addEventListener('change', (event) => { state.selectedTrend = event.target.value; renderTrendSelectors(); redrawCharts(); });
  $('editor-retry')?.addEventListener('click', () => { state.editorLoadStarted = false; $('editor-retry').hidden = true; loadEditorModule(); });
  window.addEventListener('resize', redrawCharts);
  if (window.ResizeObserver) {
    const observer = new ResizeObserver(redrawCharts);
    if ($('trend-chart')) observer.observe($('trend-chart').parentElement);
    if ($('large-trend-chart')) observer.observe($('large-trend-chart').parentElement);
  }
}

async function bootstrap() {
  bindEvents();
  startStaleMonitor();
  loadEditorModule();
  try {
    const result = await api.me();
    await openAuthenticatedSession(result.user);
  } catch (error) {
    if (error.status && error.status !== 401 && error.status !== 403) $('login-error').textContent = 'Oracle service is not available. You can retry sign in when it is online.';
    showLogin($('login-error').textContent);
  }
}

window.oracleHmi = {
  getState: () => state.snapshot,
  getUser: () => state.user,
  sendCommand,
  showView
};

bootstrap();
