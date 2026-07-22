# Live Wallpapers for Mac

Живые видео-, GIF- и графические обои для macOS. Приложение работает из строки меню и не занимает место в Dock.

Live video, GIF and image wallpapers for macOS. The app runs from the menu bar and stays out of the Dock.

- Создатель / Creator: [@Bubblegumbbbbb](https://x.com/Bubblegumbbbbb)
- Скачать / Download: [GitHub Releases](https://github.com/medusa4111/LiveWallpapersForMac/releases)
- Системные требования / System requirement: macOS 13+

## Установка

1. Скачайте файл `Live Wallpapers for Mac-<версия>.dmg` со страницы [Releases](https://github.com/medusa4111/LiveWallpapersForMac/releases).
2. Откройте DMG и перетащите `Live Wallpapers for Mac.app` на ярлык `Applications`.
3. Запустите приложение из папки «Программы». Его значок появится в строке меню.
4. При первом запуске macOS может предупредить, что разработчик не подтверждён. Нажмите по приложению правой кнопкой мыши, выберите «Открыть», затем подтвердите запуск. Если кнопки нет, используйте «Системные настройки» → «Конфиденциальность и безопасность» → «Всё равно открыть».
5. Разрешите приложению запрошенный доступ в настройках macOS.

Для обновления откройте новый DMG и замените приложение в папке «Программы». Не переименовывайте приложение и не меняйте путь установки `/Applications/Live Wallpapers for Mac.app`: это важно для сохранения разрешений macOS.

Подробная инструкция: [INSTALL_RU.txt](INSTALL_RU.txt).

## Installation

1. Download `Live Wallpapers for Mac-<version>.dmg` from [Releases](https://github.com/medusa4111/LiveWallpapersForMac/releases).
2. Open the DMG and drag `Live Wallpapers for Mac.app` onto the `Applications` shortcut.
3. Launch the app from Applications. Its icon will appear in the menu bar.
4. On first launch, macOS may warn that the developer cannot be verified. Control-click the app, choose Open, then confirm. If that option is unavailable, use System Settings → Privacy & Security → Open Anyway.
5. Grant the requested macOS permissions.

To update, open the new DMG and replace the app in Applications. Do not rename the app or change its installation path, `/Applications/Live Wallpapers for Mac.app`; this is important for preserving macOS permissions.

Detailed instructions: [INSTALL_EN.txt](INSTALL_EN.txt).

## Release and Updates

Updates are distributed through [GitHub Releases](https://github.com/medusa4111/LiveWallpapersForMac/releases).

Build signed ZIP and DMG packages:

```bash
./script/package_release.sh 0.1.0 1
```

The output is written to `dist/release/`:

- `Live Wallpapers for Mac-<version>.dmg`
- `Live Wallpapers for Mac-<version>.dmg.sha256`
- `Live Wallpapers for Mac-<version>.zip`
- `Live Wallpapers for Mac-<version>.zip.sha256`

Verify or install a ZIP update:

```bash
./script/install_update.sh --verify-only "dist/release/Live Wallpapers for Mac-0.1.0.zip"
./script/install_update.sh "dist/release/Live Wallpapers for Mac-0.1.0.zip"
```

## TCC Stability Rules

macOS privacy permissions are preserved only when the updated app has the same designated requirement as the installed app.

Do not change between releases:

- `CFBundleIdentifier`: `com.medusa411.LiveWallpapersForMac`
- `CFBundleExecutable`: `Live Wallpapers for Mac`
- app path: `/Applications/Live Wallpapers for Mac.app`
- signing identity: `Live Wallpapers for Mac Release Signing`
- designated requirement baseline in `release/designated-requirement.txt`
- certificate SHA-1 baseline in `release/certificate-sha1.txt`

Allowed release changes:

- `CFBundleShortVersionString`
- `CFBundleVersion`
- source code and resources

The release packager refuses to fall back to ad-hoc signing.
