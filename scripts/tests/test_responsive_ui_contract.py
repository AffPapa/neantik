import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTENT = ROOT / "Sources" / "NeAntik" / "ContentView.swift"
PROFILE_LIST_HEADER = (
    ROOT / "Sources" / "NeAntik" / "ProfileListHeaderView.swift"
)
WORKSPACE_TOOLBAR = (
    ROOT / "Sources" / "NeAntik" / "WorkspaceToolbarContent.swift"
)
PROFILE_WORKSPACE_VIEWS = (
    ROOT / "Sources" / "NeAntik" / "ProfileWorkspaceViews.swift"
)
EDITOR = ROOT / "Sources" / "NeAntik" / "ProfileEditorView.swift"
PROFILE_NOTE_EDITOR = (
    ROOT / "Sources" / "NeAntik" / "ProfileNoteEditorView.swift"
)
AUDIT = ROOT / "Sources" / "NeAntik" / "FingerprintAuditView.swift"
BULK_IMPORT = ROOT / "Sources" / "NeAntik" / "BulkProxyImport.swift"
MODELS = ROOT / "Sources" / "NeAntik" / "Models.swift"
PROFILE_LIST_PROJECTION = (
    ROOT / "Sources" / "NeAntik" / "ProfileListProjection.swift"
)
PROFILE_ROW_PRESENTATION = (
    ROOT / "Sources" / "NeAntik" / "ProfileRowPresentation.swift"
)
WORKSPACE_DOMAIN = ROOT / "Sources" / "NeAntik" / "WorkspaceDomain.swift"
WORKSPACE_READINESS = (
    ROOT / "Sources" / "NeAntik" / "WorkspaceReadiness.swift"
)
WORKSPACE_READINESS_VIEW = (
    ROOT / "Sources" / "NeAntik" / "WorkspaceReadinessView.swift"
)
PROFILE_ENVIRONMENT = (
    ROOT / "Sources" / "NeAntik" / "ProfileEnvironmentView.swift"
)
APP = ROOT / "Sources" / "NeAntik" / "NeAntikApp.swift"
PROFILE_COMMANDS = ROOT / "Sources" / "NeAntik" / "ProfileCommands.swift"
SHORTCUT_CATALOG = (
    ROOT / "Sources" / "NeAntik" / "NeAntikShortcutCatalog.swift"
)
SETTINGS_VIEW = ROOT / "Sources" / "NeAntik" / "NeAntikSettingsView.swift"
FOLDER_PICKER = (
    ROOT / "Sources" / "NeAntik" / "ProfileFolderPickerSheet.swift"
)
TAG_APPEARANCE = (
    ROOT / "Sources" / "NeAntik" / "ProfileTagAppearance.swift"
)
FIRST_PROFILE = (
    ROOT / "Sources" / "NeAntik" / "FirstProfileBootstrap.swift"
)
POST_SAVE_REVEAL = (
    ROOT / "Sources" / "NeAntik" / "ProfilePostSaveRevealPolicy.swift"
)
BULK_PROXY_ACTION = (
    ROOT / "Sources" / "NeAntik" / "BulkProxyActionProjection.swift"
)
README = ROOT / "README.md"
PRODUCT = ROOT / "docs" / "PRODUCT.md"
ROADMAP = ROOT / "docs" / "ROADMAP.md"


class ResponsiveUIContractTests(unittest.TestCase):
    def test_batch_tag_save_preserves_draft_on_failure(self):
        sheet = (ROOT / 'Sources/NeAntik/ProfileBatchTagSheet.swift').read_text()
        content = CONTENT.read_text()
        self.assertIn('let onApply: (ProfileMetadataBatchAction) throws -> Void', sheet)
        self.assertIn('try performBatchMetadata(action, to: request.profileIDs)', content)
        operation = sheet.split('private func apply()', 1)[1]
        success, failure = operation.split('} catch {', 1)
        self.assertIn('try onApply', success)
        self.assertIn('dismiss()', success)
        self.assertNotIn('dismiss()', failure)
        self.assertIn('errorMessage = error.localizedDescription', failure)
        self.assertNotIn('tag = ""', failure)

    def test_proxy_password_has_explicit_temporary_reveal_control(self) -> None:
        source = EDITOR.read_text(encoding="utf-8")
        self.assertIn("SensitiveRevealLeaseState()", source)
        self.assertIn("SensitiveRevealLeaseState.defaultLifetime", source)
        self.assertIn("NSApplication.willResignActiveNotification", source)
        self.assertIn('"Показать пароль прокси"', source)
        self.assertIn('"Скрыть пароль прокси"', source)
        self.assertIn("proxyPasswordRevealLease.isRevealed", source)

    def test_workspace_uses_native_list_first_navigation_and_optional_inspector(
        self,
    ) -> None:
        text = CONTENT.read_text(encoding="utf-8")
        self.assertNotIn(".safeAreaInset(edge: .top", text)
        self.assertNotIn(".padding(.top, 46)", text)
        self.assertNotIn("windowTitlebarInset", text)
        navigation_start = text.index("private var workspaceBase")
        sheets_start = text.index("private var workspaceSheets")
        self.assertNotIn("GeometryReader", text[navigation_start:sheets_start])
        self.assertIn(
            "NavigationSplitView(columnVisibility: $columnVisibility)",
            text,
        )
        self.assertIn("workspaceSources", text)
        self.assertIn("profileListPane", text)
        self.assertIn("} detail: {", text)
        self.assertIn(".inspector(isPresented: $showsProfileInspector)", text)
        self.assertIn(
            "detail\n                .workspaceKeyboardRegion(.inspector)\n                .inspectorColumnWidth(",
            text,
        )
        self.assertIn("WorkspaceLayout.minimumSourceColumnWidth", text)
        self.assertIn("WorkspaceLayout.minimumProfileColumnWidth", text)
        self.assertIn("WorkspaceLayout.minimumInspectorWidth", text)
        self.assertIn("WorkspaceLayout.idealInspectorWidth", text)
        self.assertIn("WorkspaceLayout.maximumInspectorWidth", text)
        self.assertIn(".navigationSplitViewStyle(.balanced)", text)
        self.assertIn(".toolbar {", text)
        self.assertIn("WorkspaceToolbarContent(", text)

    def test_workspace_sources_expose_profiles_folders_tags_and_keyboard_navigation(
        self,
    ) -> None:
        text = CONTENT.read_text(encoding="utf-8")
        sources_start = text.index("private func workspaceSources(")
        list_start = text.index("private func profileListPane(")
        sources = text[sources_start:list_start]

        self.assertIn('Text("Профили")', sources)
        self.assertIn("Color(nsColor: .secondaryLabelColor)", sources)
        self.assertIn("Color(nsColor: .labelColor)", text)
        self.assertIn('title: "Все профили"', sources)
        self.assertIn('title: "Закреплённые"', sources)
        self.assertIn('title: "Папки"', sources)
        self.assertIn('title: "Без папки"', sources)
        self.assertIn('title: "Теги"', sources)
        self.assertIn("folderPreview.visibleItems", sources)
        self.assertIn("tagPreview.visibleItems", sources)
        self.assertIn("previewToggleButton(", sources)
        self.assertIn(".onKeyPress(.upArrow)", sources)
        self.assertIn(".onKeyPress(.downArrow)", sources)
        self.assertIn('"Переименовать папку"', sources)
        self.assertGreaterEqual(
            sources.count(".frame(width: 32, height: 32)"),
            2,
        )

    def test_list_first_header_owns_actions_and_toolbar_toggles_inspector(
        self,
    ) -> None:
        text = CONTENT.read_text(encoding="utf-8")
        workspace_views = PROFILE_WORKSPACE_VIEWS.read_text(encoding="utf-8")
        toolbar = WORKSPACE_TOOLBAR.read_text(encoding="utf-8")

        self.assertIn("ToolbarItem(placement: .primaryAction)", toolbar)
        self.assertIn('Label("Готовность", systemImage: "checkmark.shield")', toolbar)
        self.assertIn("onPresentReadiness", toolbar)
        self.assertIn("Button(action: onToggleInspector)", toolbar)
        self.assertIn('systemImage: "sidebar.right"', toolbar)
        self.assertNotIn(".keyboardShortcut", toolbar)
        self.assertIn(".disabled(!hasSelectedProfile)", toolbar)
        self.assertNotIn("profileCommandSet(", toolbar)

        commands = PROFILE_COMMANDS.read_text(encoding="utf-8")
        shortcuts = SHORTCUT_CATALOG.read_text(encoding="utf-8")
        settings = SETTINGS_VIEW.read_text(encoding="utf-8")
        self.assertIn("NeAntikShortcut.toggleInspector.keyEquivalent", commands)
        self.assertIn("NeAntikShortcut.toggleSelectedProfile.keyEquivalent", commands)
        self.assertIn('CommandMenu("Рабочее пространство")', commands)
        self.assertIn('case toggleSelectedProfile', shortcuts)
        self.assertIn('case editSelectedNote', shortcuts)
        self.assertIn('Section("Сочетания клавиш")', settings)
        self.assertIn("$preferences.rowDensity", settings)
        self.assertIn("var accessibilityChord: String", shortcuts)
        self.assertIn("shortcut.accessibilityChord", settings)

        header = PROFILE_LIST_HEADER.read_text(encoding="utf-8")
        self.assertIn('Label("Создать профиль", systemImage: "plus")', header)
        self.assertIn("ViewThatFits(in: .horizontal)", header)
        self.assertIn("commandRow.labelStyle(.iconOnly)", header)
        self.assertIn(
            ".fixedSize(horizontal: true, vertical: false)",
            header,
        )
        self.assertIn(".buttonStyle(.borderedProminent)", header)
        self.assertIn(".tint(.green)", header)
        self.assertIn(
            'Label("Действия", systemImage: "ellipsis.circle")',
            header,
        )
        self.assertIn(
            '"Дополнительные действия со списком профилей"',
            header,
        )
        self.assertIn("filtersMenu", header)
        self.assertIn("operationalFilterBar", header)
        self.assertIn("ProfileOperationalFilter.allCases", header)
        self.assertIn("summary.count(for: filter)", header)
        self.assertIn(
            ".accessibilityAddTraits(isSelected ? .isSelected : [])",
            header,
        )
        self.assertIn("ProfileOperationalProjection.resolve", text)
        self.assertNotIn("processes.runningProfileIDs.contains($0.id)", header)
        self.assertIn('"Создать из списка прокси…"', header)
        self.assertIn('"Проверить прокси (\\(bulkProxyAction.count))"', header)
        self.assertIn("if !bulkProxyTestIsRunning", header)
        self.assertIn("if bulkProxyTestIsRunning", header)
        self.assertLess(
            header.index(
                'Label("Действия", systemImage: "ellipsis.circle")'
            ),
            header.index('Label("Создать профиль", systemImage: "plus")'),
        )

        self.assertIn("private func profileTableHeader", text)
        self.assertIn("ProfileRowLayout.minimumWideWidth", text)
        self.assertIn("GeometryReader", text)
        self.assertIn('Text("Выбор / запуск")', text)
        self.assertIn('Text("Подключение")', text)
        self.assertIn('Text("Заметка / активность")', text)
        self.assertIn("wideRow(presentation)", workspace_views)
        self.assertIn("compactRow(presentation)", workspace_views)
        self.assertIn("ProfileRowLayout.minimumIdentityWidth", workspace_views)
        self.assertIn("maxWidth: .infinity", workspace_views)
        self.assertIn("private var actionsMenu", workspace_views)
        self.assertIn("private var profileListViewMenu", text)
        self.assertIn('Picker("Сортировка"', text)
        self.assertIn('Picker("Подключение"', text)
        self.assertIn(
            'accessibilityLabel("Фильтры и сортировка профилей")', text
        )
        list_menu_start = text.index("private var profileListViewMenu")
        list_menu_end = text.index(
            "private var profileRouteFilterBinding", list_menu_start
        )
        list_menu = text[list_menu_start:list_menu_end]
        self.assertIn(
            'Label("Фильтры", systemImage: "line.3.horizontal.decrease")',
            list_menu,
        )
        self.assertNotIn("ViewThatFits", list_menu)
        self.assertIn("profileRouteFilter = .all", text)
        self.assertIn("profileRouteFilter != .all", text)
        self.assertIn("profileRouteFilter = decision.routeFilter", text)
        self.assertIn("ProfileListEmptyStatePresentation.resolve", text)
        self.assertIn("Text(empty.message)", text)
        self.assertIn('.accessibilityLabel("Убрать фильтр \\(title)")', text)
        self.assertIn('Image(systemName: "info.circle")', header)
        self.assertIn('Text("Поиск по полям")', header)
        self.assertIn("ProfileSearchSyntaxHelp.examples", header)

        active_filters_start = text.index(
            "private var activeFiltersBar"
        )
        active_filters_end = text.index(
            "private func filterChip", active_filters_start
        )
        active_filters = text[active_filters_start:active_filters_end]
        self.assertNotIn("profileOperationalFilter", active_filters)

        for dead_symbol in (
            "isSidebarVisible",
            "profileListTitle",
            "private var sidebar:",
            "sidebarHeader",
            "sidebarHeaderActionIcon",
            "sidebarControls",
            "primaryActions",
            "actionColumns",
            "compactActionLabel",
            "onToggleSidebar",
        ):
            self.assertNotIn(dead_symbol, text)

    def test_v4_workspace_keeps_notes_visible_and_direct_route_explicit(
        self,
    ) -> None:
        content = CONTENT.read_text(encoding="utf-8")
        editor = EDITOR.read_text(encoding="utf-8")

        self.assertIn('"Добавить заметку…"', content)
        self.assertIn('"Изменить заметку…"', content)
        self.assertIn(
            ".onChange(of: processes.runningProfileIDs)", content
        )
        self.assertIn(
            ".onChange(of: processes.processStateRevision)", content
        )
        self.assertIn(
            ".onChange(of: proxyHealthCoordinator.healthByProfileID)",
            content,
        )
        self.assertIn(
            "initialOperationalFilter: ProfileOperationalFilter = .all",
            content,
        )
        self.assertIn("workspacePreferences.rowDensity", content)
        self.assertIn('"Прямое подключение"', editor)
        self.assertIn(
            '"Сайты увидят обычный публичный адрес этого Mac или "',
            editor,
        )
        self.assertIn(
            '"системного VPN. Для профиля не настроен отдельный прокси."',
            editor,
        )

    def test_readiness_center_is_local_actionable_and_redacted(self) -> None:
        content = CONTENT.read_text(encoding="utf-8")
        readiness = WORKSPACE_READINESS.read_text(encoding="utf-8")
        view = WORKSPACE_READINESS_VIEW.read_text(encoding="utf-8")

        self.assertIn("WorkspaceReadinessSystemInspector.inspect", content)
        self.assertIn("Task.detached(priority: .userInitiated)", content)
        self.assertIn("processes.reconcile(profiles: store.profiles)", content)
        self.assertIn('"Проверить снова"', view)
        self.assertIn('"Скопировать путь"', view)
        self.assertIn('"Показать в Finder"', view)
        self.assertIn(
            "Не добавляй вложенный NeAntik Browser.app",
            view,
        )
        self.assertIn(
            "Диагностика не содержит пароли, адреса прокси",
            view,
        )
        self.assertNotIn("URLSession", readiness)
        self.assertNotIn("NWConnection", readiness)
        diagnostic_start = readiness.index(
            "private static func diagnosticText("
        )
        diagnostic = readiness[diagnostic_start:]
        self.assertNotIn("bundlePath", diagnostic)
        self.assertNotIn("message", diagnostic)

    def test_app_is_single_window_and_profile_commands_are_focus_aware(
        self,
    ) -> None:
        app = APP.read_text(encoding="utf-8")
        content = CONTENT.read_text(encoding="utf-8")
        commands = PROFILE_COMMANDS.read_text(encoding="utf-8")

        self.assertIn('Window("NeAntik", id: "main")', app)
        self.assertNotIn("WindowGroup", app)
        self.assertIn("WorkspaceCommandMenu()", app)
        self.assertIn("ProfileCommandMenu()", app)
        self.assertIn("CommandGroup(after: .textEditing)", commands)
        self.assertIn('CommandMenu("Папка")', commands)
        self.assertIn('"Переименовать…"', commands)
        self.assertIn('"Удалить папку"', commands)
        self.assertIn(".focusedSceneValue(", content)
        self.assertIn("selectedProfileCommandSet", content)
        self.assertIn('CommandMenu("Профиль")', commands)
        for action in (
            '"Изменить…"',
            '"Создать похожий"',
            '"Переместить в папку"',
            '"Показать папку данных в Finder"',
            '"Удалить профиль"',
        ):
            self.assertIn(action, commands)

    def test_commands_are_modal_aware_and_folder_move_is_bounded(self) -> None:
        content = CONTENT.read_text(encoding="utf-8")
        commands = PROFILE_COMMANDS.read_text(encoding="utf-8")
        picker = FOLDER_PICKER.read_text(encoding="utf-8")

        self.assertIn("private var isWorkspaceModalPresented", content)
        self.assertIn("guard !isWorkspaceModalPresented", content)
        self.assertIn("forceStopRequest != nil", content)
        self.assertIn("workspaceCommandSet", content)
        self.assertIn("static let unavailable = WorkspaceCommandSet", commands)
        self.assertNotIn("neAntikCreateProfile", content)
        self.assertNotIn("neAntikCreateProfile", APP.read_text(encoding="utf-8"))
        self.assertIn("state == .stopped || state.isConfirmedRunning", content)
        self.assertIn("appliesOnNextLaunch", content)
        self.assertIn("noteIsEnabled", commands)
        self.assertIn(
            ".disabled(!resolved.presentation.noteIsEnabled)", commands
        )
        self.assertIn("ProfileFolderCommandProjection.resolve", content)
        self.assertIn("static let defaultLimit = 8", commands)
        batch_actions = (
            ROOT / "Sources" / "NeAntik" / "ProfileBatchActions.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("ViewThatFits(in: .horizontal)", batch_actions)
        self.assertIn("compactActionBar", batch_actions)
        self.assertIn(
            'Label("Действия", systemImage: "ellipsis.circle")',
            batch_actions,
        )
        self.assertIn('Button("Снять выделение"', batch_actions)
        self.assertNotIn("ScrollView(.horizontal", batch_actions)
        self.assertNotIn(
            '.keyboardShortcut("z", modifiers: [.command])',
            batch_actions,
        )
        projection_start = commands.index(
            "struct ProfileFolderCommandProjection"
        )
        projection_end = commands.index(
            "@MainActor\nstruct ProfileCommandSet",
            projection_start,
        )
        self.assertNotIn(
            ".sorted",
            commands[projection_start:projection_end],
        )
        self.assertIn('"Выбрать другую папку…"', commands)
        self.assertIn('TextField("Поиск папок"', picker)
        self.assertIn("localizedCaseInsensitiveContains", picker)
        self.assertIn(
            "let visibleFolders = presentation.filteredFolders",
            picker,
        )
        self.assertIn(".onSubmit(selectFirstSearchResult)", picker)
        self.assertIn(".keyboardShortcut(.cancelAction)", picker)
        self.assertIn("ProfileFolderPickerUnavailableSheet", picker)
        self.assertNotIn(".sorted", picker)

    def test_tag_color_is_stable_supplemental_and_schema_free(self) -> None:
        appearance = TAG_APPEARANCE.read_text(encoding="utf-8")
        content = (
            CONTENT.read_text(encoding="utf-8")
            + PROFILE_WORKSPACE_VIEWS.read_text(encoding="utf-8")
        )

        self.assertIn("stableHash(tagID.rawValue)", appearance)
        self.assertIn("ProfileTagID(displayName: displayName)", appearance)
        self.assertIn("ProfileTagMarker", appearance)
        self.assertIn("Text(tag)", appearance)
        self.assertNotIn("systemRed", appearance)
        self.assertNotIn("systemOrange", appearance)
        self.assertNotIn("systemGreen", appearance)
        self.assertIn("ProfileTagAppearance.tone(", content)
        self.assertIn("ProfileTagChip(", content)

    def test_empty_workspace_offers_one_click_permanent_profile(self) -> None:
        text = CONTENT.read_text(encoding="utf-8")
        onboarding = FIRST_PROFILE.read_text(encoding="utf-8")
        list_start = text.index("private func profileListPane(")
        empty_start = text.index(
            "if store.profiles.isEmpty {",
            list_start,
        )
        empty_end = text.index(
            "} else if listState.visibleProfiles.isEmpty {",
            empty_start,
        )
        empty_state = text[empty_start:empty_end]

        self.assertIn("FirstProfileOnboardingView(", empty_state)
        self.assertIn(
            "onCreateAndOpen: createAndOpenProfileQuickly", empty_state
        )
        self.assertIn("onConfigure: beginCreatingProfile", empty_state)

        self.assertIn('"Создать и открыть"', onboarding)
        self.assertIn('Button("Настроить…"', onboarding)
        self.assertIn("FirstProfileBootstrap.routeSummary", onboarding)
        self.assertIn("ViewThatFits(in: .horizontal)", onboarding)
        self.assertIn(".buttonStyle(.borderedProminent)", onboarding)
        create_button_start = onboarding.index(
            "private var createAndOpenButton: some View"
        )
        configure_button_start = onboarding.index(
            "private var configureButton: some View",
            create_button_start,
        )
        create_button = onboarding[create_button_start:configure_button_start]
        self.assertIn(".keyboardShortcut(.defaultAction)", create_button)
        self.assertIn(
            ".disabled(!presentation.primaryIsEnabled)",
            create_button,
        )
        self.assertIn(
            '"Проверяем встроенный браузерный движок."',
            onboarding,
        )
        self.assertIn(
            '"Кнопка станет доступна после проверки"',
            onboarding,
        )
        self.assertIn('primaryTitle: "Повторить проверку"', onboarding)
        self.assertIn("terminalAccessibilityAnnouncement", onboarding)
        self.assertIn("постоянный локальный профиль браузера", onboarding)

    def test_fingerprint_audit_separates_manual_reports_from_release_authority(
        self,
    ) -> None:
        text = CONTENT.read_text(encoding="utf-8")
        release_start = text.index(
            ".sheet(isPresented: $showingReleaseFingerprintAudit)"
        )
        manual_start = text.index(
            ".sheet(item: $fingerprintAuditRequest)"
        )
        manual_end = text.index('.alert(\n            "Удалить профиль?"')
        release_sheet = text[release_start:manual_start]
        manual_sheet = text[manual_start:manual_end]

        self.assertIn("releaseContext: fingerprintEvidenceReleaseContext", release_sheet)
        self.assertNotIn("onReport:", release_sheet)
        self.assertIn("onReport:", manual_sheet)
        self.assertIn("revisionBoundFingerprintObservations", manual_sheet)
        self.assertIn("fingerprintObservationStore.record", manual_sheet)
        self.assertNotIn("releaseContext:", manual_sheet)
        self.assertIn("private func beginFingerprintAudit()", text)
        self.assertIn("fingerprintAuditRequest = FingerprintAuditRequest(", text)
        self.assertIn("onRunFingerprintAudit:", text)
        self.assertEqual(
            text.count("showingReleaseFingerprintAudit = true"),
            1,
        )
        release_gate = text.index(
            "private func presentReleaseFingerprintAuditIfNeeded()"
        )
        assignment = text.index(
            "showingReleaseFingerprintAudit = true"
        )
        self.assertGreater(assignment, release_gate)
        self.assertIn("guard launchIntent.opensFingerprintAudit", text)

    def test_proxy_import_is_local_and_connection_test_is_optional(
        self,
    ) -> None:
        text = EDITOR.read_text(encoding="utf-8")
        self.assertIn('Label("Вставить прокси"', text)
        self.assertIn('Label("Проверить прокси"', text)
        self.assertIn("private func importProxy()", text)
        self.assertNotIn("importProxyAndTest", text)
        import_start = text.index("private func importProxy()")
        test_start = text.index("private func startProxyTest(")
        import_body = text[import_start:test_start]
        self.assertNotIn("startProxyTest(", import_body)

    def test_advanced_editor_row_has_explicit_button(self) -> None:
        text = EDITOR.read_text(encoding="utf-8")
        self.assertIn('title: "Создание профиля"', text)
        self.assertIn('title: "Редактирование профиля"', text)
        self.assertIn(".accessibilityHeading(.h1)", text)
        self.assertIn(
            'static let summary = "Стартовая страница, папка, теги и оформление"',
            text,
        )
        advanced_start = text.index("showsAdvancedOptions.toggle()")
        advanced_end = text.index("if showsAdvancedOptions {", advanced_start)
        advanced = text[advanced_start:advanced_end]
        self.assertIn("showsAdvancedOptions.toggle()", advanced)
        self.assertIn("maxWidth: .infinity", advanced)
        self.assertIn("minHeight: 28", advanced)
        self.assertIn(".contentShape(Rectangle())", advanced)
        self.assertIn(".accessibilityHidden(true)", advanced)
        self.assertIn(
            '.accessibilityLabel("Дополнительные настройки профиля")',
            advanced,
        )
        self.assertIn(
            'showsAdvancedOptions ? "Развёрнуто" : "Свёрнуто"',
            advanced,
        )
        self.assertIn(".accessibilityHint(", advanced)
        self.assertNotIn(
            'DisclosureGroup(\n            "Дополнительно"',
            text,
        )
        self.assertNotIn(".onSubmit(save)", text)

    def test_profile_note_is_progressively_disclosed_from_a_full_row(
        self,
    ) -> None:
        editor = EDITOR.read_text(encoding="utf-8")
        profile_start = editor.index('Section("Профиль")')
        network_start = editor.index('Section("Сеть")', profile_start)
        profile = editor[profile_start:network_start]
        note_editor_start = editor.index("private var noteEditor")
        note_editor_end = editor.index(
            "private var proxyImportOrderPicker",
            note_editor_start,
        )
        note_editor = editor[note_editor_start:note_editor_end]

        self.assertIn("noteEditor", profile)
        self.assertLess(
            profile.index('TextField("Название"'),
            profile.index("noteEditor"),
        )
        self.assertLess(profile_start, network_start)
        advanced_call = editor.index("advancedOptionsSection", network_start)
        self.assertLess(network_start, advanced_call)
        advanced_definition = editor.index(
            "private var advancedOptionsSection"
        )
        advanced = editor[advanced_definition:note_editor_start]
        self.assertIn('Text("Организация")', advanced)
        self.assertIn("folderControl", advanced)
        self.assertIn("ProfileTagEditor(", advanced)
        self.assertIn('TextField("Стартовая страница"', advanced)
        self.assertIn('Text("Заметка (необязательно)")', note_editor)
        self.assertGreaterEqual(
            note_editor.count(
                '.accessibilityLabel("Необязательная заметка профиля")'
            ),
            2,
        )
        self.assertIn(
            "initialValue: original == nil || initialFocus == .note",
            editor,
        )
        self.assertIn('"Не добавлена"', note_editor)
        self.assertIn('"Добавлена"', note_editor)
        self.assertIn("Button", note_editor)
        self.assertIn("TextEditor(text:", note_editor)
        self.assertIn(
            '"Без паролей, ключей и seed-фраз"',
            note_editor,
        )
        self.assertIn(".frame(maxWidth: .infinity", note_editor)
        self.assertIn(".contentShape(Rectangle())", note_editor)
        self.assertNotIn("DisclosureGroup", note_editor)

    def test_profile_note_stays_compact_but_readable_and_searchable(
        self,
    ) -> None:
        content = PROFILE_WORKSPACE_VIEWS.read_text(encoding="utf-8")
        workspace_content = CONTENT.read_text(encoding="utf-8")
        projection = PROFILE_LIST_PROJECTION.read_text(encoding="utf-8")
        row_presentation = PROFILE_ROW_PRESENTATION.read_text(
            encoding="utf-8"
        )

        row_start = content.index("struct ProfileRow")
        detail_start = content.index("struct ProfileDetailView", row_start)
        row = content[row_start:detail_start]
        self.assertIn("presentation.noteSummary", row)
        self.assertIn('? "square.and.pencil" : "note.text"', row)
        self.assertIn("Button(action: onEditNote)", row)
        self.assertIn('summary.isEmpty ? "Добавить заметку"', row)
        self.assertNotIn("isNoteEditingEnabled", row)
        self.assertIn('"Заметка добавлена"', row)
        self.assertIn("presentation.statusTitle", row)
        self.assertIn("presentation.routeTitle", row)
        self.assertIn("launchAction.title", row)
        self.assertIn(".buttonStyle(.bordered)", row)
        self.assertIn(".privacySensitive()", row)
        self.assertNotIn(".help(presentation.noteSummary)", row)
        self.assertIn("processState.title", row_presentation)
        self.assertIn(
            'profile.proxy?.displayName ?? "Без прокси"',
            row_presentation,
        )
        self.assertIn(
            "ProfileNotePresentation.resolve(", row_presentation
        )
        self.assertIn("profile.note", row_presentation)
        self.assertIn(
            "static let maximumNoteSummaryLength = 120",
            row_presentation,
        )

        detail_content_start = content.index(
            "private var detailContent: some View",
            detail_start,
        )
        detail_content_end = content.index(
            "private var networkSummary: some View",
            detail_content_start,
        )
        detail = content[detail_content_start:detail_content_end]
        self.assertIn("profile.note", detail)
        self.assertIn('Label("Заметка", systemImage: "note.text")', detail)
        self.assertIn('Text("Не добавлена")', detail)
        self.assertIn(".lineLimit(", detail)
        self.assertIn(
            "notePresentation.shouldOfferExpansion &&",
            detail,
        )
        self.assertIn("!noteExpanded", detail)

        detail_view = content[detail_start:]
        self.assertIn('"Показать полностью"', detail_view)
        self.assertIn('"Свернуть"', detail_view)
        self.assertIn('"Изменить заметку…"', detail_view)
        self.assertIn('"Добавить заметку…"', detail_view)

        search = PROFILE_LIST_HEADER.read_text(encoding="utf-8")
        self.assertIn('"Профиль или заметка"', search)
        self.assertIn(
            '"Поиск профилей, маршрутов, заметок, тегов и папок"',
            search,
        )
        self.assertIn(
            '"Можно уточнить запрос: имя, заметка, ид, тег, папка, прокси или статус.',
            search,
        )
        self.assertGreaterEqual(projection.count("profile.note"), 2)

        note_editor = PROFILE_NOTE_EDITOR.read_text(encoding="utf-8")
        self.assertIn("struct ProfileNoteEditorView: View", note_editor)
        self.assertIn('TextEditor(text: $note)', note_editor)
        self.assertIn(
            '"Заметка хранится локально открытым текстом. Не сохраняй здесь пароли, API-ключи или seed-фразы."',
            note_editor,
        )
        self.assertIn("BrowserProfile.normalizedNote", note_editor)
        self.assertIn("ProfileNoteDraftSnapshot", note_editor)
        self.assertIn(".interactiveDismissDisabled(hasUnsavedChanges)", note_editor)
        self.assertIn('"Отменить изменения заметки?"', note_editor)
        self.assertIn("requestDismiss()", note_editor)

    def test_profile_note_clone_and_public_dto_boundaries_are_explicit(
        self,
    ) -> None:
        models = MODELS.read_text(encoding="utf-8")
        domain = WORKSPACE_DOMAIN.read_text(encoding="utf-8")

        self.assertIn("var note: String", models)
        self.assertIn("maximumNoteLength", models)
        duplicate_start = models.index("func duplicated(")
        duplicate_end = models.index(
            "var displaySymbolName",
            duplicate_start,
        )
        duplicate = models[duplicate_start:duplicate_end]
        self.assertIn("BrowserProfile(", duplicate)
        self.assertNotIn("note: note", duplicate)
        self.assertIn('note: ""', duplicate)

        dto_start = domain.index("struct WorkspacePublicProfileDTO")
        dto_end = domain.index("enum WorkspaceDomain", dto_start)
        public_profile_dto = domain[dto_start:dto_end]
        self.assertNotIn("note", public_profile_dto.lower())

    def test_bulk_proxy_import_is_bounded_local_and_secret_safe(self) -> None:
        text = BULK_IMPORT.read_text(encoding="utf-8")
        normalized = " ".join(text.split())
        self.assertIn("static let maximumEntries = 100", text)
        self.assertIn("static let maximumInputBytes = 512 * 1_024", text)
        self.assertIn(".privacySensitive()", text)
        self.assertIn("BulkProxyImportParser.preview(", text)
        self.assertIn("preview.issueLineNumbers", text)
        self.assertIn("issuePreviewRows", text)
        self.assertIn("Исправь \\(issueCountTitle", text)
        self.assertNotIn("DisclosureGroup(isExpanded: $showsOptions)", text)
        self.assertIn("showsOptions.toggle()", text)
        self.assertIn("maxWidth: .infinity", text)
        self.assertIn("minHeight: 32", text)
        self.assertIn(".contentShape(Rectangle())", text)
        self.assertIn('.accessibilityLabel("Параметры импорта")', text)
        self.assertIn(
            'showsOptions ? "Развёрнуто" : "Свёрнуто"',
            text,
        )
        self.assertIn(".focused($proxyInputIsFocused)", text)
        self.assertIn("BulkProxyImportDraftSnapshot", text)
        self.assertIn(
            ".interactiveDismissDisabled(isCreating || hasUnsavedChanges)",
            text,
        )
        self.assertIn('"Отменить импорт?"', text)
        self.assertIn("requestDismiss()", text)
        self.assertIn("будет автоматически проверяться", normalized)
        self.assertIn("перед каждым запуском профиля", normalized)
        self.assertIn("Эта проверка не", normalized)
        self.assertIn("подтверждает маршрут Chromium", normalized)
        self.assertNotIn("ProxyTester", text)
        self.assertNotIn("startProxyTest", text)

    def test_narrow_proxy_and_audit_controls_have_fallbacks(self) -> None:
        editor = EDITOR.read_text(encoding="utf-8")
        audit = AUDIT.read_text(encoding="utf-8")
        self.assertGreaterEqual(editor.count("ViewThatFits"), 2)
        self.assertGreaterEqual(audit.count("ViewThatFits"), 2)
        self.assertIn(".focused($primaryActionIsFocused)", audit)

    def test_editor_footer_remains_visible_at_minimum_height(self) -> None:
        editor = EDITOR.read_text(encoding="utf-8")
        footer_start = editor.index('Button("Отмена")')
        frame_start = editor.index(
            ".frame(\n      minWidth: 460",
            footer_start,
        )
        footer = editor[footer_start:frame_start]

        self.assertIn(".fixedSize(horizontal: false, vertical: true)", footer)
        self.assertIn(".background(.bar)", footer)
        self.assertIn(
            ".frame(minHeight: 0, maxHeight: .infinity)",
            editor[:footer_start],
        )
        self.assertIn(".layoutPriority(-1)", editor[:footer_start])

    def test_environment_section_uses_the_full_row_as_disclosure_control(
        self,
    ) -> None:
        text = PROFILE_ENVIRONMENT.read_text(encoding="utf-8")
        details_start = text.index("if showingDetails {")
        details_end = text.index(
            ".padding(.top, 4)",
            details_start,
        )
        details = text[details_start:details_end]
        button_start = text.index(
            "private func diagnosticSectionButton("
        )
        button_end = text.index(
            "private var overview: some View",
            button_start,
        )
        button = text[button_start:button_end]

        self.assertNotIn("DisclosureGroup(", details)
        self.assertIn("diagnosticSection(", details)
        self.assertIn("setSectionExpanded(", button)
        self.assertIn("maxWidth: .infinity", button)
        self.assertIn("minHeight: 32", button)
        self.assertIn(".contentShape(Rectangle())", button)
        self.assertIn(".onHover", button)
        self.assertIn('isExpanded ? "Развёрнуто" : "Свёрнуто"', button)

    def test_environment_overview_hides_optional_unavailable_actions(self) -> None:
        text = PROFILE_ENVIRONMENT.read_text(encoding="utf-8")
        overview_start = text.index("private var overview: some View")
        tools_start = text.index("private var diagnosticTools: some View")
        overview = text[overview_start:tools_start]

        self.assertIn("if hasOverviewAction", overview)
        self.assertIn("recommendedAction", overview)
        self.assertNotIn("snapshot.limitations.last", overview)
        self.assertNotIn("fingerprintDisabledReason", overview)
        self.assertIn('Text("Дополнительные проверки")', text)

    def test_post_save_reveal_policy_covers_every_workspace_facet(self) -> None:
        text = POST_SAVE_REVEAL.read_text(encoding="utf-8")

        self.assertIn("ProfilePostSaveRevealDecision", text)
        self.assertIn("let query: WorkspaceQueryState", text)
        self.assertIn("let searchText: String", text)
        self.assertIn("let selectedProfileID: UUID", text)
        self.assertIn("currentQuery.scope", text)
        self.assertIn("currentQuery.folderFilter", text)
        self.assertIn("currentQuery.tag", text)
        self.assertIn("ProfileListProjection.filtered(", text)
        self.assertIn('? currentSearchText : ""', text)

    def test_bulk_proxy_action_has_one_target_snapshot_contract(self) -> None:
        text = BULK_PROXY_ACTION.read_text(encoding="utf-8")

        self.assertIn("let profiles: [BrowserProfile]", text)
        self.assertIn("var profileIDs: [UUID]", text)
        self.assertIn("var count: Int", text)
        self.assertIn("var isVisible: Bool", text)
        self.assertIn("profile.proxy != nil", text)
        self.assertIn("processState(profile.id) == .stopped", text)
        self.assertIn("!isPreparing(profile.id)", text)
        self.assertIn("!isTesting(profile.id)", text)

    def test_runtime_and_proxy_launch_docs_match_direct_behavior(self) -> None:
        readme = README.read_text(encoding="utf-8")
        product = PRODUCT.read_text(encoding="utf-8")
        roadmap = ROADMAP.read_text(encoding="utf-8")

        self.assertIn("перед каждой сессией прокси-профиля", readme)
        self.assertIn("Ручная проверка остаётся", readme)
        self.assertIn("before every proxy-bound browser", product)
        self.assertIn("Bundled compatible ARM64 NeAntik Browser", product)
        self.assertNotIn("Installed or manually selected Chromium", product)
        self.assertNotIn("separately installed compatible Chromium", product)
        self.assertIn("перед каждой прокси-сессией", roadmap)
        self.assertIn("не переиспользует ручную проверку", roadmap)


if __name__ == "__main__":
    unittest.main()
