# Installing and updating Tilvero

[English](#english) · [Русский](#русский)

## English

**Current availability:** no public DMG has been published. [Build from source](../README.md#build-and-run) if you want to use the development build. Local packages marked **TEST** use ad-hoc signing for internal verification; they are not the recommended public installation route. A local package, a checksum or a successful build alone does not establish Gatekeeper or notarization acceptance.

The first distribution scope is **Monitoring Preview**, for **Apple silicon (arm64), macOS 26.0+**. Monitoring, local history and diagnostics do not require administrator approval. The monitoring package contains no privileged helper and does not register a service. Physical charging, power-mode and fan controls remain disabled.

### When a trusted release is published

Use the exact release and DMG linked from the README. A preview/beta uses its explicit prerelease tag; a generic “latest” link can resolve to a different stable release. Check that the release identifies the version, arm64 architecture, minimum macOS, source commit and verified Developer ID/notarization status. Its release notes must include the matching source archive, `SHA256SUMS` and `release.json`.

1. Download the listed DMG and verification files from that same release. In Terminal, change to the folder containing those files and run `shasum -a 256 -c SHA256SUMS`; download every file named in the checksum list before checking it. Open the DMG only after the listed checks pass.
2. Drag Tilvero to **Applications**, then eject the disk image.
3. Open **Tilvero from Applications**. Click its battery item in the menu bar for the quick panel and choose **Battery Info** for details.

If macOS rejects the download or the checksum does not match, stop and [report the problem](https://github.com/RaNDoM6913/Tilvero/issues/new/choose) with minimal redacted details. Do not remove quarantine, disable Gatekeeper or install a development helper to bypass a failed check. Opening an app inside a mounted image does not install it.

### Manual updates and local data

Read the new release's migration notes, quit the running version, and replace the app in Applications with the verified new bundle. Never run the prototype and production application together during migration. Keep history/preferences intact; an import failure should be reported rather than repaired by deleting the old store. The release notes must state which migrations were actually verified. No automatic update service is enabled.

The production build keeps its history in `~/Library/Application Support/Tilvero/Production/History.sqlite`; the development prototype uses `~/Library/Application Support/Tilvero/History.sqlite`. The separate production store protects the prototype's original data. Ordinary exports exclude identity tokens; preview diagnostics before sharing. Removing the app does not imply that its history was erased.

### Help and source

[Current capabilities](../README.md#what-works-today) · [Compatibility](COMPATIBILITY.md) · [Changelog](../CHANGELOG.md) · [Source and build instructions](../README.md#build-and-run) · [GPL-3.0-only](../LICENSE)

## Русский

**Что доступно сейчас:** публичный DMG ещё не опубликован. Для версии в разработке доступна [сборка из исходников](../README.ru.md#сборка-и-запуск). Локальные пакеты **TEST** подписаны ad-hoc и предназначены для внутренней проверки, а не для рекомендуемой публичной установки. Само наличие локального пакета, контрольной суммы или успешной сборки не подтверждает проверку Gatekeeper и нотарификацию.

Первый выпуск готовится в объёме **Monitoring Preview** для **Apple silicon (arm64), macOS 26.0+**. Мониторинг, локальная история и диагностика не требуют прав администратора. Пакет мониторинга не содержит привилегированного помощника и не регистрирует службу. Физическое управление зарядкой, режимом питания и вентиляторами отключено.

### Когда появится доверенный выпуск

Используйте конкретный выпуск и DMG по ссылке из README. Для preview/beta нужна ссылка на явный тег предварительного выпуска: общая ссылка «latest» может открыть другой стабильный релиз. Проверьте указанные версию, архитектуру arm64, минимальную macOS, коммит исходников и подтверждённый статус Developer ID/нотарификации. Рядом должны быть соответствующий архив исходников, `SHA256SUMS` и `release.json`.

1. Скачайте указанный DMG и файлы проверки из того же выпуска. В Терминале перейдите в папку с этими файлами и выполните `shasum -a 256 -c SHA256SUMS`; предварительно скачайте все файлы, перечисленные в списке сумм. Открывайте DMG только после успешной проверки.
2. Перетащите Tilvero в **«Программы» / Applications**, затем извлеките образ диска.
3. Откройте **Tilvero из «Программ»**. Нажмите на значок батареи в строке меню; пункт **«Информация о батарее» / Battery Info** открывает подробности.

Если macOS отклоняет загрузку или сумма не совпадает, остановитесь и [сообщите о проблеме](https://github.com/RaNDoM6913/Tilvero/issues/new/choose), скрыв личные данные. Не удаляйте карантин, не отключайте Gatekeeper и не устанавливайте помощник для разработки в обход проверки. Открытие приложения внутри подключённого образа не устанавливает его.

### Ручное обновление и данные

Прочитайте заметки о переносе данных, завершите работающую версию и замените приложение в «Программах» проверенным новым пакетом. Во время переноса не запускайте прототип и production-приложение одновременно. Сохраните историю и настройки; о сбое импорта следует сообщить, а не исправлять его удалением старой базы. Заметки выпуска должны указывать, какие варианты переноса действительно проверены. Автоматическое обновление не включено.

Production-сборка хранит историю в `~/Library/Application Support/Tilvero/Production/History.sqlite`, прототип для разработки — в `~/Library/Application Support/Tilvero/History.sqlite`. Отдельная база защищает исходные данные прототипа. Обычный экспорт исключает идентификационные токены; перед передачей диагностики просмотрите её. Удаление приложения само по себе не означает удаления истории.

### Помощь и исходники

[Текущие возможности](../README.ru.md#что-уже-работает) · [Совместимость](COMPATIBILITY.md) · [История изменений](../CHANGELOG.md) · [Исходники и сборка](../README.ru.md#сборка-и-запуск) · [GPL-3.0-only](../LICENSE)
