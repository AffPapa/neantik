const status = document.getElementById('status');
const refresh = document.getElementById('refresh');
const exception = document.getElementById('exception');
let siteHost;
let exceptionEnabled = false;
async function render() {
  const {threatMetadata, threatUpdateError} = await chrome.storage.local.get(['threatMetadata', 'threatUpdateError']);
  const policy = await (await fetch(chrome.runtime.getURL('profile-policy.json'))).json();
  const trackers = await (await fetch(chrome.runtime.getURL('tracker-provenance.json'))).json();
  const cookies = await chrome.privacy.websites.thirdPartyCookiesAllowed.get({});
  const baseline = await (await fetch(chrome.runtime.getURL('baseline-provenance.json'))).json();
  const enabled = await chrome.declarativeNetRequest.getEnabledRulesets();
  const dynamic = await chrome.declarativeNetRequest.getDynamicRules();
  const hasDynamic = dynamic.some(rule => rule.id >= 10000);
  const date = threatMetadata?.observedAt ?? baseline.fetchedAt;
  const age = Date.now() - Date.parse(date);
  const present = enabled.includes('cert_baseline') || hasDynamic;
  status.textContent = `${present ? 'Список доменов установлен' : 'Список доменов не активен'}\n${threatMetadata?.domains ?? baseline.domains} доменов · ${new Date(date).toLocaleString()}\n${Number.isFinite(age) && age >= 0 && age <= 10*60*1000 ? 'Свежая загрузка списка' : 'Свежесть списка не подтверждена'}${threatUpdateError ? '\nОбновление недоступно; сохранены прежние правила.' : ''}`;
  status.textContent += `\nТрекеры HaGeZi: ${enabled.includes('trackers') ? 'включены' : 'выключены'} · снимок ${trackers.fetchedAt ?? trackers.observedAt ?? 'дата в сведениях источника'}\nСторонние cookies: ${cookies.value === false ? 'заблокированы' : 'разрешены'} (${cookies.levelOfControl})\nОчистка tracking query: ${enabled.includes('query_cleanup') ? 'включена' : 'выключена'}\nРежим защиты сайтов: ${policy.siteProtection ? 'запрошен' : 'выключен'}`;
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  try {
    const url = new URL(tab.url); if (!['http:', 'https:'].includes(url.protocol)) throw Error();
    siteHost = url.hostname;
    const rules = await chrome.declarativeNetRequest.getSessionRules();
    exceptionEnabled = rules.some(rule => rule.id >= 50000 && rule.id < 50100 && rule.condition.initiatorDomains?.includes(siteHost));
    exception.textContent = exceptionEnabled ? 'Восстановить блокировку трекеров на этом сайте' : 'Разрешить трекеры на этом сайте до закрытия браузера';
    exception.disabled = false;
  } catch { exception.disabled = true; }
}
refresh.addEventListener('click', async () => { refresh.disabled = true; try { await chrome.runtime.sendMessage({action: 'refresh'});await render(); } finally { refresh.disabled = false; } });
exception.addEventListener('click', async () => { if (!siteHost) return;exception.disabled = true;try { const response = await chrome.runtime.sendMessage({action:'tracker-exception',enabled:!exceptionEnabled,host:siteHost});if(!response?.ok) throw Error('exception-refused');await render(); } catch { status.textContent = 'Исключение не применено. Прежние правила сохранены.'; } finally { exception.disabled = false; } });
void render().catch(() => { status.textContent = 'Не удалось подтвердить состояние правил. Проверь расширение в chrome://extensions/.'; });

document.getElementById('clear-data').addEventListener('click',async()=>{
  try { await chrome.tabs.create({url:'chrome://settings/clearBrowserData'}); window.close(); }
  catch { document.getElementById('status').textContent='Откройте очистку в этом профиле сочетанием ⌘⇧⌫.'; }
});
