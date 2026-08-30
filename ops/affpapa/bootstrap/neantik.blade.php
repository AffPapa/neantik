@extends('affpapa.layout')

@section('title', 'NeAntik — антидетект-браузер для Apple Silicon Mac | AffPapa')
@section('description', 'NeAntik — нативный менеджер браузерных профилей для macOS со встроенным Chromium. Изолированные сессии, прокси и локальное хранение. SwiftUI, без Electron, без облака.')
@section('canonical', 'https://affpapa.org/neantik')

@php
    $releaseManifestPath = public_path('neantik/release.json');
    $contentManifestPath = public_path('neantik/content.json');
    $releaseManifest = is_file($releaseManifestPath)
        ? json_decode((string) file_get_contents($releaseManifestPath), true)
        : [];
    $contentManifest = is_file($contentManifestPath)
        ? json_decode((string) file_get_contents($contentManifestPath), true)
        : [];
    $releaseManifest = is_array($releaseManifest) ? $releaseManifest : [];
    $contentManifest = is_array($contentManifest) ? $contentManifest : [];
    $releaseVersion = (string) ($releaseManifest['version'] ?? '0.3.21');
    $releaseBuild = (int) ($releaseManifest['build'] ?? 24);
    $runtimeVersion = (string) ($releaseManifest['runtime']['version'] ?? '152.0.7977.64');
    $runtimeMajor = explode('.', $runtimeVersion)[0] ?? '152';
    $artifactByFormat = [];
    foreach (($releaseManifest['artifacts'] ?? []) as $artifact) {
        if (is_array($artifact) && isset($artifact['format'])) {
            $artifactByFormat[$artifact['format']] = $artifact;
        }
    }

    $faqs = [
        ['q' => 'Это антидетект-браузер?', 'a' => 'NeAntik — нативный менеджер изолированных Chromium-профилей с fingerprint-протоколом. Он разделяет cookies, storage и proxy между профилями и включает встроенный Chromium '.$runtimeMajor.' с поддержкой Metal. Каждый выпуск проходит автоматическую проверку стабильности и разделения профилей.'],
        ['q' => 'Нужен ли установленный Chrome?', 'a' => 'Нет. NeAntik включает собственный Chromium '.$runtimeVersion.' ARM64 с Metal. Внешний браузер не требуется — всё работает из коробки.'],
        ['q' => 'Чем профиль NeAntik отличается от инкогнито?', 'a' => 'Инкогнито временно отделяет cookies и историю, но не создаёт постоянную сессию и не меняет fingerprint устройства. Профиль NeAntik сохраняется между запусками, использует отдельный data directory и может иметь собственный proxy и identity.'],
        ['q' => 'Где хранятся профили?', 'a' => 'Локально на Mac — в Application Support. Proxy-пароли хранятся отдельно в macOS Keychain. Облака и серверов нет.'],
        ['q' => 'Нужен ли аккаунт?', 'a' => 'Нет. Нет аккаунта, облачной синхронизации, аналитики или телеметрии.'],
        ['q' => 'Поддерживается ли Intel Mac?', 'a' => 'Нет. NeAntik выпускается только для Apple Silicon (ARM64) и требует macOS 14 или новее.'],
        ['q' => 'Поддерживаются ли прокси?', 'a' => 'Да. NeAntik поддерживает Direct, HTTP и HTTPS с логином и паролем, а также SOCKS5 без авторизации. Пароли HTTP/HTTPS хранятся в macOS Keychain.'],
        ['q' => 'Гарантирует ли NeAntik анонимность?', 'a' => 'Нет. Ни один браузер не может честно это гарантировать. Proxy, аккаунты, поведение и расширения могут связывать сессии. NeAntik уменьшает пересечение профилей и даёт инструмент для измерения fingerprint, но не обещает невозможность корреляции.'],
        ['q' => 'Нужно ли запускать проверку отпечатка?', 'a' => 'Нет. Перед публикацией NeAntik автоматически сравнивает два тестовых профиля и повторно проверяет первый. Пользователю достаточно создать профиль, при необходимости указать proxy и нажать «Запустить».'],
        ['q' => 'Как обновляется встроенный Chromium?', 'a' => 'Новая версия Chromium поставляется вместе с обновлением NeAntik. Текущая версия — '.$runtimeVersion.' ARM64 с Metal.'],
        ['q' => 'Это правила сайтов или капчи?', 'a' => 'NeAntik не обходит правила сайтов и не решает капчи. Каждый профиль — это отдельный рабочий контекст, как отдельный браузер. Ответственность за соблюдение правил площадок — на пользователе.'],
    ];

    $changelog = [
        [
            'ver' => '0.3.21',
            'build' => 24,
            'date' => '30 августа 2026',
            'label' => 'Public Alpha',
            'items' => [
                'Диагностика среды ведёт к реальному разделу, а официальная переустановка сохраняет данные профилей',
                'Заметка видна сразу при создании и всегда отображается в карточке профиля',
                'Установленное приложение уменьшено примерно на 125 МиБ безопасным удалением локальных символов до Developer ID signing',
                'Локали, лицензии, notices, SwiftShader, crashpad и security evidence сохранены',
                'GitHub и AffPapa публикуются двухфазно с повторной загрузкой и проверкой SHA-256; AffPapa автоматически откатывается при ошибке',
            ],
        ],
        [
            'ver' => '0.3.20',
            'build' => 23,
            'date' => '30 августа 2026',
            'label' => 'Public Alpha',
            'items' => [
                'Встроенный Chromium обновлён до 152.0.7977.64 для Apple Silicon, ARM64 и Metal',
                'Добавлен нативный однооконный workspace с папками, тегами, заметками и безопасным дублированием профилей',
                'Массовое создание профилей использует локальный предпросмотр прокси без скрытых сетевых запросов',
                'Persisted-профили и proxy-health history получили общие fail-closed byte-лимиты и атомарную запись',
                'ZIP и DMG подписаны Developer ID, нотарифицированы Apple, stapled и проверены Gatekeeper',
            ],
        ],
        [
            'ver' => '0.3.19',
            'build' => 22,
            'date' => '14 августа 2026',
            'label' => 'Public Alpha',
            'items' => [
                'Исправлена боковая панель в пустом состоянии: заголовок, создание профиля и управление sidebar теперь всегда закреплены сверху',
                'Кнопки скрытия sidebar и создания профиля получили одинаковую геометрию 32×32; значок «+» больше не сдвигается и не обрезается',
                'Поиск скрыт, пока профилей нет, а после удаления последнего профиля старые поиск и фильтры безопасно сбрасываются',
                'Добавлены нативные render-регрессии для пустого и заполненного sidebar на минимальном и широком окне',
                'Встроенный Chromium остаётся на проверенной версии 151.0.7922.108',
                'GitHub и AffPapa публикуются двухфазно с повторной загрузкой и проверкой; AffPapa автоматически откатывается при ошибке',
            ],
        ],
        [
            'ver' => '0.3.18',
            'build' => 21,
            'date' => '14 августа 2026',
            'label' => 'Public Alpha',
            'items' => [
                'Обычный интерфейс окончательно отделён от служебной проверки отпечатков: пользователю достаточно создать профиль, при необходимости указать proxy и нажать «Запустить»',
                'Постоянные технические статусы и параметры отпечатка убраны с главного экрана',
                'Новые профили по умолчанию открывают изменяемую страницу https://aff.top/tools/fingerprint; сохранённые страницы существующих профилей не переписываются',
                'Телеметрия самого NeAntik по-прежнему выключена',
                'GitHub и AffPapa публикуются двухфазно с повторной загрузкой и проверкой; AffPapa автоматически откатывается при ошибке',
            ],
        ],
        [
            'ver' => '0.3.17',
            'build' => 20,
            'date' => '12 августа 2026',
            'label' => 'Public Alpha',
            'items' => [
                'Встроенный движок обновлён до Chromium 151.0.7922.108; свежая ARM64/Metal-сборка прошла source provenance и полный Direct release gate',
                'Обычный сценарий сокращён до «профиль → прокси при необходимости → запуск», а техническая A → B → A проверка оставлена в защищённом release gate',
                'Прокси распознаются локально и мгновенно; внешняя проверка соединения запускается только отдельной необязательной кнопкой',
                'Запуск и изменение остаются на виду, а данные, архив, дублирование и удаление собраны в компактном меню «Ещё»',
                'Добавлены закрепление, архив без удаления BrowserData и безопасное дублирование профиля с новым UUID, seed и отдельной папкой',
                'Добавлено массовое создание до 100 независимых профилей из списка прокси без автоматических сетевых запросов',
                'GitHub и AffPapa публикуются двухфазно с повторной загрузкой и проверкой; AffPapa автоматически откатывается при ошибке',
            ],
        ],
        [
            'ver' => '0.3.16',
            'build' => 19,
            'date' => '6 августа 2026',
            'label' => 'Public Alpha',
            'items' => [
                'Встроенный движок обновлён до Chromium 151.0.7922.75 для Apple Silicon, ARM64 и Metal',
                'Seed и timezone профиля удалены из аргументов процессов; Chromium получает только минимальный проверенный набор переменных окружения',
                'Исправлена shipping-политика WebRTC и усилены release-gates для прокси, DNS, QUIC и WebGPU',
                'Проверка A → B → A требует согласованности page и worker, Client Hints, locale, Apple Silicon tuple и отсутствия прямой WebRTC-утечки при прокси',
                'Интерфейс профилей переработан для окон от 820 × 560: список, шапка и основные действия остаются доступными',
                'Создание профиля и вставка прокси упрощены; поддерживаются четыре распространённых формата, пароль остаётся в Связке ключей',
                'GitHub и AffPapa публикуются двухфазно с повторной загрузкой и проверкой; AffPapa автоматически откатывается при ошибке',
            ],
        ],
        [
            'ver' => '0.3.15',
            'build' => 18,
            'date' => '4 августа 2026',
            'label' => 'Public Alpha',
            'items' => [
                'NeAntik всегда использует только встроенный проверенный Chromium — ручные пути к стороннему браузеру больше не влияют на запуск',
                'Создание профиля стало короче: имя, при необходимости прокси и кнопка «Создать»; иконка, цвет, теги и стартовая страница перенесены в «Дополнительно»',
                'Поиск и фильтры по тегам больше не оставляют скрытый профиль выбранным для запуска',
                'Перед первой загрузкой существующих профилей создаётся безопасная recovery-копия метаданных без cookies и BrowserData',
                'Проверка профиля показывает понятную причину недоступности, а иконки сохраняют контраст в светлой и тёмной темах',
                'Менеджер быстрее готов к работе: тяжёлые Chromium hashes считаются только для защищённой fingerprint/release-проверки',
                'Локальная проверка встроенного runtime ускорена примерно с 23,4 до 3,7 секунды',
                'Единая Direct release-команда повторно использует точный подписанный кандидат и уже подтверждённый A → B → A отчёт',
            ],
        ],
        [
            'ver' => '0.3.14',
            'build' => 17,
            'date' => '4 августа 2026',
            'label' => 'Public Alpha',
            'items' => [
                'Проверка профиля стала одним понятным действием с результатом «пройдена / не пройдена»',
                'Добавлены локальные иконки, цвета, теги, поиск и фильтрация профилей',
                'Исправлен запуск удалённых профилей без создания пустых BrowserData-каталогов',
                'Уменьшена лишняя работа в горячем пути запуска и безопасно очищаются пустые временные каталоги проверки',
                'Релизная A → B → A проверка автоматизирована и привязана к точной подписанной сборке',
                'Доступны нотарифицированные DMG и ZIP для Apple Silicon',
            ],
        ],
        [
            'ver' => '0.3.13',
            'build' => 16,
            'date' => '30 июля 2026',
            'label' => 'Public Alpha',
            'items' => [
                'Chromium 150.0.7871.186 ARM64/Metal — обновлён public alpha release',
                'GUI fingerprint A → B → A проходит public-alpha gate',
                'Direct telemetry выключена',
                'Скачка ZIP напрямую с affpapa.org',
                'release.json для внешних интеграций',
            ],
        ],
        [
            'ver' => '0.3.12',
            'build' => 15,
            'date' => '28 июля 2026',
            'items' => [
                'Встроен проверенный Chromium 150.0.7871.186 ARM64 с Metal',
                'Совместимость окон (минимум 760 × 520)',
                'Улучшена миграция профилей и обработка Keychain',
                'Исправлены индикаторы состояния профиля',
                'Русская локализация',
                'Реализована проверка A→B→A',
                'Developer ID + Apple notarization + Gatekeeper verified',
            ],
        ],
        [
            'ver' => '0.3.1',
            'build' => 4,
            'date' => '25 июля 2026',
            'items' => [
                'Защита от PID reuse — не остановит чужой Chrome',
                'Owner-only (0600/0700) для metadata, отчётов и lock-файлов',
                'Rollback при ошибке записи на диск',
                'Строгая валидация DNS, IPv4, IPv6 proxy hosts',
                'Отключение QUIC в proxy-режиме',
                'Одноразовые browser-data directories для fingerprint check',
                'Proxy-пароли не попадают в process arguments',
                'Пройдены автоматические тесты Direct-сборки',
            ],
        ],
        [
            'ver' => '0.3.0',
            'build' => 3,
            'date' => '24 июля 2026',
            'items' => [
                'Встроенный fingerprint check A → B → A',
                'Canvas, WebGL, Audio, ClientRects, GPU, Client Hints, fonts, WebRTC',
                'Verdicts: verified, partial, unchanged, unstable',
                'Runtime manifest: Standard, Fingerprint, Cloak flavors',
                'Preflight: path, executable, Mach-O, signature, version',
                'Проверяемая Direct Distribution сборка для macOS',
            ],
        ],
        [
            'ver' => '0.2.0',
            'build' => 2,
            'date' => '24 июля 2026',
            'items' => [
                'Постоянный fingerprint seed для каждого профиля',
                'Различение stock Chrome и fingerprint-compatible runtime',
                'Проверка proxy: exit IP, город, страна, timezone, locale',
                'DNS и WebRTC leak controls',
                'Проверка ARM64 — Intel-only runtime не предлагается',
            ],
        ],
        [
            'ver' => '0.1',
            'build' => 1,
            'date' => '24 июля 2026',
            'label' => 'Prototype',
            'items' => [
                'Первый SwiftUI MVP для Apple Silicon',
                'Создание, редактирование, удаление профилей',
                'Отдельный Chromium data directory на профиль',
                'Постоянные cookies, local storage, sessions',
                'HTTP/HTTPS и SOCKS5 proxy, пароли в Keychain',
                'Process locks и browser logs',
            ],
        ],
    ];
    if (!empty($contentManifest['changelog']) && is_array($contentManifest['changelog'])) {
        $changelog = array_map(static fn (array $release): array => [
            'ver' => (string) ($release['version'] ?? ''),
            'build' => (int) ($release['build'] ?? 0),
            'date' => (string) ($release['date'] ?? ''),
            'label' => isset($release['label']) ? (string) $release['label'] : null,
            'items' => array_values(array_filter(
                $release['items'] ?? [],
                static fn ($item): bool => is_string($item)
            )),
        ], $contentManifest['changelog']);
    }

    $compareHeaders = ['', 'NeAntik', 'Multilogin', 'GoLogin', 'AdsPower', 'Dolphin Anty', 'Octo'];
    $compare = [
        ['Тип',             'Native macOS',  'Кросс-платформа', 'Кросс-платформа', 'Кросс-платформа', 'Кросс-платформа', 'Кросс-платформа'],
        ['Движок',          'SwiftUI + Chromium', 'Electron/Web', 'Electron',      'Electron',        'Electron',        'Electron/Web'],
        ['Браузер внутри',  'Chromium '.$runtimeMajor.' ARM64', 'Mimic/Stealthfox', 'Orbita',    'SunBrowser',      'Anty Browser',    'Octo Browser'],
        ['Облако',          'Нет',           'Да',              'Да',              'Да',              'Да (старшие)',    'Да'],
        ['Аккаунт',         'Не нужен',      'Нужен',           'Нужен',           'Нужен',           'Нужен',           'Нужен'],
        ['Команды и роли',  '—',             '✓',               '✓',               '✓',               '✓',               '✓'],
        ['Fingerprint',     'Стабильная identity профиля', 'Генерация', 'Генерация',   'Генерация',       'Генерация',       'Генерация'],
        ['Для кого',        'Индивид. на Mac', 'Команды',       'Команды',         'Команды',         'Affiliate-команды','Команды'],
    ];

    $surfaces = ['Canvas', 'WebGL pixels', 'WebGL vendor/renderer', 'Audio', 'ClientRects', 'GPU/device', 'Client Hints', 'Fonts', 'Timezone/locale', 'WebRTC'];

    $proofItems = [
        ['num' => $releaseVersion, 'label' => 'текущая версия'],
        ['num' => $runtimeMajor, 'label' => 'Chromium ARM64'],
        ['num' => '10', 'label' => 'поверхностей release-аудита'],
        ['num' => (string) $releaseBuild, 'label' => 'текущий build'],
    ];

    $dmgDownloadUrl = (string) ($artifactByFormat['dmg']['url'] ?? '#');
    $zipDownloadUrl = (string) ($artifactByFormat['zip']['url'] ?? '#');
    $githubReleaseUrl = (string) ($releaseManifest['source']['release'] ?? 'https://github.com/AffPapa/neantik/releases');
    $dmgSha256 = (string) ($artifactByFormat['dmg']['sha256'] ?? '');
    $zipSha256 = (string) ($artifactByFormat['zip']['sha256'] ?? '');
@endphp

@push('head')
<meta property="og:type" content="product">
<script type="application/ld+json">{!! json_encode([
    chr(64).'context' => 'https://schema.org',
    '@graph' => [
        [
            '@type' => 'SoftwareApplication',
            '@id' => 'https://affpapa.org/neantik#app',
            'name' => 'NeAntik',
            'applicationCategory' => 'UtilityApplication',
            'operatingSystem' => 'macOS 14 or later',
            'softwareVersion' => $releaseVersion,
            'processorRequirements' => 'Apple Silicon / ARM64',
            'downloadUrl' => $dmgDownloadUrl,
            'description' => 'Нативный менеджер изолированных браузерных профилей для Apple Silicon Mac со встроенным Chromium и автоматической проверкой каждого выпуска.',
        ],
        [
            '@type' => 'FAQPage',
            '@id' => 'https://affpapa.org/neantik#faq',
            'mainEntity' => array_map(fn ($f) => [
                '@type' => 'Question',
                'name' => $f['q'],
                'acceptedAnswer' => ['@type' => 'Answer', 'text' => $f['a']],
            ], $faqs),
        ],
    ],
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) !!}</script>
<style>
/* ── Scroll reveal ── */
.nk-reveal { opacity:0; transform:translateY(12px); transition:opacity 400ms cubic-bezier(.23,1,.32,1), transform 400ms cubic-bezier(.23,1,.32,1); }
.nk-reveal.is-visible { opacity:1; transform:translateY(0); }
@media (prefers-reduced-motion:reduce) { .nk-reveal { opacity:1; transform:none; transition:none; } }

/* ── Hero two-col ── */
.nk-hero-grid { display:grid; grid-template-columns:1fr; gap:2rem; align-items:center; }
@media (min-width:740px) { .nk-hero-grid { grid-template-columns:1fr 280px; } }
.nk-hero-visual { display:flex; align-items:center; justify-content:center; }
.nk-hero-icon { width:180px; height:180px; border-radius:32px; background:var(--accent-soft); border:1px solid var(--line); display:flex; align-items:center; justify-content:center; overflow:hidden; }
.nk-hero-icon svg { width:100px; height:100px; }
@media (max-width:739px) { .nk-hero-visual { display:none; } }

/* ── Platform line ── */
.nk-platform { display:flex; flex-wrap:wrap; gap:.5rem; margin-top:1rem; }
.nk-platform .chip { font-family:var(--mono); font-size:.72rem; letter-spacing:.02em; }

/* ── A→B→A interactive ── */
.nk-aba-demo { margin:1.5rem 0; }
.nk-aba { display:flex; align-items:center; gap:.5rem; flex-wrap:wrap; margin:0 0 .75rem; }
.nk-aba__node { position:relative; display:flex; flex-direction:column; align-items:center; gap:.2rem; padding:.7rem 1.1rem; border:1px solid var(--line); border-radius:var(--radius-sm); background:var(--bg-soft); min-width:90px; transition:border-color 250ms var(--ease-out), background 250ms var(--ease-out); }
.nk-aba__node--active { border-color:var(--accent-dim); background:var(--accent-soft); }
.nk-aba__node--done { border-color:var(--money, var(--accent-dim)); }
.nk-aba__node-label { font-family:var(--mono); font-size:.85rem; font-weight:700; color:var(--ink); }
.nk-aba__node-sub { font-size:.72rem; color:var(--ink-2); transition:color 200ms var(--ease-out); }
.nk-aba__node--active .nk-aba__node-sub { color:var(--accent-dim); }
.nk-aba__arrow { color:var(--ink-2); font-size:1.1rem; opacity:.4; transition:opacity 200ms var(--ease-out); }
.nk-aba__arrow--active { opacity:1; color:var(--accent-dim); }
.nk-aba__verdict { font-family:var(--mono); font-size:.82rem; font-weight:700; padding:.3rem .7rem; border-radius:var(--radius-sm); opacity:0; transform:scale(.95); transition:opacity 250ms var(--ease-out), transform 250ms var(--ease-out); }
.nk-aba__verdict.is-visible { opacity:1; transform:scale(1); }
.nk-aba__verdict--verified { color:var(--money); background:rgba(91,228,155,.08); border:1px solid rgba(91,228,155,.2); }
.nk-aba__btn { font-family:var(--mono); font-size:.78rem; padding:.45rem .9rem; border-radius:var(--radius-sm); border:1px solid var(--line); background:var(--bg-soft); color:var(--ink-2); cursor:pointer; transition:border-color 150ms var(--ease-out), color 150ms var(--ease-out), transform 120ms var(--ease-out); }
.nk-aba__btn:active { transform:scale(.97); }
@media (hover:hover) and (pointer:fine) { .nk-aba__btn:hover { border-color:var(--accent-dim); color:var(--accent-dim); } }

/* ── Surfaces chips ── */
.nk-surfaces { display:flex; flex-wrap:wrap; gap:.35rem; margin-top:.75rem; }
.nk-surfaces .chip { font-size:.75rem; }

/* ── Problem section ── */
.nk-problem { max-width:38rem; }
.nk-problem p { color:var(--ink-2); font-size:.95rem; line-height:1.55; margin-bottom:.75rem; }
.nk-problem p:last-child { margin-bottom:0; }

/* ── Local-first cards ── */
.nk-local-cards { display:grid; grid-template-columns:1fr; gap:.75rem; }
@media (min-width:600px) { .nk-local-cards { grid-template-columns:repeat(3,1fr); } }
.nk-local-card { padding:1.15rem; }
.nk-local-card h3 { margin:0 0 .3rem; font-size:.95rem; font-weight:700; }
.nk-local-card p { margin:0; color:var(--ink-2); font-size:.88rem; line-height:1.45; }
.nk-local-card__icon { font-family:var(--mono); font-size:.75rem; font-weight:600; color:var(--accent-dim); margin-bottom:.5rem; display:block; }

/* ── Feature cards ── */
.nk-features { display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:1rem; }
.nk-feat { position:relative; padding:1.25rem; }
.nk-feat__icon { width:2.2rem; height:2.2rem; display:flex; align-items:center; justify-content:center; border-radius:var(--radius-sm); background:var(--accent-soft); color:var(--accent-dim); font-family:var(--mono); font-size:1.1rem; font-weight:700; margin-bottom:.75rem; }
.nk-feat h3 { margin:0 0 .35rem; font-size:1rem; font-weight:700; }
.nk-feat p { margin:0; color:var(--ink-2); font-size:.92rem; line-height:1.45; }

/* ── Steps ── */
.nk-steps { counter-reset:step; display:grid; gap:.6rem; }
.nk-step { position:relative; padding:.9rem 1rem .9rem 3.4rem; }
.nk-step::before { counter-increment:step; content:counter(step); position:absolute; left:1rem; top:.9rem; width:1.8rem; height:1.8rem; display:flex; align-items:center; justify-content:center; border-radius:50%; background:var(--accent-soft); color:var(--accent-dim); font-family:var(--mono); font-weight:700; font-size:.85rem; }
.nk-step h3 { margin:0 0 .2rem; font-size:.95rem; font-weight:700; }
.nk-step p { margin:0; color:var(--ink-2); font-size:.88rem; }

/* ── Proof stats ── */
.nk-proof { display:grid; grid-template-columns:repeat(auto-fit,minmax(120px,1fr)); gap:.75rem; margin-top:1rem; }
.nk-proof-stat { padding:.85rem; text-align:center; }
.nk-proof-stat__num { display:block; font-family:var(--mono); font-variant-numeric:tabular-nums; font-size:1.6rem; font-weight:800; color:var(--ink); letter-spacing:-0.03em; }
.nk-proof-stat__label { display:block; font-size:.78rem; color:var(--ink-2); margin-top:.15rem; }

/* ── Comparison table ── */
.nk-compare-wrap { overflow-x:auto; border:1px solid var(--line); border-radius:var(--radius); }
.nk-compare { width:100%; border-collapse:collapse; font-size:.82rem; min-width:780px; }
.nk-compare th, .nk-compare td { padding:.6rem .7rem; text-align:left; border-bottom:1px solid var(--line); vertical-align:top; }
.nk-compare thead th { font-weight:700; color:var(--ink); background:var(--bg-soft); position:sticky; top:0; z-index:2; }
.nk-compare thead th:nth-child(2) { color:var(--accent-dim); }
.nk-compare tbody th { font-weight:500; color:var(--ink-2); background:var(--bg); position:sticky; left:0; z-index:1; }
.nk-compare tbody td { color:var(--ink); }
.nk-compare tbody td:first-of-type { color:var(--accent-dim); font-weight:600; }
.nk-compare tr:last-child th, .nk-compare tr:last-child td { border-bottom:0; }
@media (hover:hover) and (pointer:fine) {
    .nk-compare tbody tr { transition:background-color 120ms ease; }
    .nk-compare tbody tr:hover { background:var(--bg-soft); }
}

/* ── Changelog ── */
.nk-changelog { display:grid; gap:1.5rem; }
.nk-release { position:relative; padding-left:1.5rem; border-left:2px solid var(--line); }
.nk-release__head { display:flex; align-items:baseline; gap:.5rem; flex-wrap:wrap; margin-bottom:.4rem; }
.nk-release__ver { font-family:var(--mono); font-variant-numeric:tabular-nums; font-size:1rem; font-weight:800; color:var(--ink); }
.nk-release__label { font-size:.75rem; color:var(--accent-dim); font-weight:600; }
.nk-release__date { font-size:.78rem; color:var(--ink-2); }
.nk-release__list { margin:0; padding:0 0 0 1rem; }
.nk-release__list li { font-size:.88rem; color:var(--ink-2); line-height:1.5; margin-bottom:.2rem; }
.nk-release:first-child { border-left-color:var(--accent-dim); }

/* ── Honest boundary ── */
.nk-boundary { padding:1.15rem 1.25rem; border-left:3px solid var(--accent); border-radius:0 var(--radius-sm) var(--radius-sm) 0; background:var(--bg-soft); }
.nk-boundary__title { font-size:.9rem; font-weight:700; color:var(--ink); margin:0 0 .5rem; }
.nk-boundary p { margin:.4rem 0 0; font-size:.88rem; color:var(--ink-2); line-height:1.55; }
.nk-boundary p:first-of-type { margin:0; }

/* ── Editions ── */
.nk-editions { display:grid; grid-template-columns:1fr; gap:1rem; }
@media (min-width:600px) { .nk-editions { grid-template-columns:1fr 1fr; } }
.nk-edition { padding:1.25rem; }
.nk-edition h3 { margin:0 0 .35rem; font-size:1rem; font-weight:700; }
.nk-edition p { margin:0; color:var(--ink-2); font-size:.88rem; line-height:1.45; }
.nk-edition__badge { display:inline-block; font-family:var(--mono); font-size:.7rem; font-weight:600; padding:.15rem .45rem; border-radius:999px; margin-bottom:.5rem; }
.nk-edition__badge--direct { background:var(--accent-soft); color:var(--accent-dim); }

/* ── Security chips ── */
.nk-security { display:flex; flex-wrap:wrap; gap:.5rem; margin-top:1rem; }
.nk-security .chip { font-family:var(--mono); font-size:.72rem; letter-spacing:.02em; }
.nk-security .chip--verified { border-color:rgba(91,228,155,.3); color:var(--money); }

/* ── SHA line ── */
.nk-sha { font-family:var(--mono); font-size:.72rem; color:var(--ink-2); word-break:break-all; line-height:1.5; margin-top:.75rem; padding:.6rem .8rem; background:var(--bg-soft); border:1px solid var(--line); border-radius:var(--radius-sm); }
.nk-sha strong { color:var(--ink); font-weight:600; }

/* ── Privacy cards ── */
.nk-privacy { display:grid; grid-template-columns:1fr; gap:.75rem; }
@media (min-width:600px) { .nk-privacy { grid-template-columns:1fr 1fr; } }
.nk-privacy-card { padding:1.15rem; }
.nk-privacy-card h3 { margin:0 0 .35rem; font-size:.95rem; font-weight:700; }
.nk-privacy-card ul { margin:.3rem 0 0; padding:0 0 0 1.1rem; }
.nk-privacy-card li { color:var(--ink-2); font-size:.88rem; line-height:1.5; margin-bottom:.15rem; }
.nk-privacy-card__icon { font-family:var(--mono); font-size:.75rem; font-weight:600; margin-bottom:.5rem; display:block; }
.nk-privacy-card__icon--green { color:var(--money); }
.nk-privacy-card__icon--muted { color:var(--ink-2); }

/* ── FAQ smooth ── */
.nk-faq-item { border:1px solid var(--line); border-radius:var(--radius-sm); margin-bottom:.6rem; background:var(--bg); overflow:hidden; }
.nk-faq-item__q { width:100%; border:none; background:none; padding:.85rem 2.5rem .85rem 1rem; font:inherit; font-weight:600; font-size:1rem; color:var(--ink); text-align:left; cursor:pointer; position:relative; }
.nk-faq-item__q::after { content:'+'; position:absolute; right:1rem; top:.85rem; font-family:var(--mono); color:var(--accent-dim); font-size:1.1rem; transition:transform 200ms var(--ease-out); }
.nk-faq-item.is-open .nk-faq-item__q::after { transform:rotate(45deg); }
@media (hover:hover) and (pointer:fine) { .nk-faq-item__q:hover { color:var(--accent-dim); } }
.nk-faq-item__a { display:grid; grid-template-rows:0fr; transition:grid-template-rows 250ms var(--ease-out); }
.nk-faq-item.is-open .nk-faq-item__a { grid-template-rows:1fr; }
.nk-faq-item__a-inner { overflow:hidden; }
.nk-faq-item__a-inner p { padding:0 1rem .85rem; margin:0; color:var(--ink-2); font-size:.92rem; line-height:1.5; }
@media (prefers-reduced-motion:reduce) { .nk-faq-item__a { transition:none; } }

/* ── Product screenshots ── */
.nk-screenshots { display:grid; grid-template-columns:1fr; gap:1.25rem; }
@media (min-width:740px) { .nk-screenshots { grid-template-columns:repeat(3,1fr); } }
.nk-screenshot { border:1px solid var(--line); border-radius:var(--radius); overflow:hidden; background:var(--bg-soft); }
.nk-screenshot img { width:100%; height:auto; display:block; }
.nk-screenshot__caption { padding:.75rem 1rem; }
.nk-screenshot__caption h3 { margin:0 0 .2rem; font-size:.95rem; font-weight:700; }
.nk-screenshot__caption p { margin:0; color:var(--ink-2); font-size:.82rem; line-height:1.45; }

/* ── Buttons ── */
.btn:active { transform:scale(.97); }
.btn--disabled { opacity:.5; pointer-events:none; }
</style>
@endpush

@section('content')
    {{-- ═══ HERO ═══ --}}
    <section class="hero" id="top">
        <div class="nk-hero-grid">
            <div>
                <p class="badge"><span class="badge-dot" aria-hidden="true"></span>Public Alpha · Apple Silicon · Chromium {{ $runtimeMajor }}</p>
                <h1 class="hero-title">Отдельный браузер<br>для каждой рабочей сессии</h1>
                <p class="hero-lead">NeAntik разделяет cookies, сессии, storage и&nbsp;proxy между профилями. Встроенный Chromium {{ $runtimeMajor }} — ничего не&nbsp;нужно устанавливать отдельно. SwiftUI, без Electron, без аккаунта, без телеметрии.</p>

                <div class="nk-platform">
                    <span class="chip">macOS 14+</span>
                    <span class="chip">Apple Silicon</span>
                    <span class="chip">ARM64 only</span>
                    <span class="chip">SwiftUI</span>
                    <span class="chip">v{{ $releaseVersion }}</span>
                    <span class="chip">Chromium {{ $runtimeMajor }}</span>
                </div>

                <div class="hero-actions" style="margin-top:1.25rem;">
                    <a class="btn btn-primary" href="{{ $dmgDownloadUrl }}">Скачать DMG</a>
                    <a class="btn btn-ghost" href="{{ $zipDownloadUrl }}">Скачать ZIP</a>
                    <a class="btn btn-ghost" href="{{ $githubReleaseUrl }}" rel="noopener">GitHub Release</a>
                </div>

                <div class="nk-security">
                    <span class="chip chip--verified">Developer ID</span>
                    <span class="chip chip--verified">Apple Notarized</span>
                    <span class="chip chip--verified">Gatekeeper Verified</span>
                </div>
            </div>
            <div class="nk-hero-visual">
                <div class="nk-hero-icon" aria-hidden="true">
                    <svg viewBox="0 0 100 100" fill="none" xmlns="http://www.w3.org/2000/svg">
                        <rect x="18" y="22" width="64" height="48" rx="6" stroke="var(--accent-dim)" stroke-width="2.5" fill="none"/>
                        <rect x="28" y="32" width="18" height="28" rx="3" stroke="var(--ink-2)" stroke-width="1.5" fill="var(--accent-soft)" opacity=".6"/>
                        <rect x="54" y="32" width="18" height="28" rx="3" stroke="var(--ink-2)" stroke-width="1.5" fill="var(--bg-soft)" opacity=".6"/>
                        <line x1="50" y1="36" x2="50" y2="56" stroke="var(--accent-dim)" stroke-width="1" stroke-dasharray="3 2"/>
                        <path d="M40 76 50 82 60 76" stroke="var(--accent-dim)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
                    </svg>
                </div>
            </div>
        </div>
    </section>

    {{-- ═══ SCREENSHOTS ═══ --}}
    <section class="section nk-reveal" id="neantik-screenshots">
        <div class="section-head"><h2>Как выглядит NeAntik</h2></div>
        <div class="nk-screenshots">
            <div class="nk-screenshot nk-reveal" style="transition-delay:0ms">
                <img src="/img/neantik/profiles.svg" alt="NeAntik — менеджер профилей" width="1440" height="900" loading="lazy">
                <div class="nk-screenshot__caption">
                    <h3>Профили и запуск</h3>
                    <p>Локальные профили, понятный статус proxy и быстрый запуск браузера без тяжёлой shell-платформы.</p>
                </div>
            </div>
            <div class="nk-screenshot nk-reveal" style="transition-delay:80ms">
                <img src="/img/neantik/audit.svg" alt="NeAntik — автоматический fingerprint-аудит выпуска" width="1440" height="900" loading="lazy">
                <div class="nk-screenshot__caption">
                    <h3>Проверка выпуска</h3>
                    <p>Перед публикацией автоматический A → B → A аудит подтверждает различие профилей и стабильность повторного запуска.</p>
                </div>
            </div>
            <div class="nk-screenshot nk-reveal" style="transition-delay:160ms">
                <img src="/img/neantik/proxy-privacy.svg" alt="NeAntik — proxy и приватность" width="1440" height="900" loading="lazy">
                <div class="nk-screenshot__caption">
                    <h3>Proxy и приватность</h3>
                    <p>Proxy на профиль, Keychain для паролей, локальные данные и выключенная в Direct-сборке телеметрия.</p>
                </div>
            </div>
        </div>
    </section>

    {{-- ═══ PROBLEM ═══ --}}
    <section class="section nk-reveal" id="neantik-problem">
        <div class="section-head"><h2>Профили должны разделять контексты, а&nbsp;не&nbsp;усложнять работу</h2></div>
        <div class="nk-problem">
            <p>Режим инкогнито не&nbsp;создаёт новое устройство для сайта. Cookies можно очистить, но&nbsp;Canvas, WebGL, Audio, GPU, timezone и&nbsp;другие сигналы остаются связанными с&nbsp;тем&nbsp;же браузером и&nbsp;Mac.</p>
            <p>Большие антидетект-платформы решают эту задачу вместе с&nbsp;облаком, командами, API, RPA и&nbsp;десятками настроек. Это полезно для масштабных операций, но&nbsp;лишнее, если нужны несколько постоянных локальных контекстов на&nbsp;одном Mac.</p>
            <p>NeAntik оставляет только основу: профиль, proxy, встроенный Chromium и&nbsp;стабильная identity. Сложная диагностика остаётся внутри release-процесса.</p>
        </div>
    </section>

    {{-- ═══ AUTOMATIC RELEASE AUDIT ═══ --}}
    <section class="section nk-reveal" id="neantik-check">
        <div class="section-head"><h2>Каждый выпуск проверяется автоматически</h2></div>
        <p class="muted" style="max-width:640px; margin-bottom:1rem;">Перед публикацией NeAntik сравнивает два тестовых профиля и повторно запускает первый. Обычному пользователю не нужно разбираться в отчётах: релиз не публикуется без успешного результата.</p>

        <div class="nk-aba-demo">
            <div class="nk-aba">
                <div class="nk-aba__node nk-aba__node--done">
                    <span class="nk-aba__node-label">Profile A</span>
                    <span class="nk-aba__node-sub" style="color:var(--money)">stable</span>
                </div>
                <span class="nk-aba__arrow nk-aba__arrow--active" aria-hidden="true">→</span>
                <div class="nk-aba__node nk-aba__node--done">
                    <span class="nk-aba__node-label">Profile B</span>
                    <span class="nk-aba__node-sub" style="color:var(--accent-dim)">distinct</span>
                </div>
                <span class="nk-aba__arrow nk-aba__arrow--active" aria-hidden="true">→</span>
                <div class="nk-aba__node nk-aba__node--done">
                    <span class="nk-aba__node-label">Profile A</span>
                    <span class="nk-aba__node-sub" style="color:var(--money)">stable</span>
                </div>
                <span class="nk-aba__verdict is-visible nk-aba__verdict--verified">release verified</span>
            </div>
        </div>

        <p style="font-size:.88rem; color:var(--ink-2); margin:.5rem 0;">Release gate проверяет различие профилей и повторяемость первого профиля. Подробный отчёт нужен разработчикам, а не в обычной работе.</p>

        <div class="nk-surfaces">
            @foreach ($surfaces as $s)
                <span class="chip">{{ $s }}</span>
            @endforeach
        </div>
    </section>

    {{-- ═══ LOCAL-FIRST ═══ --}}
    <section class="section nk-reveal" id="neantik-local">
        <div class="section-head"><h2>Ваши профили остаются на&nbsp;вашем Mac</h2></div>
        <div class="nk-local-cards">
            <div class="card nk-local-card nk-reveal" style="transition-delay:0ms">
                <span class="nk-local-card__icon" aria-hidden="true">SESSION</span>
                <h3>Отдельные сессии</h3>
                <p>Cookies, localStorage, cache и авторизация каждого профиля изолированы в отдельных папках.</p>
            </div>
            <div class="card nk-local-card nk-reveal" style="transition-delay:60ms">
                <span class="nk-local-card__icon" aria-hidden="true">NETWORK</span>
                <h3>Отдельная сеть</h3>
                <p>Direct, HTTP, HTTPS и SOCKS5 proxy назначается профилю. Проверка exit IP и согласование timezone.</p>
            </div>
            <div class="card nk-local-card nk-reveal" style="transition-delay:120ms">
                <span class="nk-local-card__icon" aria-hidden="true">KEYCHAIN</span>
                <h3>macOS security</h3>
                <p>Пароли прокси в Keychain, owner-only файлы, proxy credentials не попадают в command line.</p>
            </div>
        </div>
    </section>

    {{-- ═══ WHY NEANTIK ═══ --}}
    <section class="section nk-reveal" id="neantik-why">
        <div class="section-head"><h2>Почему NeAntik</h2></div>
        <div class="nk-features">
            <div class="card nk-feat nk-reveal" style="transition-delay:0ms">
                <div class="nk-feat__icon" aria-hidden="true">◆</div>
                <h3>Нативный для Mac</h3>
                <p>SwiftUI, ARM64-only. Без Electron, Tauri, Node.js. Менеджер + встроенный Chromium — всё в одном приложении.</p>
            </div>
            <div class="card nk-feat nk-reveal" style="transition-delay:60ms">
                <div class="nk-feat__icon" aria-hidden="true">⊘</div>
                <h3>Без облака и аккаунта</h3>
                <p>Профили хранятся на Mac. Нет синхронизации, нет телеметрии, нет сервера. История, cookies, URL — не передаются.</p>
            </div>
            <div class="card nk-feat nk-reveal" style="transition-delay:120ms">
                <div class="nk-feat__icon" aria-hidden="true">⊞</div>
                <h3>Chromium {{ $runtimeMajor }} из коробки</h3>
                <p>Встроенный Chromium {{ $runtimeVersion }} ARM64 с Metal. Внешний Chrome не нужен — скачал, открыл, работаешь.</p>
            </div>
            <div class="card nk-feat nk-reveal" style="transition-delay:180ms">
                <div class="nk-feat__icon" aria-hidden="true">↻</div>
                <h3>Proxy + leak control</h3>
                <p>Direct, HTTP/HTTPS, SOCKS5. Проверка exit IP, блокировка DNS fallback, отключение QUIC и non-proxied WebRTC.</p>
            </div>
        </div>
    </section>

    {{-- ═══ HOW IT WORKS ═══ --}}
    <section class="section nk-reveal" id="neantik-how">
        <div class="section-head"><h2>Четыре шага</h2></div>
        <div class="nk-steps">
            <div class="card nk-step nk-reveal" style="transition-delay:0ms">
                <h3>Скачайте и установите</h3>
                <p>Откройте DMG и перетащите NeAntik.app в папку «Программы». ZIP доступен как альтернативный формат.</p>
            </div>
            <div class="card nk-step nk-reveal" style="transition-delay:80ms">
                <h3>Создайте профиль</h3>
                <p>Откройте NeAntik. Имя, цвет, стартовая страница — приложение создаст изолированное хранилище.</p>
            </div>
            <div class="card nk-step nk-reveal" style="transition-delay:160ms">
                <h3>Подключите proxy</h3>
                <p>Direct, HTTP/HTTPS или SOCKS5. Проверьте exit IP, страну и timezone одной кнопкой.</p>
            </div>
            <div class="card nk-step nk-reveal" style="transition-delay:240ms">
                <h3>Запустите браузер</h3>
                <p>Нажмите «Запустить» — откроется встроенный Chromium с данными, сетью и identity выбранного профиля.</p>
            </div>
        </div>
    </section>

    {{-- ═══ PRIVACY ═══ --}}
    <section class="section nk-reveal" id="neantik-privacy">
        <div class="section-head"><h2>Что хранится локально, что не отправляется</h2></div>
        <div class="nk-privacy">
            <div class="card nk-privacy-card nk-reveal" style="transition-delay:0ms">
                <span class="nk-privacy-card__icon nk-privacy-card__icon--green" aria-hidden="true">LOCAL</span>
                <h3>Хранится на Mac</h3>
                <ul>
                    <li>Данные профилей (Application Support)</li>
                    <li>Cookies, localStorage, cache</li>
                    <li>История посещений и URL</li>
                    <li>Proxy-пароли (macOS Keychain)</li>
                    <li>Технические отчёты локальной диагностики</li>
                </ul>
            </div>
            <div class="card nk-privacy-card nk-reveal" style="transition-delay:60ms">
                <span class="nk-privacy-card__icon nk-privacy-card__icon--muted" aria-hidden="true">NOT SENT</span>
                <h3>Не передаётся никуда</h3>
                <ul>
                    <li>Телеметрия отключена</li>
                    <li>Нет облачной синхронизации</li>
                    <li>Нет аналитики использования</li>
                    <li>Нет аккаунта и регистрации</li>
                    <li>Нет серверов NeAntik</li>
                </ul>
            </div>
        </div>
    </section>

    {{-- ═══ PROOF ═══ --}}
    <section class="section nk-reveal" id="neantik-proof">
        <div class="section-head"><h2>Что уже проверено</h2></div>
        <div class="nk-proof">
            @foreach ($proofItems as $pi)
                <div class="card nk-proof-stat nk-reveal">
                    <span class="nk-proof-stat__num">{!! $pi['num'] !!}</span>
                    <span class="nk-proof-stat__label">{!! $pi['label'] !!}</span>
                </div>
            @endforeach
        </div>
        <p class="muted" style="margin-top:1rem; font-size:.82rem; max-width:38rem;">Swift strict-concurrency, ARM64-only release, Developer ID + Apple notarization, Gatekeeper verified, owner-only metadata, PID reuse protection, proxy injection tests.</p>

        <div class="nk-sha">
            <strong>DMG SHA-256:</strong> {{ $dmgSha256 }}<br>
            <strong>ZIP SHA-256:</strong> {{ $zipSha256 }}
        </div>
    </section>

    {{-- ═══ COMPARISON ═══ --}}
    <section class="section nk-reveal" id="neantik-compare">
        <div class="section-head"><h2>NeAntik vs антидетект-платформы</h2></div>
        <div class="nk-compare-wrap">
            <table class="nk-compare">
                <thead>
                    <tr>
                        @foreach ($compareHeaders as $h)
                            <th>{{ $h }}</th>
                        @endforeach
                    </tr>
                </thead>
                <tbody>
                    @foreach ($compare as $row)
                        <tr>
                            <th scope="row">{{ $row[0] }}</th>
                            @for ($i = 1; $i < count($row); $i++)
                                <td>{{ $row[$i] }}</td>
                            @endfor
                        </tr>
                    @endforeach
                </tbody>
            </table>
        </div>
        <p class="muted" style="margin-top:.8rem; font-size:.78rem;">NeAntik не заменяет командные функции больших платформ. Он для другого: быстрые локальные профили на Apple Silicon без инфраструктуры вокруг.</p>
    </section>

    {{-- ═══ DISTRIBUTION ═══ --}}
    <section class="section nk-reveal" id="neantik-editions">
        <div class="section-head"><h2>Direct Distribution для macOS</h2></div>
        <div class="nk-editions">
            <div class="card nk-edition">
                <span class="nk-edition__badge nk-edition__badge--direct">Direct</span>
                <h3>Одна полноценная версия</h3>
                <p>NeAntik распространяется с сайта и GitHub. В приложение встроен Chromium {{ $runtimeMajor }}, используются отдельные каталоги данных и fingerprint identity. Сборка подписана Developer ID, нотарифицирована Apple и проверена Gatekeeper.</p>
            </div>
        </div>
    </section>

    {{-- ═══ HONEST BOUNDARY ═══ --}}
    <section class="section nk-reveal" id="neantik-boundary">
        <div class="nk-boundary">
            <p class="nk-boundary__title">Честный public alpha</p>
            <p>NeAntik — рабочий инструмент на стадии public alpha. Встроенный Chromium {{ $runtimeMajor }} с Metal работает, а каждый опубликованный кандидат проходит автоматический release-аудит. Но это альфа: возможны баги, интерфейс меняется между релизами, профили могут потребовать миграцию при обновлении.</p>
            <p>NeAntik не гарантирует анонимность и не обходит правила сайтов. Proxy, аккаунты, поведение и расширения могут связывать сессии. Инструмент уменьшает пересечение профилей и даёт способ это измерить — но ответственность за использование остаётся на пользователе.</p>
        </div>
    </section>

    {{-- ═══ CHANGELOG ═══ --}}
    <section class="section nk-reveal" id="neantik-changelog">
        <div class="section-head"><h2>Changelog</h2></div>
        <div class="nk-changelog">
            @foreach ($changelog as $rel)
                <div class="nk-release">
                    <div class="nk-release__head">
                        <span class="nk-release__ver">{{ $rel['ver'] }}</span>
                        @if (!empty($rel['label']))
                            <span class="nk-release__label">{{ $rel['label'] }}</span>
                        @endif
                        <span class="nk-release__date">build {{ $rel['build'] }} · {{ $rel['date'] }}</span>
                    </div>
                    <ul class="nk-release__list">
                        @foreach ($rel['items'] as $item)
                            <li>{{ $item }}</li>
                        @endforeach
                    </ul>
                </div>
            @endforeach
        </div>
    </section>

    {{-- ═══ FAQ ═══ --}}
    <section class="section nk-reveal" id="neantik-faq">
        <div class="section-head"><h2>Вопросы и ответы</h2></div>
        @foreach ($faqs as $f)
            <div class="nk-faq-item" x-data="{open:false}" :class="{'is-open':open}">
                <button class="nk-faq-item__q" type="button" @click="open=!open" :aria-expanded="open">{{ $f['q'] }}</button>
                <div class="nk-faq-item__a" role="region">
                    <div class="nk-faq-item__a-inner">
                        <p>{{ $f['a'] }}</p>
                    </div>
                </div>
            </div>
        @endforeach
    </section>

    {{-- ═══ FINAL CTA ═══ --}}
    <section class="section nk-reveal" style="text-align:center; padding:2.5rem 0;">
        <h2 style="font-size:1.3rem; margin:0 0 .5rem;">Начните с чистого профиля</h2>
        <p class="muted" style="margin:0 0 1.25rem; max-width:480px; margin-left:auto; margin-right:auto;">Скачайте, создайте профиль, нажмите Launch. Встроенный Chromium, без аккаунта, без облака.</p>
        <div class="hero-actions" style="justify-content:center;">
            <a class="btn btn-primary" href="{{ $dmgDownloadUrl }}">Скачать DMG</a>
            <a class="btn btn-ghost" href="{{ $zipDownloadUrl }}">Скачать ZIP</a>
            <a class="btn btn-ghost" href="{{ $githubReleaseUrl }}" rel="noopener">GitHub</a>
        </div>
        <div class="nk-security" style="justify-content:center; margin-top:.75rem;">
            <span class="chip chip--verified">Developer ID</span>
            <span class="chip chip--verified">Apple Notarized</span>
            <span class="chip chip--verified">SHA-256 verified</span>
        </div>
    </section>

    <script>
    (function () {
        if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
            var obs = new IntersectionObserver(function (entries) {
                entries.forEach(function (e) {
                    if (e.isIntersecting) { e.target.classList.add('is-visible'); obs.unobserve(e.target); }
                });
            }, { threshold: 0.08, rootMargin: '0px 0px -40px 0px' });
            document.querySelectorAll('.nk-reveal').forEach(function (el) { obs.observe(el); });
        } else {
            document.querySelectorAll('.nk-reveal').forEach(function (el) { el.classList.add('is-visible'); });
        }
    })();

    </script>
@endsection
