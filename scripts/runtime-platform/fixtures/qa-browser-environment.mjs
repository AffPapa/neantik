// Match the manager's narrow inherited environment. Never forward developer
// credentials, proxy env overrides, dynamic loader injections or other profiles.
export const inheritedBrowserKeys=Object.freeze(['HOME','LANG','LC_ALL','LC_CTYPE','LOGNAME','PATH','SHELL','TMPDIR','USER','XPC_FLAGS','XPC_SERVICE_NAME','__CFBundleIdentifier']);
const allowed=new Set(inheritedBrowserKeys);
export function browserFixtureEnvironment(inherited=process.env){
  return Object.fromEntries(Object.entries(inherited).filter(([key,value])=>allowed.has(key)&&typeof value==='string'));
}
if(process.argv[2]==='--self-test'){
  const {default:assert}=await import('node:assert/strict');
  const names=['GITHUB_TOKEN','ANTHROPIC_API_KEY','OPENAI_API_KEY','DYLD_INSERT_LIBRARIES','DYLD_LIBRARY_PATH','LD_PRELOAD','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY','NEANTIK_PROFILE_SEED','NEANTIK_PROFILE_TIMEZONE','FURY_FP_JSON','UNRELATED_SECRET'];
  const input=Object.fromEntries([...inheritedBrowserKeys.map(k=>[k,'owned-nonsecret-test-value']),...names.map(k=>[k,'owned-rejection-marker'])]);
  const result=browserFixtureEnvironment(input);assert.deepEqual(Object.keys(result),inheritedBrowserKeys);for(const n of names)assert(!Object.hasOwn(result,n));assert.equal(input.GITHUB_TOKEN,'owned-rejection-marker');
  const fs=await import('node:fs');assert(process.argv[3], 'Pass current manager source path');const source=fs.readFileSync(process.argv[3],'utf8');
  const body=source.match(/allowedInheritedEnvironmentKeys: Set<String> = \[([\s\S]*?)\]/)?.[1];assert(body);const sourceKeys=Array.from(body.matchAll(/"([A-Za-z_][A-Za-z_0-9]*)"/g),m=>m[1]);assert.deepEqual(sourceKeys,inheritedBrowserKeys,'QA/production inherited environment semantic drift');
  console.log(JSON.stringify({status:'verified-fixture-environment-policy',allowedKeys:inheritedBrowserKeys.length,negativeControls:names.length,productionSourceMatches:true,actualBrowser:false}));
}
