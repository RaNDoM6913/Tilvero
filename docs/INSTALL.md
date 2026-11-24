# Installing and updating Tilvero

[English](#english) · [Русский](#русский)

## English

### Install now: one command

Tilvero installs from source on **Apple silicon, macOS 26.0+** with Xcode installed:

```sh
git clone https://github.com/RaNDoM6913/Tilvero.git && cd Tilvero && bash scripts/install.sh
```

`scripts/install.sh` checks the requirements (`--check` stops there), builds a release
copy, verifies its signature and installs it into `/Applications` (`--applications-dir`
picks another folder). It refuses while Tilvero runs from that folder and will not replace
a signed copy without `--replace-signed`; the previous copy is kept in `build/install.noindex/`.
It needs no `sudo` and changes no charging, fan, power or sleep setting.
Developers can instead follow [Build from source](../README.md#build-from-source-developers).

**No trusted public DMG is available yet.** Developer ID signing, notarization and
downloaded-install acceptance remain prerequisites. Local **TEST** packages use
ad-hoc signing for internal checks and are not the recommended installation route.
See [release preparation](RELEASING.md) for the distribution status.

A default source build uses the development identity and includes separately
gated controls and an unregistered helper. The planned **Monitoring Preview**
DMG will contain no helper/service and will disable control actions and Keep Mac
Awake. Monitoring, history and diagnostics need no administrator approval.

### Verify a source release

The release supplies `Tilvero-0.8.0-source.zip`,
`source-release.json` and `SHA256SUMS`. Download all three from the same explicit
release, then run `shasum -a 256 -c SHA256SUMS` in their folder. Every entry must
match. The source manifest identifies the tag, exact commit and source ZIP hash;
it does not describe a signed app. Extract the ZIP, enter its project folder and
use the build commands below, starting with `bash scripts/test.sh`.

### Source-build essentials

```sh
git clone --branch v0.8.0 https://github.com/RaNDoM6913/Tilvero.git
cd Tilvero
bash scripts/test.sh
bash scripts/build-local-app.sh
bash scripts/run-local.sh
```

The builder refuses to overwrite a running bundle. Preserve an existing copy with
`bash scripts/build-local-app.sh --output build/dev-candidates.noindex/my-build/Tilvero.app`;
the destination must not exist. Keep one development copy running at a time and
quit normally before switching copies, so active sessions can end and recovery
can complete. Diagnostics identifies the running bundle path.

A brand-new install opens a first-run setup window once; an existing install never sees it.
The menu bar battery opens the quick panel. **History & reports…** opens the main
window; the gear opens Settings. In the app, **⌘⌥B** toggles the panel and **⌘,**
opens Settings. Reopening Tilvero restores a window when its menu item is hidden.

### When the trusted DMG is published

Use the exact release linked from the README, including its explicit beta tag.
Its notes must identify the version, arm64 architecture, minimum macOS, source
commit, verified signing/notarization status and matching verification files.

1. Download the DMG and all files named in that release’s `SHA256SUMS`. In their folder, run `shasum -a 256 -c SHA256SUMS` and require every listed file to match.
2. Open the verified DMG, drag Tilvero to **Applications**, then eject the image.
3. Open **Tilvero from Applications** and click its menu bar battery.

If the checksum fails or macOS rejects the app, stop and
[report the problem](https://github.com/RaNDoM6913/Tilvero/issues/new/choose).
Do not bypass quarantine/Gatekeeper or install a development helper to work
around rejection. A checksum confirms integrity, not signing trust or notarization.

### Updates and local data

Updates are manual. Tilvero checks GitHub once a day for a newer release (a few public requests, no readings sent; switch it off in
Settings > Updates) and shows a "New version" notice, but never downloads or installs anything. Read migration notes, quit the running version normally,
then replace it with the verified new app. Preserve history and preferences;
report an import failure instead of deleting the old store. Do not run prototype
and production copies together during migration.

| Build identity | History location |
| --- | --- |
| Development prototype | `~/Library/Application Support/Tilvero/History.sqlite` |
| Production / Monitoring Preview | `~/Library/Application Support/Tilvero/Production/History.sqlite` |

Production uses a separate store to protect prototype data. Release notes must
state which migration paths were verified. Removing the app does not erase its
history.

Before Tilvero upgrades the history to a newer format it keeps a copy of the old
one next to it (`History.pre-v3.sqlite`, private, removed after 30 days). An
older Tilvero cannot read the upgraded store. To roll back: quit Tilvero, run
`bash scripts/restore-history-backup.sh "<History.sqlite path>"` (it refuses
while Tilvero runs and moves the upgraded files aside as `History.v3-<time>.*`,
deleting nothing), then open the older version. Readings recorded after the
upgrade stay only in the moved-aside store. Use Settings to erase history intentionally; preview exports/diagnostics
before sharing them. No automatic updater is enabled.

[Compatibility](COMPATIBILITY.md) · [Changelog](../CHANGELOG.md) · [License](../LICENSE)

## Русский

### Установка сейчас: одна команда

Tilvero устанавливается из исходников на **Apple silicon, macOS 26.0+** с установленным Xcode:

```sh
git clone https://github.com/RaNDoM6913/Tilvero.git && cd Tilvero && bash scripts/install.sh
```

`scripts/install.sh` проверяет требования (`--check` на этом останавливается), собирает
релизную копию, проверяет подпись и устанавливает её в `/Applications` (`--applications-dir`
задаёт другую папку). Скрипт откажется работать, пока Tilvero запущен из этой папки, и не заменит
подписанную копию без `--replace-signed`; предыдущая копия сохраняется в `build/install.noindex/`.
Ему не нужен `sudo`, и он не меняет настройки зарядки, вентиляторов, питания и сна.
Разработчики могут пойти путём [«Сборка из исходников»](../README.ru.md#сборка-из-исходников-для-разработчиков).

**Доверенный публичный DMG пока недоступен.** Нужны подпись Developer ID,
нотарификация и проверка скачанной установки. Локальные пакеты **TEST** с
ad-hoc подписью предназначены для внутренних проверок.
Состояние подготовки описано в [документе о выпуске](RELEASING.md).

Обычная сборка исходников использует идентификатор для разработки, содержит
отдельно ограниченное управление и незарегистрированный помощник. Планируемый
DMG **Monitoring Preview** не будет содержать помощника/службы; управление
и предотвращение сна будут отключены. Мониторинг, история и диагностика
не требуют прав администратора.

### Проверка выпуска исходников

Выпуск содержит `Tilvero-0.8.0-source.zip`,
`source-release.json` и `SHA256SUMS`. Скачайте все три файла из одного конкретного
выпуска и выполните в их папке `shasum -a 256 -c SHA256SUMS`; все записи должны
совпасть. Манифест исходников указывает тег, точный коммит и сумму ZIP, но не
описывает подписанное приложение. Распакуйте ZIP, перейдите в каталог проекта
и выполняйте команды ниже, начиная с `bash scripts/test.sh`.

### Сборка из исходников

```sh
git clone --branch v0.8.0 https://github.com/RaNDoM6913/Tilvero.git
cd Tilvero
bash scripts/test.sh
bash scripts/build-local-app.sh
bash scripts/run-local.sh
```

Сборщик не перезаписывает работающий пакет. Чтобы сохранить существующую копию,
выполните `bash scripts/build-local-app.sh --output build/dev-candidates.noindex/my-build/Tilvero.app`;
указанный путь не должен существовать. Запускайте одну копию для разработки.
Перед переключением завершайте приложение штатно, чтобы закончились активные
сеансы и восстановление. Путь работающей копии виден в диагностике.

На совсем новой установке один раз появляется окно первого запуска; уже установленная копия его не показывает.
Значок батареи открывает быструю панель. **«История и отчёты…»** открывает
главное окно, шестерёнка — настройки. В приложении **⌘⌥B** переключает панель,
**⌘,** открывает настройки. Повторное открытие Tilvero восстанавливает окно,
если значок скрыт.

### Когда появится доверенный DMG

Используйте конкретный выпуск по ссылке из README, включая явный beta-тег.
В заметках должны быть версия, архитектура arm64, минимальная macOS, коммит
исходников, подтверждённые подпись/нотарификация и соответствующие файлы проверки.

1. Скачайте DMG и все файлы, перечисленные в `SHA256SUMS` этого выпуска. В их папке выполните `shasum -a 256 -c SHA256SUMS`; все суммы должны совпасть.
2. Откройте проверенный DMG, перетащите Tilvero в **«Программы» / Applications**, затем извлеките образ.
3. Откройте **Tilvero из «Программ»** и нажмите на значок батареи в строке меню.

При несовпадении суммы или отказе macOS остановитесь и
[сообщите о проблеме](https://github.com/RaNDoM6913/Tilvero/issues/new/choose).
Не обходите карантин/Gatekeeper и не устанавливайте помощник для разработки
ради обхода отказа. Контрольная сумма подтверждает целостность, но не доверие
к подписи или нотарификацию.

### Обновление и данные

Обновление ручное. Tilvero раз в сутки проверяет GitHub на новый выпуск (несколько публичных запросов, показания не отправляются;
отключается в Настройки > Обновления) и показывает пометку «Новая версия», но ничего не скачивает и не устанавливает.
Прочитайте заметки о переносе, штатно завершите приложение
и замените его проверенной новой версией. Сохраните историю и настройки;
о сбое импорта сообщите, не удаляя старую базу. Не запускайте прототип
и production-копию одновременно во время переноса.

| Тип сборки | Путь истории |
| --- | --- |
| Прототип для разработки | `~/Library/Application Support/Tilvero/History.sqlite` |
| Production / Monitoring Preview | `~/Library/Application Support/Tilvero/Production/History.sqlite` |

Отдельная production-база защищает данные прототипа. Заметки выпуска должны
указывать проверенные варианты переноса. Удаление приложения не удаляет историю.

Перед переводом истории в новый формат Tilvero сохраняет рядом копию старой
базы (`History.pre-v3.sqlite`, только для владельца, удаляется через 30 дней).
Более старая версия Tilvero обновлённую базу не прочитает. Чтобы откатиться:
завершите Tilvero, выполните
`bash scripts/restore-history-backup.sh "<путь к History.sqlite>"` (скрипт
откажется работать, пока Tilvero запущен, и отложит обновлённые файлы как
`History.v3-<время>.*`, ничего не удаляя), затем откройте старую версию.
Измерения после обновления останутся только в отложенной базе.
Для намеренного удаления используйте настройки; просмотрите экспорт и диагностику
перед передачей. Автоматическое обновление не включено.

[Совместимость](COMPATIBILITY.md) · [История изменений](../CHANGELOG.md) · [Лицензия](../LICENSE)
