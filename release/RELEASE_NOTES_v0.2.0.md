# Live Wallpapers for Mac 0.2.0

## Что изменилось

- Добавлена автоматическая установка обновлений из меню приложения.
- Приложение скачивает DMG с GitHub, проверяет SHA-256, Bundle ID, executable, версию и подпись.
- Designated requirement новой версии должен полностью совпадать с установленной копией.
- Замена приложения выполняется безопасно с резервной копией и откатом при ошибке.
- После успешной установки приложение запускается автоматически.

## Важно

Переход с `0.1.1` на `0.2.0` выполняется вручную через DMG, потому что в `0.1.1` ещё нет встроенного установщика. Все следующие обновления после установки `0.2.0` смогут устанавливаться автоматически.

Для сохранения разрешений macOS приложение должно находиться по адресу `/Applications/Live Wallpapers for Mac.app`.

## Changes

- Added automatic update installation from the app menu.
- The app downloads the GitHub DMG and verifies its SHA-256, Bundle ID, executable, version and signature.
- The new version must have the same designated requirement as the installed app.
- Application replacement uses a backup and rolls back on failure.
- The app relaunches automatically after a successful update.

The upgrade from `0.1.1` to `0.2.0` is manual because `0.1.1` does not contain the installer yet. Future updates can install automatically after `0.2.0` is installed in `/Applications`.
