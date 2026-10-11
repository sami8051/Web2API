var origin = window.location.origin;
document.getElementById('openai-url').textContent = origin + '/v1';

// ======Settings=========
var AUTH_STORAGE_KEY = 'wta-auth-token';
// ======Settings=========

var dashboardAuthRequired = false;

function getAuthToken() {
  return localStorage.getItem(AUTH_STORAGE_KEY) || '';
}

function setAuthToken(token) {
  var trimmed = (token || '').trim();
  if (trimmed) localStorage.setItem(AUTH_STORAGE_KEY, trimmed);
  else localStorage.removeItem(AUTH_STORAGE_KEY);
}

function initAuthFromUrl() {
  var params = new URLSearchParams(window.location.search);
  var token = params.get('token');
  if (!token) return;
  setAuthToken(token);
  params.delete('token');
  var qs = params.toString();
  history.replaceState(null, '', window.location.pathname + (qs ? '?' + qs : '') + window.location.hash);
}

function apiHeaders(base) {
  var headers = base ? Object.assign({}, base) : {};
  var token = getAuthToken();
  if (token && !headers.Authorization && !headers.authorization) {
    headers.Authorization = 'Bearer ' + token;
  }
  return headers;
}

function apiFetch(url, options) {
  options = options || {};
  options.headers = apiHeaders(options.headers);
  return fetch(url, options);
}

async function loadDashboardConfig() {
  try {
    var res = await apiFetch('/dashboard/config.json');
    if (!res.ok) return;
    var cfg = await res.json();
    dashboardAuthRequired = Boolean(cfg.authRequired);
    updateAuthUi();
  } catch (e) {
    /* ignore */
  }
}

function updateAuthUi() {
  var block = document.getElementById('api-auth-block');
  var divider = document.getElementById('api-auth-divider');
  if (!block) return;
  var visible = dashboardAuthRequired || Boolean(getAuthToken());
  block.classList.toggle('hidden', !visible);
  if (divider) divider.classList.toggle('hidden', !visible);
}

async function saveApiAuthToken() {
  var input = document.getElementById('api-auth-token');
  setAuthToken(input.value);
  showToast('API token saved');
  updateAuthUi();
  loadSettings();
  loadProviders();
  loadHealth();
}

var providerOrigins = {
  'deepseek-web': 'https://chat.deepseek.com',
  'qwen-web': 'https://chat.qwen.ai',
  'kimi-web': 'https://www.kimi.ai',
};

var DUAL_IMPORT_RULES = {
  'qwen-web': {
    label: 'Qwen',
    validateCookies: validateQwenCookies,
    validateState: validateQwenState,
    cookiesError: 'Cookies file must be a Cookie-Editor JSON array exported from chat.qwen.ai (non-empty)',
    stateError: 'State file must include localStorage.token or localStorage.user_info',
    dualNote: 'Qwen needs both files. Cookie-Editor for session cookies + Console export for localStorage.token.',
  },
};

function buildConsoleExportScript(downloadName) {
  return `(() => {
  const run = async () => {
    const localStorageData = Object.fromEntries(
      Array.from({ length: localStorage.length }, (_, i) => {
        const k = localStorage.key(i);
        return [k, localStorage.getItem(k)];
      })
    );
    const sessionStorageData = Object.fromEntries(
      Array.from({ length: sessionStorage.length }, (_, i) => {
        const k = sessionStorage.key(i);
        return [k, sessionStorage.getItem(k)];
      })
    );

    let cookies = document.cookie;
    if (window.cookieStore && typeof window.cookieStore.getAll === 'function') {
      try {
        const all = await cookieStore.getAll();
        if (all.length > 0) {
          cookies = all.map((c) => ({
            name: c.name,
            value: c.value,
            domain: location.hostname,
            path: c.path || '/',
            secure: Boolean(c.secure),
            sameSite: c.sameSite || 'Lax',
          }));
        }
      } catch (err) {
        console.warn('cookieStore.getAll failed, using document.cookie only', err);
      }
    }

    const data = {
      url: location.href,
      origin: location.origin,
      localStorage: localStorageData,
      sessionStorage: sessionStorageData,
      cookies: cookies,
    };

    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = ${JSON.stringify(downloadName)};
    a.click();
    URL.revokeObjectURL(a.href);
    console.log('Exported', ${JSON.stringify(downloadName)}, Object.keys(localStorageData).length, 'localStorage keys');
  };
  run();
})();`;
}

var exportScriptNames = {
  'deepseek-web': 'deepseek-state.json',
  'qwen-web': 'qwen-state.json',
  'kimi-web': 'kimi-refresh',
};

var modelsByProvider = {};

// Toast notification
function showToast(msg) {
  var t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.add('show');
  setTimeout(function () {
    t.classList.remove('show');
  }, 2000);
}

// Copy URL — uses data-target attribute instead of inline onclick
function copyText(targetId) {
  var text = document.getElementById(targetId).textContent;
  navigator.clipboard.writeText(text).then(function () {
    showToast('Copied to clipboard!');
  });
}

// Bind copy buttons via data-target (no inline handlers)
document.querySelectorAll('.btn-copy[data-target]').forEach(function (btn) {
  btn.addEventListener('click', function () {
    copyText(btn.getAttribute('data-target'));
  });
});

document.getElementById('btn-check-all').addEventListener('click', checkAllProviders);
document.getElementById('btn-test-all').addEventListener('click', testAllProviders);
document.getElementById('btn-refresh-all').addEventListener('click', refreshAllCookies);

// ======Settings=========
var LOGS_POLL_MS = 5000;
// ======Settings=========

var logsPollTimer = null;
document.getElementById('btn-import-state').addEventListener('click', importSelectedStateFile);
document.getElementById('state-provider').addEventListener('change', updateImportForm);
document.getElementById('btn-copy-export-script').addEventListener('click', copyExportScript);
document.getElementById('btn-toggle-script').addEventListener('click', toggleExportScript);
document.getElementById('btn-save-auto-order').addEventListener('click', saveAutoOrder);
document.getElementById('btn-reset-auto-order').addEventListener('click', resetAutoOrder);
document.getElementById('btn-save-api-auth').addEventListener('click', saveApiAuthToken);
document.getElementById('btn-restart-service').addEventListener('click', restartService);
document.getElementById('btn-load-logs').addEventListener('click', loadServiceLogs);

// Logs fold: load and poll only while it is open
document.getElementById('logs-panel').addEventListener('toggle', function (e) {
  if (e.target.open) {
    loadServiceLogs();
    startLogsPoll();
  } else {
    stopLogsPoll();
  }
});

function formatUptime(seconds) {
  if (seconds < 60) return seconds + 's';
  if (seconds < 3600) return Math.floor(seconds / 60) + 'm';
  return Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm';
}

async function loadModels() {
  try {
    var res = await apiFetch('/v1/models');
    var data = await res.json();
    var grouped = {};
    (data.data || []).forEach(function (m) {
      if (!m.id || m.id === 'auto') return;
      var slash = m.id.indexOf('/');
      if (slash < 0) return;
      var providerId = m.id.slice(0, slash);
      var modelId = m.id.slice(slash + 1);
      if (!grouped[providerId]) grouped[providerId] = [];
      grouped[providerId].push(modelId);
    });
    Object.keys(grouped).forEach(function (providerId) {
      grouped[providerId].sort();
    });
    modelsByProvider = grouped;
  } catch (e) {
    /* keep previous cache */
  }
}

function buildModelSelect(providerId, authenticated) {
  var wrap = document.createElement('div');
  wrap.className = 'provider-models';

  var select = document.createElement('select');
  select.className = 'model-select';
  select.disabled = !authenticated;

  var models = modelsByProvider[providerId] || [];
  if (!authenticated) {
    var opt = document.createElement('option');
    opt.textContent = 'Login to load models';
    select.appendChild(opt);
  } else if (models.length === 0) {
    var emptyOpt = document.createElement('option');
    emptyOpt.textContent = 'No models available';
    select.appendChild(emptyOpt);
  } else {
    models.forEach(function (modelId) {
      var option = document.createElement('option');
      option.value = modelId;
      option.textContent = modelId;
      select.appendChild(option);
    });
  }

  var copyBtn = document.createElement('button');
  copyBtn.type = 'button';
  copyBtn.className = 'btn-copy-model';
  copyBtn.textContent = 'Copy ID';
  copyBtn.disabled = !authenticated || models.length === 0;
  copyBtn.addEventListener('click', function () {
    if (!select.value) return;
    navigator.clipboard.writeText(providerId + '/' + select.value).then(function () {
      showToast('Model ID copied');
    });
  });

  wrap.appendChild(select);
  wrap.appendChild(copyBtn);
  return wrap;
}

// Load providers list
var connectAutoOpened = false;

async function loadProviders() {
  updateExtensionUi();
  await loadModels();
  try {
    var res = await apiFetch('/admin/providers');
    var data = await res.json();
    var list = document.getElementById('provider-list');
    var countEl = document.getElementById('provider-count');

    if (!data.providers || data.providers.length === 0) {
      list.textContent = '';
      var emptyDiv = document.createElement('div');
      emptyDiv.className = 'empty';
      emptyDiv.textContent = 'No providers configured.';
      list.appendChild(emptyDiv);
      countEl.textContent = '0 / 0';
      return;
    }

    var authCount = data.providers.filter(function (p) {
      return p.authenticated;
    }).length;
    countEl.textContent = authCount + ' of ' + data.providers.length + ' active';

    list.textContent = '';

    data.providers.forEach(function (p) {
      var card = document.createElement('div');
      card.className = 'provider-card' + (p.authenticated ? ' active' : '');

      var head = document.createElement('div');
      head.className = 'provider-head';

      var dot = document.createElement('div');
      dot.className = 'status-indicator ' + (p.authenticated ? 'active' : 'inactive');
      head.appendChild(dot);

      var info = document.createElement('div');
      info.className = 'provider-info';

      var nameEl = document.createElement('span');
      nameEl.className = 'provider-name';
      nameEl.textContent = p.name;
      info.appendChild(nameEl);

      var idEl = document.createElement('span');
      idEl.className = 'provider-id';
      idEl.textContent = p.id;
      info.appendChild(idEl);

      head.appendChild(info);

      var meta = document.createElement('div');
      meta.className = 'provider-meta';

      if (p.authenticated) {
        var badge = document.createElement('span');
        badge.className = 'model-badge';
        var modelCount = (modelsByProvider[p.id] || []).length || p.modelCount;
        badge.textContent = modelCount + ' models';
        meta.appendChild(badge);
      } else {
        var btn = document.createElement('button');
        btn.className = 'btn-login';
        btn.textContent = 'Login';
        btn.addEventListener('click', function () {
          loginProvider(p.id);
        });
        meta.appendChild(btn);
      }

      head.appendChild(meta);
      card.appendChild(head);
      if (p.authenticated) card.appendChild(buildModelSelect(p.id, true));
      list.appendChild(card);
    });

    if ((authCount < data.providers.length || !extensionInstalled()) && !connectAutoOpened) {
      connectAutoOpened = true;
      document.getElementById('connect').open = true;
    }
  } catch (err) {
    var list = document.getElementById('provider-list');
    list.textContent = '';
    var errDiv = document.createElement('div');
    errDiv.className = 'error';
    errDiv.textContent = 'Failed to load: ' + err.message;
    list.appendChild(errDiv);
  }
}

async function checkAllProviders() {
  var box = document.getElementById('ops-result');
  box.textContent = 'Checking providers...';
  try {
    var res = await apiFetch('/admin/providers/check-all', { method: 'POST' });
    var data = await res.json();
    if (!res.ok) throw new Error(data.message || data.error || res.statusText);
    box.textContent = '';
    var title = document.createElement('div');
    title.className = 'result-title';
    title.textContent = 'Checked at ' + data.checkedAt;
    box.appendChild(title);
    (data.providers || []).forEach(function (p) {
      var row = document.createElement('div');
      row.className = 'check-row ' + (p.authenticated ? 'ok' : 'bad');
      row.textContent = p.id + ': ' + p.message;
      box.appendChild(row);
    });
    showToast('Provider check complete');
    loadProviders();
    loadHealth();
  } catch (err) {
    box.textContent = 'Check failed: ' + err.message;
    showToast('Check failed');
  }
}

async function testAllProviders() {
  var box = document.getElementById('ops-result');
  box.textContent = 'Testing all providers with real requests (pong)...';
  try {
    var res = await apiFetch('/admin/providers/test-all', { method: 'POST' });
    var data = await res.json();
    if (!res.ok) throw new Error(data.message || data.error || res.statusText);
    box.textContent = '';
    var title = document.createElement('div');
    title.className = 'result-title';
    title.textContent = 'Tested at ' + data.testedAt;
    box.appendChild(title);
    Object.keys(data.results || {}).forEach(function (id) {
      var r = data.results[id];
      var row = document.createElement('div');
      row.className = 'check-row ' + (r.status === 'ok' ? 'ok' : 'bad');
      var latency = r.latencyMs ? ' (' + r.latencyMs + 'ms)' : '';
      row.textContent = id + ': ' + (r.status === 'ok' ? 'OK' : 'FAIL') + latency + ' - ' + r.message;
      box.appendChild(row);
    });
    showToast('Deep test complete');
    loadProviders();
    loadHealth();
  } catch (err) {
    box.textContent = 'Test failed: ' + err.message;
    showToast('Test failed');
  }
}

async function refreshAllCookies() {
  var box = document.getElementById('ops-result');
  box.textContent = 'Re-importing sessions from ~/.web-to-api/imports/...';
  try {
    var res = await apiFetch('/admin/auth/refresh-all', { method: 'POST' });
    var data = await res.json();
    if (!res.ok) throw new Error(data.message || data.error || res.statusText);
    box.textContent = '';

    if (data.status === 'no_files') {
      var info = document.createElement('div');
      info.className = 'check-row warn';
      info.textContent = data.message;
      box.appendChild(info);
      var hint = document.createElement('div');
      hint.className = 'check-row muted';
      hint.textContent = 'If you logged in via Chrome profile only — sessions are already active, import files are optional.';
      box.appendChild(hint);
      showToast('No import files found');
      return;
    }

    var title = document.createElement('div');
    title.className = 'result-title';
    title.textContent = 'Re-imported from ' + (data.importsDir || 'imports');
    box.appendChild(title);

    (data.results || []).forEach(function (r) {
      var row = document.createElement('div');
      var cls = 'check-row ';
      if (r.status === 'imported') cls += 'ok';
      else if (r.status === 'error') cls += 'bad';
      else cls += 'warn';
      row.className = cls;
      if (r.status === 'imported') {
        row.textContent = r.providerId + ': OK — ' + (r.file || 'imported');
      } else {
        row.textContent = r.providerId + ': ' + (r.error || r.message || r.status);
      }
      box.appendChild(row);
    });

    var imported = (data.results || []).filter(function (r) { return r.status === 'imported'; }).length;
    showToast(imported > 0 ? 'Re-imported ' + imported + ' provider(s)' : 'Nothing imported');
    loadProviders();
    loadHealth();
  } catch (err) {
    box.textContent = 'Re-import failed: ' + err.message;
    showToast('Re-import failed');
  }
}

async function loadSettings() {
  var box = document.getElementById('settings-result');
  try {
    var res = await apiFetch('/admin/settings');
    var data = await res.json();
    if (!res.ok) throw new Error(data.message || data.error || res.statusText);
    document.getElementById('auto-order-input').value = (data.autoModelOrder || []).join('\n');
    box.textContent = 'Settings loaded. Service: ' + data.serviceName;
  } catch (err) {
    box.textContent = 'Failed to load settings: ' + err.message;
  }
}

async function saveAutoOrder() {
  var box = document.getElementById('settings-result');
  var order = document.getElementById('auto-order-input').value
    .split('\n')
    .map(function (line) { return line.trim(); })
    .filter(Boolean);
  box.textContent = 'Saving auto order...';
  try {
    var res = await apiFetch('/admin/settings/auto-order', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ order: order }),
    });
    var data = await res.json();
    if (!res.ok) throw new Error(data.message || data.error || res.statusText);
    document.getElementById('auto-order-input').value = data.autoModelOrder.join('\n');
    box.textContent = 'Saved. Restart is optional; current runtime already uses this order.';
    showToast('Auto order saved');
    loadProviders();
  } catch (err) {
    box.textContent = 'Save failed: ' + err.message;
    showToast('Save failed');
  }
}

async function resetAutoOrder() {
  var box = document.getElementById('settings-result');
  box.textContent = 'Resetting auto order...';
  try {
    var res = await apiFetch('/admin/settings/auto-order/reset', { method: 'POST' });
    var data = await res.json();
    if (!res.ok) throw new Error(data.message || data.error || res.statusText);
    document.getElementById('auto-order-input').value = data.autoModelOrder.join('\n');
    box.textContent = 'Reset to default order.';
    showToast('Auto order reset');
    loadProviders();
  } catch (err) {
    box.textContent = 'Reset failed: ' + err.message;
    showToast('Reset failed');
  }
}

async function restartService() {
  var box = document.getElementById('settings-result');
  if (!window.confirm('Restart web-to-api service now?')) return;
  box.textContent = 'Restart requested. Page may be unavailable for a few seconds...';
  try {
    var res = await apiFetch('/admin/service/restart', { method: 'POST' });
    var data = await res.json();
    if (!res.ok) throw new Error(data.message || data.error || res.statusText);
    showToast('Service restarting');
    setTimeout(function () {
      loadHealth();
      loadProviders();
      loadSettings();
    }, 5000);
  } catch (err) {
    box.textContent = 'Restart failed: ' + err.message;
    showToast('Restart failed');
  }
}

async function loadServiceLogs(silent) {
  var box = document.getElementById('service-logs');
  if (!silent) box.textContent = 'Loading logs...';
  try {
    var res = await apiFetch('/admin/service/logs?lines=200');
    var data = await res.json();
    if (!res.ok) throw new Error(data.message || data.error || res.statusText);
    var header = data.source && data.source !== 'none'
      ? '# ' + data.source + '\n\n'
      : '';
    box.textContent = header + (data.logs || '(empty)');
    scrollLogBoxToBottom(box);
  } catch (err) {
    box.textContent = 'Log load failed: ' + err.message;
    if (!silent) showToast('Log load failed');
  }
}

function scrollLogBoxToBottom(box) {
  requestAnimationFrame(function () {
    box.scrollTop = box.scrollHeight;
  });
}

function startLogsPoll() {
  stopLogsPoll();
  logsPollTimer = setInterval(function () {
    var panel = document.getElementById('logs-panel');
    if (panel && panel.open) {
      loadServiceLogs(true);
    }
  }, LOGS_POLL_MS);
}

function stopLogsPoll() {
  if (logsPollTimer) {
    clearInterval(logsPollTimer);
    logsPollTimer = null;
  }
}

async function importSelectedStateFile() {
  var providerId = document.getElementById('state-provider').value;
  var box = document.getElementById('import-result');

  try {
    if (providerId === 'kimi-web') {
      await importKimiRefreshToken(box);
    } else if (DUAL_IMPORT_RULES[providerId]) {
      await importDualProvider(box, providerId);
    } else {
      await importSingleFile(box, providerId);
    }
    showToast('Import completed for ' + providerId);
    loadProviders();
    loadHealth();
  } catch (err) {
    box.textContent = 'Import failed: ' + err.message;
    showToast('Import failed');
  }
}

async function importDualProvider(box, providerId) {
  var rules = DUAL_IMPORT_RULES[providerId];
  if (!rules) throw new Error('Unknown dual-import provider');

  var cookiesInput = document.getElementById('state-cookies-file');
  var stateInput = document.getElementById('state-local-file');
  if (!cookiesInput.files?.length || !stateInput.files?.length) {
    throw new Error(rules.label + ' requires both files: Cookie-Editor cookies JSON and Console state JSON');
  }

  var cookiesFile = cookiesInput.files[0];
  var stateFile = stateInput.files[0];
  var cookiesParsed = JSON.parse(await cookiesFile.text());
  var stateParsed = JSON.parse(await stateFile.text());

  if (!rules.validateCookies(cookiesParsed)) {
    throw new Error(rules.cookiesError);
  }
  if (!rules.validateState(stateParsed)) {
    throw new Error(rules.stateError);
  }

  box.textContent = 'Importing cookies from ' + cookiesFile.name + '...';
  await postImportState(providerId, normalizeStateFile(cookiesParsed, providerId), {
    raw: cookiesParsed,
    persistKind: 'cookies',
  });

  box.textContent = 'Importing state from ' + stateFile.name + '...';
  var result = await postImportState(providerId, normalizeStateFile(stateParsed, providerId), {
    raw: stateParsed,
    persistKind: 'state',
  });
  box.textContent = JSON.stringify(result, null, 2);
}

function parseKimiRefreshToken(raw) {
  var token = String(raw || '').trim().replace(/^['"]|['"]$/g, '');
  if (!token) throw new Error('Paste refresh_token from kimi.ai');
  var parts = token.split('.');
  if (parts.length < 2) throw new Error('Not a JWT. Copy localStorage.getItem("refresh_token")');
  try {
    var payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')));
    if (payload.typ === 'access') {
      throw new Error('This is access_token (~15 min). Paste refresh_token instead');
    }
  } catch (err) {
    if (err.message && err.message.indexOf('access_token') !== -1) throw err;
  }
  return token;
}

async function importKimiRefreshToken(box) {
  var token = parseKimiRefreshToken(document.getElementById('kimi-refresh-token').value);
  box.textContent = 'Saving Kimi refresh_token...';
  var raw = { origin: 'https://www.kimi.ai', localStorage: { refresh_token: token, access_token: '' } };
  var result = await postImportState('kimi-web', raw, {
    raw: raw,
    persistKind: 'single',
  });
  box.textContent = JSON.stringify(result, null, 2);
}

async function importSingleFile(box, providerId) {
  var input = document.getElementById('state-file');
  if (!input.files || input.files.length === 0) {
    throw new Error('Select a JSON file first');
  }

  var file = input.files[0];
  box.textContent = 'Reading ' + file.name + '...';
  var parsed = JSON.parse(await file.text());
  var state = normalizeStateFile(parsed, providerId);
  if (providerId === 'deepseek-web' && !state.localStorage?.userToken && !state.localStorage?.settingsJwt) {
    throw new Error('Need Console export with localStorage.userToken or settingsJwt. Cookie-Editor is not enough anymore.');
  }
  var result = await postImportState(providerId, state, {
    raw: parsed,
    persistKind: 'single',
  });
  box.textContent = JSON.stringify(result, null, 2);
}

async function postImportState(providerId, state, options) {
  var res = await apiFetch('/admin/auth/import-state', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      providerId: providerId,
      state: state,
      raw: options && options.raw !== undefined ? options.raw : state,
      persistKind: options && options.persistKind ? options.persistKind : undefined,
    }),
  });
  var data = await res.json();
  if (!res.ok) throw new Error(data.message || data.error || res.statusText);
  return data;
}

function validateDeepSeekCookies(parsed) {
  if (!Array.isArray(parsed) || parsed.length === 0) return false;
  return parsed.some(function (c) {
    return c && (c.name === 'ds_session_id' || c.name === 'ds_chat_token');
  });
}

function validateDeepSeekState(parsed) {
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return false;
  var ls = parsed.localStorage || {};
  return Boolean(ls.userToken || ls.settingsJwt);
}

function validateQwenCookies(parsed) {
  return Array.isArray(parsed) && parsed.length > 0;
}

function validateQwenState(parsed) {
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return false;
  var ls = parsed.localStorage || {};
  return Boolean(ls.token || ls.user_info);
}

function updateImportForm() {
  var providerId = document.getElementById('state-provider').value;
  var dualRules = DUAL_IMPORT_RULES[providerId];
  var dual = Boolean(dualRules);
  var isKimi = providerId === 'kimi-web';
  document.getElementById('import-single').classList.toggle('hidden', dual || isKimi);
  document.getElementById('import-dual').classList.toggle('hidden', !dual);
  document.getElementById('import-kimi').classList.toggle('hidden', !isKimi);
  if (dualRules) {
    document.getElementById('import-dual-note').textContent = dualRules.dualNote;
  }

  var scriptBox = document.getElementById('export-script-box');
  var scriptName = exportScriptNames[providerId];
  if (scriptName) {
    scriptBox.classList.remove('hidden');
    document.getElementById('export-script').textContent = providerId === 'kimi-web'
      ? "copy(localStorage.getItem('refresh_token'))"
      : buildConsoleExportScript(scriptName);
    var body = document.getElementById('export-script-body');
    var toggleBtn = document.getElementById('btn-toggle-script');
    body.classList.add('collapsed');
    if (toggleBtn) toggleBtn.textContent = 'Show';
  } else {
    scriptBox.classList.add('hidden');
  }

  var hints = {
    'deepseek-web': 'Upload Console state JSON. Cookie-Editor no longer has the login token.',
    'kimi-web': 'Paste refresh_token only. Access tokens are rejected.',
    'qwen-web': 'Upload Cookie-Editor cookies + Console state (two files).',
  };
  document.getElementById('import-result').textContent = hints[providerId] || 'Select provider and upload session JSON.';
}

function copyExportScript() {
  var text = document.getElementById('export-script').textContent;
  navigator.clipboard.writeText(text).then(function () {
    showToast('Export script copied');
  });
}

function toggleExportScript() {
  var body = document.getElementById('export-script-body');
  var btn = document.getElementById('btn-toggle-script');
  var collapsed = body.classList.toggle('collapsed');
  btn.textContent = collapsed ? 'Show' : 'Hide';
}

updateImportForm();

function normalizeStateFile(parsed, providerId) {
  var fallbackOrigin = providerOrigins[providerId] || 'https://chat.qwen.ai';
  if (Array.isArray(parsed)) {
    return { origin: fallbackOrigin, cookies: parsed };
  }
  if (!parsed || typeof parsed !== 'object') {
    throw new Error('Unsupported JSON format');
  }
  if (Array.isArray(parsed.cookies) && Array.isArray(parsed.origins)) {
    return normalizePlaywrightStorageState(parsed, fallbackOrigin);
  }
  return {
    url: typeof parsed.url === 'string' ? parsed.url : undefined,
    origin: typeof parsed.origin === 'string' ? parsed.origin : fallbackOrigin,
    localStorage: normalizeRecord(parsed.localStorage),
    sessionStorage: normalizeRecord(parsed.sessionStorage),
    cookies: typeof parsed.cookies === 'string' || Array.isArray(parsed.cookies)
      ? parsed.cookies
      : undefined,
  };
}

function normalizePlaywrightStorageState(state, fallbackOrigin) {
  var origins = Array.isArray(state.origins) ? state.origins : [];
  var matched = origins.find(function (entry) {
    return entry && entry.origin === fallbackOrigin;
  }) || origins[0] || {};
  var localStorage = {};
  (matched.localStorage || []).forEach(function (entry) {
    if (entry && typeof entry.name === 'string') {
      localStorage[entry.name] = String(entry.value || '');
    }
  });
  return {
    origin: matched.origin || fallbackOrigin,
    localStorage: localStorage,
    cookies: state.cookies || [],
  };
}

function normalizeRecord(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  var out = {};
  Object.keys(value).forEach(function (key) {
    out[key] = String(value[key] == null ? '' : value[key]);
  });
  return out;
}

// Login flow: Google blocks sign-in inside the automated Chrome, so the user logs in with their own
// Chrome (new tab) and a bookmark on that tab sends the session back here through the URL fragment.
function extensionInstalled() {
  return Boolean(document.documentElement.dataset.wtaExtension);
}

function updateExtensionUi() {
  document.getElementById('extension-status').textContent = extensionInstalled()
    ? 'Installed. Reload your Qwen / Kimi / DeepSeek tabs once.'
    : 'Not detected. Reload this page after installing.';
}

function loginProvider(providerId) {
  // The extension is what carries the login back here, so it has to exist before the user signs in.
  if (!extensionInstalled()) {
    document.getElementById('connect').open = true;
    showToast('Install the extension first (step 1), then log in');
    return;
  }
  window.open(providerOrigins[providerId], '_blank');
  showToast('Log in on the new tab, then click the "web-to-api capture" bookmark there');
}

// Pairing secret: only a bookmark/script built by this dashboard can make it import a captured session,
// so a crafted #capture link from another site cannot swap in someone else's login.
function captureSecret() {
  var key = 'wta_capture_secret';
  var secret = localStorage.getItem(key);
  if (!secret) {
    secret = Array.from(crypto.getRandomValues(new Uint8Array(16)), function (b) { return b.toString(16).padStart(2, '0'); }).join('');
    localStorage.setItem(key, secret);
  }
  return secret;
}

function buildCaptureBookmarklet() {
  var body = '(async()=>{var D=' + JSON.stringify(location.origin) + ';var ls={};'
    + 'for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);ls[k]=localStorage.getItem(k)}'
    + 'var ck=document.cookie;'
    + 'try{var a=await cookieStore.getAll();if(a.length)ck=a.map(c=>({name:c.name,value:c.value,domain:location.hostname,path:c.path||"/",secure:!!c.secure,sameSite:c.sameSite||"Lax"}))}catch(e){}'
    + 'var d={k:' + JSON.stringify(captureSecret()) + ',origin:location.origin,url:location.href,localStorage:ls,cookies:ck};'
    + 'window.open(D+"/#capture="+btoa(unescape(encodeURIComponent(JSON.stringify(d)))),"_blank")})()';
  return 'javascript:' + encodeURIComponent(body);
}

// Chrome only loads unpacked extensions through its own Extensions page, so show the steps with copy buttons.
async function installExtension() {
  var box = document.getElementById('extension-steps');
  try {
    var res = await apiFetch('/admin/extension');
    var data = await res.json().catch(function () { return {}; });
    if (!res.ok) throw new Error(data.message || data.error || ('HTTP ' + res.status + ' (restart the server so it has the new build)'));
    box.textContent = '';
    [
      ['1. Open a new tab and go to', 'chrome://extensions'],
      ['2. Turn on "Developer mode" (top right).'],
      ['3. Click "Load unpacked" and choose this folder:', data.dir],
      ['4. Reload this page and your Qwen / Kimi tabs.'],
    ].forEach(function (step) {
      var row = document.createElement('div');
      row.textContent = step[0];
      if (step[1]) {
        var value = document.createElement('code');
        value.textContent = step[1];
        var copy = document.createElement('button');
        copy.type = 'button';
        copy.className = 'btn sm';
        copy.textContent = 'Copy';
        copy.addEventListener('click', function () {
          navigator.clipboard.writeText(step[1]).then(function () { showToast('Copied'); });
        });
        row.append(' ', value, ' ', copy);
      }
      box.appendChild(row);
    });
    box.classList.remove('hidden');
  } catch (err) {
    box.textContent = 'Could not load the extension steps: ' + err.message;
    box.classList.remove('hidden');
  }
}

async function importCapturedSession() {
  var m = location.hash.match(/^#capture=(.+)$/);
  if (!m) return;
  history.replaceState(null, '', location.pathname + location.search);   // tokens must not stay in the address bar/history
  try {
    var d = JSON.parse(decodeURIComponent(escape(atob(m[1]))));
    if (d.k !== captureSecret()) throw new Error('capture not made with this dashboard bookmark; re-drag or re-copy it');
    var providerId = Object.keys(providerOrigins).find(function (id) { return providerOrigins[id] === d.origin; });
    if (!providerId) throw new Error('Unknown site ' + d.origin);
    // A crafted link could carry someone else's session, so never import without asking.
    if (!confirm('Import the ' + providerId + ' session captured from ' + d.origin + '?')) return;
    var raw = { origin: d.origin, url: d.url, localStorage: d.localStorage, cookies: d.cookies };
    var result = await postImportState(providerId, normalizeStateFile(raw, providerId), { raw: raw, persistKind: 'single' });
    showToast(providerId + (result.verified === false ? ': no session token found, are you logged in?' : ' session imported'));
    loadProviders();
    loadHealth();
  } catch (err) {
    showToast('Capture failed: ' + err.message);
  }
}

// Load server health into the header status line
async function loadHealth() {
  var statusEl = document.getElementById('server-status');
  try {
    var res = await apiFetch('/admin/health');
    var data = await res.json();
    var isHealthy = data.status === 'healthy';
    statusEl.className = 'status ' + (isHealthy ? 'online' : '');
    statusEl.textContent = isHealthy
      ? 'Online · up ' + formatUptime(data.uptime || 0)
      : (data.status || 'Unknown');
  } catch (e) {
    statusEl.className = 'status offline';
    statusEl.textContent = 'Offline';
  }
}

// Initial load + auto-refresh every 10s
initAuthFromUrl();
loadDashboardConfig().then(function () {
  document.getElementById('capture-bookmarklet').href = buildCaptureBookmarklet();
  document.getElementById('btn-install-extension').addEventListener('click', installExtension);
  document.getElementById('btn-copy-capture').addEventListener('click', function () {
    // Paste into the DevTools Console of the logged-in provider tab (type "allow pasting" first if Chrome asks).
    navigator.clipboard.writeText(decodeURIComponent(buildCaptureBookmarklet().replace(/^javascript:/, '')));
    showToast('Copied. Paste it in the provider tab Console (F12) and press Enter');
  });
  importCapturedSession();
  loadSettings();
  loadProviders();
  loadHealth();
});
setInterval(function () {
  loadProviders();
  loadHealth();
}, 10000);
