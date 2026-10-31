// Offline GPL-data conversion. Never executes downloaded contents or fetches URLs.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import {canonicalDomain} from '../../Resources/SiteProtection/policy.mjs';
const root=path.resolve(import.meta.dirname,'../..');
const input=path.join(root,'runtime/site-protection-data/hagezi-light');
const output=path.join(root,'Resources/SiteProtection');
const provenance=JSON.parse(fs.readFileSync(path.join(input,'provenance.json'),'utf8'));
const digest=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
for(const [name,record] of Object.entries(provenance.files)) {
  const data=fs.readFileSync(path.join(input,name));assert(data.length<=8*1024*1024);
  assert.equal(digest(data),record.sha256,'Upstream source bytes changed');
}
const raw=fs.readFileSync(path.join(input,'upstream-domains.txt'));
const domains=[...new Set(new TextDecoder('utf-8',{fatal:true}).decode(raw).split(/\r?\n/)
  .filter(line=>line!==''&&!line.startsWith('#')).map(canonicalDomain))].sort();
assert(domains.length>=1000&&domains.length<=100000,'Unexpected basic-list domain count');
const rules=[{id:1000,priority:100,action:{type:'block'},condition:{requestDomains:domains,domainType:'thirdParty',excludedResourceTypes:['main_frame']}}];
const data=JSON.stringify(rules)+'\n';assert(Buffer.byteLength(data)<=4*1024*1024);
fs.writeFileSync(path.join(output,'tracker-rules.json'),data);
fs.copyFileSync(path.join(input,'LICENSE-GPL-3.0.txt'),path.join(output,'TRACKER-LICENSE-GPL-3.0.txt'));
fs.writeFileSync(path.join(output,'tracker-provenance.json'),JSON.stringify({schemaVersion:1,
  upstream:'HaGeZi Multi LIGHT',source:provenance.files['upstream-domains.txt'].source,
  fetchedAt:provenance.fetchedAt,sourceSHA256:digest(raw),rulesSHA256:digest(data),domains:domains.length,
  license:'GPL-3.0',sourceSnapshot:'runtime/site-protection-data/hagezi-light/upstream-domains.txt',
  scope:'Basic third-party ads/trackers/telemetry and some badware; not complete protection',
  updatePolicy:'Bundled snapshot updated with NeAntik releases; CERT feed refresh is separate',
  conversion:'Modified/converted by NeAntik; no endorsement'},null,2)+'\n');
console.log(JSON.stringify({status:'built',domains:domains.length,rules:rules.length,bytes:Buffer.byteLength(data),rulesSHA256:digest(data)}));
