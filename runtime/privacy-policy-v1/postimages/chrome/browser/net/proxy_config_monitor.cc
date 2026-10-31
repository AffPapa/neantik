// Copyright 2017 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/net/proxy_config_monitor.h"

#include <utility>
#include <memory>
#include <string>

#include "base/check.h"
#include "base/command_line.h"
#include "base/environment.h"
#include "chrome/common/chrome_switches.h"
#include "net/base/proxy_server.h"
#include "net/base/proxy_string_util.h"
#include "net/proxy_resolution/proxy_config.h"
#include "net/proxy_resolution/proxy_config_service_fixed.h"
#include "net/proxy_resolution/proxy_config_with_annotation.h"
#include "net/traffic_annotation/network_traffic_annotation.h"

#include "base/strings/utf_string_conversions.h"
#include "build/build_config.h"
#include "build/chromeos_buildflags.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/net/proxy_service_factory.h"
#include "chrome/browser/policy/profile_policy_connector.h"
#include "chrome/browser/profiles/profile.h"
#include "components/enterprise/buildflags/buildflags.h"
#include "components/proxy_config/pref_proxy_config_tracker_impl.h"
#include "content/public/browser/browser_thread.h"
#include "extensions/buildflags/buildflags.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "services/network/public/mojom/network_context.mojom.h"

#if BUILDFLAG(ENTERPRISE_PROXY)
#include "chrome/browser/enterprise/net/enterprise_proxy_service_factory.h"
#endif  // BUILDFLAG(ENTERPRISE_PROXY)

#if BUILDFLAG(IS_CHROMEOS)
#include "chrome/browser/ash/profiles/profile_helper.h"
#endif  // BUILDFLAG(IS_CHROMEOS)

#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)
#include "extensions/browser/api/proxy/proxy_api.h"
#endif // BUILDFLAG(ENABLE_EXTENSIONS_CORE)

using content::BrowserThread;

namespace {
constexpr auto kNeAntikOwnedProxyTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("neantik_owned_profile_proxy", R"(
      semantics {
        sender: "NeAntik profile proxy"
        description: "Routes profile traffic through the user-selected mandatory proxy."
        trigger: "Profile network requests while mandatory proxy mode is active."
        data: "Requested destinations and normal proxied protocol data."
        destination: OTHER
        destination_other: "The user-selected proxy endpoint."
      }
      policy {
        cookies_allowed: YES
        cookies_store: "Cookies for this browser profile."
        setting: "User selects a required proxy for the browser profile."
        policy_exception_justification: "This profile explicitly requires its selected proxy."
      })");

std::unique_ptr<net::ProxyConfigService> NeAntikLockedProxyService() {
  const auto required = base::Environment::Create()->GetVar(
      "NEANTIK_PROFILE_PROXY_REQUIRED");
  if (!required) {
    return nullptr;
  }
  // Malformed owner protocol must stop before creating any NetworkContext.
  // Never print endpoint/environment values, or fall back to DIRECT/PAC.
  CHECK(*required == "1");
  const auto* command = base::CommandLine::ForCurrentProcess();
  CHECK(!command->HasSwitch(switches::kNoProxyServer));
  CHECK(!command->HasSwitch(switches::kProxyPacUrl));
  CHECK(!command->HasSwitch(switches::kProxyAutoDetect));
  CHECK(command->HasSwitch(switches::kProxyServer));
  CHECK(command->GetSwitchValueASCII(switches::kProxyBypassList) == "<-loopback>");
  const std::string raw = command->GetSwitchValueASCII(switches::kProxyServer);
  const size_t separator = raw.find("://");
  CHECK(separator != std::string::npos);
  const std::string scheme = raw.substr(0, separator);
  CHECK(scheme == "http" || scheme == "https" || scheme == "socks5");
  const std::string authority = raw.substr(separator + 3);
  CHECK(!authority.empty());
  CHECK(authority.find_first_of("/?#@,;=\\ \t\r\n") == std::string::npos);
  const auto server = net::ProxyUriToProxyServer(raw, net::ProxyServer::SCHEME_INVALID);
  CHECK(server.is_valid());
  CHECK(server.GetPort() > 0);
  CHECK(server.scheme() == net::ProxyServer::SCHEME_HTTP ||
        server.scheme() == net::ProxyServer::SCHEME_HTTPS ||
        server.scheme() == net::ProxyServer::SCHEME_SOCKS5);
  net::ProxyConfig config;
  config.proxy_rules().type = net::ProxyConfig::ProxyRules::Type::PROXY_LIST;
  config.proxy_rules().single_proxies.SetSingleProxyServer(server);
  config.proxy_rules().bypass_rules.ParseFromString("<-loopback>");
  return std::make_unique<net::ProxyConfigServiceFixed>(
      net::ProxyConfigWithAnnotation(config, kNeAntikOwnedProxyTrafficAnnotation));
}
}  // namespace


ProxyConfigMonitor::ProxyConfigMonitor(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  DCHECK(profile);

#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)
  profile_ = profile;
#endif  // BUILDFLAG(ENABLE_EXTENSIONS_CORE)

// If this is the ChromeOS sign-in or lock screen profile, just create the
// tracker from global state.
#if BUILDFLAG(IS_CHROMEOS)
  if (ash::ProfileHelper::IsSigninProfile(profile) ||
      ash::ProfileHelper::IsLockScreenProfile(profile)) {
    pref_proxy_config_tracker_ =
        ProxyServiceFactory::CreatePrefProxyConfigTrackerOfLocalState(
            g_browser_process->local_state());
  }
#endif  // BUILDFLAG(IS_CHROMEOS)

  if (!pref_proxy_config_tracker_) {
    enterprise_net::EnterpriseProxyService* enterprise_proxy_service = nullptr;
#if BUILDFLAG(ENTERPRISE_PROXY)
    enterprise_proxy_service =
        EnterpriseProxyServiceFactory::GetForProfile(profile);
#endif  // BUILDFLAG(ENTERPRISE_PROXY)
    pref_proxy_config_tracker_ =
        ProxyServiceFactory::CreatePrefProxyConfigTrackerOfProfile(
            profile->GetPrefs(), g_browser_process->local_state(),
            profile->GetProfilePolicyConnector()->policy_service(),
            enterprise_proxy_service);
  }

  proxy_config_service_ = ProxyServiceFactory::CreateProxyConfigService(
      pref_proxy_config_tracker_.get(), profile);

  if (auto locked = NeAntikLockedProxyService()) {
    proxy_config_service_ = std::move(locked);
  }
  proxy_config_service_->AddObserver(this);
}

ProxyConfigMonitor::ProxyConfigMonitor(PrefService* local_state) {
  DCHECK(BrowserThread::CurrentlyOn(BrowserThread::UI) ||
         !BrowserThread::IsThreadInitialized(BrowserThread::UI));

  pref_proxy_config_tracker_ =
      ProxyServiceFactory::CreatePrefProxyConfigTrackerOfLocalState(
          local_state);

  proxy_config_service_ = ProxyServiceFactory::CreateProxyConfigService(
      pref_proxy_config_tracker_.get(), nullptr);
  if (auto locked = NeAntikLockedProxyService()) {
    proxy_config_service_ = std::move(locked);
  }
  proxy_config_service_->AddObserver(this);
}

ProxyConfigMonitor::~ProxyConfigMonitor() {
  DCHECK(BrowserThread::CurrentlyOn(BrowserThread::UI) ||
         !BrowserThread::IsThreadInitialized(BrowserThread::UI));
  proxy_config_service_->RemoveObserver(this);
  pref_proxy_config_tracker_->DetachFromPrefService();
}

void ProxyConfigMonitor::AddToNetworkContextParams(
    network::mojom::NetworkContextParams* network_context_params) {
  mojo::PendingRemote<network::mojom::ProxyConfigClient> proxy_config_client;
  network_context_params->proxy_config_client_receiver =
      proxy_config_client.InitWithNewPipeAndPassReceiver();
  proxy_config_client_set_.Add(std::move(proxy_config_client));

  if (proxy_config_service_->UsesPolling()) {
    poller_receiver_set_.Add(this,
                             network_context_params->proxy_config_poller_client
                                 .InitWithNewPipeAndPassReceiver());
  }

#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)
  error_receiver_set_.Add(this, network_context_params->proxy_error_client
                                    .InitWithNewPipeAndPassReceiver());
#endif  // BUILDFLAG(ENABLE_EXTENSIONS_CORE)

  net::ProxyConfigWithAnnotation proxy_config;
  net::ProxyConfigService::ConfigAvailability availability =
      proxy_config_service_->GetLatestProxyConfig(&proxy_config);
  if (availability != net::ProxyConfigService::CONFIG_PENDING)
    network_context_params->initial_proxy_config = proxy_config;
}

void ProxyConfigMonitor::FlushForTesting() {
  proxy_config_client_set_.FlushForTesting();
}

void ProxyConfigMonitor::OnProxyConfigChanged(
    const net::ProxyConfigWithAnnotation& config,
    net::ProxyConfigService::ConfigAvailability availability) {
  DCHECK(BrowserThread::CurrentlyOn(BrowserThread::UI) ||
         !BrowserThread::IsThreadInitialized(BrowserThread::UI));
  for (const auto& proxy_config_client : proxy_config_client_set_) {
    switch (availability) {
      case net::ProxyConfigService::CONFIG_VALID:
        proxy_config_client->OnProxyConfigUpdated(config);
        break;
      case net::ProxyConfigService::CONFIG_UNSET:
        proxy_config_client->OnProxyConfigUpdated(
            net::ProxyConfigWithAnnotation::CreateDirect());
        break;
      case net::ProxyConfigService::CONFIG_PENDING:
        NOTREACHED();
    }
  }
}

void ProxyConfigMonitor::OnLazyProxyConfigPoll() {
  proxy_config_service_->OnLazyPoll();
}

#if BUILDFLAG(ENABLE_EXTENSIONS_CORE)
void ProxyConfigMonitor::OnPACScriptError(int32_t line_number,
                                          const std::string& details) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  extensions::ProxyEventRouter::GetInstance()->OnPACScriptError(
      profile_, line_number, base::UTF8ToUTF16(details));
}

void ProxyConfigMonitor::OnRequestMaybeFailedDueToProxySettings(
    int32_t net_error) {
  DCHECK(BrowserThread::CurrentlyOn(BrowserThread::UI) ||
         !BrowserThread::IsThreadInitialized(BrowserThread::UI));

  if (net_error >= 0) {
    // If the error is obviously wrong, don't dispatch it to extensions. If the
    // PAC executor process is compromised, then |net_error| could be attacker
    // controlled.
    return;
  }

  extensions::ProxyEventRouter::GetInstance()->OnProxyError(profile_,
                                                            net_error);
}
#endif  // BUILDFLAG(ENABLE_EXTENSIONS_CORE)
