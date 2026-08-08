(function (global) {
  'use strict';

  var SCHEMA_VERSION = 1;
  var DEFAULT_VIEWPORT = { width: 1920, height: 1080, background: '#07101a' };

  function clone(value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  }

  function uid(prefix) {
    var random = Math.random().toString(36).slice(2, 8);
    return (prefix || 'id') + '-' + Date.now().toString(36) + '-' + random;
  }

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function finite(value, fallback) {
    return Number.isFinite(Number(value)) ? Number(value) : fallback;
  }

  function frame(x, y, width, height) {
    return {
      x: finite(x, 0),
      y: finite(y, 0),
      width: Math.max(1, finite(width, 100)),
      height: Math.max(1, finite(height, 80)),
      rotation: 0
    };
  }

  var PARTS = {
    tank: {
      type: 'tank',
      name: 'Tank',
      category: 'Process equipment',
      description: 'Vertical tank with a level visualization.',
      defaultFrame: frame(260, 300, 180, 240),
      minSize: { width: 80, height: 100 },
      rotations: [0, 180],
      props: { label: 'TK-101', description: 'Process tank' },
      ports: [
        { id: 'inlet', label: 'Inlet', side: 'top', accepts: ['pipe'] },
        { id: 'outlet', label: 'Outlet', side: 'bottom', accepts: ['pipe'] },
        { id: 'signal', label: 'Signal', side: 'right', accepts: ['instrument'] }
      ],
      bindings: { level: { label: 'Level', valueType: 'number', unit: '%' } }
    },
    pump: {
      type: 'pump',
      name: 'Pump',
      category: 'Process equipment',
      description: 'Centrifugal transfer pump.',
      defaultFrame: frame(560, 390, 150, 110),
      minSize: { width: 90, height: 70 },
      rotations: [0, 90, 180, 270],
      props: { label: 'P-101', description: 'Transfer pump' },
      ports: [
        { id: 'inlet', label: 'Inlet', side: 'left', accepts: ['pipe'] },
        { id: 'outlet', label: 'Outlet', side: 'right', accepts: ['pipe'] },
        { id: 'signal', label: 'Run feedback', side: 'top', accepts: ['instrument'] }
      ],
      bindings: { run: { label: 'Run state', valueType: 'boolean', unit: '' } }
    },
    valve: {
      type: 'valve',
      name: 'Valve',
      category: 'Valves',
      description: 'Actuated process valve.',
      defaultFrame: frame(790, 390, 130, 90),
      minSize: { width: 75, height: 55 },
      rotations: [0, 90, 180, 270],
      props: { label: 'XV-101', description: 'Inlet valve', valveStyle: 'actuated' },
      ports: [
        { id: 'inlet', label: 'Inlet', side: 'left', accepts: ['pipe'] },
        { id: 'outlet', label: 'Outlet', side: 'right', accepts: ['pipe'] },
        { id: 'signal', label: 'Open feedback', side: 'top', accepts: ['instrument'] }
      ],
      bindings: { open: { label: 'Open state', valueType: 'boolean', unit: '' } }
    },
    instrument: {
      type: 'instrument',
      name: 'Instrument',
      category: 'Instrumentation',
      description: 'Numeric process instrument with a tag binding.',
      defaultFrame: frame(980, 270, 150, 100),
      minSize: { width: 90, height: 65 },
      rotations: [0, 90, 180, 270],
      props: { label: 'FT-101', description: 'Flow transmitter', valueFormat: '0.0' },
      ports: [{ id: 'signal', label: 'Signal', side: 'bottom', accepts: ['pipe', 'instrument'] }],
      bindings: { value: { label: 'Value', valueType: 'number', unit: 'm³/h' } }
    },
    pipe: {
      type: 'pipe',
      name: 'Pipe',
      category: 'Structure',
      description: 'Straight process pipe segment.',
      defaultFrame: frame(470, 430, 100, 24),
      minSize: { width: 30, height: 12 },
      rotations: [0, 90, 180, 270],
      props: { label: '', description: 'Process pipe' },
      ports: [
        { id: 'start', label: 'Start', side: 'left', accepts: ['pipe'] },
        { id: 'end', label: 'End', side: 'right', accepts: ['pipe'] }
      ],
      bindings: { flow: { label: 'Flow', valueType: 'number', unit: 'm³/h' } }
    },
    text: {
      type: 'text',
      name: 'Text',
      category: 'Structure',
      description: 'Operator-facing annotation.',
      defaultFrame: frame(120, 120, 260, 50),
      minSize: { width: 40, height: 24 },
      rotations: [0, 90, 180, 270],
      props: { label: 'Process Area', description: 'Screen annotation', text: 'Process Area' },
      ports: [],
      bindings: {}
    }
  };

  var CATEGORIES = ['Process equipment', 'Valves', 'Instrumentation', 'Structure'];

  function createLayer(name, zIndex) {
    return { id: uid('layer'), name: name, zIndex: zIndex, visible: true, locked: false };
  }

  function createElement(type, options) {
    var part = PARTS[type] || PARTS.text;
    var opts = options || {};
    var sourceFrame = opts.frame || part.defaultFrame;
    var element = {
      id: opts.id || uid('element'),
      type: part.type,
      layerId: opts.layerId || null,
      parentId: opts.parentId || null,
      frame: frame(sourceFrame.x, sourceFrame.y, sourceFrame.width, sourceFrame.height),
      locked: Boolean(opts.locked),
      hidden: Boolean(opts.hidden),
      props: Object.assign({}, clone(part.props), clone(opts.props || {})),
      style: Object.assign({
        fill: '#0b2535',
        stroke: '#4a839d',
        strokeWidth: 2,
        opacity: 1,
        fontSize: 18,
        fontFamily: 'Inter, Segoe UI, sans-serif'
      }, clone(opts.style || {})),
      bindings: Object.assign({}, clone(opts.bindings || {})),
      metadata: Object.assign({ createdAt: new Date().toISOString() }, clone(opts.metadata || {}))
    };
    if (opts.frame && Number.isFinite(Number(opts.frame.rotation))) {
      element.frame.rotation = Number(opts.frame.rotation);
    }
    return element;
  }

  function createConnector(options) {
    var opts = options || {};
    return {
      id: opts.id || uid('connector'),
      type: opts.type || 'pipe',
      source: clone(opts.source || { elementId: '', portId: '' }),
      target: clone(opts.target || { elementId: '', portId: '' }),
      waypoints: clone(opts.waypoints || []),
      style: Object.assign({ stroke: '#3d6c83', strokeWidth: 6, routing: 'orthogonal' }, clone(opts.style || {})),
      bindings: clone(opts.bindings || {})
    };
  }

  function createDocument(options) {
    var opts = options || {};
    var processLayer = createLayer('Process', 10);
    var annotationLayer = createLayer('Annotations', 20);
    var doc = {
      schemaVersion: SCHEMA_VERSION,
      id: opts.id || uid('screen'),
      name: opts.name || 'New Process Screen',
      status: opts.status || 'draft',
      revision: Number.isFinite(Number(opts.revision)) ? Number(opts.revision) : 1,
      viewport: Object.assign({}, DEFAULT_VIEWPORT, clone(opts.viewport || {})),
      grid: Object.assign({ size: 8, visible: true, snap: true }, clone(opts.grid || {})),
      layers: clone(opts.layers || [processLayer, annotationLayer]),
      elements: [],
      connectors: [],
      metadata: Object.assign({
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        createdBy: 'local-editor',
        updatedBy: 'local-editor'
      }, clone(opts.metadata || {}))
    };
    if (Array.isArray(opts.elements)) {
      doc.elements = opts.elements.map(function (item) {
        return createElement(item.type, Object.assign({}, item, { layerId: item.layerId || processLayer.id }));
      });
    }
    if (Array.isArray(opts.connectors)) {
      doc.connectors = opts.connectors.map(createConnector);
    }
    if (!doc.elements.length && opts.seed !== false) {
      doc.elements = [
        createElement('text', { layerId: annotationLayer.id, frame: frame(110, 85, 420, 55), props: { text: doc.name, label: doc.name } })
      ];
    }
    return doc;
  }

  function addElement(doc, type, options) {
    var element = createElement(type, options);
    if (!element.layerId) {
      var firstLayer = doc.layers.slice().sort(function (a, b) { return a.zIndex - b.zIndex; })[0];
      element.layerId = firstLayer ? firstLayer.id : null;
    }
    doc.elements.push(element);
    return element;
  }

  function getPart(type) {
    return PARTS[type] || null;
  }

  function getPort(type, portId) {
    var part = getPart(type);
    if (!part) return null;
    return part.ports.filter(function (port) { return port.id === portId; })[0] || null;
  }

  function portPosition(element, portId) {
    var port = getPort(element.type, portId);
    if (!port) return null;
    var x = element.frame.x;
    var y = element.frame.y;
    var w = element.frame.width;
    var h = element.frame.height;
    var position = { x: x + w / 2, y: y + h / 2 };
    if (port.side === 'left') position = { x: x, y: y + h / 2 };
    if (port.side === 'right') position = { x: x + w, y: y + h / 2 };
    if (port.side === 'top') position = { x: x + w / 2, y: y };
    if (port.side === 'bottom') position = { x: x + w / 2, y: y + h };
    return position;
  }

  function normalizeDocument(input) {
    var source = typeof input === 'string' ? JSON.parse(input) : clone(input);
    if (!source || typeof source !== 'object') throw new Error('A screen document object is required.');
    var doc = createDocument(Object.assign({}, source, { seed: false }));
    doc.schemaVersion = Number(source.schemaVersion) || SCHEMA_VERSION;
    doc.layers = Array.isArray(source.layers) && source.layers.length ? source.layers : doc.layers;
    doc.elements = Array.isArray(source.elements) ? source.elements.map(function (item) {
      var element = createElement(item.type, Object.assign({}, item, { layerId: item.layerId || doc.layers[0].id }));
      if (!PARTS[item.type]) element.type = item.type;
      return element;
    }) : [];
    doc.connectors = Array.isArray(source.connectors) ? source.connectors.map(createConnector) : [];
    return doc;
  }

  function serialize(doc, pretty) {
    return JSON.stringify(normalizeDocument(doc), null, pretty ? 2 : 0);
  }

  function deserialize(json) {
    return normalizeDocument(json);
  }

  function boundsOf(element) {
    return {
      left: element.frame.x,
      top: element.frame.y,
      right: element.frame.x + element.frame.width,
      bottom: element.frame.y + element.frame.height,
      centerX: element.frame.x + element.frame.width / 2,
      centerY: element.frame.y + element.frame.height / 2
    };
  }

  function validate(doc, tagCatalog) {
    var normalized = normalizeDocument(doc);
    var errors = [];
    var warnings = [];
    var ids = {};
    var layers = {};
    var tags = {};
    (tagCatalog || []).forEach(function (tag) { tags[tag.key || tag.id] = true; });
    if (!String(normalized.id || '').trim()) errors.push({ code: 'SCREEN_ID_REQUIRED', message: 'Screen ID is required.' });
    if (!String(normalized.name || '').trim()) errors.push({ code: 'SCREEN_NAME_REQUIRED', message: 'Screen name is required.' });
    normalized.layers.forEach(function (layer) {
      if (layers[layer.id]) errors.push({ code: 'DUPLICATE_LAYER_ID', message: 'Layer IDs must be unique: ' + layer.id });
      layers[layer.id] = true;
    });
    normalized.elements.forEach(function (element) {
      if (ids[element.id]) errors.push({ code: 'DUPLICATE_ELEMENT_ID', message: 'Element IDs must be unique: ' + element.id });
      ids[element.id] = true;
      if (!PARTS[element.type]) errors.push({ code: 'UNKNOWN_PART_TYPE', message: 'Unknown part type: ' + element.type });
      if (!layers[element.layerId]) errors.push({ code: 'MISSING_LAYER', message: 'Element ' + element.id + ' references a missing layer.' });
      var f = element.frame || {};
      if (![f.x, f.y, f.width, f.height, f.rotation].every(Number.isFinite)) errors.push({ code: 'INVALID_GEOMETRY', message: 'Element ' + element.id + ' has invalid geometry.' });
      if (f.width <= 0 || f.height <= 0) errors.push({ code: 'INVALID_SIZE', message: 'Element ' + element.id + ' must have a positive size.' });
      var part = PARTS[element.type];
      if (part && part.bindings) {
        Object.keys(element.bindings || {}).forEach(function (slot) {
          var binding = element.bindings[slot];
          if (!binding || !String(binding.tagKey || '').trim()) errors.push({ code: 'EMPTY_BINDING', message: element.id + ' has an empty ' + slot + ' binding.' });
          else if (tagCatalog && tagCatalog.length && !tags[binding.tagKey]) warnings.push({ code: 'UNKNOWN_TAG', message: 'Tag not found in catalog: ' + binding.tagKey });
        });
      }
      if (f.x < -32 || f.y < -32 || f.x + f.width > normalized.viewport.width + 32 || f.y + f.height > normalized.viewport.height + 32) {
        warnings.push({ code: 'OUTSIDE_VIEWPORT', message: element.id + ' is outside the visible screen area.' });
      }
    });
    normalized.connectors.forEach(function (connector) {
      var source = normalized.elements.filter(function (item) { return item.id === connector.source.elementId; })[0];
      var target = normalized.elements.filter(function (item) { return item.id === connector.target.elementId; })[0];
      if (!source || !target) errors.push({ code: 'MISSING_CONNECTOR_ELEMENT', message: 'Connector ' + connector.id + ' references a missing element.' });
      if (source && !getPort(source.type, connector.source.portId)) errors.push({ code: 'MISSING_SOURCE_PORT', message: 'Connector ' + connector.id + ' has an invalid source port.' });
      if (target && !getPort(target.type, connector.target.portId)) errors.push({ code: 'MISSING_TARGET_PORT', message: 'Connector ' + connector.id + ' has an invalid target port.' });
    });
    for (var i = 0; i < normalized.elements.length; i += 1) {
      for (var j = i + 1; j < normalized.elements.length; j += 1) {
        var a = boundsOf(normalized.elements[i]);
        var b = boundsOf(normalized.elements[j]);
        if (a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top && normalized.elements[i].type !== 'pipe' && normalized.elements[j].type !== 'pipe') {
          warnings.push({ code: 'OVERLAP', message: normalized.elements[i].id + ' overlaps ' + normalized.elements[j].id + '.' });
        }
      }
    }
    return { valid: errors.length === 0, errors: errors, warnings: warnings };
  }

  function baseTemplate(name, id) {
    return createDocument({ name: name, id: id, seed: false });
  }

  function templateLine1() {
    var doc = baseTemplate('NILIT Line 1 Overview', 'screen-line-1-overview');
    var processLayer = doc.layers[0].id;
    var annotationLayer = doc.layers[1].id;
    var tank = addElement(doc, 'tank', { id: 'element-tk-101', layerId: processLayer, frame: frame(190, 310, 190, 250), props: { label: 'TK-101', description: 'Feed tank' }, bindings: { level: { tagKey: 'TK-101.level', displayUnit: '%' } } });
    var pump = addElement(doc, 'pump', { id: 'element-p-101', layerId: processLayer, frame: frame(540, 390, 160, 110), props: { label: 'P-101' }, bindings: { run: { tagKey: 'P-101.run' } } });
    var valve = addElement(doc, 'valve', { id: 'element-xv-101', layerId: processLayer, frame: frame(850, 400, 140, 90), props: { label: 'XV-101' }, bindings: { open: { tagKey: 'XV-101.open' } } });
    var flow = addElement(doc, 'instrument', { id: 'element-ft-101', layerId: processLayer, frame: frame(1040, 250, 170, 105), props: { label: 'FT-101', description: 'Transfer flow' }, bindings: { value: { tagKey: 'FT-101.flow', displayUnit: 'm³/h' } } });
    addElement(doc, 'text', { id: 'element-title', layerId: annotationLayer, frame: frame(110, 90, 740, 60), props: { label: 'NILIT Line 1 Overview', text: 'NILIT LINE 1  /  TRANSFER OVERVIEW' }, style: { fontSize: 28, fill: '#e9f7ff', stroke: 'none' } });
    addElement(doc, 'text', { id: 'element-note', layerId: annotationLayer, frame: frame(110, 160, 480, 38), props: { label: 'Simulation note', text: 'SIMULATION MODE  •  CONTROL LOGIC NOT CONNECTED' }, style: { fontSize: 14, fill: '#75d8e6', stroke: 'none' } });
    addElement(doc, 'pipe', { id: 'element-pipe-1', layerId: processLayer, frame: frame(380, 425, 160, 24) });
    addElement(doc, 'pipe', { id: 'element-pipe-2', layerId: processLayer, frame: frame(700, 425, 150, 24) });
    doc.connectors = [
      createConnector({ id: 'connector-tank-pump', source: { elementId: tank.id, portId: 'outlet' }, target: { elementId: pump.id, portId: 'inlet' } }),
      createConnector({ id: 'connector-pump-valve', source: { elementId: pump.id, portId: 'outlet' }, target: { elementId: valve.id, portId: 'inlet' } })
    ];
    return doc;
  }

  function templateTankFarm() {
    var doc = baseTemplate('Tank Farm', 'screen-tank-farm');
    var processLayer = doc.layers[0].id;
    ['TK-101', 'TK-102', 'TK-103'].forEach(function (label, index) {
      addElement(doc, 'tank', { id: 'element-' + label.toLowerCase(), layerId: processLayer, frame: frame(160 + index * 330, 300, 190, 250), props: { label: label, description: 'Storage tank' }, bindings: { level: { tagKey: label + '.level', displayUnit: '%' } } });
    });
    addElement(doc, 'text', { layerId: doc.layers[1].id, frame: frame(120, 100, 700, 60), props: { text: 'NILIT TANK FARM', label: 'NILIT Tank Farm' }, style: { fontSize: 30, fill: '#e9f7ff', stroke: 'none' } });
    return doc;
  }

  function templatePumpStation() {
    var doc = baseTemplate('Pump Station', 'screen-pump-station');
    var processLayer = doc.layers[0].id;
    addElement(doc, 'pump', { layerId: processLayer, frame: frame(350, 410, 180, 120), props: { label: 'P-201', description: 'Duty pump' }, bindings: { run: { tagKey: 'P-201.run' } } });
    addElement(doc, 'pump', { layerId: processLayer, frame: frame(760, 410, 180, 120), props: { label: 'P-202', description: 'Standby pump' }, bindings: { run: { tagKey: 'P-202.run' } } });
    addElement(doc, 'instrument', { layerId: processLayer, frame: frame(570, 220, 180, 110), props: { label: 'PT-201', description: 'Header pressure' }, bindings: { value: { tagKey: 'PT-201.pressure', displayUnit: 'bar' } } });
    addElement(doc, 'text', { layerId: doc.layers[1].id, frame: frame(120, 100, 720, 60), props: { text: 'PUMP STATION', label: 'Pump Station' }, style: { fontSize: 30, fill: '#e9f7ff', stroke: 'none' } });
    return doc;
  }

  var TEMPLATES = {
    blank: function () { return baseTemplate('Blank 1920×1080 Screen', 'screen-blank'); },
    line1: templateLine1,
    tankFarm: templateTankFarm,
    pumpStation: templatePumpStation
  };

  function createFromTemplate(key) {
    return (TEMPLATES[key] || TEMPLATES.blank)();
  }

  global.OracleScreenEditorModel = {
    SCHEMA_VERSION: SCHEMA_VERSION,
    DEFAULT_VIEWPORT: clone(DEFAULT_VIEWPORT),
    PARTS: clone(PARTS),
    CATEGORIES: clone(CATEGORIES),
    TEMPLATES: Object.keys(TEMPLATES).map(function (key) { return { key: key, name: createFromTemplate(key).name }; }),
    clone: clone,
    uid: uid,
    clamp: clamp,
    createDocument: createDocument,
    createElement: createElement,
    createConnector: createConnector,
    addElement: addElement,
    getPart: getPart,
    getPort: getPort,
    portPosition: portPosition,
    normalizeDocument: normalizeDocument,
    serialize: serialize,
    deserialize: deserialize,
    validate: validate,
    createFromTemplate: createFromTemplate,
    boundsOf: boundsOf
  };
}(window));
