// Own local MV3 fixture: privacy permission only, no host access or remote code.
(async () => {
  const policy = OWN_POLICY_MODE;
  const settings = chrome.privacy.network.webRTCIPHandlingPolicy;
  const bounded = operation => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('OwnedPrivacyOperationTimeout')), 3000);
    operation(value => {clearTimeout(timer); resolve(value);});
  });
  const get = () => bounded(done => settings.get({}, value => done({value: value?.value,
    levelOfControl: value?.levelOfControl, error: chrome.runtime.lastError?.message ?? null})));
  const set = value => bounded(done => settings.set({value, scope: 'regular'}, () =>
    done({value, error: chrome.runtime.lastError?.message ?? null})));
  try {
    const operations = [];
    if (!policy) for (const value of ['disable_non_proxied_udp', 'default']) {
      operations.push({set: await set(value), get: await get()});
    }
    globalThis.OWN_EXTENSION_RECEIPT = {nonce: document.body.dataset.ownExtension,
      runtimeID: chrome.runtime.id, policy, operations, final: await get(),
      permissions: chrome.runtime.getManifest().permissions};
  } catch (error) {
    globalThis.OWN_EXTENSION_RECEIPT = {error: error.name};
  }
})();
