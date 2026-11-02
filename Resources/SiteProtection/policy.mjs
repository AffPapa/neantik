// Domain-only protection. No page contents or visited URLs leave the browser.
export const FEED_URL = 'https://hole.cert.pl/domains/v2/domains.txt';
export const MAX_FEED_BYTES = 8 * 1024 * 1024;
export const MAX_DOMAINS = 300000;
export const THREAT_ID_BASE = 10000;
export const THREAT_PRIORITY = 1000;
export const RESOURCE_TYPES = Object.freeze(['main_frame', 'sub_frame', 'stylesheet', 'script', 'image', 'font', 'object', 'xmlhttprequest', 'ping', 'csp_report', 'media', 'websocket', 'webtransport', 'webbundle', 'other']);
export const TRACKER_HOSTS = Object.freeze(['google-analytics.com', 'stats.g.doubleclick.net', 'bat.bing.com', 'pixel.quantserve.com', 'analytics.twitter.com']);
export const TRACKING_PARAMETERS = Object.freeze(['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content', 'utm_id', 'gclid', 'fbclid', 'dclid', 'msclkid', 'mc_cid', 'mc_eid']);

export function canonicalDomain(raw) {
  if (typeof raw !== 'string' || raw.length > 253 || raw !== raw.trim()) throw new Error('invalid-domain');
  const host = raw.toLowerCase().replace(/\.$/, '');
  const labels = host.split('.');
  if (labels.length < 2 || /^\d+(?:\.\d+)+$/.test(host) || !/^[a-z][a-z0-9-]*$/.test(labels.at(-1))) throw new Error('invalid-domain');
  if (!labels.every(label => label.length > 0 && label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label))) throw new Error('invalid-domain');
  return host;
}

export function parseDomains(text, {minimumDomains = 1} = {}) {
  if (typeof text !== 'string' || new TextEncoder().encode(text).length > MAX_FEED_BYTES) throw new Error('feed-size');
  const domains = new Set();
  for (const line of text.replace(/^\uFEFF/, '').split(/\r?\n/)) {
    if (line === '') continue;
    domains.add(canonicalDomain(line));
    if (domains.size > MAX_DOMAINS) throw new Error('domain-limit');
  }
  if (domains.size < minimumDomains) throw new Error('feed-incomplete');
  return [...domains].sort();
}

export function threatRules(domains) {
  if (!Array.isArray(domains) || domains.length === 0 || domains.length > MAX_DOMAINS) throw new Error('domain-limit');
  const normalized = [...new Set(domains.map(canonicalDomain))].sort();
  const rules = [];
  for (let i = 0; i < normalized.length; i += 500) {
    rules.push({id: THREAT_ID_BASE + rules.length, priority: THREAT_PRIORITY, action: {type: 'block'}, condition: {requestDomains: normalized.slice(i, i + 500), resourceTypes: [...RESOURCE_TYPES]}});
  }
  return rules;
}

export function trackerRules(exceptions = []) {
  if (!Array.isArray(exceptions) || exceptions.length > 100) throw new Error('exception-limit');
  return [{id: 1000, priority: 100, action: {type: 'block'}, condition: {requestDomains: [...TRACKER_HOSTS], domainType: 'thirdParty', excludedResourceTypes: ['main_frame'], ...(exceptions.length ? {excludedInitiatorDomains: [...new Set(exceptions.map(canonicalDomain))].sort()} : {})}}];
}

export function queryCleanupRules(enabled) {
  if (!enabled) return [];
  // Only queries entirely made of these exact keys qualify. Unknown, OAuth,
  // payment and signature parameters leave the URL untouched. This conservative
  // filter is not a general redirect/bounce-tracking remover.
  // Factor one repeated key/value token to stay within Chromium's2KiB RE2 budget.
  const key = '(?:utm_(?:source|medium|campaign|term|content|id)|gclid|fbclid|dclid|msclkid|mc_(?:cid|eid))';
  // Long opaque path segments commonly carry signatures or one-time tokens.
  // Keep the whole URL intact when one is present; query-only signatures are
  // already preserved by requiring every query key to be in the allowlist.
  const path = '(?:/[^/?#]{1,31})*/?';
  const regex = `^https?://[^/?#]+${path}\\?(?:${key}=[^&#]*(?:&|$))+$`;
  return [{id: 2000, priority: 50, action: {type: 'redirect', redirect: {transform: {queryTransform: {removeParams: [...TRACKING_PARAMETERS]}}}}, condition: {regexFilter: regex, isUrlFilterCaseSensitive: true, resourceTypes: ['main_frame'], requestMethods: ['get']}}];
}

export async function limitedText(response) {
  if (!response.ok || !response.body) throw new Error('feed-response');
  const declared = response.headers.get('content-length');
  if (declared && (!/^\d+$/.test(declared) || Number(declared) > MAX_FEED_BYTES)) throw new Error('feed-size');
  const reader = response.body.getReader(); let bytes = 0; let result = '';
  const decoder = new TextDecoder('utf-8', {fatal: true});
  try {
    for (;;) {
      const {value, done} = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_FEED_BYTES) throw new Error('feed-size');
      result += decoder.decode(value, {stream: true});
    }
    return result + decoder.decode();
  } catch (error) { await reader.cancel().catch(() => {}); throw error; }
}

export async function replaceThreatRules(api, text, observedAt) {
  const domains = parseDomains(text, {minimumDomains: 1000});
  const addRules = threatRules(domains);
  const current = await api.declarativeNetRequest.getDynamicRules();
  const removeRuleIds = current.filter(rule => rule.id >= THREAT_ID_BASE && rule.id < THREAT_ID_BASE + 600).map(rule => rule.id);
  // Chrome's atomic update keeps the prior dynamic rules if replacement fails.
  await api.declarativeNetRequest.updateDynamicRules({removeRuleIds, addRules});
  // Only after the replacement exists remove the frozen baseline, so removed
  // feed entries cease to be blocked. Until then retain the previous protection.
  await api.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds: ['cert_baseline']});
  const metadata = {observedAt, domains: domains.length, source: FEED_URL, transport: 'HTTPS; not publisher-signed'};
  await api.storage.local.set({threatMetadata: metadata, threatUpdateError: null});
  return metadata;
}


// One aggregate session exception avoids N copies of a large domain list.
// Only our reserved session IDs are changed; unrelated rules are preserved.
export function sessionTrackerExceptionRules(existing, host, enabled, trackerHosts) {
  if (!Array.isArray(existing) || existing.length > 5000 || typeof enabled !== 'boolean') throw new Error('exception-shape');
  const domain = canonicalDomain(host);
  if (!Array.isArray(trackerHosts) || trackerHosts.length < 1 || trackerHosts.length > 100000) throw new Error('tracker-limit');
  const trackers = [...new Set(trackerHosts.map(canonicalDomain))].sort();
  const owned = existing.filter(rule => Number.isInteger(rule.id) && rule.id >= 50000 && rule.id < 50100);
  const sites = new Set();
  for (const rule of owned) {
    if (!Array.isArray(rule.condition?.initiatorDomains) || rule.condition.initiatorDomains.length > 100) throw new Error('exception-shape');
    for (const site of rule.condition.initiatorDomains) sites.add(canonicalDomain(site));
  }
  if (enabled) sites.add(domain); else sites.delete(domain);
  if (sites.size > 100) throw new Error('exception-limit');
  const addRules = sites.size ? [{id:50000,priority:200,action:{type:'allow'},condition:{
    initiatorDomains:[...sites].sort(),requestDomains:trackers,domainType:'thirdParty',excludedResourceTypes:['main_frame']}}] : [];
  const result = {removeRuleIds:owned.map(rule=>rule.id),addRules};
  if (new TextEncoder().encode(JSON.stringify(result)).length > 4*1024*1024) throw new Error('exception-bytes');
  return result;
}
