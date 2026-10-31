import {FEED_URL, THREAT_ID_BASE, canonicalDomain, limitedText, replaceThreatRules, sessionTrackerExceptionRules} from './policy.mjs';
const ALARM = 'neantik-cert-refresh-v1';
let activeRefresh;

async function configuration() {
  const response = await fetch(chrome.runtime.getURL('profile-policy.json'));
  const policy = await response.json();
  if (policy.schemaVersion !== 1 || typeof policy.siteProtection !== 'boolean' || typeof policy.blockThirdPartyCookies !== 'boolean' || typeof policy.trackingParameterCleanup !== 'boolean' || (policy.trackingParameterCleanup && !policy.siteProtection)) throw new Error('invalid-policy');
  return policy;
}

async function initialize() {
  const policy = await configuration();
  const cookieSetting = chrome.privacy.websites.thirdPartyCookiesAllowed;
  if (policy.blockThirdPartyCookies) await cookieSetting.set({value:false,scope:'regular'});
  else await cookieSetting.clear({scope:'regular'});
  const cookie = await cookieSetting.get({});
  await chrome.storage.local.set({thirdPartyCookiesBlocked:cookie.value===false,
    cookieControl:cookie.levelOfControl,requestedCookieBlock:policy.blockThirdPartyCookies});
  if (policy.blockThirdPartyCookies && cookie.value !== false) throw new Error('cookie-policy-not-applied');
  if (!policy.siteProtection) {
    await chrome.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds:['cert_baseline','trackers','query_cleanup']});
    const dynamic = await chrome.declarativeNetRequest.getDynamicRules();
    await chrome.declarativeNetRequest.updateDynamicRules({removeRuleIds:dynamic.filter(rule=>rule.id>=THREAT_ID_BASE&&rule.id<THREAT_ID_BASE+600).map(rule=>rule.id)});
    await chrome.alarms.clear(ALARM);
    return policy;
  }
  const dynamic = await chrome.declarativeNetRequest.getDynamicRules();
  const hasThreats = dynamic.filter(rule=>rule.id>=THREAT_ID_BASE&&rule.id<THREAT_ID_BASE+600).length >= 2;
  await chrome.declarativeNetRequest.updateEnabledRulesets({
    enableRulesetIds:['trackers',...(!hasThreats?['cert_baseline']:[]),...(policy.trackingParameterCleanup?['query_cleanup']:[])],
    disableRulesetIds:[...(hasThreats?['cert_baseline']:[]),...(!policy.trackingParameterCleanup?['query_cleanup']:[])]});
  await chrome.alarms.create(ALARM,{periodInMinutes:5});
  return policy;
}

async function refresh() {
  if (activeRefresh) return activeRefresh;
  activeRefresh = (async () => {
    try {
      const policy = await initialize();
      if (!policy.siteProtection) return;
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

let exceptionMutation = Promise.resolve();
let trackerHosts;
async function bundledTrackerHosts() {
  if (!trackerHosts) {
    const response = await fetch(chrome.runtime.getURL('tracker-rules.json'));
    const rules = await response.json();
    if (!Array.isArray(rules) || rules.length !== 1 || rules[0].id !== 1000 || rules[0].priority !== 100 ||
        rules[0].action?.type !== 'block' || rules[0].condition?.domainType !== 'thirdParty' ||
        !Array.isArray(rules[0].condition.requestDomains)) throw new Error('tracker-shape');
    trackerHosts = rules[0].condition.requestDomains.map(canonicalDomain);
  }
  return trackerHosts;
}
function trackerException(enabled, host) {
  const operation = exceptionMutation.then(async () => {
    const current = await chrome.declarativeNetRequest.getSessionRules();
    const update = sessionTrackerExceptionRules(current, host, enabled, await bundledTrackerHosts());
    // CERT blocks retain priority1000. Session allowances expire on browser exit.
    await chrome.declarativeNetRequest.updateSessionRules(update);
  });
  exceptionMutation = operation.catch(() => {});
  return operation;
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
