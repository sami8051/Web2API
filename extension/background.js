// Sends the logged-in session of the current Qwen/Kimi/DeepSeek tab to the local web-to-api server.
// Runs by itself after a page loads (at most every 10 min per site) and on a click of the toolbar icon.
const SERVER = 'http://127.0.0.1:3456';
const AUTO_SYNC_MS = 10 * 60 * 1000;
const SITES = [
  { id: 'qwen-web', host: /(^|\.)qwen\.ai$/, tokenKey: 'token' },
  { id: 'deepseek-web', host: /(^|\.)deepseek\.com$/, tokenKey: 'userToken' },
  { id: 'kimi-web', host: /(^|\.)kimi\.(ai|com)$/, tokenKey: 'refresh_token' },
];
const lastSync = {};

function siteFor(tab) {
  let host;
  try { host = new URL(tab.url).hostname; } catch { return null; }
  return SITES.find((s) => s.host.test(host)) || null;
}

async function sync(tab, site) {
  const [{ result: localStorage }] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: () => Object.fromEntries(Object.keys(localStorage).map((k) => [k, localStorage.getItem(k)])),
  });
  if (!localStorage[site.tokenKey]) return 'not logged in on this tab';

  const origin = new URL(tab.url).origin;
  const state = { origin, url: tab.url, localStorage, cookies: await chrome.cookies.getAll({ url: origin }) };
  const res = await fetch(`${SERVER}/admin/auth/import-state`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ providerId: site.id, state, raw: state, persistKind: 'single' }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.message || res.statusText);
  lastSync[site.id] = Date.now();
  return body.verified === false ? 'server found no token' : 'ok';
}

async function run(tab, manual) {
  const site = siteFor(tab);
  if (!site) { if (manual) badge(tab.id, '?', '#888', 'Open Qwen, Kimi or DeepSeek first'); return; }
  try {
    const result = await sync(tab, site);
    if (manual || result !== 'ok') badge(tab.id, result === 'ok' ? 'OK' : '!', result === 'ok' ? '#2a9d4b' : '#d98e04', `${site.id}: ${result}`);
    else badge(tab.id, 'OK', '#2a9d4b', `${site.id}: synced`);
  } catch (err) {
    badge(tab.id, 'ERR', '#c0392b', `Is web-to-api running? ${err.message}`);
  }
}

function badge(tabId, text, color, title) {
  chrome.action.setBadgeText({ tabId, text });
  chrome.action.setBadgeBackgroundColor({ tabId, color });
  chrome.action.setTitle({ tabId, title });
}

chrome.action.onClicked.addListener((tab) => run(tab, true));

chrome.tabs.onUpdated.addListener((tabId, info, tab) => {
  if (info.status !== 'complete') return;
  const site = siteFor(tab);
  if (site && Date.now() - (lastSync[site.id] || 0) > AUTO_SYNC_MS) run(tab, false);
});
