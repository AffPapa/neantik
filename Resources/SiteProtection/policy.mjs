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
  const key = `(?:${TRACKING_PARAMETERS.join('|')})`;
  const regex = `^https?://[^?#]+\\?${key}=[^&#]*(?:&${key}=[^&#]*)*$`;
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
