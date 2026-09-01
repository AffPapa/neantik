import AppKit
import SwiftUI

enum ProxyPasswordUpdate: Equatable {
  case keepExisting
  case replace(String)
  case delete

  func requiresCredentialMutation(originalHadUsername: Bool) -> Bool {
    switch self {
    case .keepExisting:
      false
    case .replace:
      true
    case .delete:
      originalHadUsername
    }
  }

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

struct ProfileEditorFolderPresentation: Equatable, Sendable {
  static let searchablePickerThreshold = 8

  let quickOptions: [ProfileFolderCommandOption]
  let selectedTitle: String
  let offersSearchablePicker: Bool

  static func resolve(
    folders: [ProfileFolder],
    selectedFolderID: UUID?
  ) -> Self {
    let offersSearchablePicker =
      folders.count > searchablePickerThreshold
    let projection = ProfileFolderCommandProjection.resolve(
      folders: folders,
      currentFolderID: selectedFolderID,
      limit: offersSearchablePicker
        ? ProfileFolderCommandProjection.defaultLimit
        : folders.count + 1
    )
    let selectedTitle = folders.first(where: {
      $0.id == selectedFolderID
    })?.name ?? "Без папки"
    return Self(
      quickOptions: projection.options,
      selectedTitle: selectedTitle,
      offersSearchablePicker: offersSearchablePicker
    )
  }
}

struct ProfileEditorProxyContextPresentation: Equatable, Sendable {
  let title: String
  let detail: String
  let systemImage: String
  let requiresAttention: Bool

  static func resolve(
    evidence: ProxyContextEvidence,
    now: Date = Date()
  ) -> Self {
    let isFresh = evidence.isFresh(relativeTo: now)
    return Self(
      title: isFresh
        ? "Контекст прокси свежий"
        : "Контекст прокси устарел",
      detail:
        "Источник: \(evidence.source) · проверено " +
        "\(evidence.observedAt.neAntikDisplayDateTime). " +
        (isFresh
          ? "Перед каждым запуском профиля NeAntik проверит " +
            "прокси заново."
          : "Перед следующим запуском профиля NeAntik проверит " +
            "прокси заново."),
      systemImage: isFresh
        ? "checkmark.circle.fill"
        : "exclamationmark.triangle.fill",
      requiresAttention: !isFresh
    )
  }
}

struct ProfileEditorView: View {
  let original: BrowserProfile?
  let keychain: KeychainStore
  let folders: [ProfileFolder]
  let suggestedTags: [String]
  let onSave: (
    BrowserProfile,
    ProxyPasswordUpdate,
    UUID?
  ) throws -> Void
  private let originalProxyPassword: String?
  private let proxyPasswordReadFailed: Bool
  private let draftProfileID: UUID
  private let initialFocus: ProfileEditorField?
  private let appliesOnNextLaunch: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var colorHex: String
  @State private var symbolName: String
  @State private var tags: [String]
  @State private var note: String
  @State private var showsNoteEditor: Bool
  @State private var selectedFolderID: UUID?
  @State private var startURL: String
  @State private var usesProxy: Bool
  @State private var proxyKind: ProxyKind
  @State private var proxyHost: String
  @State private var proxyPort: String
  @State private var proxyUsername: String
  @State private var proxyPassword: String
  @State private var proxyImportText = ""
  @State private var proxyImportOrder: ProxyImportOrder = .automatic
  @State private var proxyImportNotice: UserNotice?
  @State private var isApplyingProxyImport = false
  @State private var detectedProxy: ProxyConfiguration?
  @State private var detectedTimezone: String?
  @State private var detectedLocale: String?
  @State private var detectedLocation: String?
  @State private var detectedProxyContextEvidence: ProxyContextEvidence?
  @State private var errorMessage: String?
  @State private var validationIssue: ProfileEditorValidationIssue?
  @State private var testNotice: UserNotice?
  @State private var isTesting = false
  @State private var proxyTestTask: Task<Void, Never>?
  @State private var showsAdvancedOptions = false
  @State private var hasUnsavedChanges = false
  @State private var showingDiscardConfirmation = false
  @State private var showingFolderPicker = false
  @FocusState private var focusedField: ProfileEditorField?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    original: BrowserProfile?,
    keychain: KeychainStore,
    folders: [ProfileFolder],
    initialFolderID: UUID?,
    suggestedTags: [String],
    appliesOnNextLaunch: Bool = false,
    showsAdvancedOptionsInitially: Bool = false,
    initialFocus: ProfileEditorField? = nil,
    onSave: @escaping (
      BrowserProfile,
      ProxyPasswordUpdate,
      UUID?
    ) throws -> Void
  ) {
    self.original = original
    self.keychain = keychain
    self.folders = folders.sorted(by: ProfileFolder.areInIncreasingOrder)
    self.suggestedTags = suggestedTags
    self.appliesOnNextLaunch = appliesOnNextLaunch
    self.onSave = onSave
    self.initialFocus = initialFocus
    _showsAdvancedOptions = State(
      initialValue: showsAdvancedOptionsInitially
    )

    let profile = original ?? BrowserProfile(name: "")
    draftProfileID = profile.id
    _name = State(initialValue: profile.name)
    _colorHex = State(initialValue: profile.colorHex)
    _symbolName = State(initialValue: profile.displaySymbolName)
    _tags = State(initialValue: profile.tags)
    _note = State(initialValue: profile.note)
    _showsNoteEditor = State(
      initialValue: original == nil || initialFocus == .note
    )
    _selectedFolderID = State(
      initialValue: folders.contains { $0.id == initialFolderID }
        ? initialFolderID
        : nil
    )
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

  init(
    original: BrowserProfile?,
    keychain: KeychainStore,
    showsAdvancedOptionsInitially: Bool = false,
    onSave: @escaping (BrowserProfile, ProxyPasswordUpdate) throws -> Void
  ) {
    self.init(
      original: original,
      keychain: keychain,
      folders: [],
      initialFolderID: nil,
      suggestedTags: original?.tags ?? [],
      appliesOnNextLaunch: false,
      showsAdvancedOptionsInitially: showsAdvancedOptionsInitially
    ) { profile, passwordUpdate, _ in
      try onSave(profile, passwordUpdate)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { scrollProxy in
        Form {
        if appliesOnNextLaunch {
          Section {
            Label(
              "Профиль запущен. Название, заметка, теги и папка сохранятся сразу; параметры Chromium и прокси применятся при следующем запуске.",
              systemImage: "clock.arrow.circlepath"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
          }
        }
        Section("Профиль") {
          TextField("Название", text: $name)
            .accessibilityLabel("Название профиля")
            .focused($focusedField, equals: .name)
            .id(ProfileEditorField.name)
            .onSubmit {
              focusedField = nil
            }
            .onChange(of: name) { _, value in
              hasUnsavedChanges = true
              clearValidation(for: .name)
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
          validationLabel(for: .name)

          noteEditor
        }

        Section("Сеть") {
          Toggle("Использовать прокси", isOn: $usesProxy)
          if usesProxy {
            Picker("Тип", selection: $proxyKind) {
              ForEach(ProxyKind.allCases) { kind in
                Text(kind.title).tag(kind)
              }
            }

            SecureField(
              "Вставить прокси одной строкой",
              text: $proxyImportText
            )
            .accessibilityLabel("Строка прокси для импорта")
            Text("Например: login:password@ip:port или ip:port@login:password")
            .font(.caption)
            .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
              HStack {
                proxyImportOrderPicker
                Spacer(minLength: 8)
                importProxyButton
              }
              VStack(alignment: .leading, spacing: 8) {
                proxyImportOrderPicker
                importProxyButton
              }
            }
            if let proxyImportNotice {
              UserNoticeLabel(notice: proxyImportNotice)
            }

            ViewThatFits(in: .horizontal) {
              HStack {
                TextField("Хост", text: $proxyHost)
                  .focused($focusedField, equals: .proxyHost)
                  .id(ProfileEditorField.proxyHost)
                TextField("Порт", text: $proxyPort)
                  .frame(width: 90)
                  .focused($focusedField, equals: .proxyPort)
                  .id(ProfileEditorField.proxyPort)
              }
              VStack(alignment: .leading, spacing: 8) {
                TextField("Хост", text: $proxyHost)
                  .focused($focusedField, equals: .proxyHost)
                  .id(ProfileEditorField.proxyHost)
                TextField("Порт", text: $proxyPort)
                  .focused($focusedField, equals: .proxyPort)
                  .id(ProfileEditorField.proxyPort)
              }
            }
            validationLabel(for: .proxyHost)
            validationLabel(for: .proxyPort)
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
              .focused($focusedField, equals: .proxyPassword)
              .id(ProfileEditorField.proxyPassword)
              validationLabel(for: .proxyPassword)
            }

            HStack(spacing: 10) {
              if isTesting {
                ProgressView()
                  .controlSize(.small)
                  .accessibilityHidden(true)
                Text("Проверяем прокси…")
                  .foregroundStyle(.secondary)
                Button("Отменить") {
                  cancelProxyTest()
                }
                .help("Отменить проверку прокси")
              } else {
                Button {
                  testProxy()
                } label: {
                  Label("Проверить прокси", systemImage: "network")
                }
              }
              if let testNotice {
                UserNoticeLabel(notice: testNotice)
              }
            }

            DisclosureGroup("Как работает проверка и авторизация") {
              Text(
                "Проверка обращается к ipapi.co через прокси и показывает внешний IP и примерную локацию. Перед каждым запуском NeAntik проверяет прокси заново. Проверка не доказывает маршрут Chromium."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              if !proxyUsername.isEmpty {
                Text(
                  "Chromium может запросить логин и пароль при первом запуске. NeAntik не вводит их автоматически; пароль хранится только в Связке ключей."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
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
              let status = ProfileEditorProxyContextPresentation.resolve(
                evidence: evidence
              )
              Label(status.title, systemImage: status.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                  status.requiresAttention
                    ? Color.orange
                    : Color.secondary
                )
              Text(status.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityElement(children: .combine)
              .accessibilityLabel("\(status.title). \(status.detail)")
            } else if detectedTimezone != nil {
              Label(
                "Контекст прокси без даты проверки",
                systemImage: "exclamationmark.triangle.fill"
              )
              .font(.caption.weight(.semibold))
              .foregroundStyle(.orange)
              Text(
                "Перед следующим запуском профиля NeAntik проверит " +
                "прокси заново. Можно проверить сейчас."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          } else {
            Label(
              "Прямое подключение",
              systemImage: "exclamationmark.shield"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            Text(
              "Сайты увидят обычный публичный адрес этого Mac или " +
                "системного VPN. Для профиля не настроен отдельный прокси."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
          }
        }

        advancedOptionsSection

        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }
        }
        .formStyle(.grouped)
        .onChange(of: validationIssue?.field) { _, field in
          guard let field else { return }
          if reduceMotion {
            scrollProxy.scrollTo(field, anchor: .center)
          } else {
            withAnimation(.easeInOut(duration: 0.18)) {
              scrollProxy.scrollTo(field, anchor: .center)
            }
          }
        }
      }
      .frame(minHeight: 0, maxHeight: .infinity)
      .layoutPriority(-1)

      Divider()

      HStack {
        Spacer()
        Button("Отмена") {
          requestDismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button(original == nil ? "Создать" : "Сохранить") {
          save()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
      }
      .padding()
      .fixedSize(horizontal: false, vertical: true)
      .background(.bar)
    }
    .frame(
      minWidth: 460,
      idealWidth: 540,
      minHeight: 380,
      idealHeight: usesProxy ? 620 : 500
    )
    .sheet(isPresented: $showingFolderPicker) {
      ProfileFolderPickerSheet(
        profileName:
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Новый профиль"
            : name,
        folders: folders,
        selectedFolderID: selectedFolderID
      ) { folderID in
        selectedFolderID = folderID
      }
    }
    .interactiveDismissDisabled(hasUnsavedChanges)
    .alert(
      "Отменить изменения?",
      isPresented: $showingDiscardConfirmation
    ) {
      Button("Продолжить редактирование", role: .cancel) {}
      Button("Отменить изменения", role: .destructive) {
        dismiss()
      }
    } message: {
      Text("Несохранённые изменения профиля будут потеряны.")
    }
    .onAppear {
      let target = initialFocus ?? (original == nil ? .name : nil)
      guard let target else { return }
      if target == .note {
        showsNoteEditor = true
      }
      Task { @MainActor in
        await Task.yield()
        focusedField = target
      }
    }
    .onDisappear {
      proxyTestTask?.cancel()
    }
    .onChange(of: usesProxy) { _, _ in
      hasUnsavedChanges = true
      proxyInputDidChange()
    }
    .onChange(of: proxyKind) { _, _ in
      hasUnsavedChanges = true
      proxyInputDidChange()
    }
    .onChange(of: proxyHost) { _, _ in
      hasUnsavedChanges = true
      clearValidation(for: .proxyHost)
      proxyInputDidChange()
    }
    .onChange(of: proxyPort) { _, _ in
      hasUnsavedChanges = true
      clearValidation(for: .proxyPort)
      proxyInputDidChange()
    }
    .onChange(of: proxyUsername) { _, _ in
      hasUnsavedChanges = true
      proxyInputDidChange()
    }
    .onChange(of: proxyPassword) { _, _ in
      hasUnsavedChanges = true
      clearValidation(for: .proxyPassword)
      proxyInputDidChange()
    }
    .onChange(of: proxyImportOrder) { _, _ in
      hasUnsavedChanges = true
      proxyImportNotice = nil
    }
    .onChange(of: tags) { _, _ in
      hasUnsavedChanges = true
      clearValidation(for: .tags)
    }
    .onChange(of: note) { _, _ in
      hasUnsavedChanges = true
      clearValidation(for: .note)
    }
    .onChange(of: selectedFolderID) { _, _ in hasUnsavedChanges = true }
    .onChange(of: startURL) { _, _ in
      hasUnsavedChanges = true
      clearValidation(for: .startURL)
    }
    .onChange(of: colorHex) { _, _ in hasUnsavedChanges = true }
    .onChange(of: symbolName) { _, _ in hasUnsavedChanges = true }
  }

  private func requestDismiss() {
    if hasUnsavedChanges {
      showingDiscardConfirmation = true
    } else {
      dismiss()
    }
  }

  private var notePresentation: ProfileNotePresentation {
    ProfileNotePresentation.resolve(note)
  }

  private var folderPresentation: ProfileEditorFolderPresentation {
    ProfileEditorFolderPresentation.resolve(
      folders: folders,
      selectedFolderID: selectedFolderID
    )
  }

  private var advancedOptionsSection: some View {
    Section {
      Button {
        focusedField = nil
        if reduceMotion {
          showsAdvancedOptions.toggle()
        } else {
          withAnimation(.easeInOut(duration: 0.18)) {
            showsAdvancedOptions.toggle()
          }
        }
      } label: {
        HStack {
          Image(
            systemName:
              showsAdvancedOptions
                ? "chevron.down"
                : "chevron.right"
          )
          .font(.caption.weight(.semibold))
          .accessibilityHidden(true)
          Text("Дополнительно")
            .fontWeight(.semibold)
          Spacer()
          Text("Папка, теги и оформление")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(
          maxWidth: .infinity,
          minHeight: 28,
          alignment: .leading
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Дополнительные настройки профиля")
      .accessibilityValue(
        showsAdvancedOptions ? "Развёрнуто" : "Свёрнуто"
      )
      .accessibilityHint(
        showsAdvancedOptions
          ? "Скрывает папку, теги, стартовую страницу и оформление"
          : "Показывает папку, теги, стартовую страницу и оформление"
      )

      if showsAdvancedOptions {
        Text("Организация")
          .font(.headline)
        folderControl
        ProfileTagEditor(
          tags: $tags,
          suggestions: suggestedTags
        )
        .id(ProfileEditorField.tags)
        validationLabel(for: .tags)

        Divider()

        TextField("Стартовая страница", text: $startURL)
          .accessibilityLabel("Стартовая страница")
          .focused($focusedField, equals: .startURL)
          .id(ProfileEditorField.startURL)
        validationLabel(for: .startURL)

        Divider()

        Text("Иконка")
          .font(.headline)
        appearanceIconGrid

        Text("Цвет")
          .font(.headline)
        appearanceColorGrid
      }
    }
  }

  private var appearanceIconGrid: some View {
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(
                  symbolName == symbol ? Color.white : Color.primary
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "Иконка \(ProfileAppearance.title(for: symbol))"
        )
        .accessibilityValue(
          symbolName == symbol ? "Выбрана" : "Не выбрана"
        )
      }
    }
  }

  private var appearanceColorGrid: some View {
    LazyVGrid(
      columns: [
        GridItem(
          .adaptive(minimum: 28, maximum: 32),
          spacing: 9
        )
      ],
      alignment: .leading,
      spacing: 9
    ) {
      ForEach(ProfileAppearance.colors, id: \.self) { hex in
        Button {
          colorHex = hex
        } label: {
          Circle()
            .fill(Color(hex: hex))
            .frame(width: 24, height: 24)
            .overlay {
              if colorHex == hex {
                Image(systemName: "checkmark")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(
                    ProfileAppearance.usesDarkForeground(for: hex)
                      ? Color.black
                      : Color.white
                  )
              }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ProfileAppearance.title(forColor: hex))
        .accessibilityValue(colorHex == hex ? "Выбран" : "Не выбран")
      }
    }
  }

  @ViewBuilder
  private var folderControl: some View {
    if folderPresentation.offersSearchablePicker {
      LabeledContent("Папка") {
        Menu {
          ForEach(folderPresentation.quickOptions) { option in
            Button {
              selectedFolderID = option.folderID
            } label: {
              if option.isSelected {
                Label(option.title, systemImage: "checkmark")
              } else {
                Text(option.title)
              }
            }
          }
          Divider()
          Button("Выбрать другую папку…") {
            Task { @MainActor in
              await Task.yield()
              showingFolderPicker = true
            }
          }
        } label: {
          Text(folderPresentation.selectedTitle)
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Папка профиля в NeAntik")
        .accessibilityValue(folderPresentation.selectedTitle)
        .accessibilityHint(
          "Показывает список папок и поиск по всем папкам"
        )
      }
    } else {
      Picker("Папка", selection: $selectedFolderID) {
        ForEach(folderPresentation.quickOptions) { option in
          Text(option.title).tag(option.folderID)
        }
      }
      .pickerStyle(.menu)
      .accessibilityLabel("Папка профиля в NeAntik")
    }
  }

  @ViewBuilder
  private var noteEditor: some View {
    Button {
      let willExpand = !showsNoteEditor
      if reduceMotion {
        showsNoteEditor = willExpand
      } else {
        withAnimation(.easeInOut(duration: 0.18)) {
          showsNoteEditor = willExpand
        }
      }
      if willExpand {
        Task { @MainActor in
          await Task.yield()
          focusedField = .note
        }
      } else if focusedField == .note {
        focusedField = nil
      }
    } label: {
      HStack(spacing: 8) {
        Image(
          systemName: showsNoteEditor ? "chevron.down" : "chevron.right"
        )
        .font(.caption.weight(.semibold))
        Image(systemName: "note.text")
          .accessibilityHidden(true)
        Text("Заметка (необязательно)")
          .fontWeight(.semibold)
        Spacer()
        Text(
          notePresentation.collapsedSummary.isEmpty
            ? "Не добавлена"
            : "Добавлена"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Необязательная заметка профиля")
    .accessibilityValue(
      showsNoteEditor
        ? "Развёрнуто"
        : (
          notePresentation.collapsedSummary.isEmpty
            ? "Свёрнуто, не добавлена"
            : "Свёрнуто, добавлена"
        )
    )
    .accessibilityHint(
      showsNoteEditor
        ? "Скрывает поле заметки"
        : "Показывает поле заметки"
    )

    if !showsNoteEditor,
      !notePresentation.collapsedSummary.isEmpty
    {
      Text(notePresentation.collapsedSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityLabel("Краткая заметка")
        .accessibilityValue(notePresentation.collapsedSummary)
    }

    if showsNoteEditor {
      ZStack(alignment: .topLeading) {
        TextEditor(text: $note)
          .focused($focusedField, equals: .note)
          .id(ProfileEditorField.note)
          .accessibilityLabel("Необязательная заметка профиля")
          .accessibilityHint(
            "До \(BrowserProfile.maximumNoteLength) символов"
          )
        if note.isEmpty {
          Text("Короткий контекст для этого профиля")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
      }
      .frame(minHeight: 72, idealHeight: 84, maxHeight: 96)

      HStack(alignment: .firstTextBaseline) {
        Text(notePresentation.countLabel)
          .foregroundStyle(
            notePresentation.validationMessage == nil
              ? Color.secondary
              : Color.red
          )
        Spacer()
        if notePresentation.utf8ByteCount >
          BrowserProfile.maximumNoteUTF8Bytes
        {
          Text(
            "\(notePresentation.utf8ByteCount) из " +
              "\(BrowserProfile.maximumNoteUTF8Bytes) байт"
          )
          .foregroundStyle(.red)
        }
        Label(
          "Без паролей, ключей и seed-фраз",
          systemImage: "exclamationmark.shield"
        )
        .foregroundStyle(.secondary)
        .accessibilityLabel(
          "Заметка хранится локально открытым текстом. " +
            "Не сохраняй здесь пароли, API-ключи или seed-фразы."
        )
      }
      .font(.caption)

      if let message = notePresentation.validationMessage {
        Label(message, systemImage: "exclamationmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityElement(children: .combine)
      }
    }
  }

  private var proxyImportOrderPicker: some View {
    Picker("Порядок", selection: $proxyImportOrder) {
      ForEach(ProxyImportOrder.allCases) { order in
        Text(order.title).tag(order)
      }
    }
    .pickerStyle(.menu)
    .accessibilityLabel("Расположение адреса прокси")
  }

  private var importProxyButton: some View {
    Button {
      importProxy()
    } label: {
      Label("Вставить прокси", systemImage: "doc.on.clipboard")
    }
    .disabled(isTesting)
    .help(
      "Взять строку из поля или буфера обмена и заполнить настройки"
    )
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
    if let issue = ProfileEditorValidation.firstIssue(
      name: name,
      tags: tags,
      note: note,
      startURL: startURL,
      usesProxy: usesProxy,
      proxyKind: proxyKind,
      proxyHost: proxyHost,
      proxyPort: proxyPort,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword
    ) {
      presentValidation(issue)
      return
    }
    do {
      let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard BrowserProfile.isValidName(cleanName),
        let cleanStartURL =
          BrowserLaunchBuilder.validatedStartURL(startURL)
      else {
        throw NeAntikError.invalidProfile
      }

      var profile = original ?? BrowserProfile(
        id: draftProfileID,
        name: cleanName
      )
      profile.name = cleanName
      profile.colorHex = colorHex
      profile.symbolName = symbolName
      guard let normalizedTags = BrowserProfile.normalizedTags(tags) else {
        throw ProfileTagsValidationError()
      }
      guard let normalizedNote = BrowserProfile.normalizedNote(note) else {
        throw NeAntikError.invalidProfile
      }
      profile.tags = normalizedTags
      profile.note = normalizedNote
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
      try onSave(profile, passwordUpdate, selectedFolderID)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      announce(error.localizedDescription)
    }
  }

  @ViewBuilder
  private func validationLabel(
    for field: ProfileEditorField
  ) -> some View {
    if validationIssue?.field == field,
      let message = validationIssue?.message
    {
      Label(message, systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
  }

  private func presentValidation(_ issue: ProfileEditorValidationIssue) {
    validationIssue = issue
    errorMessage = nil
    switch issue.field {
    case .startURL, .tags:
      showsAdvancedOptions = true
    case .name, .note, .proxyHost, .proxyPort, .proxyPassword:
      break
    }
    if issue.field == .note {
      showsNoteEditor = true
    }
    announce(issue.message)
    Task { @MainActor in
      await Task.yield()
      switch issue.field {
      case .name, .note, .startURL, .proxyHost, .proxyPort,
        .proxyPassword:
        focusedField = issue.field
      case .tags:
        focusedField = nil
      }
    }
  }

  private func clearValidation(for field: ProfileEditorField) {
    if validationIssue?.field == field {
      validationIssue = nil
    }
  }

  private func testProxy() {
    do {
      guard let proxy = try makeProxy() else { return }
      startProxyTest(
        configuration: proxy,
        password: proxyPassword
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func cancelProxyTest() {
    proxyTestTask?.cancel()
    proxyTestTask = nil
    isTesting = false
    testNotice = UserNotice(
      "Проверка отменена",
      level: .information
    )
    announce("Проверка прокси отменена.")
  }

  private func importProxy() {
    do {
      let source = proxyImportText.isEmpty
        ? NSPasteboard.general.string(forType: .string) ?? ""
        : proxyImportText
      let draft = try ProxyImportParser.parse(
        source,
        kind: proxyKind,
        order: proxyImportOrder
      )
      isApplyingProxyImport = true
      usesProxy = true
      proxyHost = draft.configuration.host
      proxyPort = String(draft.configuration.port)
      proxyUsername = draft.configuration.username
      proxyPassword = draft.password
      proxyImportNotice = UserNotice(
        "Прокси распознан: \(draft.redactedSummary). " +
          "Соединение ещё не проверено.",
        level: .information
      )
      announce(proxyImportNotice?.message ?? "Прокси распознан.")
      errorMessage = nil

      Task { @MainActor in
        await Task.yield()
        proxyImportText = ""
        isApplyingProxyImport = false
      }
    } catch {
      isApplyingProxyImport = false
      proxyImportNotice = UserNotice(
        error.localizedDescription,
        level: .failure
      )
      announce(error.localizedDescription)
    }
  }

  private func startProxyTest(
    configuration proxy: ProxyConfiguration,
    password: String
  ) {
    proxyTestTask?.cancel()
    isTesting = true
    testNotice = nil
    proxyTestTask = Task {
        do {
          let result = try await ProxyTester().test(
            configuration: proxy,
            password: password
          )
          try Task.checkCancellation()
          await MainActor.run {
            let location = result.locationSummary
            let message = location.isEmpty
              ? "Прокси отвечает · \(result.ipAddress)"
              : "Прокси отвечает · \(result.ipAddress) · \(location)"
            testNotice = UserNotice(message, level: .success)
            detectedProxy = proxy
            detectedTimezone = result.timezoneIdentifier
            detectedLocale = result.localeIdentifier
            detectedLocation = location.isEmpty ? nil : location
            detectedProxyContextEvidence = .ipAPI()
            isTesting = false
            proxyTestTask = nil
            announce(testNotice?.message ?? "Прокси подключён.")
          }
        } catch {
          guard !Task.isCancelled else { return }
          await MainActor.run {
            testNotice = UserNotice(
              error.localizedDescription,
              level: .failure
            )
            isTesting = false
            proxyTestTask = nil
            announce(error.localizedDescription)
          }
        }
      }
  }

  private func invalidateProxyEvidence() {
    proxyTestTask?.cancel()
    proxyTestTask = nil
    isTesting = false
    testNotice = nil
    detectedProxy = nil
    detectedTimezone = nil
    detectedLocale = nil
    detectedLocation = nil
    detectedProxyContextEvidence = nil
  }

  private func proxyInputDidChange() {
    guard !isApplyingProxyImport else { return }
    proxyImportNotice = nil
    invalidateProxyEvidence()
  }

  @MainActor
  private func announce(_ message: String) {
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.medium.rawValue
      ]
    )
  }
}

private struct ProfileTagsValidationError: LocalizedError {
  var errorDescription: String? {
    "Проверь теги: не больше \(BrowserProfile.maximumTagCount), до \(BrowserProfile.maximumTagLength) символов каждый."
  }
}
