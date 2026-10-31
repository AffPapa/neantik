import {FEED_URL, THREAT_ID_BASE, TRACKER_HOSTS, canonicalDomain, limitedText, replaceThreatRules} from './policy.mjs';
const ALARM = 'neantik-cert-refresh-v1';
let activeRefresh;

async function configuration() {
  const response = await fetch(chrome.runtime.getURL('profile-policy.json'));
  const policy = await response.json();
  if (policy.schemaVersion !== 1 || typeof policy.trackingParameterCleanup !== 'boolean') throw new Error('invalid-policy');
  return policy;
}

async function initialize() {
  const policy = await configuration();
  await chrome.declarativeNetRequest.updateEnabledRulesets({enableRulesetIds: ['trackers', ...(policy.trackingParameterCleanup ? ['query_cleanup'] : [])], disableRulesetIds: policy.trackingParameterCleanup ? [] : ['query_cleanup']});
  await chrome.alarms.create(ALARM, {periodInMinutes: 5});
}

async function refresh() {
  if (activeRefresh) return activeRefresh;
  activeRefresh = (async () => {
    try {
      await initialize();
      const response = await fetch(FEED_URL, {cache: 'no-store', credentials: 'omit', redirect: 'error', referrerPolicy: 'no-referrer', signal: AbortSignal.timeout(15000)});
      await replaceThreatRules(chrome, await limitedText(response), new Date().toISOString());
    } catch {
      // Deliberately fixed vocabulary: no URL, response body, IP or exception
      // text is stored. Last-known rule replacement is atomic in DNR.
      await chrome.storage.local.set({threatUpdateError: 'update-unavailable'});
    } finally { activeRefresh = undefined; }
  })();
  return activeRefresh;
}

async function trackerException(enabled, host) {
  const domain = canonicalDomain(host);
  const current = await chrome.declarativeNetRequest.getSessionRules();
  const remaining = current.filter(rule => rule.id >= 50000 && rule.id < 50100 && rule.condition.initiatorDomains?.[0] !== domain);
  if (enabled) {
    if (remaining.length >= 100) throw new Error('exception-limit');
    let id = 50000; const used = new Set(remaining.map(rule => rule.id)); while (used.has(id)) ++id;
    remaining.push({id, priority: 200, action: {type: 'allow'}, condition: {initiatorDomains: [domain], requestDomains: [...TRACKER_HOSTS], domainType: 'thirdParty', excludedResourceTypes: ['main_frame']}});
  }
  // Exceptions only allow the small tracker list; priority200 cannot override
  // CERT threat blocks(priority1000). They expire when this browser exits.
  await chrome.declarativeNetRequest.updateSessionRules({removeRuleIds: current.filter(rule => rule.id >= 50000 && rule.id < 50100).map(rule => rule.id), addRules: remaining});
}

chrome.runtime.onInstalled.addListener(() => { void refresh(); });
chrome.runtime.onStartup.addListener(() => { void refresh(); });
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === ALARM) void refresh(); });
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // Only the local popup may operate. No content scripts/external messaging or
  // web-accessible resources are declared by this extension.
  if (sender.id !== chrome.runtime.id || sender.url !== chrome.runtime.getURL('popup.html')) return false;
  if (message?.action === 'refresh') { refresh().then(() => sendResponse({ok: true})); return true; }
  if (message?.action === 'tracker-exception' && typeof message.enabled === 'boolean' && typeof message.host === 'string') {
    trackerException(message.enabled, message.host).then(() => sendResponse({ok: true}), () => sendResponse({ok: false})); return true;
  }
  return false;
});
