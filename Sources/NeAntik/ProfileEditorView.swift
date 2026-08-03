import SwiftUI

enum ProxyPasswordUpdate: Equatable {
  case keepExisting
  case replace(String)
  case delete

  static func resolve(
    currentHasUsername: Bool,
    originalHadUsername: Bool,
    enteredPassword: String,
    originalPassword: String?,
    readFailed: Bool
  ) -> Self {
    guard currentHasUsername else {
      return .delete
    }
    guard originalHadUsername else {
      return enteredPassword.isEmpty
        ? .delete
        : .replace(enteredPassword)
    }
    if readFailed {
      return enteredPassword.isEmpty
        ? .keepExisting
        : .replace(enteredPassword)
    }
    if enteredPassword == (originalPassword ?? "") {
      return .keepExisting
    }
    return enteredPassword.isEmpty
      ? .delete
      : .replace(enteredPassword)
  }
}

struct ProfileEditorView: View {
  let original: BrowserProfile?
  let keychain: KeychainStore
  let onSave: (BrowserProfile, ProxyPasswordUpdate) throws -> Void
  private let originalProxyPassword: String?
  private let proxyPasswordReadFailed: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var colorHex: String
  @State private var symbolName: String
  @State private var tagsText: String
  @State private var startURL: String
  @State private var usesProxy: Bool
  @State private var proxyKind: ProxyKind
  @State private var proxyHost: String
  @State private var proxyPort: String
  @State private var proxyUsername: String
  @State private var proxyPassword: String
  @State private var detectedProxy: ProxyConfiguration?
  @State private var detectedTimezone: String?
  @State private var detectedLocale: String?
  @State private var detectedLocation: String?
  @State private var detectedProxyContextEvidence: ProxyContextEvidence?
  @State private var errorMessage: String?
  @State private var testMessage: String?
  @State private var isTesting = false
  @State private var proxyTestTask: Task<Void, Never>?
  @State private var showsAdvancedOptions = false
  @FocusState private var nameIsFocused: Bool

  init(
    original: BrowserProfile?,
    keychain: KeychainStore,
    onSave: @escaping (BrowserProfile, ProxyPasswordUpdate) throws -> Void
  ) {
    self.original = original
    self.keychain = keychain
    self.onSave = onSave

    let profile = original ?? BrowserProfile(name: "")
    _name = State(initialValue: profile.name)
    _colorHex = State(initialValue: profile.colorHex)
    _symbolName = State(initialValue: profile.displaySymbolName)
    _tagsText = State(initialValue: profile.tags.joined(separator: ", "))
    _startURL = State(initialValue: profile.startURL)
    _usesProxy = State(initialValue: profile.proxy != nil)
    _proxyKind = State(initialValue: profile.proxy?.kind ?? .http)
    _proxyHost = State(initialValue: profile.proxy?.host ?? "")
    _proxyPort = State(initialValue: profile.proxy.map { String($0.port) } ?? "")
    _proxyUsername = State(initialValue: profile.proxy?.username ?? "")
    if original == nil {
      originalProxyPassword = nil
      proxyPasswordReadFailed = false
      _proxyPassword = State(initialValue: "")
    } else {
      do {
        let password = try keychain.proxyPassword(
          profileID: profile.id
        )
        originalProxyPassword = password
        proxyPasswordReadFailed = false
        _proxyPassword = State(
          initialValue: password ?? ""
        )
      } catch {
        originalProxyPassword = nil
        proxyPasswordReadFailed = true
        _proxyPassword = State(initialValue: "")
        _errorMessage = State(
          initialValue:
            "Не удалось прочитать пароль прокси: \(error.localizedDescription)"
        )
      }
    }
    _detectedProxy = State(
      initialValue: profile.identity.timezoneIdentifier == nil
        ? nil
        : profile.proxy
    )
    _detectedTimezone = State(
      initialValue: profile.identity.timezoneIdentifier
    )
    _detectedLocale = State(
      initialValue: profile.identity.localeIdentifier
    )
    _detectedLocation = State(initialValue: nil)
    _detectedProxyContextEvidence = State(
      initialValue: profile.identity.proxyContextEvidence
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Профиль") {
          TextField("Название", text: $name)
            .accessibilityLabel("Название профиля")
            .focused($nameIsFocused)
            .onSubmit(save)
            .onChange(of: name) { _, value in
              if value.count > BrowserProfile.maximumNameLength {
                name = String(
                  value.prefix(
                    BrowserProfile.maximumNameLength
                  )
                )
              }
            }
          Text(
            "\(name.count) из \(BrowserProfile.maximumNameLength) символов"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Section {
          DisclosureGroup(
            "Дополнительно",
            isExpanded: $showsAdvancedOptions
          ) {
            VStack(alignment: .leading, spacing: 14) {
              TextField("Стартовая страница", text: $startURL)
                .accessibilityLabel("Стартовая страница")

              Text("Иконка и цвет")
                .font(.headline)
              LazyVGrid(
                columns: [
                  GridItem(
                    .adaptive(minimum: 42, maximum: 46),
                    spacing: 10
                  )
                ],
                alignment: .leading,
                spacing: 10
              ) {
                ForEach(ProfileAppearance.symbols, id: \.self) { symbol in
                  Button {
                    symbolName = symbol
                  } label: {
                    RoundedRectangle(cornerRadius: 10)
                      .fill(
                        symbolName == symbol
                          ? Color.accentColor
                          : Color.secondary.opacity(0.12)
                      )
                      .frame(width: 42, height: 42)
                      .overlay {
                        Image(systemName: symbol)
                          .font(
                            .system(
                              size: 18,
                              weight: .medium
                            )
                          )
                          .foregroundStyle(
                            symbolName == symbol
                              ? Color.white
                              : Color.primary
                          )
                      }
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(
                    "Иконка \(ProfileAppearance.title(for: symbol))"
                  )
                  .accessibilityValue(
                    symbolName == symbol
                      ? "Выбрана"
                      : "Не выбрана"
                  )
                }
              }

              HStack(spacing: 9) {
                Text("Цвет")
                Spacer()
                ForEach(ProfileAppearance.colors, id: \.self) { hex in
                  Button {
                    colorHex = hex
                  } label: {
                    Circle()
                      .fill(Color(hex: hex))
                      .frame(width: 22, height: 22)
                      .overlay {
                        if colorHex == hex {
                          Image(systemName: "checkmark")
                            .font(
                              .system(
                                size: 9,
                                weight: .bold
                              )
                            )
                            .foregroundStyle(
                              ProfileAppearance
                                .usesDarkForeground(
                                  for: hex
                                )
                                ? Color.black
                                : Color.white
                            )
                        }
                      }
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(
                    ProfileAppearance.title(forColor: hex)
                  )
                  .accessibilityValue(
                    colorHex == hex
                      ? "Выбран"
                      : "Не выбран"
                  )
                }
              }

              Divider()
              TextField(
                "Теги через запятую",
                text: $tagsText,
                prompt: Text("Например: работа, магазин")
              )
              .accessibilityLabel("Теги профиля")
              Text(
                "До \(BrowserProfile.maximumTagCount) тегов, каждый не длиннее \(BrowserProfile.maximumTagLength) символов. Теги хранятся только на этом Mac."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
          }
        }

        Section("Сеть") {
          Toggle("Использовать прокси", isOn: $usesProxy)
          if usesProxy {
            Picker("Тип", selection: $proxyKind) {
              ForEach(ProxyKind.allCases) { kind in
                Text(kind.title).tag(kind)
              }
            }

            HStack {
              TextField("Хост", text: $proxyHost)
              TextField("Порт", text: $proxyPort)
                .frame(width: 90)
            }
            if proxyKind == .socks5 {
              Text(
                "Chromium поддерживает SOCKS5 только без логина и пароля. DNS для сайтов будет идти через прокси."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            } else {
              TextField(
                "Логин (необязательно)",
                text: $proxyUsername
              )
              SecureField(
                "Пароль (хранится в Связке ключей)",
                text: $proxyPassword
              )
            }

            HStack {
              Button {
                testProxy()
              } label: {
                Label("Проверить прокси", systemImage: "network")
              }
              .disabled(isTesting)

              if isTesting {
                ProgressView()
                  .controlSize(.small)
              }
              if let testMessage {
                Text(testMessage)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            Text(
              "Проверка обращается к ipapi.co через прокси, чтобы увидеть внешний IP и примерную локацию."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if !proxyUsername.isEmpty {
              Text(
                "Chromium может попросить логин и пароль при первом запуске. NeAntik не подставляет их автоматически: скопируй логин и пароль из карточки профиля. Пароль хранится только в Связке ключей."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              Text(
                "Проверка подтверждает доступность прокси и его внешний адрес, но не ввод логина в окне Chromium."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }

            if let detectedTimezone {
              Text(
                [
                  detectedLocation,
                  detectedTimezone,
                  detectedLocale,
                ]
                .compactMap { $0 }
                .joined(separator: " · ")
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            if let evidence = detectedProxyContextEvidence {
              Text(
                "Источник: \(evidence.source) · проверено \(evidence.observedAt.formatted(date: .abbreviated, time: .shortened)). При запуске повторного запроса нет."
              )
              .font(.caption)
              .foregroundStyle(
                evidence.isFresh()
                  ? Color.secondary
                  : Color.orange
              )
            } else if detectedTimezone != nil {
              Text(
                "Сохранено старой версией без даты проверки. Нажми «Проверить прокси», чтобы обновить контекст."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("Отмена") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button(original == nil ? "Создать" : "Сохранить") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(
      minWidth: 460,
      idealWidth: 540,
      minHeight: 380,
      idealHeight: usesProxy ? 580 : 430
    )
    .onAppear {
      if original == nil {
        nameIsFocused = true
      }
    }
    .onDisappear {
      proxyTestTask?.cancel()
    }
  }

  private func makeProxy() throws -> ProxyConfiguration? {
    guard usesProxy else { return nil }
    guard let port = Int(proxyPort) else {
      throw NeAntikError.invalidProxy
    }
    let value = ProxyConfiguration(
      kind: proxyKind,
      host: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
      port: port,
      username: proxyKind == .socks5
        ? ""
        : proxyUsername.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
    )
    guard value.isValid else {
      throw NeAntikError.invalidProxy
    }
    return value
  }

  private func save() {
    do {
      let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard BrowserProfile.isValidName(cleanName),
        let cleanStartURL =
          BrowserLaunchBuilder.validatedStartURL(startURL)
      else {
        throw NeAntikError.invalidProfile
      }

      var profile = original ?? BrowserProfile(name: cleanName)
      profile.name = cleanName
      profile.colorHex = colorHex
      profile.symbolName = symbolName
      profile.tags = try parsedTags()
      profile.startURL = cleanStartURL.absoluteString
      let proxy = try makeProxy()
      profile.proxy = proxy
      let locationMatchesProxy = proxy != nil && proxy == detectedProxy
      profile.identity = profile.identity.replacingProxyContext(
        timezoneIdentifier: locationMatchesProxy
          ? detectedTimezone
          : nil,
        localeIdentifier: locationMatchesProxy
          ? detectedLocale
          : nil,
        evidence: locationMatchesProxy
          ? detectedProxyContextEvidence
          : nil
      )
      let passwordUpdate = ProxyPasswordUpdate.resolve(
        currentHasUsername: proxy?.username.isEmpty == false,
        originalHadUsername:
          original?.proxy?.username.isEmpty == false,
        enteredPassword: proxyPassword,
        originalPassword: originalProxyPassword,
        readFailed: proxyPasswordReadFailed
      )
      try onSave(profile, passwordUpdate)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func parsedTags() throws -> [String] {
    let values = tagsText.split(
      separator: ",",
      omittingEmptySubsequences: true
    ).map(String.init)
    guard let normalized = BrowserProfile.normalizedTags(values) else {
      throw ProfileTagsValidationError()
    }
    return normalized
  }

  private func testProxy() {
    do {
      guard let proxy = try makeProxy() else { return }
      proxyTestTask?.cancel()
      isTesting = true
      testMessage = nil
      let password = proxyPassword
      proxyTestTask = Task {
        do {
          let result = try await ProxyTester().test(
            configuration: proxy,
            password: password
          )
          try Task.checkCancellation()
          await MainActor.run {
            let location = result.locationSummary
            testMessage =
              location.isEmpty
              ? "Подключено · \(result.ipAddress)"
              : "Подключено · \(result.ipAddress) · \(location)"
            detectedProxy = proxy
            detectedTimezone = result.timezoneIdentifier
            detectedLocale = result.localeIdentifier
            detectedLocation = location.isEmpty ? nil : location
            detectedProxyContextEvidence = .ipAPI()
            isTesting = false
          }
        } catch {
          guard !Task.isCancelled else { return }
          await MainActor.run {
            testMessage = error.localizedDescription
            isTesting = false
          }
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct ProfileTagsValidationError: LocalizedError {
  var errorDescription: String? {
    "Проверь теги: не больше \(BrowserProfile.maximumTagCount), до \(BrowserProfile.maximumTagLength) символов каждый."
  }
}
