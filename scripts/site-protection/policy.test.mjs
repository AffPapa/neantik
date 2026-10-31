import test from 'node:test';
import assert from 'node:assert/strict';
import {canonicalDomain, parseDomains, threatRules, trackerRules, queryCleanupRules, replaceThreatRules, limitedText, RESOURCE_TYPES} from '../../Resources/SiteProtection/policy.mjs';

test('domain normalization is bounded and never broadens to parent hosts', () => {
  assert.equal(canonicalDomain('A.Example.COM.'), 'a.example.com');
  assert.deepEqual(parseDomains('a.example.com\r\na.example.com\n'), ['a.example.com']);
  for (const bad of ['com', '.example.com', 'a..com', 'https://example.com', '*.example.com', 'a.com/path', '127.0.0.1', 'a.com\u0000', ' a.com', '-a.com', 'a-.com', 'a'.repeat(64)+'.com']) assert.throws(() => canonicalDomain(bad));
  assert.equal(threatRules(['a.example.com'])[0].condition.requestDomains[0], 'a.example.com');
});

test('main frames, workers network fetch type and websocket paths are explicit', () => {
  const rules = threatRules(Array.from({length: 501}, (_,i)=>`d${i}.example.com`));
  assert.equal(rules.length, 2);
  assert.equal(rules[0].condition.requestDomains.length, 500);
  assert.ok(RESOURCE_TYPES.includes('main_frame'));
  assert.ok(RESOURCE_TYPES.includes('xmlhttprequest'));
  assert.ok(RESOURCE_TYPES.includes('websocket'));
  assert.ok(rules.every(r=>r.priority>queryCleanupRules(true)[0].priority));
});

test('query cleanup preserves unknown OAuth payment signatures and mixed queries', () => {
  const [rule] = queryCleanupRules(true); const re = new RegExp(rule.condition.regexFilter);
  assert.ok(re.test('https://example.com/path?utm_source=test&fbclid=123'));
  for (const url of ['https://example.com/?code=x&utm_source=y', 'https://example.com/?signature=x&utm_source=y', 'https://example.com/?X-Amz-Signature=x&utm_source=y','https://example.com/?order=1&utm_source=x','https://example.com/?utm_source=x&value=y','https://example.com/?url=https%3A%2F%2Fother.invalid']) assert.ok(!re.test(url), url);
  assert.deepEqual(queryCleanupRules(false), []);
  assert.deepEqual(rule.condition.requestMethods, ['get']);
});

test('tracker exception does not become a threat allow rule', () => {
  const [rule] = trackerRules(['news.example.com']);
  assert.deepEqual(rule.condition.excludedInitiatorDomains, ['news.example.com']);
  assert.equal(rule.action.type, 'block');
  assert.equal(rule.condition.domainType, 'thirdParty');
  assert.throws(()=>trackerRules(['https://example.com']));
});

test('failed atomic update cannot erase last-known protection or commit success', async () => {
  const text = Array.from({length:1000},(_,i)=>`d${i}.example.com`).join('\n');let touched=false;
  const api = {declarativeNetRequest:{getDynamicRules:async()=>[{id:10000}],updateDynamicRules:async()=>{throw Error('quota')},updateEnabledRulesets:async()=>{touched=true}},storage:{local:{set:async()=>{touched=true}}}};
  await assert.rejects(replaceThreatRules(api,text,'test'));assert.equal(touched,false);
});

test('valid replacement keeps unrelated rules and disables static only afterwards', async () => {
  const calls=[];const text=Array.from({length:1000},(_,i)=>`d${i}.example.com`).join('\n');
  const api={declarativeNetRequest:{getDynamicRules:async()=>[{id:10000},{id:1000}],updateDynamicRules:async options=>{calls.push('dynamic');assert.deepEqual(options.removeRuleIds,[10000])},updateEnabledRulesets:async()=>{calls.push('static')}},storage:{local:{set:async()=>{calls.push('metadata')}}}};
  const result=await replaceThreatRules(api,text,'test');assert.equal(result.domains,1000);assert.deepEqual(calls,['dynamic','static','metadata']);
});

test('response parser fails closed for size invalid UTF8 and response errors', async () => {
  assert.equal(await limitedText(new Response('a.example.com')), 'a.example.com');
  await assert.rejects(limitedText(new Response('x',{status:500})));
  await assert.rejects(limitedText(new Response('x',{headers:{'content-length':'999999999'}})));
  await assert.rejects(limitedText(new Response(new Uint8Array([255]))));
});
