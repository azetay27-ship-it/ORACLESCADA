(function (global) {
  'use strict';

  var SVG_NS = 'http://www.w3.org/2000/svg';
  var VIEWBOX = { width: 1200, height: 700 };
  var Model = global.OracleScreenEditorModel;

  function svg(name, attrs) {
    var node = global.document.createElementNS(SVG_NS, name);
    Object.keys(attrs || {}).forEach(function (key) { node.setAttribute(key, String(attrs[key])); });
    if (arguments.length > 2 && arguments[2] !== undefined) node.appendChild(global.document.createTextNode(String(arguments[2])));
    return node;
  }

  function html(name, className, text) {
    var node = global.document.createElement(name);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(label, action, className, title) {
    var node = html('button', 'oracle-editor-button ' + (className || ''), label);
    node.type = 'button';
    if (action) node.dataset.action = action;
    if (title) node.title = title;
    return node;
  }

  function input(type, value, className) {
    var node = global.document.createElement('input');
    node.type = type || 'text';
    node.className = className || 'oracle-editor-input';
    if (value !== undefined) node.value = value;
    return node;
  }

  function labelFor(text, control) {
    var wrapper = html('label', 'oracle-editor-field');
    wrapper.appendChild(html('span', 'oracle-editor-field-label', text));
    wrapper.appendChild(control);
    return wrapper;
  }

  function readPath(source, path) {
    return String(path || '').split('.').reduce(function (value, key) {
      return value == null ? undefined : value[key];
    }, source);
  }

  function same(a, b) {
    return JSON.stringify(a) === JSON.stringify(b);
  }

  function OracleScreenEditor(root, options) {
    if (!root) throw new Error('OracleScreenEditor requires a root element.');
    Model = global.OracleScreenEditorModel || Model;
    if (!Model) throw new Error('OracleScreenEditorModel must load before editor.js.');
    this.root = root;
    this.options = options || {};
    this.doc = this.options.document ? Model.deserialize(this.options.document) : Model.createFromTemplate('line1');
    this.mode = 'edit';
    this.tool = 'select';
    this.selectedIds = [];
    this.selectedConnectorIds = [];
    this.activeLayerId = this.doc.layers[0] ? this.doc.layers[0].id : null;
    this.pan = { x: 26, y: 22 };
    this.zoom = 0.55;
    this.history = [];
    this.redoStack = [];
    this.guides = [];
    this.marquee = null;
    this.gesture = null;
    this.runtimeSnapshot = this.options.runtimeSnapshot || null;
    this.tagCatalog = this.options.tagCatalog || [];
    this.libraryFilter = '';
    this.validationResult = null;
    this.buildShell();
    this.bindEvents();
    this.renderLibrary();
    this.renderTemplates();
    this.render();
    this.fitToScreen();
    this.renderStatus();
  }

  OracleScreenEditor.prototype.buildShell = function () {
    this.root.className = 'oracle-editor-root';
    this.root.setAttribute('role', 'application');
    this.root.setAttribute('aria-label', 'Oracle process screen editor');
    this.root.tabIndex = 0;
    this.root.innerHTML = '';

    var shell = html('div', 'oracle-editor-shell');
    var toolbar = html('header', 'oracle-editor-toolbar');
    var brand = html('div', 'oracle-editor-brand');
    brand.appendChild(html('span', 'oracle-editor-brand-mark', 'O'));
    var brandText = html('div', 'oracle-editor-brand-text');
    brandText.appendChild(html('strong', '', 'ORACLE'));
    brandText.appendChild(html('small', '', 'NILIT SCREEN EDITOR'));
    brand.appendChild(brandText);
    toolbar.appendChild(brand);

    var mode = html('div', 'oracle-editor-mode-switch', '');
    mode.appendChild(button('Edit', 'mode-edit', 'is-active', 'Edit screen geometry and metadata'));
    mode.appendChild(button('Runtime', 'mode-runtime', '', 'Preview the published visual screen'));
    toolbar.appendChild(mode);

    var toolGroup = html('div', 'oracle-editor-toolbar-group');
    toolGroup.appendChild(button('Select', 'tool-select', 'is-active', 'Select and move parts (V)'));
    toolGroup.appendChild(button('Pan', 'tool-pan', '', 'Pan the screen (H)'));
    toolGroup.appendChild(button('Connector', 'tool-connector', '', 'Connect compatible ports'));
    toolbar.appendChild(toolGroup);

    var historyGroup = html('div', 'oracle-editor-toolbar-group');
    historyGroup.appendChild(button('Undo', 'undo', '', 'Undo (Ctrl/Cmd+Z)'));
    historyGroup.appendChild(button('Redo', 'redo', '', 'Redo (Ctrl/Cmd+Shift+Z)'));
    historyGroup.appendChild(button('Duplicate', 'duplicate', '', 'Duplicate selection (Ctrl/Cmd+D)'));
    historyGroup.appendChild(button('Delete', 'delete', 'danger', 'Delete selection (Delete)'));
    toolbar.appendChild(historyGroup);

    var viewGroup = html('div', 'oracle-editor-toolbar-group oracle-editor-toolbar-group-right');
    viewGroup.appendChild(button('Grid', 'toggle-grid', 'is-active', 'Show or hide the layout grid'));
    viewGroup.appendChild(button('Snap', 'toggle-snap', 'is-active', 'Snap movement to the grid'));
    viewGroup.appendChild(button('−', 'zoom-out', '', 'Zoom out'));
    viewGroup.appendChild(button('100%', 'fit', '', 'Fit screen to workspace'));
    viewGroup.appendChild(button('+', 'zoom-in', '', 'Zoom in'));
    viewGroup.appendChild(button('Save', 'save', 'primary', 'Emit a save event for integration'));
    viewGroup.appendChild(button('Validate', 'validate', '', 'Validate the current screen'));
    viewGroup.appendChild(button('Publish', 'publish', 'primary', 'Emit a publish event after validation'));
    toolbar.appendChild(viewGroup);
    shell.appendChild(toolbar);

    var body = html('div', 'oracle-editor-body');
    var library = html('aside', 'oracle-editor-library');
    library.appendChild(html('div', 'oracle-editor-panel-heading', 'Parts & Templates'));
    var search = input('search', '', 'oracle-editor-input oracle-editor-library-search');
    search.placeholder = 'Search parts';
    search.setAttribute('aria-label', 'Search parts');
    search.dataset.role = 'library-search';
    library.appendChild(search);
    var libraryList = html('div', 'oracle-editor-library-list');
    libraryList.dataset.role = 'library-list';
    library.appendChild(libraryList);
    var templateHeading = html('div', 'oracle-editor-subheading', 'Templates');
    library.appendChild(templateHeading);
    var templateList = html('div', 'oracle-editor-template-list');
    templateList.dataset.role = 'template-list';
    library.appendChild(templateList);
    body.appendChild(library);

    var workspace = html('main', 'oracle-editor-workspace');
    var canvasToolbar = html('div', 'oracle-editor-canvas-toolbar');
    canvasToolbar.appendChild(html('span', 'oracle-editor-screen-name', ''));
    canvasToolbar.appendChild(html('span', 'oracle-editor-canvas-help', 'Drag parts onto the canvas • Shift-click for multi-select • Esc cancels'));
    workspace.appendChild(canvasToolbar);
    var stage = html('div', 'oracle-editor-stage');
    var svgCanvas = svg('svg', { class: 'oracle-editor-canvas', viewBox: '0 0 1200 700', preserveAspectRatio: 'xMidYMid meet', tabindex: '0', role: 'img', 'aria-label': 'Process screen canvas' });
    stage.appendChild(svgCanvas);
    var canvasLive = html('div', 'oracle-editor-sr-only');
    canvasLive.dataset.role = 'canvas-live';
    canvasLive.setAttribute('aria-live', 'polite');
    stage.appendChild(canvasLive);
    workspace.appendChild(stage);
    var status = html('div', 'oracle-editor-statusbar');
    status.appendChild(html('span', 'oracle-editor-status-text', ''));
    status.appendChild(html('span', 'oracle-editor-status-coordinates', ''));
    status.appendChild(html('span', 'oracle-editor-status-validation', ''));
    workspace.appendChild(status);
    body.appendChild(workspace);

    var inspector = html('aside', 'oracle-editor-inspector');
    inspector.dataset.role = 'inspector';
    body.appendChild(inspector);
    shell.appendChild(body);
    this.root.appendChild(shell);
    this.svgCanvas = svgCanvas;
    this.stage = stage;
    this.libraryList = libraryList;
    this.templateList = templateList;
    this.inspector = inspector;
    this.status = status;
  };

  OracleScreenEditor.prototype.bindEvents = function () {
    var self = this;
    this.root.addEventListener('click', function (event) { self.onRootClick(event); });
    this.root.addEventListener('change', function (event) { self.onRootChange(event); });
    this.root.addEventListener('input', function (event) {
      if (event.target.dataset && event.target.dataset.role === 'library-search') {
        self.libraryFilter = event.target.value.toLowerCase();
        self.renderLibrary();
      }
    });
    this.root.addEventListener('keydown', function (event) { self.onKeyDown(event); });
    this.svgCanvas.addEventListener('pointerdown', function (event) { self.onCanvasPointerDown(event); });
    this.svgCanvas.addEventListener('pointermove', function (event) { self.onCanvasPointerMove(event); });
    this.svgCanvas.addEventListener('pointerup', function (event) { self.onCanvasPointerUp(event); });
    this.svgCanvas.addEventListener('pointercancel', function (event) { self.cancelGesture(event); });
    this.svgCanvas.addEventListener('wheel', function (event) { self.onWheel(event); }, { passive: false });
    this.svgCanvas.addEventListener('dragover', function (event) { event.preventDefault(); });
    this.svgCanvas.addEventListener('drop', function (event) { self.onDrop(event); });
    this.svgCanvas.addEventListener('pointerleave', function () { self.updateCoordinates(null); });
    this.svgCanvas.addEventListener('pointermove', function (event) { self.updateCoordinates(event); });
  };

  OracleScreenEditor.prototype.onRootClick = function (event) {
    var actionNode = event.target.closest ? event.target.closest('[data-action]') : null;
    if (actionNode && this.root.contains(actionNode)) {
      this.handleAction(actionNode.dataset.action, actionNode);
      return;
    }
    var partNode = event.target.closest ? event.target.closest('[data-part-type]') : null;
    if (partNode && this.root.contains(partNode)) {
      this.addPart(partNode.dataset.partType);
      return;
    }
    var templateNode = event.target.closest ? event.target.closest('[data-template-key]') : null;
    if (templateNode && this.root.contains(templateNode)) this.loadTemplate(templateNode.dataset.templateKey);
  };

  OracleScreenEditor.prototype.onRootChange = function (event) {
    var target = event.target;
    if (!target || !target.dataset) return;
    if (target.dataset.field) this.updateField(target);
  };

  OracleScreenEditor.prototype.handleAction = function (action, actionNode) {
    if (action === 'mode-edit') this.setMode('edit');
    else if (action === 'mode-runtime') this.setMode('runtime');
    else if (action === 'tool-select') this.setTool('select');
    else if (action === 'tool-pan') this.setTool('pan');
    else if (action === 'tool-connector') this.setTool('connector');
    else if (action === 'undo') this.undo();
    else if (action === 'redo') this.redo();
    else if (action === 'duplicate') this.duplicateSelection();
    else if (action === 'delete') this.deleteSelection();
    else if (action === 'toggle-grid') { this.doc.grid.visible = !this.doc.grid.visible; this.render(); }
    else if (action === 'toggle-snap') { this.doc.grid.snap = !this.doc.grid.snap; this.render(); }
    else if (action === 'zoom-in') this.setZoom(this.zoom * 1.18);
    else if (action === 'zoom-out') this.setZoom(this.zoom / 1.18);
    else if (action === 'fit') this.fitToScreen();
    else if (action === 'save') this.save();
    else if (action === 'validate') this.validate();
    else if (action === 'publish') this.publish();
    else if (action === 'layer-select-all') this.selectLayer(actionNode ? actionNode.dataset.layerId : null);
    else if (action === 'layer-lock') this.toggleLayer(actionNode ? actionNode.dataset.layerId : null, 'locked');
    else if (action === 'layer-hide') this.toggleLayer(actionNode ? actionNode.dataset.layerId : null, 'visible');
  };

  OracleScreenEditor.prototype.setMode = function (mode) {
    if (mode !== 'edit' && mode !== 'runtime') return;
    this.mode = mode;
    this.selectedIds = [];
    this.selectedConnectorIds = [];
    this.setTool('select');
    this.emit('oracle-editor-mode-change', { mode: mode, document: Model.clone(this.doc) });
    this.render();
  };

  OracleScreenEditor.prototype.setTool = function (tool) {
    this.tool = tool;
    var buttons = this.root.querySelectorAll('[data-action^="tool-"]');
    Array.prototype.forEach.call(buttons, function (node) { node.classList.toggle('is-active', node.dataset.action === 'tool-' + tool); });
    this.svgCanvas.classList.toggle('is-pan-tool', tool === 'pan');
    this.svgCanvas.classList.toggle('is-connector-tool', tool === 'connector');
    this.renderCanvas();
  };

  OracleScreenEditor.prototype.renderLibrary = function () {
    var self = this;
    this.libraryList.replaceChildren();
    Model.CATEGORIES.forEach(function (category) {
      var parts = Object.keys(Model.PARTS).map(function (key) { return Model.PARTS[key]; }).filter(function (part) {
        return part.category === category && (!self.libraryFilter || (part.name + ' ' + part.description).toLowerCase().indexOf(self.libraryFilter) !== -1);
      });
      if (!parts.length) return;
      self.libraryList.appendChild(html('div', 'oracle-editor-library-category', category));
      parts.forEach(function (part) {
        var item = html('button', 'oracle-editor-part-card');
        item.type = 'button';
        item.draggable = true;
        item.dataset.partType = part.type;
        item.setAttribute('aria-label', 'Add ' + part.name);
        item.addEventListener('dragstart', function (event) {
          event.dataTransfer.effectAllowed = 'copy';
          event.dataTransfer.setData('application/x-oracle-part', part.type);
        });
        var icon = html('span', 'oracle-editor-part-icon oracle-editor-part-icon-' + part.type, part.type === 'tank' ? '▱' : part.type === 'pump' ? '◉' : part.type === 'valve' ? '◇' : part.type === 'instrument' ? '◌' : part.type === 'pipe' ? '━' : 'T');
        item.appendChild(icon);
        var text = html('span', 'oracle-editor-part-card-text');
        text.appendChild(html('strong', '', part.name));
        text.appendChild(html('small', '', part.description));
        item.appendChild(text);
        self.libraryList.appendChild(item);
      });
    });
  };

  OracleScreenEditor.prototype.renderTemplates = function () {
    var self = this;
    this.templateList.replaceChildren();
    Model.TEMPLATES.forEach(function (template) {
      var item = html('button', 'oracle-editor-template-card');
      item.type = 'button';
      item.dataset.templateKey = template.key;
      item.appendChild(html('span', 'oracle-editor-template-preview', template.key === 'blank' ? '□' : template.key === 'line1' ? '◫' : template.key === 'tankFarm' ? '▥' : '◉'));
      item.appendChild(html('span', '', template.name));
      self.templateList.appendChild(item);
    });
  };

  OracleScreenEditor.prototype.onDrop = function (event) {
    event.preventDefault();
    if (this.mode !== 'edit') return;
    var type = event.dataTransfer.getData('application/x-oracle-part');
    if (!type || !Model.PARTS[type]) return;
    var position = this.screenToWorld(event.clientX, event.clientY);
    this.addPart(type, position);
  };

  OracleScreenEditor.prototype.addPart = function (type, position) {
    if (this.mode !== 'edit' || !Model.PARTS[type]) return;
    var part = Model.PARTS[type];
    var point = position || this.screenToWorld(this.svgCanvas.getBoundingClientRect().left + this.svgCanvas.clientWidth / 2, this.svgCanvas.getBoundingClientRect().top + this.svgCanvas.clientHeight / 2);
    var newFrame = Model.clone(part.defaultFrame);
    newFrame.x = point.x - newFrame.width / 2;
    newFrame.y = point.y - newFrame.height / 2;
    if (this.doc.grid.snap) {
      newFrame.x = Math.round(newFrame.x / this.doc.grid.size) * this.doc.grid.size;
      newFrame.y = Math.round(newFrame.y / this.doc.grid.size) * this.doc.grid.size;
    }
    var self = this;
    this.commit('Add ' + part.name, function () {
      var element = Model.addElement(self.doc, type, { layerId: self.activeLayerId, frame: newFrame });
      self.selectedIds = [element.id];
      self.selectedConnectorIds = [];
    });
    this.announce('Added ' + part.name + '.');
  };

  OracleScreenEditor.prototype.loadTemplate = function (key) {
    if (this.mode !== 'edit') return;
    var self = this;
    this.commit('Load template', function () {
      self.doc = Model.createFromTemplate(key);
      self.activeLayerId = self.doc.layers[0] ? self.doc.layers[0].id : null;
      self.selectedIds = [];
      self.selectedConnectorIds = [];
    });
    this.fitToScreen();
    this.announce('Template loaded.');
  };

  OracleScreenEditor.prototype.commit = function (label, mutator) {
    if (this.mode !== 'edit') return;
    var before = Model.clone(this.doc);
    mutator();
    this.doc.metadata.updatedAt = new Date().toISOString();
    if (same(before, this.doc)) return;
    this.history.push({ label: label, before: before, after: Model.clone(this.doc) });
    if (this.history.length > 80) this.history.shift();
    this.redoStack = [];
    this.validationResult = null;
    this.emit('oracle-editor-change', { label: label, document: Model.clone(this.doc), json: Model.serialize(this.doc) });
    this.render();
  };

  OracleScreenEditor.prototype.recordGesture = function (label, before) {
    if (!before || same(before, this.doc)) return;
    this.doc.metadata.updatedAt = new Date().toISOString();
    this.history.push({ label: label, before: before, after: Model.clone(this.doc) });
    this.redoStack = [];
    this.validationResult = null;
    this.emit('oracle-editor-change', { label: label, document: Model.clone(this.doc), json: Model.serialize(this.doc) });
  };

  OracleScreenEditor.prototype.undo = function () {
    if (this.mode !== 'edit' || !this.history.length) return;
    var item = this.history.pop();
    this.redoStack.push(item);
    this.doc = Model.clone(item.before);
    this.selectedIds = [];
    this.selectedConnectorIds = [];
    this.render();
    this.emit('oracle-editor-change', { label: 'Undo ' + item.label, document: Model.clone(this.doc), json: Model.serialize(this.doc) });
  };

  OracleScreenEditor.prototype.redo = function () {
    if (this.mode !== 'edit' || !this.redoStack.length) return;
    var item = this.redoStack.pop();
    this.history.push(item);
    this.doc = Model.clone(item.after);
    this.render();
    this.emit('oracle-editor-change', { label: 'Redo ' + item.label, document: Model.clone(this.doc), json: Model.serialize(this.doc) });
  };

  OracleScreenEditor.prototype.duplicateSelection = function () {
    if (this.mode !== 'edit' || !this.selectedIds.length) return;
    var self = this;
    var ids = this.selectedIds.slice();
    this.commit('Duplicate selection', function () {
      var copies = ids.map(function (id) {
        var original = self.findElement(id);
        if (!original || original.locked) return null;
        var copy = Model.clone(original);
        copy.id = Model.uid('element');
        copy.frame.x += self.doc.grid.size;
        copy.frame.y += self.doc.grid.size;
        copy.metadata = Object.assign({}, copy.metadata, { createdAt: new Date().toISOString(), duplicatedFrom: original.id });
        self.doc.elements.push(copy);
        return copy.id;
      }).filter(Boolean);
      self.selectedIds = copies;
      self.selectedConnectorIds = [];
    });
    this.announce('Selection duplicated.');
  };

  OracleScreenEditor.prototype.deleteSelection = function () {
    if (this.mode !== 'edit') return;
    var self = this;
    var ids = this.selectedIds.slice();
    var connectorIds = this.selectedConnectorIds.slice();
    if (!ids.length && !connectorIds.length) return;
    this.commit('Delete selection', function () {
      self.doc.elements = self.doc.elements.filter(function (item) { return ids.indexOf(item.id) === -1 || item.locked; });
      self.doc.connectors = self.doc.connectors.filter(function (item) {
        if (connectorIds.indexOf(item.id) !== -1) return false;
        return ids.indexOf(item.source.elementId) === -1 && ids.indexOf(item.target.elementId) === -1;
      });
      self.selectedIds = [];
      self.selectedConnectorIds = [];
    });
    this.announce('Selection deleted.');
  };

  OracleScreenEditor.prototype.findElement = function (id) {
    return this.doc.elements.filter(function (item) { return item.id === id; })[0] || null;
  };

  OracleScreenEditor.prototype.getSelectedElements = function () {
    var self = this;
    return this.selectedIds.map(function (id) { return self.findElement(id); }).filter(Boolean);
  };

  OracleScreenEditor.prototype.selectLayer = function (layerId) {
    if (!layerId) return;
    this.activeLayerId = layerId;
    this.selectedIds = this.doc.elements.filter(function (item) { return item.layerId === layerId; }).map(function (item) { return item.id; });
    this.selectedConnectorIds = [];
    this.render();
  };

  OracleScreenEditor.prototype.toggleLayer = function (layerId, property) {
    if (this.mode !== 'edit' || !layerId) return;
    var self = this;
    this.commit(property === 'locked' ? 'Toggle layer lock' : 'Toggle layer visibility', function () {
      var layer = self.doc.layers.filter(function (item) { return item.id === layerId; })[0];
      if (layer) layer[property] = property === 'visible' ? !layer.visible : !layer.locked;
    });
  };

  OracleScreenEditor.prototype.updateField = function (target) {
    var field = target.dataset.field;
    var self = this;
    if (field === 'screen-name' || field === 'screen-id' || field === 'viewport-background' || field === 'grid-size') {
      this.commit('Update screen ' + field, function () {
        if (field === 'screen-name') self.doc.name = target.value;
        if (field === 'screen-id') self.doc.id = target.value;
        if (field === 'viewport-background') self.doc.viewport.background = target.value;
        if (field === 'grid-size') self.doc.grid.size = Math.max(1, Math.min(100, Number(target.value) || 8));
      });
      return;
    }
    var element = this.findElement(target.dataset.elementId);
    if (!element || element.locked || this.mode !== 'edit') return;
    this.commit('Update ' + field, function () {
      if (field.indexOf('prop:') === 0) element.props[field.slice(5)] = target.value;
      else if (field.indexOf('geometry:') === 0) element.frame[field.slice(9)] = Number(target.value) || 0;
      else if (field.indexOf('style:') === 0) element.style[field.slice(6)] = target.value;
      else if (field === 'layer') element.layerId = target.value;
      else if (field === 'locked') element.locked = target.checked;
      else if (field === 'hidden') element.hidden = target.checked;
      else if (field.indexOf('binding:') === 0) {
        var pieces = field.split(':');
        element.bindings[pieces[1]] = element.bindings[pieces[1]] || {};
        element.bindings[pieces[1]][pieces[2]] = target.value;
      }
    });
  };

  OracleScreenEditor.prototype.onCanvasPointerDown = function (event) {
    if (event.button === 1 || this.tool === 'pan' || this.spacePanning) {
      this.beginPan(event);
      return;
    }
    if (event.button !== 0 || this.mode !== 'edit') return;
    if (event.target === this.svgCanvas || event.target.dataset && event.target.dataset.role === 'canvas-background') {
      if (this.tool === 'connector') {
        this.setTool('select');
        this.announce('Connector cancelled.');
        return;
      }
      var point = this.screenToWorld(event.clientX, event.clientY);
      this.marquee = { start: point, current: point };
      this.svgCanvas.setPointerCapture(event.pointerId);
      this.renderCanvas();
    }
  };

  OracleScreenEditor.prototype.onElementPointerDown = function (event, id) {
    event.stopPropagation();
    var element = this.findElement(id);
    if (!element) return;
    if (this.mode === 'runtime') {
      this.emit('oracle-editor-runtime-select', { elementId: id, document: Model.clone(this.doc), runtimeSnapshot: Model.clone(this.runtimeSnapshot) });
      return;
    }
    if (this.tool === 'connector') {
      this.selectOnly(id);
      return;
    }
    if (element.locked || this.layerFor(element).locked) {
      this.selectOnly(id);
      this.announce('This part is locked.');
      return;
    }
    if (event.shiftKey) {
      if (this.selectedIds.indexOf(id) === -1) this.selectedIds.push(id);
      else this.selectedIds = this.selectedIds.filter(function (item) { return item !== id; });
    } else if (this.selectedIds.indexOf(id) === -1) {
      this.selectOnly(id);
    }
    this.activeLayerId = element.layerId;
    var point = this.screenToWorld(event.clientX, event.clientY);
    this.gesture = {
      type: 'move',
      pointerId: event.pointerId,
      start: point,
      before: Model.clone(this.doc),
      initial: this.getSelectedElements().map(function (item) { return { id: item.id, frame: Model.clone(item.frame) }; })
    };
    this.svgCanvas.setPointerCapture(event.pointerId);
    this.renderCanvas();
  };

  OracleScreenEditor.prototype.onPortPointerDown = function (event, elementId, portId) {
    event.stopPropagation();
    if (this.mode !== 'edit' || this.tool !== 'connector') return;
    if (!this.gesture || this.gesture.type !== 'connector') {
      this.gesture = { type: 'connector', source: { elementId: elementId, portId: portId } };
      this.announce('Source port selected. Select a compatible target port.');
      this.renderCanvas();
      return;
    }
    var source = this.gesture.source;
    if (source.elementId === elementId && source.portId === portId) return;
    var sourceElement = this.findElement(source.elementId);
    var targetElement = this.findElement(elementId);
    var sourcePort = Model.getPort(sourceElement.type, source.portId);
    var targetPort = Model.getPort(targetElement.type, portId);
    var compatible = sourcePort && targetPort && (sourcePort.accepts.indexOf(targetElement.type) !== -1 || targetPort.accepts.indexOf(sourceElement.type) !== -1 || (sourcePort.accepts.indexOf('pipe') !== -1 && targetPort.accepts.indexOf('pipe') !== -1) || sourceElement.type === 'pipe' || targetElement.type === 'pipe');
    if (!compatible) {
      this.announce('Those ports are not compatible.');
      return;
    }
    var self = this;
    this.commit('Add connector', function () {
      self.doc.connectors.push(Model.createConnector({ source: source, target: { elementId: elementId, portId: portId } }));
      self.selectedConnectorIds = [self.doc.connectors[self.doc.connectors.length - 1].id];
      self.selectedIds = [];
    });
    this.gesture = null;
    this.announce('Connector added.');
  };

  OracleScreenEditor.prototype.onHandlePointerDown = function (event, id, handle) {
    event.stopPropagation();
    if (this.mode !== 'edit') return;
    var element = this.findElement(id);
    if (!element || element.locked || this.layerFor(element).locked) return;
    this.gesture = { type: 'resize', pointerId: event.pointerId, elementId: id, handle: handle, start: this.screenToWorld(event.clientX, event.clientY), before: Model.clone(this.doc), initial: Model.clone(element.frame) };
    this.svgCanvas.setPointerCapture(event.pointerId);
  };

  OracleScreenEditor.prototype.onConnectorPointerDown = function (event, id) {
    event.stopPropagation();
    if (this.mode !== 'edit') return;
    this.selectedConnectorIds = [id];
    this.selectedIds = [];
    this.renderCanvas();
  };

  OracleScreenEditor.prototype.onCanvasPointerMove = function (event) {
    if (!this.gesture && !this.marquee) return;
    if (this.gesture && this.gesture.type === 'pan') {
      var rect = this.svgCanvas.getBoundingClientRect();
      this.pan.x = this.gesture.pan.x + ((event.clientX - this.gesture.clientX) / rect.width) * VIEWBOX.width;
      this.pan.y = this.gesture.pan.y + ((event.clientY - this.gesture.clientY) / rect.height) * VIEWBOX.height;
      this.renderCanvas();
      return;
    }
    if (this.gesture && this.gesture.type === 'move') {
      var point = this.screenToWorld(event.clientX, event.clientY);
      var dx = point.x - this.gesture.start.x;
      var dy = point.y - this.gesture.start.y;
      var adjusted = this.snapDelta(dx, dy, this.gesture.initial);
      var self = this;
      this.gesture.initial.forEach(function (initial) {
        var element = self.findElement(initial.id);
        if (element) {
          element.frame.x = initial.frame.x + adjusted.dx;
          element.frame.y = initial.frame.y + adjusted.dy;
        }
      });
      this.guides = adjusted.guides;
      this.renderCanvas();
      return;
    }
    if (this.gesture && this.gesture.type === 'resize') {
      this.resizeElement(event);
      this.renderCanvas();
      return;
    }
    if (this.marquee) {
      this.marquee.current = this.screenToWorld(event.clientX, event.clientY);
      this.renderCanvas();
    }
  };

  OracleScreenEditor.prototype.onCanvasPointerUp = function (event) {
    if (this.gesture && this.gesture.type === 'pan') {
      this.gesture = null;
      return;
    }
    if (this.gesture && this.gesture.type === 'move') {
      this.recordGesture('Move selection', this.gesture.before);
      this.gesture = null;
      this.guides = [];
      this.render();
      return;
    }
    if (this.gesture && this.gesture.type === 'resize') {
      this.recordGesture('Resize part', this.gesture.before);
      this.gesture = null;
      this.render();
      return;
    }
    if (this.marquee) {
      var box = this.rectFromPoints(this.marquee.start, this.marquee.current);
      var additive = event.shiftKey;
      var hits = this.doc.elements.filter(function (element) {
        var bounds = Model.boundsOf(element);
        return bounds.left < box.right && bounds.right > box.left && bounds.top < box.bottom && bounds.bottom > box.top;
      }).map(function (element) { return element.id; });
      this.selectedIds = additive ? Array.from(new Set(this.selectedIds.concat(hits))) : hits;
      this.selectedConnectorIds = [];
      this.marquee = null;
      this.render();
    }
  };

  OracleScreenEditor.prototype.cancelGesture = function () {
    if (this.gesture && this.gesture.before) this.doc = this.gesture.before;
    this.gesture = null;
    this.marquee = null;
    this.guides = [];
    this.render();
  };

  OracleScreenEditor.prototype.beginPan = function (event) {
    this.gesture = { type: 'pan', pointerId: event.pointerId, clientX: event.clientX, clientY: event.clientY, pan: Model.clone(this.pan) };
    this.svgCanvas.setPointerCapture(event.pointerId);
  };

  OracleScreenEditor.prototype.resizeElement = function (event) {
    var gesture = this.gesture;
    var element = this.findElement(gesture.elementId);
    if (!element) return;
    var point = this.screenToWorld(event.clientX, event.clientY);
    var dx = point.x - gesture.start.x;
    var dy = point.y - gesture.start.y;
    var initial = gesture.initial;
    var next = Model.clone(initial);
    var min = Model.PARTS[element.type].minSize;
    if (gesture.handle.indexOf('e') !== -1) next.width = Math.max(min.width, initial.width + dx);
    if (gesture.handle.indexOf('s') !== -1) next.height = Math.max(min.height, initial.height + dy);
    if (gesture.handle.indexOf('w') !== -1) { next.x = initial.x + dx; next.width = Math.max(min.width, initial.width - dx); if (next.width === min.width) next.x = initial.x + initial.width - min.width; }
    if (gesture.handle.indexOf('n') !== -1) { next.y = initial.y + dy; next.height = Math.max(min.height, initial.height - dy); if (next.height === min.height) next.y = initial.y + initial.height - min.height; }
    if (this.doc.grid.snap) {
      next.width = Math.max(min.width, Math.round(next.width / this.doc.grid.size) * this.doc.grid.size);
      next.height = Math.max(min.height, Math.round(next.height / this.doc.grid.size) * this.doc.grid.size);
    }
    element.frame = next;
  };

  OracleScreenEditor.prototype.snapDelta = function (rawDx, rawDy, initialFrames) {
    var selection = this.boundsForFrames(initialFrames);
    var others = this.doc.elements.filter(function (item) { return initialFrames.every(function (initial) { return initial.id !== item.id; }); });
    var bestX = { difference: Infinity, delta: rawDx, guide: null };
    var bestY = { difference: Infinity, delta: rawDy, guide: null };
    var self = this;
    others.forEach(function (other) {
      var bounds = Model.boundsOf(other);
      [[bounds.left, selection.left], [bounds.centerX, selection.centerX], [bounds.right, selection.right]].forEach(function (pair) {
        var desired = pair[0] - pair[1];
        var difference = Math.abs(rawDx - desired);
        if (difference < bestX.difference && difference <= 12) bestX = { difference: difference, delta: desired, guide: { orientation: 'vertical', value: pair[0] } };
      });
      [[bounds.top, selection.top], [bounds.centerY, selection.centerY], [bounds.bottom, selection.bottom]].forEach(function (pair) {
        var desired = pair[0] - pair[1];
        var difference = Math.abs(rawDy - desired);
        if (difference < bestY.difference && difference <= 12) bestY = { difference: difference, delta: desired, guide: { orientation: 'horizontal', value: pair[0] } };
      });
    });
    var dx = bestX.delta;
    var dy = bestY.delta;
    if (this.doc.grid.snap) {
      if (!bestX.guide) dx = Math.round((selection.left + rawDx) / this.doc.grid.size) * this.doc.grid.size - selection.left;
      if (!bestY.guide) dy = Math.round((selection.top + rawDy) / this.doc.grid.size) * this.doc.grid.size - selection.top;
    }
    var guides = [];
    if (bestX.guide) guides.push(bestX.guide);
    if (bestY.guide) guides.push(bestY.guide);
    return { dx: dx, dy: dy, guides: guides };
  };

  OracleScreenEditor.prototype.boundsForFrames = function (frames) {
    var left = Infinity; var top = Infinity; var right = -Infinity; var bottom = -Infinity;
    frames.forEach(function (item) {
      left = Math.min(left, item.frame.x); top = Math.min(top, item.frame.y);
      right = Math.max(right, item.frame.x + item.frame.width); bottom = Math.max(bottom, item.frame.y + item.frame.height);
    });
    return { left: left, top: top, right: right, bottom: bottom, centerX: (left + right) / 2, centerY: (top + bottom) / 2 };
  };

  OracleScreenEditor.prototype.rectFromPoints = function (a, b) {
    return { left: Math.min(a.x, b.x), top: Math.min(a.y, b.y), right: Math.max(a.x, b.x), bottom: Math.max(a.y, b.y) };
  };

  OracleScreenEditor.prototype.selectOnly = function (id) {
    this.selectedIds = id ? [id] : [];
    this.selectedConnectorIds = [];
  };

  OracleScreenEditor.prototype.onKeyDown = function (event) {
    var target = event.target;
    var editingText = target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable);
    if (event.key === 'Escape') { this.cancelGesture(); this.setTool('select'); return; }
    if (editingText) return;
    if (event.key.toLowerCase() === 'v') this.setTool('select');
    if (event.key.toLowerCase() === 'h') this.setTool('pan');
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'z') { event.preventDefault(); event.shiftKey ? this.redo() : this.undo(); return; }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'y') { event.preventDefault(); this.redo(); return; }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'd') { event.preventDefault(); this.duplicateSelection(); return; }
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a') { event.preventDefault(); this.selectedIds = this.doc.elements.map(function (item) { return item.id; }); this.renderCanvas(); return; }
    if (event.key === 'Delete' || event.key === 'Backspace') { event.preventDefault(); this.deleteSelection(); return; }
    if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].indexOf(event.key) !== -1 && this.mode === 'edit') {
      event.preventDefault();
      var amount = event.shiftKey ? this.doc.grid.size * 10 : this.doc.grid.size;
      var dx = event.key === 'ArrowLeft' ? -amount : event.key === 'ArrowRight' ? amount : 0;
      var dy = event.key === 'ArrowUp' ? -amount : event.key === 'ArrowDown' ? amount : 0;
      var self = this;
      this.commit('Nudge selection', function () { self.getSelectedElements().forEach(function (item) { if (!item.locked) { item.frame.x += dx; item.frame.y += dy; } }); });
    }
  };

  OracleScreenEditor.prototype.onWheel = function (event) {
    event.preventDefault();
    var anchor = this.screenToWorld(event.clientX, event.clientY);
    var nextZoom = Model.clamp(this.zoom * (event.deltaY < 0 ? 1.1 : 0.9), 0.18, 3.5);
    var screen = this.viewBoxPoint(event.clientX, event.clientY);
    this.zoom = nextZoom;
    this.pan.x = screen.x - anchor.x * this.zoom;
    this.pan.y = screen.y - anchor.y * this.zoom;
    this.renderCanvas();
  };

  OracleScreenEditor.prototype.viewBoxPoint = function (clientX, clientY) {
    var rect = this.svgCanvas.getBoundingClientRect();
    return { x: ((clientX - rect.left) / rect.width) * VIEWBOX.width, y: ((clientY - rect.top) / rect.height) * VIEWBOX.height };
  };

  OracleScreenEditor.prototype.screenToWorld = function (clientX, clientY) {
    var screen = this.viewBoxPoint(clientX, clientY);
    return { x: (screen.x - this.pan.x) / this.zoom, y: (screen.y - this.pan.y) / this.zoom };
  };

  OracleScreenEditor.prototype.setZoom = function (zoom) {
    this.zoom = Model.clamp(zoom, 0.18, 3.5);
    this.renderCanvas();
  };

  OracleScreenEditor.prototype.fitToScreen = function () {
    var rect = this.svgCanvas.getBoundingClientRect();
    var width = rect.width || 900;
    var height = rect.height || 600;
    this.zoom = Model.clamp(Math.min((width / rect.width) * (VIEWBOX.width / this.doc.viewport.width), (height / rect.height) * (VIEWBOX.height / this.doc.viewport.height)) * 0.92, 0.18, 3.5);
    if (!Number.isFinite(this.zoom) || this.zoom <= 0) this.zoom = 0.45;
    this.pan.x = (VIEWBOX.width - this.doc.viewport.width * this.zoom) / 2;
    this.pan.y = (VIEWBOX.height - this.doc.viewport.height * this.zoom) / 2;
    this.renderCanvas();
  };

  OracleScreenEditor.prototype.layerFor = function (element) {
    return this.doc.layers.filter(function (layer) { return layer.id === element.layerId; })[0] || { locked: false, visible: true };
  };

  OracleScreenEditor.prototype.bindingValue = function (element, slot) {
    var binding = element.bindings && element.bindings[slot];
    if (!binding || !binding.tagKey || !this.runtimeSnapshot) return undefined;
    var tags = this.runtimeSnapshot.tags || {};
    var tag = tags[binding.tagKey] || readPath(tags, binding.tagKey);
    return tag && typeof tag === 'object' && Object.prototype.hasOwnProperty.call(tag, 'value') ? tag.value : tag;
  };

  OracleScreenEditor.prototype.render = function () {
    this.renderCanvas();
    this.renderInspector();
    this.renderStatus();
    this.root.querySelectorAll('[data-action="mode-edit"]').forEach(function (node) { node.classList.toggle('is-active', this.mode === 'edit'); }, this);
    this.root.querySelectorAll('[data-action="mode-runtime"]').forEach(function (node) { node.classList.toggle('is-active', this.mode === 'runtime'); }, this);
  };

  OracleScreenEditor.prototype.renderCanvas = function () {
    var self = this;
    this.svgCanvas.replaceChildren();
    this.svgCanvas.setAttribute('aria-label', this.doc.name + ' process screen canvas, ' + this.mode + ' mode');
    var defs = svg('defs');
    var pattern = svg('pattern', { id: 'oracle-editor-grid', width: this.doc.grid.size, height: this.doc.grid.size, patternUnits: 'userSpaceOnUse' });
    pattern.appendChild(svg('path', { d: 'M ' + this.doc.grid.size + ' 0 L 0 0 0 ' + this.doc.grid.size, fill: 'none', stroke: '#173244', 'stroke-width': 0.8 }));
    defs.appendChild(pattern);
    var filter = svg('filter', { id: 'oracle-editor-glow' });
    filter.appendChild(svg('feGaussianBlur', { stdDeviation: 3, result: 'blur' }));
    defs.appendChild(filter);
    this.svgCanvas.appendChild(defs);
    var world = svg('g', { class: 'oracle-editor-world', transform: 'translate(' + this.pan.x + ' ' + this.pan.y + ') scale(' + this.zoom + ')' });
    var background = svg('rect', { x: 0, y: 0, width: this.doc.viewport.width, height: this.doc.viewport.height, fill: this.doc.viewport.background, 'data-role': 'canvas-background' });
    world.appendChild(background);
    if (this.doc.grid.visible) world.appendChild(svg('rect', { x: 0, y: 0, width: this.doc.viewport.width, height: this.doc.viewport.height, fill: 'url(#oracle-editor-grid)', opacity: 0.75, 'pointer-events': 'none' }));
    var connectorLayer = svg('g', { class: 'oracle-editor-connectors' });
    this.doc.connectors.forEach(function (connector) { self.renderConnector(connectorLayer, connector); });
    world.appendChild(connectorLayer);
    var elementLayer = svg('g', { class: 'oracle-editor-elements' });
    this.doc.layers.slice().sort(function (a, b) { return a.zIndex - b.zIndex; }).forEach(function (layer) {
      if (!layer.visible) return;
      self.doc.elements.filter(function (element) { return element.layerId === layer.id && !element.hidden; }).forEach(function (element) { self.renderElement(elementLayer, element); });
    });
    world.appendChild(elementLayer);
    var guideLayer = svg('g', { class: 'oracle-editor-guides' });
    this.guides.forEach(function (guide) {
      if (guide.orientation === 'vertical') guideLayer.appendChild(svg('line', { x1: guide.value, y1: 0, x2: guide.value, y2: self.doc.viewport.height, class: 'oracle-editor-guide' }));
      else guideLayer.appendChild(svg('line', { x1: 0, y1: guide.value, x2: self.doc.viewport.width, y2: guide.value, class: 'oracle-editor-guide' }));
    });
    if (this.marquee) {
      var box = this.rectFromPoints(this.marquee.start, this.marquee.current);
      guideLayer.appendChild(svg('rect', { x: box.left, y: box.top, width: Math.max(1, box.right - box.left), height: Math.max(1, box.bottom - box.top), class: 'oracle-editor-marquee' }));
    }
    this.renderSelection(guideLayer);
    world.appendChild(guideLayer);
    this.svgCanvas.appendChild(world);
  };

  OracleScreenEditor.prototype.renderElement = function (parent, element) {
    var self = this;
    var selected = this.selectedIds.indexOf(element.id) !== -1;
    var group = svg('g', { class: 'oracle-editor-element oracle-editor-element-' + element.type + (selected ? ' is-selected' : '') + (element.locked ? ' is-locked' : ''), transform: 'translate(' + element.frame.x + ' ' + element.frame.y + ') rotate(' + element.frame.rotation + ' ' + element.frame.width / 2 + ' ' + element.frame.height / 2 + ')', 'data-element-id': element.id, tabindex: '0', role: 'img', 'aria-label': (element.props.label || element.type) + (element.locked ? ', locked' : '') });
    group.addEventListener('pointerdown', function (event) { self.onElementPointerDown(event, element.id); });
    group.addEventListener('keydown', function (event) { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); self.onElementPointerDown(event, element.id); } });
    var w = element.frame.width; var h = element.frame.height;
    var fill = element.style.fill || '#0b2535'; var stroke = element.style.stroke || '#4a839d';
    if (element.type === 'tank') {
      group.appendChild(svg('rect', { x: 5, y: 12, width: w - 10, height: h - 24, rx: 12, fill: fill, stroke: stroke, 'stroke-width': element.style.strokeWidth }));
      group.appendChild(svg('ellipse', { cx: w / 2, cy: 12, rx: (w - 10) / 2, ry: 12, fill: fill, stroke: stroke, 'stroke-width': element.style.strokeWidth }));
      group.appendChild(svg('ellipse', { cx: w / 2, cy: h - 12, rx: (w - 10) / 2, ry: 12, fill: fill, stroke: stroke, 'stroke-width': element.style.strokeWidth }));
      var level = Number(this.bindingValue(element, 'level'));
      if (Number.isFinite(level)) {
        var levelHeight = Math.max(0, Math.min(100, level)) / 100 * (h - 32);
        group.appendChild(svg('rect', { x: 10, y: h - 16 - levelHeight, width: w - 20, height: levelHeight, fill: '#2ab8cb', opacity: 0.55, 'pointer-events': 'none' }));
        group.appendChild(svg('text', { x: w - 12, y: h - 22, class: 'oracle-editor-value-label', 'text-anchor': 'end' }, String(Math.round(level * 10) / 10) + '%'));
      }
    } else if (element.type === 'pump') {
      group.appendChild(svg('circle', { cx: w / 2, cy: h / 2, r: Math.min(w, h) * 0.28, fill: fill, stroke: stroke, 'stroke-width': element.style.strokeWidth }));
      group.appendChild(svg('path', { d: 'M ' + (w * 0.42) + ' ' + (h * 0.34) + ' L ' + (w * 0.68) + ' ' + (h * 0.5) + ' L ' + (w * 0.42) + ' ' + (h * 0.66) + ' Z', fill: '#b9f4f5' }));
      group.appendChild(svg('path', { d: 'M 10 ' + (h * 0.5) + ' H ' + (w * 0.22) + ' M ' + (w * 0.78) + ' ' + (h * 0.5) + ' H ' + (w - 10), stroke: stroke, 'stroke-width': 8, 'stroke-linecap': 'round' }));
      var running = this.bindingValue(element, 'run');
      if (running !== undefined) group.appendChild(svg('circle', { cx: w - 18, cy: 16, r: 6, class: running ? 'oracle-editor-status-good' : 'oracle-editor-status-off' }));
    } else if (element.type === 'valve') {
      group.appendChild(svg('path', { d: 'M 12 ' + (h / 2) + ' L ' + (w / 2 - 4) + ' 12 L ' + (w / 2 - 4) + ' ' + (h - 12) + ' Z', fill: fill, stroke: stroke, 'stroke-width': element.style.strokeWidth }));
      group.appendChild(svg('path', { d: 'M ' + (w - 12) + ' ' + (h / 2) + ' L ' + (w / 2 + 4) + ' 12 L ' + (w / 2 + 4) + ' ' + (h - 12) + ' Z', fill: fill, stroke: stroke, 'stroke-width': element.style.strokeWidth }));
      group.appendChild(svg('line', { x1: w / 2, y1: 12, x2: w / 2, y2: 0, stroke: '#b9f4f5', 'stroke-width': 3 }));
      var open = this.bindingValue(element, 'open');
      if (open !== undefined) group.appendChild(svg('circle', { cx: w - 16, cy: 14, r: 6, class: open ? 'oracle-editor-status-good' : 'oracle-editor-status-off' }));
    } else if (element.type === 'instrument') {
      group.appendChild(svg('circle', { cx: w / 2, cy: h / 2 - 4, r: Math.min(w, h) * 0.33, fill: fill, stroke: stroke, 'stroke-width': element.style.strokeWidth }));
      var value = this.bindingValue(element, 'value');
      group.appendChild(svg('text', { x: w / 2, y: h / 2 + 5, class: 'oracle-editor-instrument-value', 'text-anchor': 'middle' }, value === undefined ? '—' : String(Math.round(Number(value) * 10) / 10)));
      group.appendChild(svg('text', { x: w / 2, y: h - 8, class: 'oracle-editor-unit-label', 'text-anchor': 'middle' }, (element.bindings.value && element.bindings.value.displayUnit) || ''));
    } else if (element.type === 'pipe') {
      group.appendChild(svg('rect', { x: 0, y: h * 0.25, width: w, height: h * 0.5, rx: h * 0.2, fill: fill, stroke: stroke, 'stroke-width': element.style.strokeWidth }));
      group.appendChild(svg('path', { d: 'M ' + (w * 0.56) + ' ' + (h * 0.38) + ' L ' + (w * 0.76) + ' ' + (h / 2) + ' L ' + (w * 0.56) + ' ' + (h * 0.62), fill: 'none', stroke: '#9fe8ef', 'stroke-width': 2 }));
    } else if (element.type === 'text') {
      group.appendChild(svg('text', { x: 0, y: Math.max(20, Number(element.style.fontSize) || 18), fill: element.style.fill || '#e9f7ff', 'font-size': element.style.fontSize || 18, 'font-family': element.style.fontFamily, 'font-weight': '600' }, element.props.text || element.props.label || 'Text'));
    }
    if (element.type !== 'text' && element.props.label) group.appendChild(svg('text', { x: w / 2, y: h + 20, class: 'oracle-editor-label', 'text-anchor': 'middle' }, element.props.label));
    if (this.mode === 'runtime' && element.bindings && Object.keys(element.bindings).length) group.appendChild(svg('rect', { x: 3, y: 3, width: Math.max(1, w - 6), height: Math.max(1, h - 6), class: 'oracle-editor-runtime-overlay' }));
    if ((selected || this.tool === 'connector') && this.mode === 'edit') this.renderPorts(group, element);
    parent.appendChild(group);
  };

  OracleScreenEditor.prototype.renderPorts = function (group, element) {
    var self = this;
    var part = Model.PARTS[element.type];
    if (!part) return;
    part.ports.forEach(function (port) {
      var position = Model.portPosition(element, port.id);
      var localX = position.x - element.frame.x; var localY = position.y - element.frame.y;
      var portNode = svg('circle', { cx: localX, cy: localY, r: 8, class: 'oracle-editor-port', tabindex: '0', 'data-port-id': port.id, 'aria-label': port.label + ' port' });
      portNode.addEventListener('pointerdown', function (event) { self.onPortPointerDown(event, element.id, port.id); });
      group.appendChild(portNode);
    });
  };

  OracleScreenEditor.prototype.renderConnector = function (parent, connector) {
    var self = this;
    var source = this.findElement(connector.source.elementId);
    var target = this.findElement(connector.target.elementId);
    if (!source || !target) return;
    var a = Model.portPosition(source, connector.source.portId);
    var b = Model.portPosition(target, connector.target.portId);
    if (!a || !b) return;
    var midX = (a.x + b.x) / 2;
    var points = [a, { x: midX, y: a.y }, { x: midX, y: b.y }, b];
    if (connector.waypoints && connector.waypoints.length) points = [a].concat(connector.waypoints).concat([b]);
    var d = points.map(function (point, index) { return (index ? 'L ' : 'M ') + point.x + ' ' + point.y; }).join(' ');
    var selected = this.selectedConnectorIds.indexOf(connector.id) !== -1;
    var hit = svg('path', { d: d, class: 'oracle-editor-connector-hit', fill: 'none', 'data-connector-id': connector.id });
    hit.addEventListener('pointerdown', function (event) { self.onConnectorPointerDown(event, connector.id); });
    parent.appendChild(hit);
    parent.appendChild(svg('path', { d: d, class: 'oracle-editor-connector' + (selected ? ' is-selected' : ''), fill: 'none', stroke: connector.style.stroke, 'stroke-width': connector.style.strokeWidth, 'stroke-linejoin': 'round', 'stroke-linecap': 'round', 'pointer-events': 'none' }));
  };

  OracleScreenEditor.prototype.renderSelection = function (parent) {
    var self = this;
    var selected = this.getSelectedElements();
    if (!selected.length || this.mode !== 'edit') return;
    var bounds = this.boundsForFrames(selected.map(function (item) { return { id: item.id, frame: item.frame }; }));
    parent.appendChild(svg('rect', { x: bounds.left - 6, y: bounds.top - 6, width: bounds.right - bounds.left + 12, height: bounds.bottom - bounds.top + 12, class: 'oracle-editor-selection-box' }));
    if (selected.length === 1 && !selected[0].locked && !this.layerFor(selected[0]).locked) {
      ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'].forEach(function (handle) {
        var x = handle.indexOf('w') !== -1 ? bounds.left : handle.indexOf('e') !== -1 ? bounds.right : (bounds.left + bounds.right) / 2;
        var y = handle.indexOf('n') !== -1 ? bounds.top : handle.indexOf('s') !== -1 ? bounds.bottom : (bounds.top + bounds.bottom) / 2;
        var handleNode = svg('rect', { x: x - 6, y: y - 6, width: 12, height: 12, class: 'oracle-editor-resize-handle', 'data-handle': handle, 'data-element-id': selected[0].id, tabindex: '0', 'aria-label': 'Resize ' + handle });
        handleNode.addEventListener('pointerdown', function (event) { self.onHandlePointerDown(event, selected[0].id, handle); });
        parent.appendChild(handleNode);
      });
    }
  };

  OracleScreenEditor.prototype.renderInspector = function () {
    var self = this;
    this.inspector.replaceChildren();
    var heading = html('div', 'oracle-editor-panel-heading', this.selectedIds.length === 1 ? 'Properties' : 'Screen Properties');
    this.inspector.appendChild(heading);
    if (this.selectedIds.length === 1) {
      var element = this.findElement(this.selectedIds[0]);
      if (element) this.renderElementInspector(element);
    } else {
      this.inspector.appendChild(labelFor('Screen name', this.fieldInput('screen-name', this.doc.name)));
      this.inspector.appendChild(labelFor('Screen ID', this.fieldInput('screen-id', this.doc.id)));
      this.inspector.appendChild(labelFor('Canvas background', this.fieldInput('viewport-background', this.doc.viewport.background, 'color')));
      this.inspector.appendChild(labelFor('Grid size', this.fieldInput('grid-size', this.doc.grid.size, 'number')));
      var info = html('div', 'oracle-editor-inspector-note');
      info.appendChild(html('strong', '', 'Selection'));
      info.appendChild(html('span', '', this.selectedIds.length ? this.selectedIds.length + ' parts selected.' : 'Click a part or drag a marquee to inspect it.'));
      info.appendChild(html('span', '', 'Runtime mode is read-only and emits integration events only; it never executes equipment commands.'));
      this.inspector.appendChild(info);
    }
    this.renderLayers();
    if (this.validationResult) this.renderValidation(this.validationResult);
    return self;
  };

  OracleScreenEditor.prototype.fieldInput = function (field, value, type) {
    var node = input(type || 'text', value);
    node.dataset.field = field;
    return node;
  };

  OracleScreenEditor.prototype.renderElementInspector = function (element) {
    var self = this;
    var part = Model.PARTS[element.type];
    var title = html('div', 'oracle-editor-inspector-title');
    title.appendChild(html('span', 'oracle-editor-inspector-type', part ? part.name : element.type));
    title.appendChild(html('code', '', element.id));
    this.inspector.appendChild(title);
    var identity = html('div', 'oracle-editor-inspector-section');
    identity.appendChild(html('div', 'oracle-editor-subheading', 'Identity'));
    identity.appendChild(labelFor('Label', this.elementField(element, 'prop:label', element.props.label || '')));
    identity.appendChild(labelFor('Description', this.elementField(element, 'prop:description', element.props.description || '')));
    if (element.type === 'text') identity.appendChild(labelFor('Text', this.elementField(element, 'prop:text', element.props.text || element.props.label || '')));
    if (element.type === 'instrument') identity.appendChild(labelFor('Value format', this.elementField(element, 'prop:valueFormat', element.props.valueFormat || '0.0')));
    this.inspector.appendChild(identity);

    var geometry = html('div', 'oracle-editor-inspector-section');
    geometry.appendChild(html('div', 'oracle-editor-subheading', 'Geometry'));
    var row1 = html('div', 'oracle-editor-field-row');
    row1.appendChild(labelFor('X', this.elementField(element, 'geometry:x', element.frame.x, 'number')));
    row1.appendChild(labelFor('Y', this.elementField(element, 'geometry:y', element.frame.y, 'number')));
    geometry.appendChild(row1);
    var row2 = html('div', 'oracle-editor-field-row');
    row2.appendChild(labelFor('Width', this.elementField(element, 'geometry:width', element.frame.width, 'number')));
    row2.appendChild(labelFor('Height', this.elementField(element, 'geometry:height', element.frame.height, 'number')));
    geometry.appendChild(row2);
    geometry.appendChild(labelFor('Rotation', this.elementField(element, 'geometry:rotation', element.frame.rotation, 'number')));
    this.inspector.appendChild(geometry);

    var appearance = html('div', 'oracle-editor-inspector-section');
    appearance.appendChild(html('div', 'oracle-editor-subheading', 'Appearance'));
    var colorRow = html('div', 'oracle-editor-field-row');
    colorRow.appendChild(labelFor('Fill', this.elementField(element, 'style:fill', element.style.fill, 'color')));
    colorRow.appendChild(labelFor('Stroke', this.elementField(element, 'style:stroke', element.style.stroke, 'color')));
    appearance.appendChild(colorRow);
    var styleRow = html('div', 'oracle-editor-field-row');
    styleRow.appendChild(labelFor('Line', this.elementField(element, 'style:strokeWidth', element.style.strokeWidth, 'number')));
    styleRow.appendChild(labelFor('Font', this.elementField(element, 'style:fontSize', element.style.fontSize, 'number')));
    appearance.appendChild(styleRow);
    this.inspector.appendChild(appearance);

    if (part && Object.keys(part.bindings || {}).length) {
      var bindings = html('div', 'oracle-editor-inspector-section');
      bindings.appendChild(html('div', 'oracle-editor-subheading', 'Tag bindings'));
      Object.keys(part.bindings).forEach(function (slot) {
        var binding = element.bindings[slot] || {};
        var slotBox = html('div', 'oracle-editor-binding');
        slotBox.appendChild(html('span', 'oracle-editor-binding-label', part.bindings[slot].label + ' (' + slot + ')'));
        slotBox.appendChild(labelFor('Tag key', self.elementField(element, 'binding:' + slot + ':tagKey', binding.tagKey || '')));
        slotBox.appendChild(labelFor('Display unit', self.elementField(element, 'binding:' + slot + ':displayUnit', binding.displayUnit || part.bindings[slot].unit || '')));
        bindings.appendChild(slotBox);
      });
      var bindingNote = html('div', 'oracle-editor-inspector-note');
      bindingNote.textContent = 'Bindings are metadata for runtime visualization. The editor does not read PLCs or execute control commands.';
      bindings.appendChild(bindingNote);
      this.inspector.appendChild(bindings);
    }

    var layout = html('div', 'oracle-editor-inspector-section');
    layout.appendChild(html('div', 'oracle-editor-subheading', 'Layout & access'));
    var layerSelect = global.document.createElement('select');
    layerSelect.className = 'oracle-editor-input'; layerSelect.dataset.field = 'layer'; layerSelect.dataset.elementId = element.id;
    this.doc.layers.slice().sort(function (a, b) { return a.zIndex - b.zIndex; }).forEach(function (layer) { var option = html('option', '', layer.name); option.value = layer.id; option.selected = layer.id === element.layerId; layerSelect.appendChild(option); });
    layout.appendChild(labelFor('Layer', layerSelect));
    layout.appendChild(this.checkboxField('Locked', element.locked, 'locked', element.id));
    layout.appendChild(this.checkboxField('Hidden', element.hidden, 'hidden', element.id));
    this.inspector.appendChild(layout);
  };

  OracleScreenEditor.prototype.elementField = function (element, field, value, type) {
    var node = input(type || 'text', value);
    node.dataset.field = field; node.dataset.elementId = element.id;
    if (type === 'number') node.step = 'any';
    return node;
  };

  OracleScreenEditor.prototype.checkboxField = function (label, checked, field, id) {
    var wrapper = html('label', 'oracle-editor-check-row');
    var node = global.document.createElement('input'); node.type = 'checkbox'; node.checked = checked; node.dataset.field = field; node.dataset.elementId = id;
    wrapper.appendChild(node); wrapper.appendChild(html('span', '', label)); return wrapper;
  };

  OracleScreenEditor.prototype.renderLayers = function () {
    var self = this;
    var section = html('div', 'oracle-editor-inspector-section oracle-editor-layers-section');
    section.appendChild(html('div', 'oracle-editor-subheading', 'Layers'));
    this.doc.layers.slice().sort(function (a, b) { return b.zIndex - a.zIndex; }).forEach(function (layer) {
      var row = html('div', 'oracle-editor-layer-row' + (self.activeLayerId === layer.id ? ' is-active' : ''));
      var select = button(layer.name, 'layer-select-all', '', 'Select all parts on ' + layer.name); select.dataset.layerId = layer.id;
      row.appendChild(select);
      var lock = button(layer.locked ? '🔒' : '🔓', 'layer-lock', 'icon', layer.locked ? 'Unlock layer' : 'Lock layer'); lock.dataset.layerId = layer.id; lock.setAttribute('aria-label', lock.title); row.appendChild(lock);
      var hide = button(layer.visible ? '◉' : '○', 'layer-hide', 'icon', layer.visible ? 'Hide layer' : 'Show layer'); hide.dataset.layerId = layer.id; hide.setAttribute('aria-label', hide.title); row.appendChild(hide);
      section.appendChild(row);
    });
    this.inspector.appendChild(section);
  };

  OracleScreenEditor.prototype.renderValidation = function (result) {
    var box = html('div', 'oracle-editor-validation-box ' + (result.valid ? 'is-valid' : 'has-errors'));
    box.appendChild(html('strong', '', result.valid ? 'Screen is valid' : 'Screen needs attention'));
    if (result.errors.length) {
      var errors = html('ul', 'oracle-editor-validation-list');
      result.errors.forEach(function (issue) { errors.appendChild(html('li', '', issue.message)); });
      box.appendChild(errors);
    }
    if (result.warnings.length) {
      var warnings = html('ul', 'oracle-editor-validation-list warnings');
      result.warnings.slice(0, 5).forEach(function (issue) { warnings.appendChild(html('li', '', issue.message)); });
      box.appendChild(warnings);
    }
    this.inspector.appendChild(box);
  };

  OracleScreenEditor.prototype.renderStatus = function () {
    this.root.querySelector('.oracle-editor-screen-name').textContent = this.doc.name + '  /  ' + this.mode.toUpperCase();
    this.status.querySelector('.oracle-editor-status-text').textContent = this.mode === 'runtime' ? 'Published visual preview • read-only' : 'Draft editing • local changes';
    this.status.querySelector('.oracle-editor-status-coordinates').textContent = 'Zoom ' + Math.round(this.zoom * 100) + '%  •  ' + this.selectedIds.length + ' selected';
    var validationText = this.validationResult ? (this.validationResult.valid ? '✓ Valid' : '⚠ ' + this.validationResult.errors.length + ' error(s)') : 'Not validated';
    this.status.querySelector('.oracle-editor-status-validation').textContent = validationText;
    var gridButton = this.root.querySelector('[data-action="toggle-grid"]'); if (gridButton) gridButton.classList.toggle('is-active', this.doc.grid.visible);
    var snapButton = this.root.querySelector('[data-action="toggle-snap"]'); if (snapButton) snapButton.classList.toggle('is-active', this.doc.grid.snap);
  };

  OracleScreenEditor.prototype.updateCoordinates = function (event) {
    var node = this.status.querySelector('.oracle-editor-status-coordinates');
    if (!event) { node.textContent = 'Zoom ' + Math.round(this.zoom * 100) + '%'; return; }
    var point = this.screenToWorld(event.clientX, event.clientY);
    node.textContent = 'X ' + Math.round(point.x) + '  Y ' + Math.round(point.y) + '  •  Zoom ' + Math.round(this.zoom * 100) + '%';
  };

  OracleScreenEditor.prototype.validate = function () {
    this.validationResult = Model.validate(this.doc, this.tagCatalog);
    this.render();
    this.emit('oracle-editor-validate', { document: Model.clone(this.doc), result: Model.clone(this.validationResult), json: Model.serialize(this.doc) });
    this.announce(this.validationResult.valid ? 'Screen validation passed.' : 'Screen validation found errors.');
    return this.validationResult;
  };

  OracleScreenEditor.prototype.save = function () {
    this.emit('oracle-editor-save', { document: Model.clone(this.doc), json: Model.serialize(this.doc), mode: this.mode });
    this.announce('Save event emitted for integration.');
  };

  OracleScreenEditor.prototype.publish = function () {
    var result = this.validate();
    if (!result.valid) return result;
    var self = this;
    this.commit('Publish screen', function () { self.doc.status = 'published'; self.doc.revision += 1; });
    this.emit('oracle-editor-publish', { document: Model.clone(this.doc), json: Model.serialize(this.doc), revision: this.doc.revision, result: Model.clone(result) });
    this.announce('Publish event emitted for integration.');
    return result;
  };

  OracleScreenEditor.prototype.setRuntimeSnapshot = function (snapshot) {
    this.runtimeSnapshot = Model.clone(snapshot);
    if (this.mode === 'runtime') this.renderCanvas();
  };

  OracleScreenEditor.prototype.serialize = function (pretty) {
    return Model.serialize(this.doc, pretty);
  };

  OracleScreenEditor.prototype.deserialize = function (json) {
    this.loadDocument(json);
  };

  OracleScreenEditor.prototype.loadDocument = function (json) {
    this.doc = Model.deserialize(json);
    this.history = [];
    this.redoStack = [];
    this.selectedIds = [];
    this.selectedConnectorIds = [];
    this.activeLayerId = this.doc.layers[0] ? this.doc.layers[0].id : null;
    this.validationResult = null;
    this.render();
    this.emit('oracle-editor-load', { document: Model.clone(this.doc), json: Model.serialize(this.doc) });
  };

  OracleScreenEditor.prototype.emit = function (name, detail) {
    this.root.dispatchEvent(new global.CustomEvent(name, { bubbles: true, detail: detail }));
  };

  OracleScreenEditor.prototype.announce = function (message) {
    var live = this.root.querySelector('[data-role="canvas-live"]');
    if (live) live.textContent = message;
  };

  OracleScreenEditor.prototype.destroy = function () {
    this.root.replaceChildren();
    this.root.className = '';
  };

  function init() {
    var root = global.document.querySelector('#screen-editor-root');
    if (!root || root.__oracleScreenEditor) return root ? root.__oracleScreenEditor : null;
    root.__oracleScreenEditor = new OracleScreenEditor(root);
    return root.__oracleScreenEditor;
  }

  global.OracleScreenEditor = OracleScreenEditor;
  global.initOracleScreenEditor = init;
  if (global.document.readyState === 'loading') global.document.addEventListener('DOMContentLoaded', init);
  else init();
}(window));
