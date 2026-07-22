import AVFoundation
import Carbon
import Cocoa
import CoreAudio
import CoreGraphics
import CoreImage
import Darwin
import ImageIO
import IOKit.ps
import UniformTypeIdentifiers

enum AppBrand {
    static let displayName = "Live Wallpapers for Mac"
    static let executableName = displayName
    static let bundleIdentifier = "com.medusa411.LiveWallpapersForMac"
    static let errorDomain = "LiveWallpapersForMac"
    static let launchAgentLabel = "\(bundleIdentifier).login"
    static let supportDirectoryName = displayName
    static let legacySupportDirectoryName = "Walpaper" + "E"
    static let logFileName = "live-wallpapers-for-mac.log"
}

enum AppIconProvider {
    static func image(size: NSSize? = nil) -> NSImage? {
        let image: NSImage?
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            image = NSImage(contentsOf: url)
        } else {
            image = NSImage(named: NSImage.applicationIconName)
        }

        guard let image else {
            return nil
        }

        if let size {
            image.size = size
        }
        image.isTemplate = false
        return image
    }

    static func menuIcon(size: CGFloat = 18) -> NSImage? {
        image(size: NSSize(width: size, height: size))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let wallpaperController = WallpaperController()
    private let hotkeyController = GlobalHotkeyController()
    private var signalSources: [DispatchSourceSignal] = []
    private var toggleWallpaperMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var previousMenuItem: NSMenuItem?
    private var nextMenuItem: NSMenuItem?
    private var displayModeItems: [WallpaperDisplayMode: NSMenuItem] = [:]
    private var speedItems: [Double: NSMenuItem] = [:]
    private var brightnessItems: [Double: NSMenuItem] = [:]
    private var dimmingItems: [Double: NSMenuItem] = [:]
    private var volumeItems: [Double: NSMenuItem] = [:]
    private var fpsItems: [WallpaperFPSLimit: NSMenuItem] = [:]
    private var rotationIntervalItems: [WallpaperRotationInterval: NSMenuItem] = [:]
    private var shuffleMenuItem: NSMenuItem?
    private var randomStartMenuItem: NSMenuItem?
    private var economyModeMenuItem: NSMenuItem?
    private var pauseOnBatteryMenuItem: NSMenuItem?
    private var pauseOnLowBatteryMenuItem: NSMenuItem?
    private var pauseInFullscreenMenuItem: NSMenuItem?
    private var pauseWhenDesktopCoveredMenuItem: NSMenuItem?
    private var pauseOnScreenLockMenuItem: NSMenuItem?
    private var pauseOnHighLoadMenuItem: NSMenuItem?
    private var pauseDuringGamesOrCallsMenuItem: NSMenuItem?
    private var autoLowerQualityMenuItem: NSMenuItem?
    private var warnHeavyFilesMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var restoreLastWallpaperMenuItem: NSMenuItem?
    private var favoriteToggleMenuItem: NSMenuItem?
    private var currentWeightMenuItem: NSMenuItem?
    private var favoritesMenu = NSMenu()
    private var recentMenu = NSMenu()
    private var collectionsMenu = NSMenu()
    private var settingsWindowController: SettingsWindowController?

    private var currentLanguage: AppLanguage {
        wallpaperController.behaviorSettings.appLanguage
    }

    private func t(_ key: String) -> String {
        AppLocalization.text(key, language: currentLanguage)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppIconProvider.image(size: NSSize(width: 128, height: 128)) {
            NSApp.applicationIconImage = icon
        }

        installTerminationHandlers()
        configureStatusItem()
        configureHotkeys()

        if let startupImageURL = StartupArguments.imageURL {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.wallpaperController.setImageWallpaper(startupImageURL) else {
                    return
                }

                self.statusItem?.button?.toolTip = "Live Wallpapers for Mac: \(startupImageURL.lastPathComponent)"
                self.refreshMenuState()
            }
        } else if let startupVideoURL = StartupArguments.videoURL {
            DispatchQueue.main.async { [weak self] in
                let startupTrim = StartupArguments.trim
                if startupTrim.startSeconds > 0 || startupTrim.endSeconds > 0 {
                    self?.wallpaperController.setTrim(
                        startSeconds: startupTrim.startSeconds,
                        endSeconds: startupTrim.endSeconds
                    )
                }
                self?.wallpaperController.setSingleVideo(startupVideoURL)
                self?.statusItem?.button?.toolTip = "Live Wallpapers for Mac: \(startupVideoURL.lastPathComponent)"
                self?.refreshMenuState()
            }
        } else if StartupArguments.openSettings {
            // Opening Settings should not request access to the last wallpaper file.
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else {
                    return
                }

                self.wallpaperController.cleanUpUnusedPosterFiles()
                if self.wallpaperController.restoreLastWallpaperIfNeeded() {
                    self.statusItem?.button?.toolTip = self.wallpaperController.statusText
                    self.refreshMenuState()
                }
            }
        }

        if StartupArguments.openSettings {
            DispatchQueue.main.async { [weak self] in
                self?.openSettings(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyController.stop()
        wallpaperController.stop()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.toolTip = "Live Wallpapers for Mac"

            if let image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "Live Wallpapers for Mac") {
                let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                let configuredImage = image.withSymbolConfiguration(configuration) ?? image
                configuredImage.isTemplate = true
                button.image = configuredImage
            } else if let fallbackImage = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "Live Wallpapers for Mac") {
                fallbackImage.isTemplate = true
                button.image = fallbackImage
            } else {
                button.title = "LW"
            }
        }

        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else {
            return
        }

        displayModeItems.removeAll()
        speedItems.removeAll()
        brightnessItems.removeAll()
        dimmingItems.removeAll()
        volumeItems.removeAll()
        fpsItems.removeAll()
        rotationIntervalItems.removeAll()
        favoritesMenu = NSMenu()
        recentMenu = NSMenu()
        collectionsMenu = NSMenu()

        let menu = NSMenu()

        let chooseItem = NSMenuItem(title: t("menu.chooseVideo"), action: #selector(chooseVideo(_:)), keyEquivalent: "o")
        chooseItem.target = self
        menu.addItem(chooseItem)

        let chooseFolderItem = NSMenuItem(title: t("menu.chooseVideoFolder"), action: #selector(chooseVideoFolder(_:)), keyEquivalent: "")
        chooseFolderItem.target = self
        menu.addItem(chooseFolderItem)

        let chooseImageItem = NSMenuItem(title: t("button.imageGif"), action: #selector(chooseImageWallpaper(_:)), keyEquivalent: "")
        chooseImageItem.target = self
        menu.addItem(chooseImageItem)

        menu.addItem(.separator())

        let toggleWallpaperItem = NSMenuItem(title: t("menu.turnOffWallpaper"), action: #selector(toggleWallpaper(_:)), keyEquivalent: "w")
        toggleWallpaperItem.keyEquivalentModifierMask = [.command, .option]
        toggleWallpaperItem.target = self
        menu.addItem(toggleWallpaperItem)
        toggleWallpaperMenuItem = toggleWallpaperItem

        let pauseItem = NSMenuItem(title: t("menu.pause"), action: #selector(togglePause(_:)), keyEquivalent: " ")
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        pauseItem.target = self
        menu.addItem(pauseItem)
        pauseMenuItem = pauseItem

        let previousItem = NSMenuItem(title: t("menu.previousWallpaper"), action: #selector(previousWallpaper(_:)), keyEquivalent: "[")
        previousItem.target = self
        menu.addItem(previousItem)
        previousMenuItem = previousItem

        let nextItem = NSMenuItem(title: t("menu.nextWallpaper"), action: #selector(nextWallpaper(_:)), keyEquivalent: "]")
        nextItem.target = self
        menu.addItem(nextItem)
        nextMenuItem = nextItem

        let trimItem = NSMenuItem(title: t("menu.trimVideo"), action: #selector(configureTrim(_:)), keyEquivalent: "")
        trimItem.target = self
        menu.addItem(trimItem)

        menu.addItem(.separator())
        menu.addItem(displayModeMenuItem())
        menu.addItem(playbackSpeedMenuItem())
        menu.addItem(playbackOptionsMenuItem())
        menu.addItem(libraryMenuItem())
        menu.addItem(volumeMenuItem())
        menu.addItem(brightnessMenuItem())
        menu.addItem(dimmingMenuItem())
        menu.addItem(performanceMenuItem())
        menu.addItem(profileMenuItem())
        menu.addItem(hotkeysMenuItem())
        menu.addItem(advancedMenuItem())

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: t("menu.checkUpdates"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let settingsItem = NSMenuItem(title: t("menu.openSettings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: t("menu.quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        refreshMenuState()
    }

    @objc private func chooseVideo(_ sender: Any?) {
        guard let url = VideoPicker.chooseVideo() else {
            return
        }

        guard validateVideoSelection([url]) else {
            return
        }

        offerManualAutomationOverrideIfNeeded()
        wallpaperController.setSingleVideo(url)
        statusItem?.button?.toolTip = "Live Wallpapers for Mac: \(url.lastPathComponent)"
        refreshMenuState()
    }

    @objc private func chooseVideoFolder(_ sender: Any?) {
        guard let folderURL = VideoPicker.chooseVideoFolder() else {
            return
        }

        let urls = VideoPicker.videoURLs(in: folderURL)
        guard !urls.isEmpty else {
            showMessage(title: "Видео не найдены", message: "В выбранной папке нет .mp4, .mov, .m4v или .webm файлов.")
            return
        }

        guard validateVideoSelection(urls) else {
            return
        }

        offerManualAutomationOverrideIfNeeded()
        wallpaperController.setPlaylist(urls, sourceFolder: folderURL)
        statusItem?.button?.toolTip = "Live Wallpapers for Mac: \(folderURL.lastPathComponent) (\(urls.count))"
        refreshMenuState()
    }

    @objc private func chooseImageWallpaper(_ sender: Any?) {
        guard let url = ImagePicker.chooseImage() else {
            return
        }

        guard ImageFileInspector.isReadableImage(url) else {
            showMessage(
                title: "Изображение не читается",
                message: "Файл не удалось открыть как изображение или GIF."
            )
            return
        }

        offerManualAutomationOverrideIfNeeded()
        wallpaperController.setImageWallpaper(url)
        statusItem?.button?.toolTip = "Live Wallpapers for Mac: \(url.lastPathComponent)"
        refreshMenuState()
    }

    @objc private func togglePause(_ sender: Any?) {
        wallpaperController.setUserPaused(!wallpaperController.isUserPaused)
        refreshMenuState()
    }

    @objc private func toggleWallpaper(_ sender: Any?) {
        wallpaperController.setWallpaperEnabled(!wallpaperController.isWallpaperEnabled)
        statusItem?.button?.toolTip = wallpaperController.statusText
        refreshMenuState()
    }

    @objc private func previousWallpaper(_ sender: Any?) {
        offerManualAutomationOverrideIfNeeded()
        wallpaperController.selectPrevious()
        statusItem?.button?.toolTip = wallpaperController.statusText
        refreshMenuState()
    }

    @objc private func nextWallpaper(_ sender: Any?) {
        offerManualAutomationOverrideIfNeeded()
        wallpaperController.selectNext()
        statusItem?.button?.toolTip = wallpaperController.statusText
        refreshMenuState()
    }

    @objc private func configureTrim(_ sender: Any?) {
        let currentTrim = wallpaperController.trim
        guard let trim = TrimPanel.run(
            initialStartSeconds: currentTrim.startSeconds,
            initialEndSeconds: currentTrim.endSeconds
        ) else {
            return
        }

        wallpaperController.setTrim(startSeconds: trim.startSeconds, endSeconds: trim.endSeconds)
        refreshMenuState()
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let mode = WallpaperDisplayMode(rawValue: sender.tag) else {
            return
        }

        wallpaperController.setDisplayMode(mode)
        refreshMenuState()
    }

    @objc private func setPlaybackSpeed(_ sender: NSMenuItem) {
        wallpaperController.setPlaybackRate(Double(sender.tag) / 100)
        refreshMenuState()
    }

    @objc private func toggleShuffle(_ sender: Any?) {
        wallpaperController.setShuffle(!wallpaperController.settings.isShuffleEnabled)
        refreshMenuState()
    }

    @objc private func toggleRandomStart(_ sender: Any?) {
        wallpaperController.setRandomStart(!wallpaperController.settings.startsAtRandomPosition)
        refreshMenuState()
    }

    @objc private func setRotationInterval(_ sender: NSMenuItem) {
        guard let interval = WallpaperRotationInterval(rawValue: sender.tag) else {
            return
        }

        wallpaperController.setRotationInterval(interval)
        refreshMenuState()
    }

    @objc private func setVolume(_ sender: NSMenuItem) {
        wallpaperController.setVolume(Double(sender.tag) / 100)
        refreshMenuState()
    }

    @objc private func setBrightness(_ sender: NSMenuItem) {
        wallpaperController.setBrightness(Double(sender.tag) / 100)
        refreshMenuState()
    }

    @objc private func setDimming(_ sender: NSMenuItem) {
        wallpaperController.setDimming(Double(sender.tag) / 100)
        refreshMenuState()
    }

    @objc private func setFPSLimit(_ sender: NSMenuItem) {
        guard let fpsLimit = WallpaperFPSLimit(rawValue: sender.tag) else {
            return
        }

        wallpaperController.setFPSLimit(fpsLimit)
        refreshMenuState()
    }

    @objc private func toggleEconomyMode(_ sender: Any?) {
        wallpaperController.setEconomyMode(!wallpaperController.settings.isEconomyModeEnabled)
        refreshMenuState()
    }

    @objc private func togglePauseOnBattery(_ sender: Any?) {
        wallpaperController.setPauseOnBattery(!wallpaperController.behaviorSettings.pauseOnBattery)
        refreshMenuState()
    }

    @objc private func togglePauseOnLowBattery(_ sender: Any?) {
        wallpaperController.setPauseOnLowBattery(!wallpaperController.behaviorSettings.pauseOnLowBattery)
        refreshMenuState()
    }

    @objc private func togglePauseInFullscreen(_ sender: Any?) {
        wallpaperController.setPauseInFullscreen(!wallpaperController.behaviorSettings.pauseInFullscreen)
        refreshMenuState()
    }

    @objc private func togglePauseWhenDesktopCovered(_ sender: Any?) {
        wallpaperController.setPauseWhenDesktopCovered(!wallpaperController.behaviorSettings.pauseWhenDesktopCovered)
        refreshMenuState()
    }

    @objc private func togglePauseOnScreenLock(_ sender: Any?) {
        wallpaperController.setPauseOnScreenLock(!wallpaperController.behaviorSettings.pauseOnScreenLock)
        refreshMenuState()
    }

    @objc private func togglePauseOnHighLoad(_ sender: Any?) {
        wallpaperController.setPauseOnHighSystemLoad(!wallpaperController.behaviorSettings.pauseOnHighSystemLoad)
        refreshMenuState()
    }

    @objc private func togglePauseDuringGamesOrCalls(_ sender: Any?) {
        wallpaperController.setPauseDuringGamesOrCalls(!wallpaperController.behaviorSettings.pauseDuringGamesOrCalls)
        refreshMenuState()
    }

    @objc private func toggleAutoLowerQuality(_ sender: Any?) {
        wallpaperController.setAutoLowerQualityOnLoad(!wallpaperController.behaviorSettings.autoLowerQualityOnLoad)
        refreshMenuState()
    }

    @objc private func toggleWarnHeavyFiles(_ sender: Any?) {
        wallpaperController.setWarnAboutHeavyFiles(!wallpaperController.behaviorSettings.warnAboutHeavyFiles)
        refreshMenuState()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            try wallpaperController.setLaunchAtLogin(!wallpaperController.behaviorSettings.launchAtLogin)
        } catch {
            showMessage(
                title: "Автозапуск не изменён",
                message: error.localizedDescription
            )
        }
        refreshMenuState()
    }

    @objc private func toggleRestoreLastWallpaper(_ sender: Any?) {
        wallpaperController.setRestoreLastWallpaperOnLaunch(
            !wallpaperController.behaviorSettings.restoreLastWallpaperOnLaunch
        )
        refreshMenuState()
    }

    @objc private func toggleCurrentFavorite(_ sender: Any?) {
        wallpaperController.toggleCurrentFavorite()
        refreshMenuState()
    }

    @objc private func openFavorite(_ sender: NSMenuItem) {
        offerManualAutomationOverrideIfNeeded()
        wallpaperController.applyFavorite(at: sender.tag)
        statusItem?.button?.toolTip = wallpaperController.statusText
        refreshMenuState()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        offerManualAutomationOverrideIfNeeded()
        wallpaperController.applyRecent(at: sender.tag)
        statusItem?.button?.toolTip = wallpaperController.statusText
        refreshMenuState()
    }

    @objc private func openCollection(_ sender: NSMenuItem) {
        offerManualAutomationOverrideIfNeeded()
        wallpaperController.applyCollection(at: sender.tag)
        statusItem?.button?.toolTip = wallpaperController.statusText
        refreshMenuState()
    }

    @objc private func saveCollection(_ sender: Any?) {
        guard let name = TextPrompt.run(title: "Новая коллекция", message: "Название коллекции:", placeholder: "Night Mode") else {
            return
        }

        wallpaperController.saveCurrentAsCollection(named: name)
        refreshMenuState()
    }

    @objc private func setCurrentWallpaperWeight(_ sender: Any?) {
        guard let weight = TextPrompt.runInteger(
            title: "Вес в коллекции",
            message: "Чем больше вес, тем чаще этот фон будет попадаться при случайной смене:",
            placeholder: "\(wallpaperController.currentWallpaperWeight ?? 1)"
        ) else {
            return
        }

        wallpaperController.setCurrentWallpaperWeight(weight)
        refreshMenuState()
    }

    @objc private func importPreset(_ sender: Any?) {
        guard let url = PresetFilePanel.chooseImportURL() else {
            return
        }

        do {
            try wallpaperController.importPreset(from: url)
            statusItem?.button?.toolTip = wallpaperController.statusText
            refreshMenuState()
        } catch {
            showMessage(title: "Импорт не выполнен", message: error.localizedDescription)
        }
    }

    @objc private func exportPreset(_ sender: Any?) {
        guard let url = PresetFilePanel.chooseExportURL() else {
            return
        }

        do {
            try wallpaperController.exportPreset(to: url)
            showMessage(title: "Пресет сохранён", message: url.path)
        } catch {
            showMessage(title: "Экспорт не выполнен", message: error.localizedDescription)
        }
    }

    @objc private func applyProfile(_ sender: NSMenuItem) {
        guard let profile = WallpaperProfile(rawValue: sender.tag) else {
            return
        }

        wallpaperController.applyProfile(profile)
        refreshMenuState()
    }

    @objc private func restoreSystemWallpaper(_ sender: Any?) {
        wallpaperController.restoreSystemWallpaperNow()
        statusItem?.button?.toolTip = wallpaperController.statusText
        refreshMenuState()
    }

    @objc private func clearCache(_ sender: Any?) {
        wallpaperController.clearCache()
        showMessage(title: "Кэш очищен", message: "Неиспользуемые постеры и временные файлы Live Wallpapers for Mac удалены.")
    }

    @objc private func showCurrentSourceInfo(_ sender: Any?) {
        showMessage(
            title: "Текущий источник",
            message: wallpaperController.currentSourceInformation()
        )
    }

    @objc private func openLogFile(_ sender: Any?) {
        AppLogger.log("Log opened from menu.")
        NSWorkspace.shared.open(AppLogger.fileURL())
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        AppUpdateUI.checkForUpdates()
    }

    @objc private func resetSettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Сбросить настройки Live Wallpapers for Mac?"
        alert.informativeText = "Настройки, последний источник и LaunchAgent автозапуска будут сброшены. Текущий системный фон будет восстановлен."
        alert.addButton(withTitle: "Сбросить")
        alert.addButton(withTitle: "Отмена")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        wallpaperController.resetAllSettings()
        statusItem?.button?.toolTip = wallpaperController.statusText
        refreshMenuState()
    }

    @objc private func openSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                wallpaperController: wallpaperController,
                onChange: { [weak self] in
                    self?.statusItem?.button?.toolTip = self?.wallpaperController.statusText
                    self?.rebuildStatusMenu()
                }
            )
        }

        settingsWindowController?.show()
    }

    private func offerManualAutomationOverrideIfNeeded() {
        guard wallpaperController.shouldOfferManualAutomationOverride(),
              let option = ManualAutomationOverridePrompt.run() else {
            return
        }

        wallpaperController.applyManualAutomationOverride(option)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func displayModeTitle(_ mode: WallpaperDisplayMode) -> String {
        switch mode {
        case .fill:
            return t("displayMode.fill")
        case .fit:
            return t("displayMode.fit")
        case .stretch:
            return t("displayMode.stretch")
        case .center:
            return t("displayMode.center")
        case .crop:
            return t("displayMode.crop")
        case .manual:
            return t("displayMode.manual")
        }
    }

    private func fpsLimitTitle(_ fpsLimit: WallpaperFPSLimit) -> String {
        switch fpsLimit {
        case .source:
            return t("fps.source")
        case .fps15:
            return "15 FPS"
        case .fps24:
            return "24 FPS"
        case .fps30:
            return "30 FPS"
        case .fps60:
            return "60 FPS"
        }
    }

    private func rotationIntervalTitle(_ interval: WallpaperRotationInterval) -> String {
        switch interval {
        case .manual:
            return t("rotation.manual")
        case .fiveMinutes:
            return t("rotation.fiveMinutes")
        case .thirtyMinutes:
            return t("rotation.thirtyMinutes")
        case .oneHour:
            return t("rotation.oneHour")
        }
    }

    private func displayModeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("row.scale"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for mode in WallpaperDisplayMode.allCases {
            let modeItem = NSMenuItem(title: displayModeTitle(mode), action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.tag = mode.rawValue
            menu.addItem(modeItem)
            displayModeItems[mode] = modeItem
        }

        item.submenu = menu
        return item
    }

    private func playbackSpeedMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("row.speed"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for speed in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            let speedItem = NSMenuItem(title: "\(speed)x", action: #selector(setPlaybackSpeed(_:)), keyEquivalent: "")
            speedItem.target = self
            speedItem.tag = Int(speed * 100)
            menu.addItem(speedItem)
            speedItems[speed] = speedItem
        }

        item.submenu = menu
        return item
    }

    private func playbackOptionsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("section.playlists"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        let shuffleItem = NSMenuItem(title: t("shuffle"), action: #selector(toggleShuffle(_:)), keyEquivalent: "")
        shuffleItem.target = self
        menu.addItem(shuffleItem)
        shuffleMenuItem = shuffleItem

        let randomStartItem = NSMenuItem(title: t("random.start"), action: #selector(toggleRandomStart(_:)), keyEquivalent: "")
        randomStartItem.target = self
        menu.addItem(randomStartItem)
        randomStartMenuItem = randomStartItem

        menu.addItem(rotationIntervalMenuItem())

        item.submenu = menu
        return item
    }

    private func libraryMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("group.collections"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        let favoriteItem = NSMenuItem(title: t("menu.addFavorite"), action: #selector(toggleCurrentFavorite(_:)), keyEquivalent: "")
        favoriteItem.target = self
        menu.addItem(favoriteItem)
        favoriteToggleMenuItem = favoriteItem

        let saveCollectionItem = NSMenuItem(title: t("button.saveCollection"), action: #selector(saveCollection(_:)), keyEquivalent: "")
        saveCollectionItem.target = self
        menu.addItem(saveCollectionItem)

        let weightItem = NSMenuItem(title: t("menu.currentWeight"), action: #selector(setCurrentWallpaperWeight(_:)), keyEquivalent: "")
        weightItem.target = self
        weightItem.image = AppIconProvider.menuIcon()
        menu.addItem(weightItem)
        currentWeightMenuItem = weightItem

        menu.addItem(.separator())

        let favoritesItem = NSMenuItem(title: t("menu.favorites"), action: nil, keyEquivalent: "")
        favoritesItem.submenu = favoritesMenu
        menu.addItem(favoritesItem)

        let recentItem = NSMenuItem(title: t("menu.recent"), action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        let collectionsItem = NSMenuItem(title: t("menu.chooseCollection"), action: nil, keyEquivalent: "")
        collectionsItem.submenu = collectionsMenu
        menu.addItem(collectionsItem)

        menu.addItem(.separator())

        let importItem = NSMenuItem(title: t("button.import"), action: #selector(importPreset(_:)), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let exportItem = NSMenuItem(title: t("button.export"), action: #selector(exportPreset(_:)), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        item.submenu = menu
        return item
    }

    private func rotationIntervalMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("row.rotationTimer"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for interval in WallpaperRotationInterval.allCases {
            let intervalItem = NSMenuItem(title: rotationIntervalTitle(interval), action: #selector(setRotationInterval(_:)), keyEquivalent: "")
            intervalItem.target = self
            intervalItem.tag = interval.rawValue
            menu.addItem(intervalItem)
            rotationIntervalItems[interval] = intervalItem
        }

        item.submenu = menu
        return item
    }

    private func volumeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("row.sound"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for volume in [0.0, 0.25, 0.5, 1.0] {
            let title = volume == 0 ? t("volume.off") : "\(Int(volume * 100))%"
            let volumeItem = NSMenuItem(title: title, action: #selector(setVolume(_:)), keyEquivalent: "")
            volumeItem.target = self
            volumeItem.tag = Int(volume * 100)
            menu.addItem(volumeItem)
            volumeItems[volume] = volumeItem
        }

        item.submenu = menu
        return item
    }

    private func brightnessMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("row.brightness"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for brightness in [1.0, 0.85, 0.7, 0.55, 0.4] {
            let title = "\(Int(brightness * 100))%"
            let brightnessItem = NSMenuItem(title: title, action: #selector(setBrightness(_:)), keyEquivalent: "")
            brightnessItem.target = self
            brightnessItem.tag = Int(brightness * 100)
            menu.addItem(brightnessItem)
            brightnessItems[brightness] = brightnessItem
        }

        item.submenu = menu
        return item
    }

    private func dimmingMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("row.dimming"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for dimming in [0.0, 0.15, 0.3, 0.45, 0.6] {
            let title = "\(Int(dimming * 100))%"
            let dimmingItem = NSMenuItem(title: title, action: #selector(setDimming(_:)), keyEquivalent: "")
            dimmingItem.target = self
            dimmingItem.tag = Int(dimming * 100)
            menu.addItem(dimmingItem)
            dimmingItems[dimming] = dimmingItem
        }

        item.submenu = menu
        return item
    }

    private func performanceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("section.performance"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        let economyItem = NSMenuItem(title: t("economy.mode"), action: #selector(toggleEconomyMode(_:)), keyEquivalent: "")
        economyItem.target = self
        menu.addItem(economyItem)
        economyModeMenuItem = economyItem

        menu.addItem(fpsLimitMenuItem())
        menu.addItem(.separator())

        let batteryItem = NSMenuItem(title: t("pause.battery"), action: #selector(togglePauseOnBattery(_:)), keyEquivalent: "")
        batteryItem.target = self
        menu.addItem(batteryItem)
        pauseOnBatteryMenuItem = batteryItem

        let lowBatteryItem = NSMenuItem(title: t("pause.lowBattery"), action: #selector(togglePauseOnLowBattery(_:)), keyEquivalent: "")
        lowBatteryItem.target = self
        menu.addItem(lowBatteryItem)
        pauseOnLowBatteryMenuItem = lowBatteryItem

        let fullscreenItem = NSMenuItem(title: t("pause.fullscreen"), action: #selector(togglePauseInFullscreen(_:)), keyEquivalent: "")
        fullscreenItem.target = self
        menu.addItem(fullscreenItem)
        pauseInFullscreenMenuItem = fullscreenItem

        let desktopCoveredItem = NSMenuItem(title: t("pause.covered"), action: #selector(togglePauseWhenDesktopCovered(_:)), keyEquivalent: "")
        desktopCoveredItem.target = self
        menu.addItem(desktopCoveredItem)
        pauseWhenDesktopCoveredMenuItem = desktopCoveredItem

        let screenLockItem = NSMenuItem(title: t("pause.screenLock"), action: #selector(togglePauseOnScreenLock(_:)), keyEquivalent: "")
        screenLockItem.target = self
        menu.addItem(screenLockItem)
        pauseOnScreenLockMenuItem = screenLockItem

        let highLoadItem = NSMenuItem(title: t("pause.highLoad"), action: #selector(togglePauseOnHighLoad(_:)), keyEquivalent: "")
        highLoadItem.target = self
        menu.addItem(highLoadItem)
        pauseOnHighLoadMenuItem = highLoadItem

        let gamesCallsItem = NSMenuItem(title: t("pause.gamesCalls"), action: #selector(togglePauseDuringGamesOrCalls(_:)), keyEquivalent: "")
        gamesCallsItem.target = self
        menu.addItem(gamesCallsItem)
        pauseDuringGamesOrCallsMenuItem = gamesCallsItem

        let autoQualityItem = NSMenuItem(title: t("auto.quality"), action: #selector(toggleAutoLowerQuality(_:)), keyEquivalent: "")
        autoQualityItem.target = self
        menu.addItem(autoQualityItem)
        autoLowerQualityMenuItem = autoQualityItem

        let warnHeavyItem = NSMenuItem(title: t("warn.heavy"), action: #selector(toggleWarnHeavyFiles(_:)), keyEquivalent: "")
        warnHeavyItem.target = self
        menu.addItem(warnHeavyItem)
        warnHeavyFilesMenuItem = warnHeavyItem

        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: t("launch.login"), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        menu.addItem(launchItem)
        launchAtLoginMenuItem = launchItem

        let restoreItem = NSMenuItem(title: t("launch.restore"), action: #selector(toggleRestoreLastWallpaper(_:)), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)
        restoreLastWallpaperMenuItem = restoreItem

        item.submenu = menu
        return item
    }

    private func profileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("menu.profiles"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for profile in WallpaperProfile.allCases {
            let profileItem = NSMenuItem(title: profile.title, action: #selector(applyProfile(_:)), keyEquivalent: "")
            profileItem.target = self
            profileItem.tag = profile.rawValue
            menu.addItem(profileItem)
        }

        item.submenu = menu
        return item
    }

    private func hotkeysMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("section.hotkeys"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for description in [
            "⌥⌘W - \(t("hotkey.toggleWallpaper"))",
            "⌥⌘Space - \(t("hotkey.pause"))",
            "⌥⌘← - \(t("hotkey.previous"))",
            "⌥⌘→ - \(t("hotkey.next"))",
            "⌥⌘E - \(t("hotkey.economy"))",
            "⌥⌘, - \(t("hotkey.menu"))"
        ] {
            let descriptionItem = NSMenuItem(title: description, action: nil, keyEquivalent: "")
            descriptionItem.isEnabled = false
            menu.addItem(descriptionItem)
        }

        item.submenu = menu
        return item
    }

    private func advancedMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: t("section.service"), action: nil, keyEquivalent: "")
        let menu = NSMenu()

        let restoreItem = NSMenuItem(title: t("button.restoreWallpaper"), action: #selector(restoreSystemWallpaper(_:)), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)

        let clearCacheItem = NSMenuItem(title: t("button.clearCache"), action: #selector(clearCache(_:)), keyEquivalent: "")
        clearCacheItem.target = self
        menu.addItem(clearCacheItem)

        let sourceInfoItem = NSMenuItem(title: t("menu.sourceInfo"), action: #selector(showCurrentSourceInfo(_:)), keyEquivalent: "")
        sourceInfoItem.target = self
        menu.addItem(sourceInfoItem)

        let logItem = NSMenuItem(title: t("menu.openLog"), action: #selector(openLogFile(_:)), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let resetItem = NSMenuItem(title: t("button.resetAll"), action: #selector(resetSettings(_:)), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        item.submenu = menu
        return item
    }

    private func fpsLimitMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "FPS", action: nil, keyEquivalent: "")
        let menu = NSMenu()

        for fpsLimit in WallpaperFPSLimit.allCases {
            let fpsItem = NSMenuItem(title: fpsLimitTitle(fpsLimit), action: #selector(setFPSLimit(_:)), keyEquivalent: "")
            fpsItem.target = self
            fpsItem.tag = fpsLimit.rawValue
            menu.addItem(fpsItem)
            fpsItems[fpsLimit] = fpsItem
        }

        item.submenu = menu
        return item
    }

    private func refreshMenuState() {
        toggleWallpaperMenuItem?.title = wallpaperController.isWallpaperEnabled
            ? t("menu.turnOffWallpaper")
            : t("menu.turnOnWallpaper")
        pauseMenuItem?.title = wallpaperController.isUserPaused ? t("menu.resume") : t("menu.pause")
        previousMenuItem?.isEnabled = wallpaperController.canSelectPreviousOrNext
        nextMenuItem?.isEnabled = wallpaperController.canSelectPreviousOrNext

        for (mode, item) in displayModeItems {
            item.state = wallpaperController.settings.displayMode == mode ? .on : .off
        }

        for (speed, item) in speedItems {
            item.state = abs(wallpaperController.settings.playbackRate - speed) < 0.001 ? .on : .off
        }

        shuffleMenuItem?.state = wallpaperController.settings.isShuffleEnabled ? .on : .off
        randomStartMenuItem?.state = wallpaperController.settings.startsAtRandomPosition ? .on : .off

        for (interval, item) in rotationIntervalItems {
            item.state = wallpaperController.settings.rotationInterval == interval ? .on : .off
        }

        for (volume, item) in volumeItems {
            item.state = abs(wallpaperController.settings.volume - volume) < 0.001 ? .on : .off
        }

        for (brightness, item) in brightnessItems {
            item.state = abs(wallpaperController.settings.brightness - brightness) < 0.001 ? .on : .off
        }

        for (dimming, item) in dimmingItems {
            item.state = abs(wallpaperController.settings.dimming - dimming) < 0.001 ? .on : .off
        }

        for (fpsLimit, item) in fpsItems {
            item.state = wallpaperController.settings.fpsLimit == fpsLimit ? .on : .off
        }

        economyModeMenuItem?.state = wallpaperController.settings.isEconomyModeEnabled ? .on : .off
        pauseOnBatteryMenuItem?.state = wallpaperController.behaviorSettings.pauseOnBattery ? .on : .off
        pauseOnLowBatteryMenuItem?.state = wallpaperController.behaviorSettings.pauseOnLowBattery ? .on : .off
        pauseInFullscreenMenuItem?.state = wallpaperController.behaviorSettings.pauseInFullscreen ? .on : .off
        pauseWhenDesktopCoveredMenuItem?.state = wallpaperController.behaviorSettings.pauseWhenDesktopCovered ? .on : .off
        pauseOnScreenLockMenuItem?.state = wallpaperController.behaviorSettings.pauseOnScreenLock ? .on : .off
        pauseOnHighLoadMenuItem?.state = wallpaperController.behaviorSettings.pauseOnHighSystemLoad ? .on : .off
        pauseDuringGamesOrCallsMenuItem?.state = wallpaperController.behaviorSettings.pauseDuringGamesOrCalls ? .on : .off
        autoLowerQualityMenuItem?.state = wallpaperController.behaviorSettings.autoLowerQualityOnLoad ? .on : .off
        warnHeavyFilesMenuItem?.state = wallpaperController.behaviorSettings.warnAboutHeavyFiles ? .on : .off
        launchAtLoginMenuItem?.state = wallpaperController.behaviorSettings.launchAtLogin ? .on : .off
        restoreLastWallpaperMenuItem?.state = wallpaperController.behaviorSettings.restoreLastWallpaperOnLaunch ? .on : .off
        favoriteToggleMenuItem?.title = wallpaperController.isCurrentFavorite
            ? t("menu.removeFavorite")
            : t("menu.addFavorite")
        currentWeightMenuItem?.isEnabled = wallpaperController.canEditCurrentWallpaperWeight
        if let weight = wallpaperController.currentWallpaperWeight {
            currentWeightMenuItem?.title = String(format: t("menu.currentWeightValue"), weight)
        } else {
            currentWeightMenuItem?.title = t("menu.currentWeight")
        }
        refreshLibraryMenus()
    }

    private func refreshLibraryMenus() {
        rebuildSourceMenu(favoritesMenu, sources: wallpaperController.favorites, action: #selector(openFavorite(_:)))
        rebuildSourceMenu(recentMenu, sources: wallpaperController.recentSources, action: #selector(openRecent(_:)))

        collectionsMenu.removeAllItems()
        if wallpaperController.collections.isEmpty {
            let emptyItem = NSMenuItem(title: t("menu.noCollections"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            collectionsMenu.addItem(emptyItem)
        } else {
            for (index, collection) in wallpaperController.collections.enumerated() {
                let item = NSMenuItem(title: "\(collection.name) (\(collection.items.count))", action: #selector(openCollection(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                collectionsMenu.addItem(item)
            }
        }
    }

    private func rebuildSourceMenu(_ menu: NSMenu, sources: [WallpaperSourceSnapshot], action: Selector) {
        menu.removeAllItems()
        if sources.isEmpty {
            let emptyItem = NSMenuItem(title: t("menu.empty"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for (index, source) in sources.enumerated() {
            let item = NSMenuItem(title: source.displayName, action: action, keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func validateVideoSelection(_ urls: [URL]) -> Bool {
        guard wallpaperController.behaviorSettings.warnAboutHeavyFiles else {
            return true
        }

        let limitBytes = wallpaperController.behaviorSettings.maximumFileSizeGB * 1024 * 1024 * 1024
        var warnings: [String] = []
        var blocked: [String] = []

        for url in urls.prefix(12) {
            let metadata = VideoFileInspector.metadata(for: url)
            if !metadata.isPlayable {
                blocked.append("\(url.lastPathComponent): видео не читается или не содержит видеодорожку")
            } else if metadata.fileSizeBytes > Int64(limitBytes) {
                blocked.append("\(url.lastPathComponent): больше \(wallpaperController.behaviorSettings.maximumFileSizeGB) GB")
            } else if let warning = metadata.performanceWarning {
                warnings.append("\(url.lastPathComponent): \(warning)")
            }
        }

        if !blocked.isEmpty {
            showMessage(
                title: "Видео слишком большое",
                message: blocked.joined(separator: "\n")
            )
            return false
        }

        guard !warnings.isEmpty else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Видео может сильно нагружать Mac"
        alert.informativeText = warnings.prefix(5).joined(separator: "\n")
        alert.addButton(withTitle: "Продолжить")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func installTerminationHandlers() {
        installSignalHandler(for: SIGTERM)
        installSignalHandler(for: SIGINT)
    }

    private func installSignalHandler(for signalNumber: Int32) {
        signal(signalNumber, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { [weak self] in
            self?.wallpaperController.stop()
            NSApp.terminate(nil)
        }
        source.resume()
        signalSources.append(source)
    }

    private func configureHotkeys() {
        hotkeyController.start(
            actions: GlobalHotkeyActions(
                toggleWallpaper: { [weak self] in
                    self?.toggleWallpaper(nil)
                },
                togglePause: { [weak self] in
                    self?.togglePause(nil)
                },
                previous: { [weak self] in
                    self?.previousWallpaper(nil)
                },
                next: { [weak self] in
                    self?.nextWallpaper(nil)
                },
                toggleEconomy: { [weak self] in
                    self?.toggleEconomyMode(nil)
                },
                showMenu: { [weak self] in
                    self?.statusItem?.button?.performClick(nil)
                }
            )
        )
    }
}

enum VideoPicker {
    static func chooseVideo() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выберите видео для живого фона"
        panel.prompt = "Выбрать"
        panel.message = "Видео будет проигрываться на рабочем столе, пока Live Wallpapers for Mac запущен."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = videoContentTypes

        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseVideoFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку с видео"
        panel.prompt = "Выбрать"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        return panel.runModal() == .OK ? panel.url : nil
    }

    static func videoURLs(in folderURL: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let supportedExtensions = Set(["mp4", "mov", "m4v", "webm"])
        return urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func isSupportedVideoURL(_ url: URL) -> Bool {
        Set(["mp4", "mov", "m4v", "webm"]).contains(url.pathExtension.lowercased())
    }

    private static var videoContentTypes: [UTType] {
        var types: [UTType] = [.movie]
        if let webm = UTType(filenameExtension: "webm") {
            types.append(webm)
        }
        return types
    }
}

enum ImagePicker {
    static func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выберите изображение или GIF для фона"
        panel.prompt = "Выбрать"
        panel.message = "Статичные изображения и GIF будут показаны на рабочем столе, пока Live Wallpapers for Mac запущен."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        return panel.runModal() == .OK ? panel.url : nil
    }

    static func isSupportedImageURL(_ url: URL) -> Bool {
        Set(["jpg", "jpeg", "png", "heic", "gif", "tiff", "webp"]).contains(url.pathExtension.lowercased())
    }
}

enum ImageFileInspector {
    static func isReadableImage(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }

        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}

enum TextPrompt {
    static func run(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.icon = AppIconProvider.image(size: NSSize(width: 64, height: 64))
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func runInteger(title: String, message: String, placeholder: String) -> Int? {
        guard let rawValue = run(title: title, message: message, placeholder: placeholder),
              let value = Int(rawValue) else {
            return nil
        }

        return max(1, min(value, 100))
    }
}

enum PresetFilePanel {
    static func chooseImportURL() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Импорт пресета Live Wallpapers for Mac"
        panel.prompt = "Импорт"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExportURL() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Экспорт пресета Live Wallpapers for Mac"
        panel.nameFieldStringValue = "Live Wallpapers for Mac Preset.json"
        panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct VideoMetadata {
    let fileSizeBytes: Int64
    let durationSeconds: Double?
    let dimensions: CGSize?
    let frameRate: Float?
    let hasVideoTrack: Bool

    var isPlayable: Bool {
        hasVideoTrack && (durationSeconds ?? 1) > 0
    }

    var performanceWarning: String? {
        var parts: [String] = []

        if let dimensions,
           dimensions.width >= 3840 || dimensions.height >= 2160 {
            parts.append("4K")
        }

        if let frameRate,
           frameRate >= 50 {
            parts.append("\(Int(frameRate.rounded())) FPS")
        }

        if fileSizeBytes > 2 * 1024 * 1024 * 1024 {
            parts.append("файл больше 2 GB")
        }

        guard !parts.isEmpty else {
            return nil
        }

        return "\(parts.joined(separator: ", ")). Рекомендуется 1080p 30 FPS для меньшей нагрузки."
    }

    var displayDescription: String {
        [
            "Размер файла: \(FileInfoFormatter.fileSize(fileSizeBytes))",
            "Длительность: \(durationSeconds.map(FileInfoFormatter.duration(_:)) ?? "не определена")",
            "Разрешение: \(dimensions.map(FileInfoFormatter.dimensions(_:)) ?? "не определено")",
            "FPS: \(frameRate.map(FileInfoFormatter.fps(_:)) ?? "не определён")",
            "Видеодорожка: \(hasVideoTrack ? "есть" : "не найдена")"
        ].joined(separator: "\n")
    }
}

enum VideoFileInspector {
    static func metadata(for url: URL) -> VideoMetadata {
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value) ?? 0
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.isNumeric ? asset.duration.seconds : nil
        let track = asset.tracks(withMediaType: .video).first
        let naturalSize = track?.naturalSize.applying(track?.preferredTransform ?? .identity)
        let dimensions = naturalSize.map {
            CGSize(width: abs($0.width), height: abs($0.height))
        }
        let frameRate = track?.nominalFrameRate

        return VideoMetadata(
            fileSizeBytes: fileSize,
            durationSeconds: duration?.isFinite == true ? duration : nil,
            dimensions: dimensions,
            frameRate: frameRate,
            hasVideoTrack: track != nil
        )
    }

    static func isPlayableVideo(_ url: URL) -> Bool {
        metadata(for: url).isPlayable
    }
}

enum FileInfoFormatter {
    static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func duration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }

        return String(format: "%d:%02d", minutes, secs)
    }

    static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) x \(Int(size.height.rounded()))"
    }

    static func fps(_ value: Float) -> String {
        value > 0 ? "\(Int(value.rounded()))" : "не определён"
    }
}

enum TrimPanel {
    static func run(initialStartSeconds: Double, initialEndSeconds: Double) -> VideoTrim? {
        let alert = NSAlert()
        alert.messageText = "Обрезка видео"
        alert.informativeText = "Укажите, сколько секунд пропустить в начале и сколько убрать с конца. Значения применяются к текущему и следующим видео."
        alert.addButton(withTitle: "Применить")
        alert.addButton(withTitle: "Отмена")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 70))

        let startLabel = NSTextField(labelWithString: "С начала, сек:")
        startLabel.frame = NSRect(x: 0, y: 40, width: 130, height: 22)
        container.addSubview(startLabel)

        let startField = NSTextField(frame: NSRect(x: 140, y: 38, width: 150, height: 24))
        startField.doubleValue = initialStartSeconds
        container.addSubview(startField)

        let endLabel = NSTextField(labelWithString: "С конца, сек:")
        endLabel.frame = NSRect(x: 0, y: 8, width: 130, height: 22)
        container.addSubview(endLabel)

        let endField = NSTextField(frame: NSRect(x: 140, y: 6, width: 150, height: 24))
        endField.doubleValue = initialEndSeconds
        container.addSubview(endField)

        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        return VideoTrim(
            startSeconds: max(0, startField.doubleValue),
            endSeconds: max(0, endField.doubleValue)
        )
    }
}

enum ScheduleRuleEditorPanel {
    static func run(kind: AutomationRuleKind, controller: WallpaperController) -> Bool {
        let settings = controller.automationSettings
        let alert = NSAlert()
        alert.messageText = "Правило: \(kind.title)"
        alert.informativeText = "Показаны только настройки, которые относятся к этому правилу."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")

        let containerHeight: CGFloat = kind == .timeOfDay ? 410 : 270
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: containerHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let enabledButton = NSButton(checkboxWithTitle: "Включить это правило", target: nil, action: nil)
        enabledButton.state = isRuleEnabled(kind, settings: settings) ? .on : .off

        stack.addArrangedSubview(sectionLabel("Когда"))
        stack.addArrangedSubview(descriptionLabel(triggerDescription(for: kind)))
        stack.addArrangedSubview(enabledButton)

        stack.addArrangedSubview(sectionLabel("Что сделать"))
        stack.addArrangedSubview(descriptionLabel(actionDescription(for: kind)))

        var slotPopups: [AutomationTimeSlot: NSPopUpButton] = [:]
        stack.addArrangedSubview(sectionLabel("Детали"))
        switch kind {
        case .timeOfDay:
            for slot in AutomationTimeSlot.allCases {
                let popup = profilePopup(selected: settings.slotProfiles[slot] ?? slot.defaultProfile)
                slotPopups[slot] = popup
                stack.addArrangedSubview(row("\(slot.title) \(slotRange(slot))", popup))
            }

        case .weekday:
            stack.addArrangedSubview(descriptionLabel("В будни применяется Work, в субботу и воскресенье - Cinematic. Если коллекции уже настроены по дням, старая привязка сохраняется."))

        case .homeWork:
            stack.addArrangedSubview(descriptionLabel("Профиль Work активен с 09:00 до 19:00. В остальное время применяется Cinematic."))

        case .power:
            stack.addArrangedSubview(descriptionLabel("От батареи применяется Battery Saver. От зарядки применяется Cinematic. Поля времени не нужны."))

        case .externalDisplay:
            stack.addArrangedSubview(descriptionLabel("При нескольких мониторах применяется Performance. При одном мониторе применяется Cinematic. Поля времени не нужны."))
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])

        alert.accessoryView = container
        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        controller.setAutomationRule(kind, enabled: enabledButton.state == .on)
        if kind == .timeOfDay {
            let profiles = Dictionary(
                uniqueKeysWithValues: slotPopups.compactMap { slot, popup -> (AutomationTimeSlot, WallpaperProfile)? in
                    guard let profile = WallpaperProfile(rawValue: popup.selectedTag()) else {
                        return nil
                    }
                    return (slot, profile)
                }
            )
            controller.updateAutomationSlotProfiles(profiles)
        }
        return true
    }

    private static func isRuleEnabled(_ kind: AutomationRuleKind, settings: WallpaperAutomationSettings) -> Bool {
        switch kind {
        case .externalDisplay:
            return settings.changeOnExternalDisplay
        case .power:
            return settings.changeOnPowerChange
        case .homeWork:
            return settings.homeWorkProfilesEnabled
        case .weekday:
            return settings.scheduleByWeekday
        case .timeOfDay:
            return settings.scheduleByTimeOfDay
        }
    }

    private static func triggerDescription(for kind: AutomationRuleKind) -> String {
        switch kind {
        case .externalDisplay:
            return "Когда меняется набор мониторов"
        case .power:
            return "Когда Mac переключается между батареей и зарядкой"
        case .homeWork:
            return "Каждый день с 09:00 до 19:00"
        case .weekday:
            return "Будни и выходные"
        case .timeOfDay:
            return "Каждый день по фиксированным блокам утра, дня, вечера и ночи"
        }
    }

    private static func actionDescription(for kind: AutomationRuleKind) -> String {
        switch kind {
        case .externalDisplay:
            return "Performance при внешнем мониторе, Cinematic при одном мониторе"
        case .power:
            return "Battery Saver от батареи, Cinematic от зарядки"
        case .homeWork:
            return "Work в рабочие часы, Cinematic после них"
        case .weekday:
            return "Work в будни, Cinematic в выходные"
        case .timeOfDay:
            return "Применить выбранный профиль для каждого временного блока"
        }
    }

    private static func slotRange(_ slot: AutomationTimeSlot) -> String {
        switch slot {
        case .morning:
            return "06:00-12:00"
        case .day:
            return "12:00-18:00"
        case .evening:
            return "18:00-23:00"
        case .night:
            return "23:00-06:00"
        }
    }

    private static func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .bold)
        label.textColor = .labelColor
        return label
    }

    private static func descriptionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 520
        return label
    }

    private static func profilePopup(selected: WallpaperProfile) -> NSPopUpButton {
        let popup = NSPopUpButton()
        for profile in WallpaperProfile.allCases {
            popup.addItem(withTitle: profile.title)
            popup.lastItem?.tag = profile.rawValue
        }
        popup.selectItem(withTag: selected.rawValue)
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return popup
    }

    private static func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }
}

enum ManualAutomationOverridePrompt {
    static func run() -> AutomationOverrideOption? {
        let alert = NSAlert()
        alert.messageText = "На сколько оставить ручной фон?"
        alert.informativeText = "Расписание включено. Выберите, когда Live Wallpapers for Mac должен вернуться к автоматизации."
        alert.addButton(withTitle: "До следующего изменения")
        alert.addButton(withTitle: "30 минут")
        alert.addButton(withTitle: "1 час")
        alert.addButton(withTitle: "Выключить расписание")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .untilNextChange
        case .alertSecondButtonReturn:
            return .thirtyMinutes
        case .alertThirdButtonReturn:
            return .oneHour
        default:
            return .disableSchedule
        }
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

final class SettingsWindowController: NSWindowController {
    private enum SettingsSection: Int, CaseIterable {
        case general
        case wallpaper
        case displays
        case performance
        case playlists
        case automation
        case hotkeys
        case service
        case creators

        func title(language: AppLanguage) -> String {
            AppLocalization.text("section.\(key)", language: language)
        }

        func subtitle(language: AppLanguage) -> String {
            AppLocalization.text("subtitle.\(key)", language: language)
        }

        private var key: String {
            switch self {
            case .general:
                return "general"
            case .wallpaper:
                return "wallpaper"
            case .displays:
                return "displays"
            case .performance:
                return "performance"
            case .playlists:
                return "playlists"
            case .automation:
                return "automation"
            case .hotkeys:
                return "hotkeys"
            case .service:
                return "service"
            case .creators:
                return "creators"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .wallpaper: return "photo.on.rectangle"
            case .displays: return "display.2"
            case .performance: return "speedometer"
            case .playlists: return "rectangle.stack"
            case .automation: return "wand.and.stars"
            case .hotkeys: return "keyboard"
            case .service: return "wrench.and.screwdriver"
            case .creators: return "person.2"
            }
        }
    }

    private let wallpaperController: WallpaperController
    private let onChange: () -> Void
    private let contentContainer = NSView()
    private var sidebarButtons: [SettingsSection: NSButton] = [:]
    private var sectionViews: [SettingsSection: NSView] = [:]
    private var selectedSection: SettingsSection = .general

    private var currentLanguage: AppLanguage {
        wallpaperController.behaviorSettings.appLanguage
    }

    private func t(_ key: String) -> String {
        AppLocalization.text(key, language: currentLanguage)
    }

    private var languageButtons: [AppLanguage: NSButton] = [:]
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Автозапуск при входе", target: nil, action: nil)
    private let restoreLastButton = NSButton(checkboxWithTitle: "Запускать последний фон", target: nil, action: nil)
    private let displayModePopup = NSPopUpButton()
    private let contentScaleSlider = NSSlider(value: 1, minValue: 0.25, maxValue: 3, target: nil, action: nil)
    private let contentOffsetXSlider = NSSlider(value: 0, minValue: -0.5, maxValue: 0.5, target: nil, action: nil)
    private let contentOffsetYSlider = NSSlider(value: 0, minValue: -0.5, maxValue: 0.5, target: nil, action: nil)
    private let speedPopup = NSPopUpButton()
    private let volumePopup = NSPopUpButton()
    private let brightnessSlider = NSSlider(value: 1, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let dimmingSlider = NSSlider(value: 0, minValue: 0, maxValue: 0.85, target: nil, action: nil)
    private let contrastSlider = NSSlider(value: 1, minValue: 0.5, maxValue: 1.8, target: nil, action: nil)
    private let saturationSlider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: nil, action: nil)
    private let blurSlider = NSSlider(value: 0, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let hueSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let vignetteSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let grainSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let continuePositionButton = NSButton(checkboxWithTitle: "Продолжать с последней позиции", target: nil, action: nil)
    private let cinematicLoopButton = NSButton(checkboxWithTitle: "Cinematic loop fade", target: nil, action: nil)
    private let fpsPopup = NSPopUpButton()
    private let economyButton = NSButton(checkboxWithTitle: "Экономичный режим", target: nil, action: nil)
    private let pauseOnBatteryButton = NSButton(checkboxWithTitle: "Пауза от батареи", target: nil, action: nil)
    private let pauseOnLowBatteryButton = NSButton(checkboxWithTitle: "Пауза ниже 20%", target: nil, action: nil)
    private let pauseInFullscreenButton = NSButton(checkboxWithTitle: "Пауза в полноэкранных приложениях", target: nil, action: nil)
    private let pauseWhenCoveredButton = NSButton(checkboxWithTitle: "Пауза, когда рабочий стол закрыт", target: nil, action: nil)
    private let pauseOnScreenLockButton = NSButton(checkboxWithTitle: "Пауза при блокировке экрана", target: nil, action: nil)
    private let pauseHighLoadButton = NSButton(checkboxWithTitle: "Пауза при высокой нагрузке", target: nil, action: nil)
    private let pauseGamesCallsButton = NSButton(checkboxWithTitle: "Пауза при играх и звонках", target: nil, action: nil)
    private let autoQualityButton = NSButton(checkboxWithTitle: "Автоснижение качества при нагрузке", target: nil, action: nil)
    private let warnHeavyFilesButton = NSButton(checkboxWithTitle: "Предупреждать о тяжёлых видео", target: nil, action: nil)
    private let shuffleButton = NSButton(checkboxWithTitle: "Случайный порядок", target: nil, action: nil)
    private let randomStartButton = NSButton(checkboxWithTitle: "Случайный старт видео", target: nil, action: nil)
    private let rotationPopup = NSPopUpButton()
    private let displaySourceModePopup = NSPopUpButton()
    private let syncPlaybackButton = NSButton(checkboxWithTitle: "Синхронное воспроизведение", target: nil, action: nil)
    private let automationPresetPopup = NSPopUpButton()
    private let automationEnabledButton = NSButton(checkboxWithTitle: "Включить автоматизацию", target: nil, action: nil)
    private let scheduleTimeButton = NSButton(checkboxWithTitle: "Менять профиль по времени суток", target: nil, action: nil)
    private let scheduleWeekdayButton = NSButton(checkboxWithTitle: "Менять коллекции и профиль по дням недели", target: nil, action: nil)
    private let powerAutomationButton = NSButton(checkboxWithTitle: "Включать Battery Saver от батареи и Cinematic от зарядки", target: nil, action: nil)
    private let externalDisplayAutomationButton = NSButton(checkboxWithTitle: "Включать Performance при подключении внешнего монитора", target: nil, action: nil)
    private let homeWorkButton = NSButton(checkboxWithTitle: "Рабочие часы: Work с 9:00 до 18:00, вечером Cinematic", target: nil, action: nil)

    init(wallpaperController: WallpaperController, onChange: @escaping () -> Void) {
        self.wallpaperController = wallpaperController
        self.onChange = onChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Live Wallpapers for Mac Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 900, height: 620)
        window.center()

        super.init(window: window)

        window.contentView = makeContentView()
        wireActions()
        selectSection(.general)
        refreshControls()
        enforceWindowSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        refreshControls()
        enforceWindowSize()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.enforceWindowSize()
        }
    }

    private func enforceWindowSize() {
        guard let window else {
            return
        }

        let size = NSSize(width: 1040, height: 720)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func makeContentView() -> NSView {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1040, height: 720))
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .active

        let sidebar = makeSidebar()
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(separator)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 212),

            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 688),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 620)
        ])

        return root
    }

    private func makeSidebar() -> NSVisualEffectView {
        let sidebar = NSVisualEffectView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let brandStack = NSStackView()
        brandStack.orientation = .horizontal
        brandStack.alignment = .centerY
        brandStack.spacing = 10
        brandStack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        if let appIcon = AppIconProvider.image(size: NSSize(width: 28, height: 28)) {
            icon.image = appIcon
        } else {
            icon.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            icon.contentTintColor = .controlAccentColor
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = -1
        let appTitle = NSTextField(labelWithString: "Live Wallpapers")
        appTitle.font = .boldSystemFont(ofSize: 12.5)
        appTitle.alignment = .left
        appTitle.lineBreakMode = .byClipping
        let appTitleSuffix = NSTextField(labelWithString: "for Mac")
        appTitleSuffix.font = .boldSystemFont(ofSize: 12.5)
        appTitleSuffix.alignment = .left
        appTitleSuffix.lineBreakMode = .byClipping
        let appSubtitle = NSTextField(labelWithString: "Live Desktop")
        appSubtitle.font = .systemFont(ofSize: 10.5)
        appSubtitle.alignment = .left
        appSubtitle.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(appTitle)
        titleStack.addArrangedSubview(appTitleSuffix)
        titleStack.addArrangedSubview(appSubtitle)

        brandStack.addArrangedSubview(icon)
        brandStack.addArrangedSubview(titleStack)
        stack.addArrangedSubview(brandStack)
        stack.setCustomSpacing(18, after: brandStack)

        for section in SettingsSection.allCases {
            let button = sidebarButton(for: section)
            sidebarButtons[section] = button
            stack.addArrangedSubview(button)
        }

        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 58)
        ])

        return sidebar
    }

    private func sidebarButton(for section: SettingsSection) -> NSButton {
        let button = NSButton(title: section.title(language: currentLanguage), target: self, action: #selector(selectSectionFromSidebar(_:)))
        button.tag = section.rawValue
        button.isBordered = false
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title(language: currentLanguage))
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.widthAnchor.constraint(equalToConstant: 180).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    @objc private func selectSectionFromSidebar(_ sender: NSButton) {
        guard let section = SettingsSection(rawValue: sender.tag) else {
            return
        }

        selectSection(section)
    }

    private func selectSection(_ section: SettingsSection) {
        selectedSection = section
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        let view = sectionView(for: section)
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        refreshSidebarSelection()
        refreshControls()
    }

    private func rebuildSection(_ section: SettingsSection) {
        sectionViews[section] = nil
        if selectedSection == section {
            selectSection(section)
        } else {
            refreshControls()
        }
    }

    private func sectionView(for section: SettingsSection) -> NSView {
        if let cachedView = sectionViews[section] {
            return cachedView
        }

        let view: NSView
        switch section {
        case .general:
            view = generalView()
        case .wallpaper:
            view = wallpaperView()
        case .displays:
            view = displaysView()
        case .performance:
            view = performanceView()
        case .playlists:
            view = playlistView()
        case .automation:
            view = automationView()
        case .hotkeys:
            view = hotkeysView()
        case .service:
            view = advancedView()
        case .creators:
            view = creatorsView()
        }

        sectionViews[section] = view
        return view
    }

    private func refreshSidebarSelection() {
        for (section, button) in sidebarButtons {
            let isSelected = section == selectedSection
            button.title = section.title(language: currentLanguage)
            button.image = NSImage(
                systemSymbolName: section.symbolName,
                accessibilityDescription: section.title(language: currentLanguage)
            )
            button.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
            button.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
        }
    }

    private func generalView() -> NSView {
        return page(
            for: .general,
            groups: [
                settingsGroup(t("group.language"), views: [
                    languageSelectorView(),
                    helpLabel(t("language.help"))
                ]),
                settingsGroup(t("group.launch"), views: [
                    launchAtLoginButton,
                    restoreLastButton
                ]),
                settingsGroup(t("group.sources"), views: [
                    actionRow([
                        button(title: t("button.video"), action: #selector(chooseVideoFromSettings(_:))),
                        button(title: t("button.imageGif"), action: #selector(chooseImageFromSettings(_:)))
                    ]),
                    DropImportView(
                        wallpaperController: wallpaperController,
                        onChange: onChange,
                        title: t("drop.import")
                    )
                ])
            ]
        )
    }

    private func wallpaperView() -> NSView {
        fillPopup(displayModePopup, items: WallpaperDisplayMode.allCases.map { (displayModeTitle($0), $0.rawValue) })
        fillPopup(speedPopup, items: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0].map { ("\($0)x", Int($0 * 100)) })
        fillPopup(volumePopup, items: [(t("volume.off"), 0), ("25%", 25), ("50%", 50), ("100%", 100)])

        return page(
            for: .wallpaper,
            groups: [
                settingsGroup(t("group.placement"), views: [
                    row(t("row.scale"), displayModePopup),
                    row(t("row.manualScale"), contentScaleSlider),
                    row(t("row.offsetX"), contentOffsetXSlider),
                    row(t("row.offsetY"), contentOffsetYSlider)
                ]),
                settingsGroup(t("group.playback"), views: [
                    row(t("row.speed"), speedPopup),
                    row(t("row.sound"), volumePopup),
                    continuePositionButton,
                    cinematicLoopButton
                ]),
                settingsGroup(t("group.appearance"), views: [
                    row(t("row.brightness"), brightnessSlider),
                    row(t("row.dimming"), dimmingSlider),
                    row(t("row.contrast"), contrastSlider),
                    row(t("row.saturation"), saturationSlider),
                    row(t("row.blur"), blurSlider),
                    row(t("row.hue"), hueSlider),
                    row(t("row.vignette"), vignetteSlider),
                    row(t("row.grain"), grainSlider)
                ])
            ]
        )
    }

    private func displaysView() -> NSView {
        fillPopup(displaySourceModePopup, items: WallpaperDisplaySourceMode.allCases.map { (displaySourceModeTitle($0), $0.rawValue) })

        return page(
            for: .displays,
            groups: [
                settingsGroup(t("group.displayBehavior"), views: [
                    row(t("row.displays"), displaySourceModePopup),
                    syncPlaybackButton
                ])
            ]
        )
    }

    private func performanceView() -> NSView {
        fillPopup(fpsPopup, items: WallpaperFPSLimit.allCases.map { (fpsLimitTitle($0), $0.rawValue) })

        return page(
            for: .performance,
            groups: [
                settingsGroup(t("group.quality"), views: [
                    row("FPS", fpsPopup),
                    economyButton,
                    autoQualityButton,
                    warnHeavyFilesButton
                ]),
                settingsGroup(t("group.autopause"), views: [
                    pauseOnBatteryButton,
                    pauseOnLowBatteryButton,
                    pauseInFullscreenButton,
                    pauseWhenCoveredButton,
                    pauseOnScreenLockButton,
                    pauseHighLoadButton,
                    pauseGamesCallsButton
                ])
            ]
        )
    }

    private func playlistView() -> NSView {
        fillPopup(rotationPopup, items: WallpaperRotationInterval.allCases.map { (rotationIntervalTitle($0), $0.rawValue) })

        return page(
            for: .playlists,
            groups: [
                settingsGroup(t("group.rotation"), views: [
                    shuffleButton,
                    randomStartButton,
                    row(t("row.rotationTimer"), rotationPopup)
                ]),
                settingsGroup(t("group.collections"), views: [
                    button(title: t("button.saveCollection"), action: #selector(saveCollectionFromSettings(_:)))
                ])
            ]
        )
    }

    private func automationView() -> NSView {
        let presentation = wallpaperController.automationSchedulePresentation
        var groups: [NSView] = [
            automationOverviewGroup(presentation),
            upcomingAutomationGroup(presentation)
        ]

        if presentation.hasEnabledRules {
            groups.append(automationRulesGroup(presentation))
        } else {
            groups.append(emptyAutomationGroup())
            groups.append(automationRulesGroup(presentation))
        }

        groups.append(automationTemplatesGroup())
        groups.append(manualOverrideGroup(presentation))
        return page(
            for: .automation,
            groups: groups
        )
    }

    private func languageSelectorView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        languageButtons.removeAll()
        for language in AppLanguage.allCases {
            let button = languageButton(for: language)
            languageButtons[language] = button
            stack.addArrangedSubview(button)
        }

        return stack
    }

    private func languageButton(for language: AppLanguage) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(setAppLanguage(_:)))
        button.tag = language.tag
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.widthAnchor.constraint(equalToConstant: 118).isActive = true
        button.heightAnchor.constraint(equalToConstant: 54).isActive = true

        let title = NSMutableAttributedString(
            string: "\(language.title)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        title.append(
            NSAttributedString(
                string: language.subtitle,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        button.attributedTitle = title
        button.toolTip = "Язык интерфейса: \(language.title) (\(language.rawValue))"
        button.setAccessibilityLabel("Язык: \(language.title)")
        return button
    }

    private func refreshLanguageButtons() {
        let selectedLanguage = wallpaperController.behaviorSettings.appLanguage
        for (language, button) in languageButtons {
            let isSelected = language == selectedLanguage
            button.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.textBackgroundColor.withAlphaComponent(0.28).cgColor
            button.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
                : NSColor.separatorColor.withAlphaComponent(0.50).cgColor
            button.layer?.borderWidth = 1
            button.contentTintColor = isSelected ? .controlAccentColor : .labelColor
        }
    }

    private func automationOverviewGroup(_ presentation: AutomationSchedulePresentation) -> NSView {
        var views: [NSView] = [automationEnabledButton]

        if let activeState = presentation.activeState {
            views.append(
                automationStatusCard(
                    symbolName: presentation.overrideDescription == nil ? "bolt.circle" : "hand.raised",
                    title: "\(t("automation.activeNow")): \(activeState.title)",
                    lines: [
                        "\(t("automation.applied")): \(activeState.applied)",
                        "\(t("automation.reason")): \(activeState.reason)",
                        "\(t("automation.nextChange")): \(activeState.nextChange)"
                    ],
                    tint: presentation.overrideDescription == nil ? .controlAccentColor : .systemOrange
                )
            )
        } else {
            views.append(
                automationStatusCard(
                    symbolName: "pause.circle",
                    title: t("automation.noActive"),
                    lines: [
                        presentation.isEnabled
                            ? t("automation.enableHint")
                            : t("automation.offHint")
                    ],
                    tint: .secondaryLabelColor
                )
            )
        }

        return settingsGroup(t("automation.activeGroup"), views: views)
    }

    private func upcomingAutomationGroup(_ presentation: AutomationSchedulePresentation) -> NSView {
        guard !presentation.upcomingEvents.isEmpty else {
            return settingsGroup(t("automation.upcoming"), views: [
                helpLabel(t("automation.upcomingNone"))
            ])
        }

        let rows = presentation.upcomingEvents.map { event in
            automationTimelineRow(time: event.timeText, title: event.title, action: event.action)
        }
        return settingsGroup(t("automation.preview24"), views: rows)
    }

    private func automationRulesGroup(_ presentation: AutomationSchedulePresentation) -> NSView {
        var views: [NSView] = [
            helpLabel(t("automation.priorityHelp"))
        ]
        views.append(contentsOf: presentation.rules.map(automationRuleCard(_:)))
        return settingsGroup(t("automation.rules"), views: views)
    }

    private func emptyAutomationGroup() -> NSView {
        let title = NSTextField(labelWithString: t("automation.emptyTitle"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor

        let description = helpLabel(t("automation.emptyDescription"))
        let addButton = button(title: t("automation.addFirst"), action: #selector(addFirstAutomationRule(_:)))
        let templateButton = button(title: t("automation.dayNightTemplate"), action: #selector(applyAutomationTemplate(_:)))
        templateButton.tag = AutomationTemplateKind.dayNight.rawValue

        return settingsGroup(t("automation.emptyGroup"), views: [
            title,
            description,
            actionRow([addButton, templateButton])
        ])
    }

    private func automationTemplatesGroup() -> NSView {
        let rows = AutomationTemplateKind.allCases.map { template in
            templateButton(for: template)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10

        return settingsGroup(t("automation.templates"), views: [
            helpLabel(t("automation.templatesHelp")),
            stack
        ])
    }

    private func manualOverrideGroup(_ presentation: AutomationSchedulePresentation) -> NSView {
        let firstRow = actionRow([
            overrideButton(title: t("automation.untilNext"), option: .untilNextChange),
            overrideButton(title: t("automation.minutes30"), option: .thirtyMinutes),
            overrideButton(title: t("automation.hour1"), option: .oneHour)
        ])
        let secondRow = actionRow([
            overrideButton(title: t("automation.disableSchedule"), option: .disableSchedule)
        ])

        var views: [NSView] = [
            helpLabel(t("automation.overrideHelp")),
            firstRow,
            secondRow
        ]

        if let overrideDescription = presentation.overrideDescription {
            views.insert(
                automationStatusCard(
                    symbolName: "hand.raised",
                    title: t("automation.overrideActive"),
                    lines: [overrideDescription],
                    tint: .systemOrange
                ),
                at: 1
            )
            views.append(button(title: t("automation.resumeNow"), action: #selector(clearAutomationOverride(_:))))
        }

        return settingsGroup(t("automation.override"), views: views)
    }

    private func automationStatusCard(symbolName: String, title: String, lines: [String], tint: NSColor) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = tint.withAlphaComponent(0.10).cgColor
        card.layer?.borderColor = tint.withAlphaComponent(0.25).cgColor
        card.layer?.borderWidth = 1

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.addArrangedSubview(titleLabel)
        for line in lines {
            let label = helpLabel(line)
            label.preferredMaxLayoutWidth = 650
            textStack.addArrangedSubview(label)
        }

        let stack = NSStackView(views: [icon, textStack])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func automationTimelineRow(time: String, title: String, action: String) -> NSView {
        let timeLabel = badgeLabel(time, color: .controlAccentColor)
        timeLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let actionLabel = helpLabel(action)
        actionLabel.preferredMaxLayoutWidth = 470

        let stack = NSStackView(views: [timeLabel, titleLabel, actionLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func automationRuleCard(_ rule: AutomationRulePresentation) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = rule.isActiveNow
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.textBackgroundColor.withAlphaComponent(0.35).cgColor
        card.layer?.borderColor = rule.isActiveNow
            ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
            : NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        card.layer?.borderWidth = 1

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: rule.kind.iconName, accessibilityDescription: rule.title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        icon.contentTintColor = rule.isActiveNow ? .controlAccentColor : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let titleLabel = NSTextField(labelWithString: rule.title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleRow.addArrangedSubview(titleLabel)
        if rule.isActiveNow {
            titleRow.addArrangedSubview(badgeLabel(t("automation.badgeActive"), color: .controlAccentColor))
        }
        titleRow.addArrangedSubview(badgeLabel(rule.isEnabled ? t("automation.enabled") : t("automation.disabled"), color: rule.isEnabled ? .systemGreen : .secondaryLabelColor))
        titleRow.addArrangedSubview(badgeLabel(rule.priorityDescription, color: .secondaryLabelColor))

        let trigger = helpLabel(formatTriggerDescription(rule))
        let action = helpLabel(formatActionDescription(rule))
        let next = helpLabel("\(t("automation.next")): \(rule.nextRunDescription)")

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.addArrangedSubview(titleRow)
        textStack.addArrangedSubview(trigger)
        textStack.addArrangedSubview(action)
        textStack.addArrangedSubview(next)
        if let conflictDescription = rule.conflictDescription {
            let conflict = helpLabel(conflictDescription)
            conflict.textColor = .systemOrange
            textStack.addArrangedSubview(conflict)
        }

        let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleAutomationRule(_:)))
        toggle.tag = rule.kind.rawValue
        toggle.state = rule.isEnabled ? .on : .off
        toggle.toolTip = rule.isEnabled ? "Выключить правило" : "Включить правило"

        let edit = NSButton(title: t("automation.edit"), target: self, action: #selector(editAutomationRule(_:)))
        edit.tag = rule.kind.rawValue
        edit.bezelStyle = .rounded
        edit.controlSize = .regular

        let controls = NSStackView(views: [toggle, edit])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let rowStack = NSStackView(views: [icon, textStack, controls])
        rowStack.orientation = .horizontal
        rowStack.alignment = .top
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.setContentHuggingPriority(.required, for: .horizontal)

        card.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    private func displayModeTitle(_ mode: WallpaperDisplayMode) -> String {
        switch mode {
        case .fill:
            return t("displayMode.fill")
        case .fit:
            return t("displayMode.fit")
        case .stretch:
            return t("displayMode.stretch")
        case .center:
            return t("displayMode.center")
        case .crop:
            return t("displayMode.crop")
        case .manual:
            return t("displayMode.manual")
        }
    }

    private func displaySourceModeTitle(_ mode: WallpaperDisplaySourceMode) -> String {
        switch mode {
        case .sameOnAllDisplays:
            return t("displaySource.same")
        case .playlistItemPerDisplay:
            return t("displaySource.playlist")
        }
    }

    private func fpsLimitTitle(_ fpsLimit: WallpaperFPSLimit) -> String {
        switch fpsLimit {
        case .source:
            return t("fps.source")
        case .fps15:
            return "15 FPS"
        case .fps24:
            return "24 FPS"
        case .fps30:
            return "30 FPS"
        case .fps60:
            return "60 FPS"
        }
    }

    private func rotationIntervalTitle(_ interval: WallpaperRotationInterval) -> String {
        switch interval {
        case .manual:
            return t("rotation.manual")
        case .fiveMinutes:
            return t("rotation.fiveMinutes")
        case .thirtyMinutes:
            return t("rotation.thirtyMinutes")
        case .oneHour:
            return t("rotation.oneHour")
        }
    }

    private func automationTemplateTitle(_ template: AutomationTemplateKind) -> String {
        switch template {
        case .dayNight:
            return t("automation.template.dayNight")
        case .workday:
            return t("automation.template.workday")
        case .batterySaver:
            return t("automation.template.batterySaver")
        case .gaming:
            return t("automation.template.gaming")
        }
    }

    private func automationTemplateSubtitle(_ template: AutomationTemplateKind) -> String {
        switch template {
        case .dayNight:
            return t("automation.template.dayNight.subtitle")
        case .workday:
            return t("automation.template.workday.subtitle")
        case .batterySaver:
            return t("automation.template.batterySaver.subtitle")
        case .gaming:
            return t("automation.template.gaming.subtitle")
        }
    }

    private func templateButton(for template: AutomationTemplateKind) -> NSButton {
        let button = NSButton(title: automationTemplateTitle(template), target: self, action: #selector(applyAutomationTemplate(_:)))
        button.tag = template.rawValue
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.toolTip = automationTemplateSubtitle(template)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        return button
    }

    private func overrideButton(title: String, option: AutomationOverrideOption) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(applyAutomationOverride(_:)))
        button.tag = option.rawValue
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    private func badgeLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.alignment = .center
        label.textColor = color
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.heightAnchor.constraint(equalToConstant: 22).isActive = true
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        return label
    }

    private func hotkeysView() -> NSView {
        return page(
            for: .hotkeys,
            groups: [
                settingsGroup(t("group.hotkeys"), views: [
                    hotkeyRow(keys: "⌥⌘W", title: t("hotkey.toggleWallpaper")),
                    hotkeyRow(keys: "⌥⌘Space", title: t("hotkey.pause")),
                    hotkeyRow(keys: "⌥⌘←", title: t("hotkey.previous")),
                    hotkeyRow(keys: "⌥⌘→", title: t("hotkey.next")),
                    hotkeyRow(keys: "⌥⌘E", title: t("hotkey.economy")),
                    hotkeyRow(keys: "⌥⌘,", title: t("hotkey.menu"))
                ])
            ]
        )
    }

    private func advancedView() -> NSView {
        return page(
            for: .service,
            groups: [
                settingsGroup(t("group.system"), views: [
                    actionRow([
                        button(title: t("button.restoreWallpaper"), action: #selector(restoreSystemWallpaper(_:))),
                        button(title: t("button.clearCache"), action: #selector(clearCache(_:))),
                        button(title: t("button.checkUpdates"), action: #selector(checkForUpdates(_:)))
                    ])
                ]),
                settingsGroup(t("group.presets"), views: [
                    actionRow([
                        button(title: t("button.import"), action: #selector(importPresetFromSettings(_:))),
                        button(title: t("button.export"), action: #selector(exportPresetFromSettings(_:)))
                    ])
                ]),
                settingsGroup(t("group.danger"), views: [
                    button(title: t("button.resetAll"), action: #selector(resetAll(_:)))
                ])
            ]
        )
    }

    private func creatorsView() -> NSView {
        return page(
            for: .creators,
            groups: [
                creatorHeroView()
            ]
        )
    }

    private func creatorHeroView() -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        card.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        card.layer?.borderWidth = 1

        let icon = NSImageView()
        icon.image = AppIconProvider.image(size: NSSize(width: 76, height: 76))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true

        let eyebrow = NSTextField(labelWithString: t("creators.madeBy"))
        eyebrow.font = .systemFont(ofSize: 12, weight: .semibold)
        eyebrow.textColor = .secondaryLabelColor

        let name = NSTextField(labelWithString: "medusa411")
        name.font = .systemFont(ofSize: 24, weight: .bold)
        name.textColor = .labelColor

        let description = helpLabel(t("creators.description"))
        description.preferredMaxLayoutWidth = 420

        let textStack = NSStackView(views: [eyebrow, name, description])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5

        let supportButton = NSButton(title: t("creators.support"), target: self, action: #selector(openSupportLink(_:)))
        supportButton.bezelStyle = .rounded
        supportButton.controlSize = .large
        supportButton.font = .systemFont(ofSize: 13, weight: .semibold)
        supportButton.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
        supportButton.imagePosition = .imageLeading
        supportButton.contentTintColor = .controlAccentColor
        supportButton.setContentHuggingPriority(.required, for: .horizontal)

        let xButton = NSButton(title: t("creators.x"), target: self, action: #selector(openCreatorXLink(_:)))
        xButton.bezelStyle = .rounded
        xButton.controlSize = .large
        xButton.font = .systemFont(ofSize: 13, weight: .semibold)
        xButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        xButton.imagePosition = .imageLeading
        xButton.setContentHuggingPriority(.required, for: .horizontal)

        let buttonStack = NSStackView(views: [supportButton, xButton])
        buttonStack.orientation = .vertical
        buttonStack.alignment = .trailing
        buttonStack.spacing = 8

        let row = NSStackView(views: [icon, textStack, buttonStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])

        card.setContentHuggingPriority(.required, for: .vertical)
        return card
    }

    private func settingsStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func page(for section: SettingsSection, groups: [NSView]) -> NSView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let view = FlippedDocumentView()
        view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = view

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: section.title(language: currentLanguage))
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .labelColor

        let subtitle = NSTextField(wrappingLabelWithString: section.subtitle(language: currentLanguage))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 620

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(22, after: subtitle)

        for group in groups {
            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        view.addSubview(stack)

        let preferredWidth = stack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -68)
        preferredWidth.priority = .defaultHigh
        let minHeight = view.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        minHeight.priority = .defaultLow

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            minHeight,
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 52),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -34),
            preferredWidth,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])

        return scrollView
    }

    private func settingsGroup(_ title: String, views: [NSView]) -> NSView {
        let group = NSView()
        group.translatesAutoresizingMaskIntoConstraints = false
        group.wantsLayer = true
        group.layer?.cornerRadius = 8
        group.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58).cgColor
        group.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        group.layer?.borderWidth = 1

        let stack = settingsStack()
        stack.spacing = 11
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(12, after: titleLabel)

        views.forEach { stack.addArrangedSubview($0) }

        group.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: group.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -16)
        ])

        group.setContentHuggingPriority(.required, for: .vertical)
        group.setContentCompressionResistancePriority(.required, for: .vertical)
        return group
    }

    private func actionRow(_ buttons: [NSButton]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func hotkeyRow(keys: String, title: String) -> NSView {
        let keyLabel = NSTextField(labelWithString: keys)
        keyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        keyLabel.alignment = .center
        keyLabel.textColor = .controlAccentColor
        keyLabel.wantsLayer = true
        keyLabel.layer?.cornerRadius = 6
        keyLabel.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        keyLabel.widthAnchor.constraint(equalToConstant: 92).isActive = true
        keyLabel.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)

        let stack = NSStackView(views: [keyLabel, titleLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 160).isActive = true
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        return stack
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .medium)
        return button
    }

    private func helpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 660
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 660).isActive = true
        return label
    }

    private func fillPopup(_ popup: NSPopUpButton, items: [(String, Int)]) {
        popup.removeAllItems()
        for item in items {
            popup.addItem(withTitle: item.0)
            popup.lastItem?.tag = item.1
        }
    }

    private func wireActions() {
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin(_:))
        restoreLastButton.target = self
        restoreLastButton.action = #selector(toggleRestoreLast(_:))
        displayModePopup.target = self
        displayModePopup.action = #selector(setDisplayMode(_:))
        contentScaleSlider.target = self
        contentScaleSlider.action = #selector(setContentScale(_:))
        contentOffsetXSlider.target = self
        contentOffsetXSlider.action = #selector(setContentOffsetX(_:))
        contentOffsetYSlider.target = self
        contentOffsetYSlider.action = #selector(setContentOffsetY(_:))
        speedPopup.target = self
        speedPopup.action = #selector(setSpeed(_:))
        volumePopup.target = self
        volumePopup.action = #selector(setVolume(_:))
        brightnessSlider.target = self
        brightnessSlider.action = #selector(setBrightness(_:))
        dimmingSlider.target = self
        dimmingSlider.action = #selector(setDimming(_:))
        contrastSlider.target = self
        contrastSlider.action = #selector(setContrast(_:))
        saturationSlider.target = self
        saturationSlider.action = #selector(setSaturation(_:))
        blurSlider.target = self
        blurSlider.action = #selector(setBlur(_:))
        hueSlider.target = self
        hueSlider.action = #selector(setHue(_:))
        vignetteSlider.target = self
        vignetteSlider.action = #selector(setVignette(_:))
        grainSlider.target = self
        grainSlider.action = #selector(setGrain(_:))
        continuePositionButton.target = self
        continuePositionButton.action = #selector(toggleContinuePosition(_:))
        cinematicLoopButton.target = self
        cinematicLoopButton.action = #selector(toggleCinematicLoop(_:))
        fpsPopup.target = self
        fpsPopup.action = #selector(setFPS(_:))
        economyButton.target = self
        economyButton.action = #selector(toggleEconomy(_:))
        pauseOnBatteryButton.target = self
        pauseOnBatteryButton.action = #selector(togglePauseOnBattery(_:))
        pauseOnLowBatteryButton.target = self
        pauseOnLowBatteryButton.action = #selector(togglePauseOnLowBattery(_:))
        pauseInFullscreenButton.target = self
        pauseInFullscreenButton.action = #selector(togglePauseInFullscreen(_:))
        pauseWhenCoveredButton.target = self
        pauseWhenCoveredButton.action = #selector(togglePauseWhenCovered(_:))
        pauseOnScreenLockButton.target = self
        pauseOnScreenLockButton.action = #selector(togglePauseOnScreenLock(_:))
        pauseHighLoadButton.target = self
        pauseHighLoadButton.action = #selector(togglePauseHighLoad(_:))
        pauseGamesCallsButton.target = self
        pauseGamesCallsButton.action = #selector(togglePauseGamesCalls(_:))
        autoQualityButton.target = self
        autoQualityButton.action = #selector(toggleAutoQuality(_:))
        warnHeavyFilesButton.target = self
        warnHeavyFilesButton.action = #selector(toggleWarnHeavy(_:))
        shuffleButton.target = self
        shuffleButton.action = #selector(toggleShuffle(_:))
        randomStartButton.target = self
        randomStartButton.action = #selector(toggleRandomStart(_:))
        rotationPopup.target = self
        rotationPopup.action = #selector(setRotation(_:))
        displaySourceModePopup.target = self
        displaySourceModePopup.action = #selector(setDisplaySourceMode(_:))
        syncPlaybackButton.target = self
        syncPlaybackButton.action = #selector(toggleSyncPlayback(_:))
        automationPresetPopup.target = self
        automationPresetPopup.action = #selector(applyAutomationPreset(_:))
        automationEnabledButton.target = self
        automationEnabledButton.action = #selector(toggleAutomation(_:))
        scheduleTimeButton.target = self
        scheduleTimeButton.action = #selector(toggleScheduleTime(_:))
        scheduleWeekdayButton.target = self
        scheduleWeekdayButton.action = #selector(toggleScheduleWeekday(_:))
        powerAutomationButton.target = self
        powerAutomationButton.action = #selector(togglePowerAutomation(_:))
        externalDisplayAutomationButton.target = self
        externalDisplayAutomationButton.action = #selector(toggleExternalDisplayAutomation(_:))
        homeWorkButton.target = self
        homeWorkButton.action = #selector(toggleHomeWork(_:))
    }

    private func refreshControls() {
        let settings = wallpaperController.settings
        let behavior = wallpaperController.behaviorSettings
        launchAtLoginButton.title = t("launch.login")
        restoreLastButton.title = t("launch.restore")
        continuePositionButton.title = t("continue.position")
        cinematicLoopButton.title = t("cinematic.loop")
        economyButton.title = t("economy.mode")
        pauseOnBatteryButton.title = t("pause.battery")
        pauseOnLowBatteryButton.title = t("pause.lowBattery")
        pauseInFullscreenButton.title = t("pause.fullscreen")
        pauseWhenCoveredButton.title = t("pause.covered")
        pauseOnScreenLockButton.title = t("pause.screenLock")
        pauseHighLoadButton.title = t("pause.highLoad")
        pauseGamesCallsButton.title = t("pause.gamesCalls")
        autoQualityButton.title = t("auto.quality")
        warnHeavyFilesButton.title = t("warn.heavy")
        shuffleButton.title = t("shuffle")
        randomStartButton.title = t("random.start")
        syncPlaybackButton.title = t("sync.playback")
        launchAtLoginButton.state = behavior.launchAtLogin ? .on : .off
        restoreLastButton.state = behavior.restoreLastWallpaperOnLaunch ? .on : .off
        displayModePopup.selectItem(withTag: settings.displayMode.rawValue)
        contentScaleSlider.doubleValue = settings.contentScale
        contentOffsetXSlider.doubleValue = settings.contentOffsetX
        contentOffsetYSlider.doubleValue = settings.contentOffsetY
        speedPopup.selectItem(withTag: Int(settings.playbackRate * 100))
        volumePopup.selectItem(withTag: Int(settings.volume * 100))
        brightnessSlider.doubleValue = settings.brightness
        dimmingSlider.doubleValue = settings.dimming
        contrastSlider.doubleValue = settings.contrast
        saturationSlider.doubleValue = settings.saturation
        blurSlider.doubleValue = settings.blurRadius
        hueSlider.doubleValue = settings.hueDegrees
        vignetteSlider.doubleValue = settings.vignette
        grainSlider.doubleValue = settings.grain
        continuePositionButton.state = settings.continuesFromLastPosition ? .on : .off
        cinematicLoopButton.state = settings.cinematicLoop ? .on : .off
        fpsPopup.selectItem(withTag: settings.fpsLimit.rawValue)
        economyButton.state = settings.isEconomyModeEnabled ? .on : .off
        pauseOnBatteryButton.state = behavior.pauseOnBattery ? .on : .off
        pauseOnLowBatteryButton.state = behavior.pauseOnLowBattery ? .on : .off
        pauseInFullscreenButton.state = behavior.pauseInFullscreen ? .on : .off
        pauseWhenCoveredButton.state = behavior.pauseWhenDesktopCovered ? .on : .off
        pauseOnScreenLockButton.state = behavior.pauseOnScreenLock ? .on : .off
        pauseHighLoadButton.state = behavior.pauseOnHighSystemLoad ? .on : .off
        pauseGamesCallsButton.state = behavior.pauseDuringGamesOrCalls ? .on : .off
        autoQualityButton.state = behavior.autoLowerQualityOnLoad ? .on : .off
        warnHeavyFilesButton.state = behavior.warnAboutHeavyFiles ? .on : .off
        shuffleButton.state = settings.isShuffleEnabled ? .on : .off
        randomStartButton.state = settings.startsAtRandomPosition ? .on : .off
        rotationPopup.selectItem(withTag: settings.rotationInterval.rawValue)
        displaySourceModePopup.selectItem(withTag: wallpaperController.displaySettings.sourceMode.rawValue)
        syncPlaybackButton.state = wallpaperController.displaySettings.synchronizePlayback ? .on : .off
        automationPresetPopup.selectItem(withTag: wallpaperController.currentAutomationPreset.rawValue)
        automationEnabledButton.state = wallpaperController.automationSettings.isEnabled ? .on : .off
        scheduleTimeButton.state = wallpaperController.automationSettings.scheduleByTimeOfDay ? .on : .off
        scheduleWeekdayButton.state = wallpaperController.automationSettings.scheduleByWeekday ? .on : .off
        powerAutomationButton.state = wallpaperController.automationSettings.changeOnPowerChange ? .on : .off
        externalDisplayAutomationButton.state = wallpaperController.automationSettings.changeOnExternalDisplay ? .on : .off
        homeWorkButton.state = wallpaperController.automationSettings.homeWorkProfilesEnabled ? .on : .off
        let automationChildren = [
            scheduleTimeButton,
            scheduleWeekdayButton,
            powerAutomationButton,
            externalDisplayAutomationButton,
            homeWorkButton
        ]
        automationChildren.forEach { $0.isEnabled = wallpaperController.automationSettings.isEnabled }
        refreshLanguageButtons()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            try wallpaperController.setLaunchAtLogin(!wallpaperController.behaviorSettings.launchAtLogin)
        } catch {
            showMessage(title: "Автозапуск не изменён", message: error.localizedDescription)
        }
        refreshControls()
        onChange()
    }

    @objc private func toggleRestoreLast(_ sender: Any?) {
        wallpaperController.setRestoreLastWallpaperOnLaunch(!wallpaperController.behaviorSettings.restoreLastWallpaperOnLaunch)
        refreshControls()
        onChange()
    }

    @objc private func setAppLanguage(_ sender: NSButton) {
        guard let language = AppLanguage.fromTag(sender.tag) else {
            return
        }

        wallpaperController.setAppLanguage(language)
        sectionViews.removeAll()
        selectSection(selectedSection)
        onChange()
    }

    @objc private func chooseVideoFromSettings(_ sender: Any?) {
        guard let url = VideoPicker.chooseVideo() else { return }
        guard VideoFileInspector.isPlayableVideo(url) else {
            showMessage(
                title: "Видео не читается",
                message: "Файл не удалось открыть как видео с видеодорожкой."
            )
            return
        }
        offerManualAutomationOverrideIfNeeded()
        wallpaperController.setSingleVideo(url)
        refreshControls()
        onChange()
    }

    @objc private func chooseImageFromSettings(_ sender: Any?) {
        guard let url = ImagePicker.chooseImage() else { return }
        guard ImageFileInspector.isReadableImage(url) else {
            showMessage(
                title: "Изображение не читается",
                message: "Файл не удалось открыть как изображение или GIF."
            )
            return
        }
        offerManualAutomationOverrideIfNeeded()
        wallpaperController.setImageWallpaper(url)
        refreshControls()
        onChange()
    }

    private func offerManualAutomationOverrideIfNeeded() {
        guard wallpaperController.shouldOfferManualAutomationOverride(),
              let option = ManualAutomationOverridePrompt.run() else {
            return
        }

        wallpaperController.applyManualAutomationOverride(option)
    }

    @objc private func setDisplayMode(_ sender: NSPopUpButton) {
        guard let mode = WallpaperDisplayMode(rawValue: sender.selectedTag()) else { return }
        wallpaperController.setDisplayMode(mode)
        onChange()
    }

    @objc private func setContentScale(_ sender: NSSlider) {
        wallpaperController.setContentScale(sender.doubleValue)
        displayModePopup.selectItem(withTag: WallpaperDisplayMode.manual.rawValue)
        onChange()
    }

    @objc private func setContentOffsetX(_ sender: NSSlider) {
        wallpaperController.setContentOffsetX(sender.doubleValue)
        displayModePopup.selectItem(withTag: WallpaperDisplayMode.manual.rawValue)
        onChange()
    }

    @objc private func setContentOffsetY(_ sender: NSSlider) {
        wallpaperController.setContentOffsetY(sender.doubleValue)
        displayModePopup.selectItem(withTag: WallpaperDisplayMode.manual.rawValue)
        onChange()
    }

    @objc private func setSpeed(_ sender: NSPopUpButton) {
        wallpaperController.setPlaybackRate(Double(sender.selectedTag()) / 100)
        onChange()
    }

    @objc private func setVolume(_ sender: NSPopUpButton) {
        wallpaperController.setVolume(Double(sender.selectedTag()) / 100)
        onChange()
    }

    @objc private func setBrightness(_ sender: NSSlider) {
        wallpaperController.setBrightness(sender.doubleValue)
        onChange()
    }

    @objc private func setDimming(_ sender: NSSlider) {
        wallpaperController.setDimming(sender.doubleValue)
        onChange()
    }

    @objc private func setContrast(_ sender: NSSlider) {
        wallpaperController.setContrast(sender.doubleValue)
        onChange()
    }

    @objc private func setSaturation(_ sender: NSSlider) {
        wallpaperController.setSaturation(sender.doubleValue)
        onChange()
    }

    @objc private func setBlur(_ sender: NSSlider) {
        wallpaperController.setBlurRadius(sender.doubleValue)
        onChange()
    }

    @objc private func setHue(_ sender: NSSlider) {
        wallpaperController.setHueDegrees(sender.doubleValue)
        onChange()
    }

    @objc private func setVignette(_ sender: NSSlider) {
        wallpaperController.setVignette(sender.doubleValue)
        onChange()
    }

    @objc private func setGrain(_ sender: NSSlider) {
        wallpaperController.setGrain(sender.doubleValue)
        onChange()
    }

    @objc private func toggleContinuePosition(_ sender: Any?) {
        wallpaperController.setContinueFromLastPosition(!wallpaperController.settings.continuesFromLastPosition)
        refreshControls()
        onChange()
    }

    @objc private func toggleCinematicLoop(_ sender: Any?) {
        wallpaperController.setCinematicLoop(!wallpaperController.settings.cinematicLoop)
        refreshControls()
        onChange()
    }

    @objc private func setFPS(_ sender: NSPopUpButton) {
        guard let fpsLimit = WallpaperFPSLimit(rawValue: sender.selectedTag()) else { return }
        wallpaperController.setFPSLimit(fpsLimit)
        onChange()
    }

    @objc private func toggleEconomy(_ sender: Any?) {
        wallpaperController.setEconomyMode(!wallpaperController.settings.isEconomyModeEnabled)
        refreshControls()
        onChange()
    }

    @objc private func togglePauseOnBattery(_ sender: Any?) {
        wallpaperController.setPauseOnBattery(!wallpaperController.behaviorSettings.pauseOnBattery)
        refreshControls()
        onChange()
    }

    @objc private func togglePauseOnLowBattery(_ sender: Any?) {
        wallpaperController.setPauseOnLowBattery(!wallpaperController.behaviorSettings.pauseOnLowBattery)
        refreshControls()
        onChange()
    }

    @objc private func togglePauseInFullscreen(_ sender: Any?) {
        wallpaperController.setPauseInFullscreen(!wallpaperController.behaviorSettings.pauseInFullscreen)
        refreshControls()
        onChange()
    }

    @objc private func togglePauseWhenCovered(_ sender: Any?) {
        wallpaperController.setPauseWhenDesktopCovered(!wallpaperController.behaviorSettings.pauseWhenDesktopCovered)
        refreshControls()
        onChange()
    }

    @objc private func togglePauseOnScreenLock(_ sender: Any?) {
        wallpaperController.setPauseOnScreenLock(!wallpaperController.behaviorSettings.pauseOnScreenLock)
        refreshControls()
        onChange()
    }

    @objc private func togglePauseHighLoad(_ sender: Any?) {
        wallpaperController.setPauseOnHighSystemLoad(!wallpaperController.behaviorSettings.pauseOnHighSystemLoad)
        refreshControls()
        onChange()
    }

    @objc private func togglePauseGamesCalls(_ sender: Any?) {
        wallpaperController.setPauseDuringGamesOrCalls(!wallpaperController.behaviorSettings.pauseDuringGamesOrCalls)
        refreshControls()
        onChange()
    }

    @objc private func toggleAutoQuality(_ sender: Any?) {
        wallpaperController.setAutoLowerQualityOnLoad(!wallpaperController.behaviorSettings.autoLowerQualityOnLoad)
        refreshControls()
        onChange()
    }

    @objc private func toggleWarnHeavy(_ sender: Any?) {
        wallpaperController.setWarnAboutHeavyFiles(!wallpaperController.behaviorSettings.warnAboutHeavyFiles)
        refreshControls()
        onChange()
    }

    @objc private func toggleShuffle(_ sender: Any?) {
        wallpaperController.setShuffle(!wallpaperController.settings.isShuffleEnabled)
        refreshControls()
        onChange()
    }

    @objc private func toggleRandomStart(_ sender: Any?) {
        wallpaperController.setRandomStart(!wallpaperController.settings.startsAtRandomPosition)
        refreshControls()
        onChange()
    }

    @objc private func setRotation(_ sender: NSPopUpButton) {
        guard let interval = WallpaperRotationInterval(rawValue: sender.selectedTag()) else { return }
        wallpaperController.setRotationInterval(interval)
        onChange()
    }

    @objc private func saveCollectionFromSettings(_ sender: Any?) {
        guard let name = TextPrompt.run(title: "Новая коллекция", message: "Название коллекции:", placeholder: "Work Mode") else {
            return
        }

        wallpaperController.saveCurrentAsCollection(named: name)
        onChange()
    }

    @objc private func setDisplaySourceMode(_ sender: NSPopUpButton) {
        guard let mode = WallpaperDisplaySourceMode(rawValue: sender.selectedTag()) else { return }
        wallpaperController.setDisplaySourceMode(mode)
        onChange()
    }

    @objc private func toggleSyncPlayback(_ sender: Any?) {
        wallpaperController.setSynchronizePlayback(!wallpaperController.displaySettings.synchronizePlayback)
        refreshControls()
        onChange()
    }

    @objc private func toggleAutomation(_ sender: Any?) {
        wallpaperController.setAutomationEnabled(!wallpaperController.automationSettings.isEnabled)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func applyAutomationPreset(_ sender: NSPopUpButton) {
        guard let preset = AutomationPreset(rawValue: sender.selectedTag()) else { return }
        wallpaperController.applyAutomationPreset(preset)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func toggleScheduleTime(_ sender: Any?) {
        wallpaperController.setScheduleByTimeOfDay(!wallpaperController.automationSettings.scheduleByTimeOfDay)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func toggleScheduleWeekday(_ sender: Any?) {
        wallpaperController.setScheduleByWeekday(!wallpaperController.automationSettings.scheduleByWeekday)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func togglePowerAutomation(_ sender: Any?) {
        wallpaperController.setChangeOnPowerChange(!wallpaperController.automationSettings.changeOnPowerChange)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func toggleExternalDisplayAutomation(_ sender: Any?) {
        wallpaperController.setChangeOnExternalDisplay(!wallpaperController.automationSettings.changeOnExternalDisplay)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func toggleHomeWork(_ sender: Any?) {
        wallpaperController.setHomeWorkProfilesEnabled(!wallpaperController.automationSettings.homeWorkProfilesEnabled)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func toggleAutomationRule(_ sender: NSButton) {
        guard let kind = AutomationRuleKind(rawValue: sender.tag) else {
            return
        }

        let currentlyEnabled = wallpaperController.automationSchedulePresentation.rules
            .first(where: { $0.kind == kind })?
            .isEnabled ?? false
        wallpaperController.setAutomationRule(kind, enabled: !currentlyEnabled)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func editAutomationRule(_ sender: NSButton) {
        guard let kind = AutomationRuleKind(rawValue: sender.tag),
              ScheduleRuleEditorPanel.run(kind: kind, controller: wallpaperController) else {
            return
        }

        rebuildSection(.automation)
        onChange()
    }

    @objc private func addFirstAutomationRule(_ sender: Any?) {
        guard ScheduleRuleEditorPanel.run(kind: .timeOfDay, controller: wallpaperController) else {
            return
        }

        rebuildSection(.automation)
        onChange()
    }

    @objc private func applyAutomationTemplate(_ sender: NSButton) {
        guard let template = AutomationTemplateKind(rawValue: sender.tag) else {
            return
        }

        wallpaperController.applyAutomationTemplate(template)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func applyAutomationOverride(_ sender: NSButton) {
        guard let option = AutomationOverrideOption(rawValue: sender.tag) else {
            return
        }

        wallpaperController.applyManualAutomationOverride(option)
        rebuildSection(.automation)
        onChange()
    }

    @objc private func clearAutomationOverride(_ sender: Any?) {
        wallpaperController.clearManualAutomationOverride()
        rebuildSection(.automation)
        onChange()
    }

    @objc private func restoreSystemWallpaper(_ sender: Any?) {
        wallpaperController.restoreSystemWallpaperNow()
        refreshControls()
        onChange()
    }

    @objc private func clearCache(_ sender: Any?) {
        wallpaperController.clearCache()
    }

    @objc private func importPresetFromSettings(_ sender: Any?) {
        guard let url = PresetFilePanel.chooseImportURL() else { return }
        do {
            try wallpaperController.importPreset(from: url)
        } catch {
            showMessage(title: "Импорт не выполнен", message: error.localizedDescription)
            return
        }
        refreshControls()
        onChange()
    }

    @objc private func exportPresetFromSettings(_ sender: Any?) {
        guard let url = PresetFilePanel.chooseExportURL() else { return }
        do {
            try wallpaperController.exportPreset(to: url)
        } catch {
            showMessage(title: "Экспорт не выполнен", message: error.localizedDescription)
        }
    }

    @objc private func resetAll(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Сбросить настройки Live Wallpapers for Mac?"
        alert.informativeText = "Настройки, последний источник и LaunchAgent автозапуска будут сброшены. Текущий системный фон будет восстановлен."
        alert.addButton(withTitle: "Сбросить")
        alert.addButton(withTitle: "Отмена")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        wallpaperController.resetAllSettings()
        refreshControls()
        onChange()
    }

    @objc private func openSupportLink(_ sender: Any?) {
        guard let url = URL(string: "https://www.donationalerts.com/r/medusa411") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    @objc private func openCreatorXLink(_ sender: Any?) {
        guard let url = URL(string: "https://x.com/Bubblegumbbbbb") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        AppUpdateUI.checkForUpdates()
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

final class DropImportView: NSView {
    private let wallpaperController: WallpaperController
    private let onChange: () -> Void
    private let label: NSTextField

    init(wallpaperController: WallpaperController, onChange: @escaping () -> Void, title: String) {
        self.wallpaperController = wallpaperController
        self.onChange = onChange
        self.label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 88))

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 520),
            heightAnchor.constraint(equalToConstant: 88),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL] ?? []

        guard !urls.isEmpty else {
            return false
        }

        wallpaperController.importDroppedURLs(urls)
        onChange()
        return true
    }
}

struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let htmlURL: URL
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case prerelease
        case draft
        case assets
    }
}

enum AppUpdateStatus {
    case upToDate(currentVersion: String, release: GitHubReleaseResponse)
    case updateAvailable(currentVersion: String, releaseVersion: String, release: GitHubReleaseResponse)
}

enum AppUpdateChecker {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/medusa4111/LiveWallpapersForMac/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func check(completion: @escaping (Result<AppUpdateStatus, Error>) -> Void) {
        var request = URLRequest(url: latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppBrand.displayName) Update Checker", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data else {
                completion(.failure(updateError("GitHub не вернул ответ.")))
                return
            }

            guard httpResponse.statusCode == 200 else {
                let message = httpResponse.statusCode == 404
                    ? "В репозитории пока нет опубликованных GitHub Releases."
                    : "GitHub вернул HTTP \(httpResponse.statusCode)."
                completion(.failure(updateError(message)))
                return
            }

            do {
                let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
                let releaseVersion = normalizedVersion(release.tagName)
                let installedVersion = normalizedVersion(Self.currentVersion)
                if compareVersions(releaseVersion, installedVersion) == .orderedDescending {
                    completion(.success(.updateAvailable(
                        currentVersion: installedVersion,
                        releaseVersion: releaseVersion,
                        release: release
                    )))
                } else {
                    completion(.success(.upToDate(currentVersion: installedVersion, release: release)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.drop { $0 == "v" || $0 == "V" }
        let numericPrefix = withoutPrefix.prefix { $0.isNumber || $0 == "." }
        return numericPrefix.isEmpty ? trimmed : String(numericPrefix)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue {
                return .orderedAscending
            }
            if leftValue > rightValue {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { part in
                let numeric = part.prefix { $0.isNumber }
                return Int(numeric) ?? 0
            }
    }

    private static func updateError(_ message: String) -> NSError {
        NSError(
            domain: AppBrand.errorDomain,
            code: 30,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum AppUpdateUI {
    static func checkForUpdates() {
        AppUpdateChecker.check { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let status):
                    show(status: status)
                case .failure(let error):
                    showError(error)
                }
            }
        }
    }

    private static func show(status: AppUpdateStatus) {
        let alert = NSAlert()
        switch status {
        case .upToDate(let currentVersion, let release):
            alert.messageText = "Обновлений нет"
            alert.informativeText = "Установлена версия \(currentVersion). Последний релиз на GitHub: \(release.tagName)."
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .updateAvailable(let currentVersion, let releaseVersion, let release):
            let assetLine = release.assets.first.map { "\nФайл релиза: \($0.name)" } ?? ""
            alert.messageText = "Доступно обновление \(releaseVersion)"
            alert.informativeText = "Установлена версия \(currentVersion). Откройте GitHub Release и установите сборку через подписанный релизный архив.\(assetLine)"
            alert.addButton(withTitle: "Открыть GitHub")
            alert.addButton(withTitle: "Позже")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.htmlURL)
            }
        }
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Проверка обновлений не выполнена"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum StartupArguments {
    static var openSettings: Bool {
        CommandLine.arguments.contains("--settings")
    }

    static var videoURL: URL? {
        guard let path = stringValue(after: "--video") else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    static var imageURL: URL? {
        guard let path = stringValue(after: "--image") else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    static var trim: VideoTrim {
        VideoTrim(
            startSeconds: doubleValue(after: "--trim-start"),
            endSeconds: doubleValue(after: "--trim-end")
        )
    }

    private static func doubleValue(after marker: String) -> Double {
        guard let rawValue = stringValue(after: marker),
              let value = Double(rawValue) else {
            return 0
        }

        return max(0, value)
    }

    private static func stringValue(after marker: String) -> String? {
        let arguments = CommandLine.arguments
        guard let markerIndex = arguments.firstIndex(of: marker) else {
            return nil
        }

        let valueIndex = arguments.index(after: markerIndex)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }

        return arguments[valueIndex]
    }
}

enum WallpaperDisplayMode: Int, CaseIterable, Codable {
    case fill
    case fit
    case stretch
    case center
    case crop
    case manual

    var title: String {
        switch self {
        case .fill:
            return "Заполнить экран"
        case .fit:
            return "Вписать целиком"
        case .stretch:
            return "Растянуть"
        case .center:
            return "По центру"
        case .crop:
            return "Обрезать по краям"
        case .manual:
            return "Ручной масштаб"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill, .crop:
            return .resizeAspectFill
        case .fit, .center, .manual:
            return .resizeAspect
        case .stretch:
            return .resize
        }
    }

    var imageScaling: NSImageScaling {
        switch self {
        case .fill, .fit, .center, .crop, .manual:
            return .scaleProportionallyUpOrDown
        case .stretch:
            return .scaleAxesIndependently
        }
    }
}

enum WallpaperFPSLimit: Int, CaseIterable, Codable {
    case source = 0
    case fps15 = 15
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var title: String {
        switch self {
        case .source:
            return "Как в видео"
        case .fps15:
            return "15 FPS"
        case .fps24:
            return "24 FPS"
        case .fps30:
            return "30 FPS"
        case .fps60:
            return "60 FPS"
        }
    }

    func capped(by other: WallpaperFPSLimit) -> WallpaperFPSLimit {
        guard self != .source else { return other }
        guard other != .source else { return self }
        return rawValue <= other.rawValue ? self : other
    }
}

enum WallpaperRotationInterval: Int, CaseIterable, Codable {
    case manual = 0
    case fiveMinutes = 300
    case thirtyMinutes = 1800
    case oneHour = 3600

    var title: String {
        switch self {
        case .manual:
            return "Вручную"
        case .fiveMinutes:
            return "5 минут"
        case .thirtyMinutes:
            return "30 минут"
        case .oneHour:
            return "1 час"
        }
    }

    var timeInterval: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }
}

enum WallpaperProfile: Int, CaseIterable, Codable {
    case performance
    case batterySaver
    case cinematic
    case work
    case gaming
    case night
    case custom

    var title: String {
        switch self {
        case .performance:
            return "Performance"
        case .batterySaver:
            return "Battery Saver"
        case .cinematic:
            return "Cinematic"
        case .work:
            return "Work"
        case .gaming:
            return "Gaming"
        case .night:
            return "Night"
        case .custom:
            return "Custom"
        }
    }

    func apply(to settings: inout WallpaperPlaybackSettings, behavior: inout WallpaperBehaviorSettings) {
        guard self != .custom else {
            return
        }

        settings.contentScale = 1
        settings.contentOffsetX = 0
        settings.contentOffsetY = 0
        settings.contrast = 1
        settings.saturation = 1
        settings.blurRadius = 0
        settings.hueDegrees = 0
        settings.vignette = 0
        settings.grain = 0

        switch self {
        case .performance:
            settings.isEconomyModeEnabled = false
            settings.fpsLimit = .fps60
            settings.playbackRate = 1
            settings.brightness = 1
            settings.dimming = 0
            behavior.pauseOnBattery = false
            behavior.pauseInFullscreen = true

        case .batterySaver:
            settings.isEconomyModeEnabled = true
            settings.fpsLimit = .fps15
            settings.playbackRate = 0.75
            settings.brightness = 0.7
            settings.dimming = 0.3
            behavior.pauseOnBattery = true
            behavior.pauseOnLowBattery = true
            behavior.pauseInFullscreen = true

        case .cinematic:
            settings.isEconomyModeEnabled = false
            settings.fpsLimit = .fps30
            settings.playbackRate = 1
            settings.brightness = 0.85
            settings.dimming = 0.15
            behavior.pauseOnBattery = false
            behavior.pauseInFullscreen = true

        case .work:
            settings.isEconomyModeEnabled = true
            settings.fpsLimit = .fps24
            settings.playbackRate = 0.75
            settings.volume = 0
            settings.brightness = 0.55
            settings.dimming = 0.45
            settings.saturation = 0.75
            settings.vignette = 0.2
            behavior.pauseOnBattery = true
            behavior.pauseInFullscreen = true

        case .gaming:
            settings.isEconomyModeEnabled = true
            settings.fpsLimit = .fps15
            settings.playbackRate = 0.5
            settings.volume = 0
            settings.brightness = 0.4
            settings.dimming = 0.6
            settings.saturation = 0.65
            settings.blurRadius = 1.5
            settings.vignette = 0.35
            behavior.pauseOnBattery = true
            behavior.pauseInFullscreen = true

        case .night:
            settings.isEconomyModeEnabled = true
            settings.fpsLimit = .fps15
            settings.playbackRate = 0.5
            settings.volume = 0
            settings.brightness = 0.4
            settings.dimming = 0.6
            settings.contrast = 0.85
            settings.saturation = 0.55
            settings.vignette = 0.45
            behavior.pauseOnBattery = false
            behavior.pauseInFullscreen = true

        case .custom:
            break
        }
    }
}

struct VideoTrim: Codable {
    var startSeconds: Double = 0
    var endSeconds: Double = 0
}

struct WallpaperPlaybackSettings: Codable {
    var displayMode: WallpaperDisplayMode = .fill
    var contentScale: Double = 1
    var contentOffsetX: Double = 0
    var contentOffsetY: Double = 0
    var playbackRate: Double = 1
    var volume: Double = 0
    var brightness: Double = 1
    var dimming: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var blurRadius: Double = 0
    var hueDegrees: Double = 0
    var vignette: Double = 0
    var grain: Double = 0
    var fpsLimit: WallpaperFPSLimit = .source
    var isEconomyModeEnabled = false
    var isShuffleEnabled = false
    var startsAtRandomPosition = false
    var continuesFromLastPosition = false
    var cinematicLoop = false
    var rotationInterval: WallpaperRotationInterval = .manual
    var trim = VideoTrim()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayMode = try container.decodeIfPresent(WallpaperDisplayMode.self, forKey: .displayMode) ?? .fill
        contentScale = try container.decodeIfPresent(Double.self, forKey: .contentScale) ?? 1
        contentOffsetX = try container.decodeIfPresent(Double.self, forKey: .contentOffsetX) ?? 0
        contentOffsetY = try container.decodeIfPresent(Double.self, forKey: .contentOffsetY) ?? 0
        playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 1
        dimming = try container.decodeIfPresent(Double.self, forKey: .dimming) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0
        hueDegrees = try container.decodeIfPresent(Double.self, forKey: .hueDegrees) ?? 0
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        fpsLimit = try container.decodeIfPresent(WallpaperFPSLimit.self, forKey: .fpsLimit) ?? .source
        isEconomyModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEconomyModeEnabled) ?? false
        isShuffleEnabled = try container.decodeIfPresent(Bool.self, forKey: .isShuffleEnabled) ?? false
        startsAtRandomPosition = try container.decodeIfPresent(Bool.self, forKey: .startsAtRandomPosition) ?? false
        continuesFromLastPosition = try container.decodeIfPresent(Bool.self, forKey: .continuesFromLastPosition) ?? false
        cinematicLoop = try container.decodeIfPresent(Bool.self, forKey: .cinematicLoop) ?? false
        rotationInterval = try container.decodeIfPresent(WallpaperRotationInterval.self, forKey: .rotationInterval) ?? .manual
        trim = try container.decodeIfPresent(VideoTrim.self, forKey: .trim) ?? VideoTrim()
    }

    var effectivePlaybackRate: Double {
        isEconomyModeEnabled ? min(playbackRate, 0.75) : playbackRate
    }

    var effectiveBrightness: Double {
        isEconomyModeEnabled ? min(brightness, 0.75) : brightness
    }

    var effectiveDimming: Double {
        isEconomyModeEnabled ? max(dimming, 0.25) : dimming
    }

    var effectiveContentScale: Double {
        min(max(contentScale, 0.25), 3)
    }

    var effectiveContentOffsetX: Double {
        min(max(contentOffsetX, -0.5), 0.5)
    }

    var effectiveContentOffsetY: Double {
        min(max(contentOffsetY, -0.5), 0.5)
    }

    var effectiveContrast: Double {
        min(max(contrast, 0.5), 1.8)
    }

    var effectiveSaturation: Double {
        min(max(saturation, 0), 2)
    }

    var effectiveBlurRadius: Double {
        min(max(blurRadius, 0), 20)
    }

    var effectiveHueRadians: Double {
        min(max(hueDegrees, -180), 180) * .pi / 180
    }

    var effectiveVignette: Double {
        min(max(vignette, 0), 1)
    }

    var effectiveGrain: Double {
        min(max(grain, 0), 1)
    }

    var effectiveFPSLimit: WallpaperFPSLimit {
        isEconomyModeEnabled ? fpsLimit.capped(by: .fps15) : fpsLimit
    }
}

enum AppLanguage: String, Codable, CaseIterable {
    case russian = "ru"
    case englishUS = "en-US"
    case polish = "pl"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var title: String {
        switch self {
        case .russian:
            return "Русский"
        case .englishUS:
            return "English (US)"
        case .polish:
            return "Polski"
        case .simplifiedChinese:
            return "简体中文"
        case .traditionalChinese:
            return "繁體中文"
        }
    }

    var subtitle: String {
        switch self {
        case .russian:
            return "RU"
        case .englishUS:
            return "US"
        case .polish:
            return "PL"
        case .simplifiedChinese:
            return "简"
        case .traditionalChinese:
            return "繁"
        }
    }

    var tag: Int {
        AppLanguage.allCases.firstIndex(of: self) ?? 0
    }

    static func fromTag(_ tag: Int) -> AppLanguage? {
        guard AppLanguage.allCases.indices.contains(tag) else {
            return nil
        }

        return AppLanguage.allCases[tag]
    }
}

enum AppLocalization {
    static func text(_ key: String, language: AppLanguage) -> String {
        translations[language]?[key] ?? translations[.russian]?[key] ?? key
    }

    private static let translations: [AppLanguage: [String: String]] = [
        .russian: [
            "section.general": "Основное",
            "section.wallpaper": "Обои",
            "section.displays": "Мониторы",
            "section.performance": "Ресурсы",
            "section.playlists": "Плейлисты",
            "section.automation": "Автоматизация",
            "section.hotkeys": "Клавиши",
            "section.service": "Сервис",
            "section.creators": "Создатели",
            "subtitle.general": "Запуск приложения и быстрый выбор источника.",
            "subtitle.wallpaper": "Масштаб, скорость, цветокоррекция и визуальные эффекты.",
            "subtitle.displays": "Поведение на одном или нескольких мониторах.",
            "subtitle.performance": "Баланс плавности, нагрузки и умной паузы.",
            "subtitle.playlists": "Случайный порядок, таймер и коллекции.",
            "subtitle.automation": "Готовые сценарии и правила смены профилей.",
            "subtitle.hotkeys": "Глобальные быстрые действия.",
            "subtitle.service": "Импорт, экспорт, очистка и восстановление.",
            "subtitle.creators": "Кто делает Live Wallpapers for Mac и как поддержать развитие.",
            "group.language": "Язык",
            "language.help": "Выбор применяется к окну настроек сразу и сохраняется в Live Wallpapers for Mac.",
            "group.launch": "Запуск",
            "group.sources": "Источники",
            "launch.login": "Автозапуск при входе",
            "launch.restore": "Запускать последний фон",
            "button.video": "Видео...",
            "button.imageGif": "Изображение / GIF...",
            "menu.chooseVideo": "Выбрать видео...",
            "menu.chooseVideoFolder": "Выбрать папку с видео...",
            "menu.turnOffWallpaper": "Выключить обои",
            "menu.turnOnWallpaper": "Включить обои",
            "menu.pause": "Пауза",
            "menu.resume": "Продолжить",
            "menu.previousWallpaper": "Предыдущий фон",
            "menu.nextWallpaper": "Следующий фон",
            "menu.trimVideo": "Обрезка видео...",
            "menu.openSettings": "Открыть настройки...",
            "menu.quit": "Закрыть",
            "menu.addFavorite": "Добавить в избранное",
            "menu.removeFavorite": "Убрать из избранного",
            "menu.currentWeight": "Вес текущего фона...",
            "menu.currentWeightValue": "Вес текущего фона: %d...",
            "menu.favorites": "Избранное",
            "menu.recent": "Недавние",
            "menu.chooseCollection": "Выбрать коллекцию",
            "menu.noCollections": "Нет коллекций",
            "menu.empty": "Пусто",
            "menu.profiles": "Профили",
            "menu.sourceInfo": "Информация о текущем источнике",
            "menu.openLog": "Открыть лог ошибок",
            "menu.checkUpdates": "Проверить обновления...",
            "drop.import": "Перетащите сюда видео, папку, GIF/изображение или JSON-пресет",
            "group.placement": "Размещение",
            "group.playback": "Воспроизведение",
            "group.appearance": "Вид",
            "row.scale": "Масштаб",
            "row.manualScale": "Ручной масштаб",
            "row.offsetX": "Смещение X",
            "row.offsetY": "Смещение Y",
            "row.speed": "Скорость",
            "row.sound": "Звук",
            "volume.off": "Выкл",
            "displayMode.fill": "Заполнить экран",
            "displayMode.fit": "Вписать целиком",
            "displayMode.stretch": "Растянуть",
            "displayMode.center": "По центру",
            "displayMode.crop": "Обрезать по краям",
            "displayMode.manual": "Ручной масштаб",
            "row.brightness": "Яркость",
            "row.dimming": "Затемнение",
            "row.contrast": "Контраст",
            "row.saturation": "Насыщенность",
            "row.blur": "Размытие",
            "row.hue": "Оттенок",
            "row.vignette": "Виньетка",
            "row.grain": "Зерно",
            "continue.position": "Продолжать с последней позиции",
            "cinematic.loop": "Cinematic loop fade",
            "group.displayBehavior": "Поведение экранов",
            "row.displays": "Мониторы",
            "displaySource.same": "Один фон на все экраны",
            "displaySource.playlist": "Разные видео из плейлиста",
            "sync.playback": "Синхронное воспроизведение",
            "group.quality": "Качество",
            "group.autopause": "Автопауза",
            "fps.source": "Как в видео",
            "economy.mode": "Экономичный режим",
            "pause.battery": "Пауза от батареи",
            "pause.lowBattery": "Пауза ниже 20%",
            "pause.fullscreen": "Пауза в полноэкранных приложениях",
            "pause.covered": "Пауза, когда рабочий стол закрыт",
            "pause.screenLock": "Пауза при блокировке экрана",
            "pause.highLoad": "Пауза при высокой нагрузке",
            "pause.gamesCalls": "Пауза при играх и звонках",
            "auto.quality": "Автоснижение качества при нагрузке",
            "warn.heavy": "Предупреждать о тяжёлых видео",
            "group.rotation": "Ротация",
            "group.collections": "Коллекции",
            "shuffle": "Случайный порядок",
            "random.start": "Случайный старт видео",
            "row.rotationTimer": "Смена по таймеру",
            "rotation.manual": "Вручную",
            "rotation.fiveMinutes": "5 минут",
            "rotation.thirtyMinutes": "30 минут",
            "rotation.oneHour": "1 час",
            "button.saveCollection": "Сохранить текущий набор как коллекцию...",
            "group.hotkeys": "Быстрые действия",
            "group.system": "Система",
            "group.presets": "Пресеты",
            "group.danger": "Опасная зона",
            "button.restoreWallpaper": "Восстановить фон",
            "button.clearCache": "Очистить кэш",
            "button.checkUpdates": "Проверить обновления...",
            "button.import": "Импорт...",
            "button.export": "Экспорт...",
            "button.resetAll": "Сбросить всё",
            "creators.madeBy": "Создатель",
            "creators.description": "Спасибо за использование Live Wallpapers for Mac. Новости и связь с создателем: https://x.com/Bubblegumbbbbb",
            "creators.support": "Поддержать",
            "creators.x": "X: @Bubblegumbbbbb",
            "automation.activeGroup": "Активно сейчас",
            "automation.activeNow": "Активно сейчас",
            "automation.applied": "Применено",
            "automation.reason": "Почему",
            "automation.nextChange": "Следующее изменение",
            "automation.noActive": "Сейчас нет активного правила расписания.",
            "automation.enableHint": "Включите правило или примените шаблон, чтобы запустить автоматизацию.",
            "automation.offHint": "Автоматизация расписаний сейчас выключена.",
            "automation.upcoming": "Ближайшие изменения",
            "automation.upcomingNone": "В ближайшие 24 часа нет изменений по времени. Правила питания и мониторов сработают при изменении состояния системы.",
            "automation.preview24": "Следующие 24 часа",
            "automation.priorityHelp": "Карточки выше имеют более высокий приоритет, если активно несколько правил. Это повторяет текущий порядок движка и сохраняет совместимость старых расписаний.",
            "automation.rules": "Правила",
            "automation.emptyGroup": "Пустое расписание",
            "automation.emptyTitle": "Расписания автоматически меняют живые обои.",
            "automation.emptyDescription": "Начните с одного понятного правила или примените шаблон и отредактируйте созданные правила.",
            "automation.addFirst": "Добавить первое правило",
            "automation.dayNightTemplate": "Шаблон День / ночь",
            "automation.templates": "Шаблоны",
            "automation.templatesHelp": "Шаблоны создают обычные редактируемые правила и не меняют формат сохранённых настроек.",
            "automation.override": "Ручное переопределение",
            "automation.overrideHelp": "Когда вы вручную выбираете фон при включённом расписании, временное переопределение помогает предсказуемо вернуться к автоматизации.",
            "automation.untilNext": "До следующего изменения",
            "automation.minutes30": "30 минут",
            "automation.hour1": "1 час",
            "automation.disableSchedule": "Выключить расписание",
            "automation.overrideActive": "Ручное переопределение активно",
            "automation.resumeNow": "Вернуться к расписанию сейчас",
            "automation.badgeActive": "Активно",
            "automation.enabled": "Вкл",
            "automation.disabled": "Выкл",
            "automation.next": "Дальше",
            "automation.edit": "Изменить",
            "automation.template.dayNight": "День / ночь",
            "automation.template.workday": "Рабочий день",
            "automation.template.batterySaver": "Экономия батареи",
            "automation.template.gaming": "Игровой режим",
            "automation.template.dayNight.subtitle": "Профили для утра, дня, вечера и ночи.",
            "automation.template.workday.subtitle": "Work в рабочие часы, Cinematic после работы.",
            "automation.template.batterySaver.subtitle": "Battery Saver от батареи, Cinematic от зарядки.",
            "automation.template.gaming.subtitle": "Сразу включает Gaming и оставляет расписание ручным.",
            "hotkey.toggleWallpaper": "Включить / выключить обои",
            "hotkey.pause": "Пауза / запуск",
            "hotkey.previous": "Предыдущий фон",
            "hotkey.next": "Следующий фон",
            "hotkey.economy": "Экономичный режим",
            "hotkey.menu": "Открыть меню"
        ],
        .englishUS: [
            "section.general": "General",
            "section.wallpaper": "Wallpaper",
            "section.displays": "Displays",
            "section.performance": "Performance",
            "section.playlists": "Playlists",
            "section.automation": "Automation",
            "section.hotkeys": "Hotkeys",
            "section.service": "Service",
            "section.creators": "Creators",
            "subtitle.general": "App startup and quick source selection.",
            "subtitle.wallpaper": "Scale, speed, color correction and visual effects.",
            "subtitle.displays": "Behavior on one or multiple displays.",
            "subtitle.performance": "Balance smoothness, load and smart pause.",
            "subtitle.playlists": "Shuffle, timers and collections.",
            "subtitle.automation": "Ready scenarios and profile switching rules.",
            "subtitle.hotkeys": "Global quick actions.",
            "subtitle.service": "Import, export, cleanup and recovery.",
            "subtitle.creators": "Who builds Live Wallpapers for Mac and how to support development.",
            "group.language": "Language",
            "language.help": "The choice applies to Settings immediately and is saved in Live Wallpapers for Mac.",
            "group.launch": "Startup",
            "group.sources": "Sources",
            "launch.login": "Launch at login",
            "launch.restore": "Restore last wallpaper on launch",
            "button.video": "Video...",
            "button.imageGif": "Image / GIF...",
            "menu.chooseVideo": "Choose video...",
            "menu.chooseVideoFolder": "Choose video folder...",
            "menu.turnOffWallpaper": "Turn wallpaper off",
            "menu.turnOnWallpaper": "Turn wallpaper on",
            "menu.pause": "Pause",
            "menu.resume": "Resume",
            "menu.previousWallpaper": "Previous wallpaper",
            "menu.nextWallpaper": "Next wallpaper",
            "menu.trimVideo": "Trim video...",
            "menu.openSettings": "Open Settings...",
            "menu.quit": "Quit",
            "menu.addFavorite": "Add to favorites",
            "menu.removeFavorite": "Remove from favorites",
            "menu.currentWeight": "Current wallpaper weight...",
            "menu.currentWeightValue": "Current wallpaper weight: %d...",
            "menu.favorites": "Favorites",
            "menu.recent": "Recent",
            "menu.chooseCollection": "Choose collection",
            "menu.noCollections": "No collections",
            "menu.empty": "Empty",
            "menu.profiles": "Profiles",
            "menu.sourceInfo": "Current source info",
            "menu.openLog": "Open error log",
            "menu.checkUpdates": "Check for Updates...",
            "drop.import": "Drop a video, folder, GIF/image or JSON preset here",
            "group.placement": "Placement",
            "group.playback": "Playback",
            "group.appearance": "Appearance",
            "row.scale": "Scale",
            "row.manualScale": "Manual scale",
            "row.offsetX": "Offset X",
            "row.offsetY": "Offset Y",
            "row.speed": "Speed",
            "row.sound": "Sound",
            "volume.off": "Off",
            "displayMode.fill": "Fill screen",
            "displayMode.fit": "Fit entirely",
            "displayMode.stretch": "Stretch",
            "displayMode.center": "Center",
            "displayMode.crop": "Crop edges",
            "displayMode.manual": "Manual scale",
            "row.brightness": "Brightness",
            "row.dimming": "Dimming",
            "row.contrast": "Contrast",
            "row.saturation": "Saturation",
            "row.blur": "Blur",
            "row.hue": "Hue",
            "row.vignette": "Vignette",
            "row.grain": "Grain",
            "continue.position": "Continue from last position",
            "cinematic.loop": "Cinematic loop fade",
            "group.displayBehavior": "Display behavior",
            "row.displays": "Displays",
            "displaySource.same": "One wallpaper on all displays",
            "displaySource.playlist": "Different playlist videos",
            "sync.playback": "Synchronized playback",
            "group.quality": "Quality",
            "group.autopause": "Auto pause",
            "fps.source": "Same as video",
            "economy.mode": "Economy mode",
            "pause.battery": "Pause on battery",
            "pause.lowBattery": "Pause below 20%",
            "pause.fullscreen": "Pause in fullscreen apps",
            "pause.covered": "Pause when desktop is covered",
            "pause.screenLock": "Pause when screen is locked",
            "pause.highLoad": "Pause on high load",
            "pause.gamesCalls": "Pause during games and calls",
            "auto.quality": "Lower quality automatically on load",
            "warn.heavy": "Warn about heavy videos",
            "group.rotation": "Rotation",
            "group.collections": "Collections",
            "shuffle": "Shuffle",
            "random.start": "Random video start",
            "row.rotationTimer": "Timed change",
            "rotation.manual": "Manual",
            "rotation.fiveMinutes": "5 minutes",
            "rotation.thirtyMinutes": "30 minutes",
            "rotation.oneHour": "1 hour",
            "button.saveCollection": "Save current set as collection...",
            "group.hotkeys": "Quick actions",
            "group.system": "System",
            "group.presets": "Presets",
            "group.danger": "Danger zone",
            "button.restoreWallpaper": "Restore wallpaper",
            "button.clearCache": "Clear cache",
            "button.checkUpdates": "Check for Updates...",
            "button.import": "Import...",
            "button.export": "Export...",
            "button.resetAll": "Reset all",
            "creators.madeBy": "Created by",
            "creators.description": "Thank you for using Live Wallpapers for Mac. News and contact: https://x.com/Bubblegumbbbbb",
            "creators.support": "Support",
            "creators.x": "X: @Bubblegumbbbbb",
            "automation.activeGroup": "Active now",
            "automation.activeNow": "Active now",
            "automation.applied": "Applied",
            "automation.reason": "Reason",
            "automation.nextChange": "Next change",
            "automation.noActive": "No schedule rule is active right now.",
            "automation.enableHint": "Enable a rule or apply a template to start automation.",
            "automation.offHint": "Schedule automation is currently turned off.",
            "automation.upcoming": "Upcoming changes",
            "automation.upcomingNone": "No timed changes in the next 24 hours. Power and display rules apply when those system states change.",
            "automation.preview24": "Next 24 hours",
            "automation.priorityHelp": "Higher cards have higher priority when multiple rules are active. This mirrors the existing automation engine and keeps old schedules compatible.",
            "automation.rules": "Rules",
            "automation.emptyGroup": "Empty schedule",
            "automation.emptyTitle": "Schedules change your live wallpaper automatically.",
            "automation.emptyDescription": "Start with one clear rule, or use a template and edit the generated rules afterwards.",
            "automation.addFirst": "Add first rule",
            "automation.dayNightTemplate": "Day / Night template",
            "automation.templates": "Templates",
            "automation.templatesHelp": "Templates create normal editable rules and do not change the saved settings format.",
            "automation.override": "Manual override",
            "automation.overrideHelp": "When you choose wallpaper manually while schedule is enabled, temporary override lets automation resume predictably.",
            "automation.untilNext": "Until next change",
            "automation.minutes30": "30 minutes",
            "automation.hour1": "1 hour",
            "automation.disableSchedule": "Disable schedule",
            "automation.overrideActive": "Manual override is active",
            "automation.resumeNow": "Resume schedule now",
            "automation.badgeActive": "Active",
            "automation.enabled": "On",
            "automation.disabled": "Off",
            "automation.next": "Next",
            "automation.edit": "Edit",
            "automation.template.dayNight": "Day / Night",
            "automation.template.workday": "Workday",
            "automation.template.batterySaver": "Battery saver",
            "automation.template.gaming": "Gaming mode",
            "automation.template.dayNight.subtitle": "Profiles for morning, day, evening and night.",
            "automation.template.workday.subtitle": "Work during office hours, Cinematic after work.",
            "automation.template.batterySaver.subtitle": "Battery Saver on battery, Cinematic when charging.",
            "automation.template.gaming.subtitle": "Applies Gaming immediately and leaves schedule manual.",
            "hotkey.toggleWallpaper": "Turn wallpaper on / off",
            "hotkey.pause": "Pause / play",
            "hotkey.previous": "Previous wallpaper",
            "hotkey.next": "Next wallpaper",
            "hotkey.economy": "Economy mode",
            "hotkey.menu": "Open menu"
        ],
        .polish: [
            "section.general": "Ogólne",
            "section.wallpaper": "Tapeta",
            "section.displays": "Monitory",
            "section.performance": "Zasoby",
            "section.playlists": "Playlisty",
            "section.automation": "Automatyzacja",
            "section.hotkeys": "Skróty",
            "section.service": "Serwis",
            "section.creators": "Twórcy",
            "subtitle.general": "Start aplikacji i szybki wybór źródła.",
            "subtitle.wallpaper": "Skala, szybkość, korekcja koloru i efekty.",
            "subtitle.displays": "Zachowanie na jednym lub wielu monitorach.",
            "subtitle.performance": "Równowaga płynności, obciążenia i pauzy.",
            "subtitle.playlists": "Losowanie, timer i kolekcje.",
            "subtitle.automation": "Gotowe scenariusze i reguły profili.",
            "subtitle.hotkeys": "Globalne szybkie akcje.",
            "subtitle.service": "Import, eksport, czyszczenie i odzyskiwanie.",
            "subtitle.creators": "Kto tworzy Live Wallpapers for Mac i jak wesprzeć rozwój.",
            "group.language": "Język",
            "language.help": "Wybór od razu zmienia Ustawienia i zapisuje się w Live Wallpapers for Mac.",
            "group.launch": "Uruchamianie",
            "group.sources": "Źródła",
            "launch.login": "Uruchamiaj przy logowaniu",
            "launch.restore": "Przywracaj ostatnią tapetę",
            "button.video": "Wideo...",
            "button.imageGif": "Obraz / GIF...",
            "menu.chooseVideo": "Wybierz wideo...",
            "menu.chooseVideoFolder": "Wybierz folder wideo...",
            "menu.turnOffWallpaper": "Wyłącz tapetę",
            "menu.turnOnWallpaper": "Włącz tapetę",
            "menu.pause": "Pauza",
            "menu.resume": "Wznów",
            "menu.previousWallpaper": "Poprzednia tapeta",
            "menu.nextWallpaper": "Następna tapeta",
            "menu.trimVideo": "Przytnij wideo...",
            "menu.openSettings": "Otwórz ustawienia...",
            "menu.quit": "Zamknij",
            "menu.addFavorite": "Dodaj do ulubionych",
            "menu.removeFavorite": "Usuń z ulubionych",
            "menu.currentWeight": "Waga bieżącej tapety...",
            "menu.currentWeightValue": "Waga bieżącej tapety: %d...",
            "menu.favorites": "Ulubione",
            "menu.recent": "Ostatnie",
            "menu.chooseCollection": "Wybierz kolekcję",
            "menu.noCollections": "Brak kolekcji",
            "menu.empty": "Pusto",
            "menu.profiles": "Profile",
            "menu.sourceInfo": "Informacje o bieżącym źródle",
            "menu.openLog": "Otwórz log błędów",
            "menu.checkUpdates": "Sprawdź aktualizacje...",
            "drop.import": "Upuść tutaj wideo, folder, GIF/obraz albo preset JSON",
            "group.placement": "Pozycja",
            "group.playback": "Odtwarzanie",
            "group.appearance": "Wygląd",
            "row.scale": "Skala",
            "row.manualScale": "Skala ręczna",
            "row.offsetX": "Przesunięcie X",
            "row.offsetY": "Przesunięcie Y",
            "row.speed": "Szybkość",
            "row.sound": "Dźwięk",
            "volume.off": "Wył.",
            "displayMode.fill": "Wypełnij ekran",
            "displayMode.fit": "Dopasuj całość",
            "displayMode.stretch": "Rozciągnij",
            "displayMode.center": "Wyśrodkuj",
            "displayMode.crop": "Przytnij krawędzie",
            "displayMode.manual": "Skala ręczna",
            "row.brightness": "Jasność",
            "row.dimming": "Przyciemnienie",
            "row.contrast": "Kontrast",
            "row.saturation": "Nasycenie",
            "row.blur": "Rozmycie",
            "row.hue": "Odcień",
            "row.vignette": "Winieta",
            "row.grain": "Ziarno",
            "continue.position": "Kontynuuj od ostatniej pozycji",
            "cinematic.loop": "Pętla filmowa",
            "group.displayBehavior": "Zachowanie ekranów",
            "row.displays": "Monitory",
            "displaySource.same": "Jedna tapeta na wszystkich ekranach",
            "displaySource.playlist": "Różne wideo z playlisty",
            "sync.playback": "Synchronizuj odtwarzanie",
            "group.quality": "Jakość",
            "group.autopause": "Automatyczna pauza",
            "fps.source": "Jak w wideo",
            "economy.mode": "Tryb oszczędny",
            "pause.battery": "Pauza na baterii",
            "pause.lowBattery": "Pauza poniżej 20%",
            "pause.fullscreen": "Pauza w aplikacjach pełnoekranowych",
            "pause.covered": "Pauza, gdy pulpit jest zasłonięty",
            "pause.screenLock": "Pauza po zablokowaniu ekranu",
            "pause.highLoad": "Pauza przy dużym obciążeniu",
            "pause.gamesCalls": "Pauza podczas gier i rozmów",
            "auto.quality": "Automatycznie obniżaj jakość",
            "warn.heavy": "Ostrzegaj o ciężkich wideo",
            "group.rotation": "Rotacja",
            "group.collections": "Kolekcje",
            "shuffle": "Losowa kolejność",
            "random.start": "Losowy start wideo",
            "row.rotationTimer": "Zmiana według timera",
            "rotation.manual": "Ręcznie",
            "rotation.fiveMinutes": "5 minut",
            "rotation.thirtyMinutes": "30 minut",
            "rotation.oneHour": "1 godzina",
            "button.saveCollection": "Zapisz bieżący zestaw jako kolekcję...",
            "group.hotkeys": "Szybkie akcje",
            "group.system": "System",
            "group.presets": "Presety",
            "group.danger": "Strefa ryzyka",
            "button.restoreWallpaper": "Przywróć tapetę",
            "button.clearCache": "Wyczyść cache",
            "button.checkUpdates": "Sprawdź aktualizacje...",
            "button.import": "Import...",
            "button.export": "Eksport...",
            "button.resetAll": "Resetuj wszystko",
            "creators.madeBy": "Twórca",
            "creators.description": "Dziękujemy za korzystanie z Live Wallpapers for Mac. Nowości i kontakt: https://x.com/Bubblegumbbbbb",
            "creators.support": "Wesprzyj",
            "creators.x": "X: @Bubblegumbbbbb",
            "automation.activeGroup": "Aktywne teraz",
            "automation.activeNow": "Aktywne teraz",
            "automation.applied": "Zastosowano",
            "automation.reason": "Powód",
            "automation.nextChange": "Następna zmiana",
            "automation.noActive": "Żadna reguła harmonogramu nie jest teraz aktywna.",
            "automation.enableHint": "Włącz regułę albo zastosuj szablon, aby uruchomić automatyzację.",
            "automation.offHint": "Automatyzacja harmonogramu jest teraz wyłączona.",
            "automation.upcoming": "Nadchodzące zmiany",
            "automation.upcomingNone": "Brak zmian czasowych w ciągu 24 godzin. Reguły zasilania i monitorów zadziałają przy zmianie stanu systemu.",
            "automation.preview24": "Następne 24 godziny",
            "automation.priorityHelp": "Wyższe karty mają wyższy priorytet, gdy aktywnych jest kilka reguł. To zachowuje zgodność ze starymi harmonogramami.",
            "automation.rules": "Reguły",
            "automation.emptyGroup": "Pusty harmonogram",
            "automation.emptyTitle": "Harmonogram automatycznie zmienia żywą tapetę.",
            "automation.emptyDescription": "Zacznij od jednej reguły albo użyj szablonu i edytuj utworzone reguły.",
            "automation.addFirst": "Dodaj pierwszą regułę",
            "automation.dayNightTemplate": "Szablon dzień / noc",
            "automation.templates": "Szablony",
            "automation.templatesHelp": "Szablony tworzą zwykłe edytowalne reguły i nie zmieniają formatu ustawień.",
            "automation.override": "Ręczne nadpisanie",
            "automation.overrideHelp": "Gdy wybierasz tapetę ręcznie przy włączonym harmonogramie, tymczasowe nadpisanie pozwala przewidywalnie wrócić do automatyzacji.",
            "automation.untilNext": "Do następnej zmiany",
            "automation.minutes30": "30 minut",
            "automation.hour1": "1 godzina",
            "automation.disableSchedule": "Wyłącz harmonogram",
            "automation.overrideActive": "Ręczne nadpisanie jest aktywne",
            "automation.resumeNow": "Wróć do harmonogramu teraz",
            "automation.badgeActive": "Aktywne",
            "automation.enabled": "Wł.",
            "automation.disabled": "Wył.",
            "automation.next": "Dalej",
            "automation.edit": "Edytuj",
            "automation.template.dayNight": "Dzień / noc",
            "automation.template.workday": "Dzień pracy",
            "automation.template.batterySaver": "Oszczędzanie baterii",
            "automation.template.gaming": "Tryb gry",
            "automation.template.dayNight.subtitle": "Profile na poranek, dzień, wieczór i noc.",
            "automation.template.workday.subtitle": "Work w godzinach pracy, Cinematic po pracy.",
            "automation.template.batterySaver.subtitle": "Battery Saver na baterii, Cinematic przy ładowaniu.",
            "automation.template.gaming.subtitle": "Od razu włącza Gaming i zostawia harmonogram ręczny.",
            "hotkey.toggleWallpaper": "Włącz / wyłącz tapetę",
            "hotkey.pause": "Pauza / start",
            "hotkey.previous": "Poprzednia tapeta",
            "hotkey.next": "Następna tapeta",
            "hotkey.economy": "Tryb oszczędny",
            "hotkey.menu": "Otwórz menu"
        ],
        .simplifiedChinese: [
            "section.general": "常规",
            "section.wallpaper": "壁纸",
            "section.displays": "显示器",
            "section.performance": "资源",
            "section.playlists": "播放列表",
            "section.automation": "自动化",
            "section.hotkeys": "快捷键",
            "section.service": "服务",
            "section.creators": "创作者",
            "subtitle.general": "应用启动和快速选择来源。",
            "subtitle.wallpaper": "缩放、速度、色彩校正和视觉效果。",
            "subtitle.displays": "单显示器或多显示器行为。",
            "subtitle.performance": "平衡流畅度、负载和智能暂停。",
            "subtitle.playlists": "随机播放、定时器和收藏集。",
            "subtitle.automation": "预设场景和配置文件切换规则。",
            "subtitle.hotkeys": "全局快速操作。",
            "subtitle.service": "导入、导出、清理和恢复。",
            "subtitle.creators": "了解谁在制作 Live Wallpapers for Mac 以及如何支持开发。",
            "group.language": "语言",
            "language.help": "选择会立即应用到设置窗口，并保存在 Live Wallpapers for Mac 中。",
            "group.launch": "启动",
            "group.sources": "来源",
            "launch.login": "登录时启动",
            "launch.restore": "启动时恢复上次壁纸",
            "button.video": "视频...",
            "button.imageGif": "图片 / GIF...",
            "menu.chooseVideo": "选择视频...",
            "menu.chooseVideoFolder": "选择视频文件夹...",
            "menu.turnOffWallpaper": "关闭壁纸",
            "menu.turnOnWallpaper": "开启壁纸",
            "menu.pause": "暂停",
            "menu.resume": "继续",
            "menu.previousWallpaper": "上一张壁纸",
            "menu.nextWallpaper": "下一张壁纸",
            "menu.trimVideo": "裁剪视频...",
            "menu.openSettings": "打开设置...",
            "menu.quit": "退出",
            "menu.addFavorite": "添加到收藏",
            "menu.removeFavorite": "从收藏移除",
            "menu.currentWeight": "当前壁纸权重...",
            "menu.currentWeightValue": "当前壁纸权重：%d...",
            "menu.favorites": "收藏",
            "menu.recent": "最近",
            "menu.chooseCollection": "选择收藏集",
            "menu.noCollections": "没有收藏集",
            "menu.empty": "空",
            "menu.profiles": "配置",
            "menu.sourceInfo": "当前来源信息",
            "menu.openLog": "打开错误日志",
            "menu.checkUpdates": "检查更新...",
            "drop.import": "将视频、文件夹、GIF/图片或 JSON 预设拖到这里",
            "group.placement": "位置",
            "group.playback": "播放",
            "group.appearance": "外观",
            "row.scale": "缩放",
            "row.manualScale": "手动缩放",
            "row.offsetX": "X 偏移",
            "row.offsetY": "Y 偏移",
            "row.speed": "速度",
            "row.sound": "声音",
            "volume.off": "关闭",
            "displayMode.fill": "填满屏幕",
            "displayMode.fit": "完整适应",
            "displayMode.stretch": "拉伸",
            "displayMode.center": "居中",
            "displayMode.crop": "裁剪边缘",
            "displayMode.manual": "手动缩放",
            "row.brightness": "亮度",
            "row.dimming": "变暗",
            "row.contrast": "对比度",
            "row.saturation": "饱和度",
            "row.blur": "模糊",
            "row.hue": "色相",
            "row.vignette": "暗角",
            "row.grain": "颗粒",
            "continue.position": "从上次位置继续",
            "cinematic.loop": "电影循环淡入淡出",
            "group.displayBehavior": "显示器行为",
            "row.displays": "显示器",
            "displaySource.same": "所有显示器使用同一壁纸",
            "displaySource.playlist": "播放列表中不同视频",
            "sync.playback": "同步播放",
            "group.quality": "质量",
            "group.autopause": "自动暂停",
            "fps.source": "与视频相同",
            "economy.mode": "省电模式",
            "pause.battery": "电池供电时暂停",
            "pause.lowBattery": "低于 20% 时暂停",
            "pause.fullscreen": "全屏应用时暂停",
            "pause.covered": "桌面被遮挡时暂停",
            "pause.screenLock": "锁屏时暂停",
            "pause.highLoad": "高负载时暂停",
            "pause.gamesCalls": "游戏和通话时暂停",
            "auto.quality": "负载高时自动降低质量",
            "warn.heavy": "提示大型视频",
            "group.rotation": "轮换",
            "group.collections": "收藏集",
            "shuffle": "随机顺序",
            "random.start": "随机视频起点",
            "row.rotationTimer": "定时切换",
            "rotation.manual": "手动",
            "rotation.fiveMinutes": "5 分钟",
            "rotation.thirtyMinutes": "30 分钟",
            "rotation.oneHour": "1 小时",
            "button.saveCollection": "将当前集合保存为收藏集...",
            "group.hotkeys": "快速操作",
            "group.system": "系统",
            "group.presets": "预设",
            "group.danger": "危险区域",
            "button.restoreWallpaper": "恢复壁纸",
            "button.clearCache": "清理缓存",
            "button.checkUpdates": "检查更新...",
            "button.import": "导入...",
            "button.export": "导出...",
            "button.resetAll": "全部重置",
            "creators.madeBy": "创作者",
            "creators.description": "感谢使用 Live Wallpapers for Mac。新闻和联系： https://x.com/Bubblegumbbbbb",
            "creators.support": "支持",
            "creators.x": "X: @Bubblegumbbbbb",
            "automation.activeGroup": "当前活动",
            "automation.activeNow": "当前活动",
            "automation.applied": "已应用",
            "automation.reason": "原因",
            "automation.nextChange": "下次更改",
            "automation.noActive": "当前没有活动的计划规则。",
            "automation.enableHint": "启用规则或应用模板以开始自动化。",
            "automation.offHint": "计划自动化当前已关闭。",
            "automation.upcoming": "即将更改",
            "automation.upcomingNone": "未来 24 小时没有定时更改。电源和显示器规则会在系统状态变化时应用。",
            "automation.preview24": "未来 24 小时",
            "automation.priorityHelp": "多个规则同时活动时，上方卡片优先级更高。这与现有自动化引擎一致，并保持旧计划兼容。",
            "automation.rules": "规则",
            "automation.emptyGroup": "空计划",
            "automation.emptyTitle": "计划会自动更改你的动态壁纸。",
            "automation.emptyDescription": "从一个清晰规则开始，或使用模板后再编辑生成的规则。",
            "automation.addFirst": "添加第一个规则",
            "automation.dayNightTemplate": "日 / 夜模板",
            "automation.templates": "模板",
            "automation.templatesHelp": "模板只会创建可编辑的普通规则，不会改变保存设置格式。",
            "automation.override": "手动覆盖",
            "automation.overrideHelp": "启用计划时手动选择壁纸，可用临时覆盖让自动化按预期恢复。",
            "automation.untilNext": "直到下次更改",
            "automation.minutes30": "30 分钟",
            "automation.hour1": "1 小时",
            "automation.disableSchedule": "关闭计划",
            "automation.overrideActive": "手动覆盖已启用",
            "automation.resumeNow": "立即恢复计划",
            "automation.badgeActive": "活动",
            "automation.enabled": "开",
            "automation.disabled": "关",
            "automation.next": "下一个",
            "automation.edit": "编辑",
            "automation.template.dayNight": "日 / 夜",
            "automation.template.workday": "工作日",
            "automation.template.batterySaver": "省电模式",
            "automation.template.gaming": "游戏模式",
            "automation.template.dayNight.subtitle": "用于早晨、白天、傍晚和夜晚的配置。",
            "automation.template.workday.subtitle": "工作时间使用 Work，下班后使用 Cinematic。",
            "automation.template.batterySaver.subtitle": "电池供电时 Battery Saver，充电时 Cinematic。",
            "automation.template.gaming.subtitle": "立即应用 Gaming，并让计划保持手动。",
            "hotkey.toggleWallpaper": "开启 / 关闭壁纸",
            "hotkey.pause": "暂停 / 播放",
            "hotkey.previous": "上一张壁纸",
            "hotkey.next": "下一张壁纸",
            "hotkey.economy": "省电模式",
            "hotkey.menu": "打开菜单"
        ],
        .traditionalChinese: [
            "section.general": "一般",
            "section.wallpaper": "桌布",
            "section.displays": "顯示器",
            "section.performance": "資源",
            "section.playlists": "播放清單",
            "section.automation": "自動化",
            "section.hotkeys": "快捷鍵",
            "section.service": "服務",
            "section.creators": "創作者",
            "subtitle.general": "應用程式啟動與快速選擇來源。",
            "subtitle.wallpaper": "縮放、速度、色彩校正與視覺效果。",
            "subtitle.displays": "單一或多個顯示器的行為。",
            "subtitle.performance": "平衡流暢度、負載與智慧暫停。",
            "subtitle.playlists": "隨機播放、計時器與收藏集。",
            "subtitle.automation": "預設情境與設定檔切換規則。",
            "subtitle.hotkeys": "全域快速操作。",
            "subtitle.service": "匯入、匯出、清理與還原。",
            "subtitle.creators": "了解誰在製作 Live Wallpapers for Mac，以及如何支持開發。",
            "group.language": "語言",
            "language.help": "選擇會立即套用到設定視窗，並儲存在 Live Wallpapers for Mac。",
            "group.launch": "啟動",
            "group.sources": "來源",
            "launch.login": "登入時啟動",
            "launch.restore": "啟動時還原上次桌布",
            "button.video": "影片...",
            "button.imageGif": "圖片 / GIF...",
            "menu.chooseVideo": "選擇影片...",
            "menu.chooseVideoFolder": "選擇影片資料夾...",
            "menu.turnOffWallpaper": "關閉桌布",
            "menu.turnOnWallpaper": "開啟桌布",
            "menu.pause": "暫停",
            "menu.resume": "繼續",
            "menu.previousWallpaper": "上一張桌布",
            "menu.nextWallpaper": "下一張桌布",
            "menu.trimVideo": "裁剪影片...",
            "menu.openSettings": "打開設定...",
            "menu.quit": "結束",
            "menu.addFavorite": "加入收藏",
            "menu.removeFavorite": "從收藏移除",
            "menu.currentWeight": "目前桌布權重...",
            "menu.currentWeightValue": "目前桌布權重：%d...",
            "menu.favorites": "收藏",
            "menu.recent": "最近",
            "menu.chooseCollection": "選擇收藏集",
            "menu.noCollections": "沒有收藏集",
            "menu.empty": "空",
            "menu.profiles": "設定檔",
            "menu.sourceInfo": "目前來源資訊",
            "menu.openLog": "打開錯誤日誌",
            "menu.checkUpdates": "檢查更新...",
            "drop.import": "將影片、資料夾、GIF/圖片或 JSON 預設拖到這裡",
            "group.placement": "位置",
            "group.playback": "播放",
            "group.appearance": "外觀",
            "row.scale": "縮放",
            "row.manualScale": "手動縮放",
            "row.offsetX": "X 偏移",
            "row.offsetY": "Y 偏移",
            "row.speed": "速度",
            "row.sound": "聲音",
            "volume.off": "關閉",
            "displayMode.fill": "填滿螢幕",
            "displayMode.fit": "完整符合",
            "displayMode.stretch": "拉伸",
            "displayMode.center": "置中",
            "displayMode.crop": "裁切邊緣",
            "displayMode.manual": "手動縮放",
            "row.brightness": "亮度",
            "row.dimming": "變暗",
            "row.contrast": "對比",
            "row.saturation": "飽和度",
            "row.blur": "模糊",
            "row.hue": "色相",
            "row.vignette": "暗角",
            "row.grain": "顆粒",
            "continue.position": "從上次位置繼續",
            "cinematic.loop": "電影循環淡入淡出",
            "group.displayBehavior": "顯示器行為",
            "row.displays": "顯示器",
            "displaySource.same": "所有顯示器使用同一桌布",
            "displaySource.playlist": "播放清單中的不同影片",
            "sync.playback": "同步播放",
            "group.quality": "品質",
            "group.autopause": "自動暫停",
            "fps.source": "與影片相同",
            "economy.mode": "省電模式",
            "pause.battery": "使用電池時暫停",
            "pause.lowBattery": "低於 20% 時暫停",
            "pause.fullscreen": "全螢幕應用時暫停",
            "pause.covered": "桌面被遮住時暫停",
            "pause.screenLock": "鎖定螢幕時暫停",
            "pause.highLoad": "高負載時暫停",
            "pause.gamesCalls": "遊戲和通話時暫停",
            "auto.quality": "高負載時自動降低品質",
            "warn.heavy": "提示大型影片",
            "group.rotation": "輪換",
            "group.collections": "收藏集",
            "shuffle": "隨機順序",
            "random.start": "隨機影片起點",
            "row.rotationTimer": "定時切換",
            "rotation.manual": "手動",
            "rotation.fiveMinutes": "5 分鐘",
            "rotation.thirtyMinutes": "30 分鐘",
            "rotation.oneHour": "1 小時",
            "button.saveCollection": "將目前集合儲存為收藏集...",
            "group.hotkeys": "快速操作",
            "group.system": "系統",
            "group.presets": "預設",
            "group.danger": "危險區域",
            "button.restoreWallpaper": "還原桌布",
            "button.clearCache": "清理快取",
            "button.checkUpdates": "檢查更新...",
            "button.import": "匯入...",
            "button.export": "匯出...",
            "button.resetAll": "全部重置",
            "creators.madeBy": "創作者",
            "creators.description": "感謝使用 Live Wallpapers for Mac。新聞與聯絡： https://x.com/Bubblegumbbbbb",
            "creators.support": "支持",
            "creators.x": "X: @Bubblegumbbbbb",
            "automation.activeGroup": "目前啟用",
            "automation.activeNow": "目前啟用",
            "automation.applied": "已套用",
            "automation.reason": "原因",
            "automation.nextChange": "下次變更",
            "automation.noActive": "目前沒有啟用的排程規則。",
            "automation.enableHint": "啟用規則或套用範本以開始自動化。",
            "automation.offHint": "排程自動化目前已關閉。",
            "automation.upcoming": "即將變更",
            "automation.upcomingNone": "未來 24 小時沒有定時變更。電源和顯示器規則會在系統狀態變化時套用。",
            "automation.preview24": "未來 24 小時",
            "automation.priorityHelp": "多個規則同時啟用時，上方卡片有較高優先權。這與現有自動化引擎一致，並保持舊排程相容。",
            "automation.rules": "規則",
            "automation.emptyGroup": "空排程",
            "automation.emptyTitle": "排程會自動變更你的動態桌布。",
            "automation.emptyDescription": "從一個清楚規則開始，或使用範本後再編輯產生的規則。",
            "automation.addFirst": "新增第一個規則",
            "automation.dayNightTemplate": "日 / 夜範本",
            "automation.templates": "範本",
            "automation.templatesHelp": "範本只會建立可編輯的一般規則，不會改變儲存設定格式。",
            "automation.override": "手動覆寫",
            "automation.overrideHelp": "啟用排程時手動選擇桌布，可用暫時覆寫讓自動化可預期地恢復。",
            "automation.untilNext": "直到下次變更",
            "automation.minutes30": "30 分鐘",
            "automation.hour1": "1 小時",
            "automation.disableSchedule": "關閉排程",
            "automation.overrideActive": "手動覆寫已啟用",
            "automation.resumeNow": "立即恢復排程",
            "automation.badgeActive": "啟用",
            "automation.enabled": "開",
            "automation.disabled": "關",
            "automation.next": "下一步",
            "automation.edit": "編輯",
            "automation.template.dayNight": "日 / 夜",
            "automation.template.workday": "工作日",
            "automation.template.batterySaver": "省電模式",
            "automation.template.gaming": "遊戲模式",
            "automation.template.dayNight.subtitle": "用於早晨、白天、傍晚與夜晚的設定檔。",
            "automation.template.workday.subtitle": "工作時間使用 Work，下班後使用 Cinematic。",
            "automation.template.batterySaver.subtitle": "電池供電時 Battery Saver，充電時 Cinematic。",
            "automation.template.gaming.subtitle": "立即套用 Gaming，並讓排程保持手動。",
            "hotkey.toggleWallpaper": "開啟 / 關閉桌布",
            "hotkey.pause": "暫停 / 播放",
            "hotkey.previous": "上一張桌布",
            "hotkey.next": "下一張桌布",
            "hotkey.economy": "省電模式",
            "hotkey.menu": "開啟選單"
        ]
    ]
}

struct WallpaperBehaviorSettings: Codable {
    var appLanguage: AppLanguage = .russian
    var launchAtLogin = false
    var restoreLastWallpaperOnLaunch = true
    var pauseOnBattery = false
    var pauseOnLowBattery = true
    var lowBatteryThreshold = 20
    var pauseInFullscreen = true
    var pauseWhenDesktopCovered = true
    var pauseOnScreenLock = true
    var pauseOnHighSystemLoad = true
    var pauseDuringGamesOrCalls = true
    var autoLowerQualityOnLoad = true
    var warnAboutHeavyFiles = true
    var maximumFileSizeGB = 10.0

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appLanguage = try container.decodeIfPresent(AppLanguage.self, forKey: .appLanguage) ?? .russian
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        restoreLastWallpaperOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .restoreLastWallpaperOnLaunch) ?? true
        pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
        pauseOnLowBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnLowBattery) ?? true
        lowBatteryThreshold = try container.decodeIfPresent(Int.self, forKey: .lowBatteryThreshold) ?? 20
        pauseInFullscreen = try container.decodeIfPresent(Bool.self, forKey: .pauseInFullscreen) ?? true
        pauseWhenDesktopCovered = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenDesktopCovered) ?? true
        pauseOnScreenLock = try container.decodeIfPresent(Bool.self, forKey: .pauseOnScreenLock) ?? true
        pauseOnHighSystemLoad = try container.decodeIfPresent(Bool.self, forKey: .pauseOnHighSystemLoad) ?? true
        pauseDuringGamesOrCalls = try container.decodeIfPresent(Bool.self, forKey: .pauseDuringGamesOrCalls) ?? true
        autoLowerQualityOnLoad = try container.decodeIfPresent(Bool.self, forKey: .autoLowerQualityOnLoad) ?? true
        warnAboutHeavyFiles = try container.decodeIfPresent(Bool.self, forKey: .warnAboutHeavyFiles) ?? true
        maximumFileSizeGB = try container.decodeIfPresent(Double.self, forKey: .maximumFileSizeGB) ?? 10.0
    }
}

struct WallpaperSourceSnapshot: Codable, Equatable {
    enum Kind: String, Codable {
        case singleVideo
        case folder
        case image
        case youtube
        case collection
        case web
    }

    var kind: Kind
    var path: String

    var displayName: String {
        switch kind {
        case .singleVideo, .image:
            return URL(fileURLWithPath: path).lastPathComponent
        case .folder:
            return "\(URL(fileURLWithPath: path).lastPathComponent) /"
        case .youtube:
            return "YouTube (удалено)"
        case .collection:
            return "Коллекция"
        case .web:
            return "Web (удалено)"
        }
    }
}

struct WallpaperCollection: Codable, Identifiable {
    var id: String
    var name: String
    var items: [WallpaperSourceSnapshot]
    var favoriteIDs: [String]
    var weights: [String: Int]

    init(
        id: String = UUID().uuidString,
        name: String,
        items: [WallpaperSourceSnapshot],
        favoriteIDs: [String] = [],
        weights: [String: Int] = [:]
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.favoriteIDs = favoriteIDs
        self.weights = weights
    }
}

enum WallpaperDisplaySourceMode: Int, Codable, CaseIterable {
    case sameOnAllDisplays
    case playlistItemPerDisplay

    var title: String {
        switch self {
        case .sameOnAllDisplays:
            return "Один фон на все экраны"
        case .playlistItemPerDisplay:
            return "Разные видео из плейлиста"
        }
    }
}

struct WallpaperDisplaySettings: Codable {
    var sourceMode: WallpaperDisplaySourceMode = .sameOnAllDisplays
    var synchronizePlayback = true
    var perDisplaySettings: [String: WallpaperPlaybackSettings] = [:]
}

enum AutomationPreset: Int, CaseIterable {
    case manual
    case workday
    case batteryAware
    case displayAware
    case smart

    var title: String {
        switch self {
        case .manual:
            return "Только вручную"
        case .workday:
            return "Рабочий день"
        case .batteryAware:
            return "Экономия батареи"
        case .displayAware:
            return "Мониторы и питание"
        case .smart:
            return "Умная автоматизация"
        }
    }
}

enum AutomationTimeSlot: String, Codable, CaseIterable {
    case morning
    case day
    case evening
    case night

    var title: String {
        switch self {
        case .morning: return "Утро"
        case .day: return "День"
        case .evening: return "Вечер"
        case .night: return "Ночь"
        }
    }

    var defaultProfile: WallpaperProfile {
        switch self {
        case .morning, .day:
            return .cinematic
        case .evening:
            return .work
        case .night:
            return .night
        }
    }
}

struct WallpaperAutomationSettings: Codable {
    var isEnabled = false
    var scheduleByTimeOfDay = false
    var scheduleByWeekday = false
    var changeOnPowerChange = false
    var changeOnExternalDisplay = false
    var homeWorkProfilesEnabled = false
    var slotProfiles: [AutomationTimeSlot: WallpaperProfile] = Dictionary(
        uniqueKeysWithValues: AutomationTimeSlot.allCases.map { ($0, $0.defaultProfile) }
    )
    var weekdayCollectionIDs: [Int: String] = [:]
}

enum AutomationRuleKind: Int, CaseIterable {
    case externalDisplay
    case power
    case homeWork
    case weekday
    case timeOfDay

    var title: String {
        switch self {
        case .externalDisplay:
            return "Внешний монитор"
        case .power:
            return "Питание"
        case .homeWork:
            return "Рабочие часы"
        case .weekday:
            return "Дни недели"
        case .timeOfDay:
            return "День / ночь"
        }
    }

    var iconName: String {
        switch self {
        case .externalDisplay:
            return "display.2"
        case .power:
            return "battery.100"
        case .homeWork:
            return "briefcase"
        case .weekday:
            return "calendar"
        case .timeOfDay:
            return "moon.stars"
        }
    }
}

enum AutomationTemplateKind: Int, CaseIterable {
    case dayNight
    case workday
    case batterySaver
    case gaming

    var title: String {
        switch self {
        case .dayNight:
            return "День / ночь"
        case .workday:
            return "Рабочий день"
        case .batterySaver:
            return "Экономия батареи"
        case .gaming:
            return "Игровой режим"
        }
    }

    var subtitle: String {
        switch self {
        case .dayNight:
            return "Профили для утра, дня, вечера и ночи."
        case .workday:
            return "Work в рабочие часы, Cinematic после работы."
        case .batterySaver:
            return "Battery Saver от батареи, Cinematic от зарядки."
        case .gaming:
            return "Сразу включает Gaming и оставляет расписание ручным."
        }
    }
}

enum AutomationOverrideOption: Int, CaseIterable {
    case untilNextChange
    case thirtyMinutes
    case oneHour
    case disableSchedule

    var title: String {
        switch self {
        case .untilNextChange:
            return "До следующего изменения"
        case .thirtyMinutes:
            return "30 минут"
        case .oneHour:
            return "1 час"
        case .disableSchedule:
            return "Выключить расписание"
        }
    }
}

struct AutomationRulePresentation {
    let kind: AutomationRuleKind
    let title: String
    let triggerDescription: String
    let actionDescription: String
    let summary: String
    let reasonDescription: String
    let isEnabled: Bool
    let isActiveNow: Bool
    let nextRunDate: Date?
    let nextRunDescription: String
    let priorityDescription: String
    let conflictDescription: String?
}

struct AutomationActiveState {
    let title: String
    let applied: String
    let reason: String
    let nextChange: String
}

struct AutomationTimelineEvent {
    let date: Date?
    let timeText: String
    let title: String
    let action: String
}

struct AutomationSchedulePresentation {
    let isEnabled: Bool
    let overrideDescription: String?
    let rules: [AutomationRulePresentation]
    let activeState: AutomationActiveState?
    let upcomingEvents: [AutomationTimelineEvent]

    var hasEnabledRules: Bool {
        rules.contains { $0.isEnabled }
    }
}

func formatTriggerDescription(_ rule: AutomationRulePresentation) -> String {
    rule.triggerDescription
}

func formatActionDescription(_ rule: AutomationRulePresentation) -> String {
    rule.actionDescription
}

func formatRuleSummary(_ rule: AutomationRulePresentation) -> String {
    rule.summary
}

enum AutomationSchedulePresenter {
    private static let calendar = Calendar.current

    static func presentation(
        settings: WallpaperAutomationSettings,
        collections: [WallpaperCollection],
        date: Date = Date(),
        powerState: PowerState = PowerStateReader.current(),
        screenCount: Int = NSScreen.screens.count,
        overrideDescription: String? = nil
    ) -> AutomationSchedulePresentation {
        var rules = AutomationRuleKind.allCases.map { kind in
            rule(
                kind: kind,
                settings: settings,
                collections: collections,
                date: date,
                powerState: powerState,
                screenCount: screenCount
            )
        }

        if settings.isEnabled {
            let activeRules = rules.filter { $0.isEnabled && $0.isActiveNow }
            if let winner = activeRules.first {
                rules = rules.map { rule in
                    guard rule.isEnabled,
                          rule.isActiveNow,
                          rule.kind != winner.kind else {
                        return rule
                    }

                    return AutomationRulePresentation(
                        kind: rule.kind,
                        title: rule.title,
                        triggerDescription: rule.triggerDescription,
                        actionDescription: rule.actionDescription,
                        summary: rule.summary,
                        reasonDescription: rule.reasonDescription,
                        isEnabled: rule.isEnabled,
                        isActiveNow: rule.isActiveNow,
                        nextRunDate: rule.nextRunDate,
                        nextRunDescription: rule.nextRunDescription,
                        priorityDescription: rule.priorityDescription,
                        conflictDescription: "Сейчас выигрывает правило с более высоким приоритетом: \(winner.title)"
                    )
                }
            }
        }

        let activeState: AutomationActiveState?
        if let overrideDescription {
            activeState = AutomationActiveState(
                title: "Ручной фон",
                applied: "Текущий фон остаётся без изменений",
                reason: overrideDescription,
                nextChange: nextOverrideChangeText(overrideDescription)
            )
        } else if settings.isEnabled, let activeRule = rules.first(where: { $0.isEnabled && $0.isActiveNow }) {
            activeState = AutomationActiveState(
                title: activeRule.title,
                applied: activeRule.actionDescription,
                reason: activeRule.reasonDescription,
                nextChange: activeRule.nextRunDescription
            )
        } else {
            activeState = nil
        }

        return AutomationSchedulePresentation(
            isEnabled: settings.isEnabled,
            overrideDescription: overrideDescription,
            rules: rules,
            activeState: activeState,
            upcomingEvents: upcomingEvents(
                settings: settings,
                collections: collections,
                date: date,
                activeState: activeState
            )
        )
    }

    static func nextScheduledChangeDate(
        settings: WallpaperAutomationSettings,
        date: Date = Date()
    ) -> Date? {
        let events = deterministicEvents(settings: settings, collections: [], date: date)
        return events.compactMap(\.date).filter { $0 > date }.sorted().first
    }

    private static func rule(
        kind: AutomationRuleKind,
        settings: WallpaperAutomationSettings,
        collections: [WallpaperCollection],
        date: Date,
        powerState: PowerState,
        screenCount: Int
    ) -> AutomationRulePresentation {
        let enabled = settings.isEnabled && isRuleEnabled(kind, settings: settings)
        let active = enabled && isRuleActiveNow(kind, date: date, powerState: powerState, screenCount: screenCount)
        let nextDate = nextRunDate(kind: kind, settings: settings, date: date)
        let nextText = nextRunText(kind: kind, settings: settings, date: date, nextDate: nextDate)

        return AutomationRulePresentation(
            kind: kind,
            title: kind.title,
            triggerDescription: triggerDescription(
                kind: kind,
                settings: settings,
                date: date,
                powerState: powerState,
                screenCount: screenCount
            ),
            actionDescription: actionDescription(
                kind: kind,
                settings: settings,
                collections: collections,
                date: date,
                powerState: powerState,
                screenCount: screenCount
            ),
            summary: summary(
                kind: kind,
                settings: settings,
                collections: collections,
                date: date,
                powerState: powerState,
                screenCount: screenCount
            ),
            reasonDescription: reasonDescription(
                kind: kind,
                settings: settings,
                date: date,
                powerState: powerState,
                screenCount: screenCount
            ),
            isEnabled: isRuleEnabled(kind, settings: settings),
            isActiveNow: active,
            nextRunDate: nextDate,
            nextRunDescription: enabled ? nextText : "Включите правило, чтобы оно участвовало в расписании",
            priorityDescription: priorityDescription(kind),
            conflictDescription: nil
        )
    }

    private static func isRuleEnabled(_ kind: AutomationRuleKind, settings: WallpaperAutomationSettings) -> Bool {
        switch kind {
        case .externalDisplay:
            return settings.changeOnExternalDisplay
        case .power:
            return settings.changeOnPowerChange
        case .homeWork:
            return settings.homeWorkProfilesEnabled
        case .weekday:
            return settings.scheduleByWeekday
        case .timeOfDay:
            return settings.scheduleByTimeOfDay
        }
    }

    private static func isRuleActiveNow(
        _ kind: AutomationRuleKind,
        date: Date,
        powerState: PowerState,
        screenCount: Int
    ) -> Bool {
        switch kind {
        case .externalDisplay, .power, .homeWork, .weekday, .timeOfDay:
            return true
        }
    }

    private static func triggerDescription(
        kind: AutomationRuleKind,
        settings: WallpaperAutomationSettings,
        date: Date,
        powerState: PowerState,
        screenCount: Int
    ) -> String {
        switch kind {
        case .externalDisplay:
            return screenCount > 1 ? "Когда подключён внешний монитор" : "Когда меняется набор мониторов"
        case .power:
            return powerState.isOnBatteryPower ? "Когда Mac работает от батареи" : "Когда Mac подключён к зарядке"
        case .homeWork:
            return "Каждый день с 09:00 до 19:00"
        case .weekday:
            return "В будни Work, в выходные Cinematic"
        case .timeOfDay:
            return "Каждый день: 06:00 утро, 12:00 день, 18:00 вечер, 23:00 ночь"
        }
    }

    private static func actionDescription(
        kind: AutomationRuleKind,
        settings: WallpaperAutomationSettings,
        collections: [WallpaperCollection],
        date: Date,
        powerState: PowerState,
        screenCount: Int
    ) -> String {
        switch kind {
        case .externalDisplay:
            return screenCount > 1 ? "Применить профиль Performance" : "Применить профиль Cinematic"
        case .power:
            return powerState.isOnBatteryPower ? "Применить профиль Battery Saver" : "Применить профиль Cinematic"
        case .homeWork:
            return isWorkHour(date) ? "Применить профиль Work" : "Применить профиль Cinematic"
        case .weekday:
            let weekday = calendar.component(.weekday, from: date)
            let profile = (weekday == 1 || weekday == 7) ? WallpaperProfile.cinematic : .work
            if let collectionName = collectionName(for: weekday, settings: settings, collections: collections) {
                return "Применить профиль \(profile.title) и коллекцию \(collectionName)"
            }
            return "Применить профиль \(profile.title)"
        case .timeOfDay:
            let slot = currentSlot(date)
            let profile = settings.slotProfiles[slot] ?? slot.defaultProfile
            return "Применить профиль \(profile.title)"
        }
    }

    private static func summary(
        kind: AutomationRuleKind,
        settings: WallpaperAutomationSettings,
        collections: [WallpaperCollection],
        date: Date,
        powerState: PowerState,
        screenCount: Int
    ) -> String {
        "\(triggerDescription(kind: kind, settings: settings, date: date, powerState: powerState, screenCount: screenCount)) -> \(actionDescription(kind: kind, settings: settings, collections: collections, date: date, powerState: powerState, screenCount: screenCount))"
    }

    private static func reasonDescription(
        kind: AutomationRuleKind,
        settings: WallpaperAutomationSettings,
        date: Date,
        powerState: PowerState,
        screenCount: Int
    ) -> String {
        switch kind {
        case .externalDisplay:
            return screenCount > 1
                ? "Сейчас подключено больше одного монитора."
                : "Сейчас подключён один монитор."
        case .power:
            return powerState.isOnBatteryPower
                ? "Текущий источник питания - батарея."
                : "Текущий источник питания - зарядка."
        case .homeWork:
            return isWorkHour(date)
                ? "Текущее время попадает в диапазон 09:00-19:00."
                : "Текущее время вне диапазона 09:00-19:00."
        case .weekday:
            let weekday = calendar.component(.weekday, from: date)
            return (weekday == 1 || weekday == 7)
                ? "Сегодня выходной."
                : "Сегодня будний день."
        case .timeOfDay:
            let slot = currentSlot(date)
            return "Текущее время попадает в блок: \(slot.title.lowercased()), \(slotRange(slot))."
        }
    }

    private static func priorityDescription(_ kind: AutomationRuleKind) -> String {
        switch kind {
        case .externalDisplay:
            return "Приоритет 1"
        case .power:
            return "Приоритет 2"
        case .homeWork:
            return "Приоритет 3"
        case .weekday:
            return "Приоритет 4"
        case .timeOfDay:
            return "Приоритет 5"
        }
    }

    private static func nextRunDate(
        kind: AutomationRuleKind,
        settings: WallpaperAutomationSettings,
        date: Date
    ) -> Date? {
        switch kind {
        case .externalDisplay, .power:
            return nil
        case .homeWork:
            return nextDate(hour: isWorkHour(date) ? 19 : 9, after: date)
        case .weekday:
            return nextDate(hour: 0, after: date)
        case .timeOfDay:
            return [6, 12, 18, 23]
                .compactMap { nextDate(hour: $0, after: date) }
                .sorted()
                .first
        }
    }

    private static func nextRunText(
        kind: AutomationRuleKind,
        settings: WallpaperAutomationSettings,
        date: Date,
        nextDate: Date?
    ) -> String {
        switch kind {
        case .externalDisplay:
            return "Когда изменится набор мониторов"
        case .power:
            return "Когда изменится источник питания"
        case .homeWork:
            guard let nextDate else { return "Следующее изменение неизвестно" }
            let nextProfile = isWorkHour(date) ? WallpaperProfile.cinematic : .work
            return "\(timeString(nextDate)) - \(nextProfile.title)"
        case .weekday:
            guard let nextDate else { return "Завтра" }
            let weekday = calendar.component(.weekday, from: nextDate)
            let profile = (weekday == 1 || weekday == 7) ? WallpaperProfile.cinematic : .work
            return "\(timeString(nextDate)) - \(profile.title)"
        case .timeOfDay:
            guard let nextDate else { return "Следующее изменение неизвестно" }
            let slot = currentSlot(nextDate)
            let profile = settings.slotProfiles[slot] ?? slot.defaultProfile
            return "\(timeString(nextDate)) - \(profile.title)"
        }
    }

    private static func upcomingEvents(
        settings: WallpaperAutomationSettings,
        collections: [WallpaperCollection],
        date: Date,
        activeState: AutomationActiveState?
    ) -> [AutomationTimelineEvent] {
        guard settings.isEnabled else {
            return []
        }

        var events: [AutomationTimelineEvent] = []
        if let activeState {
            events.append(
                AutomationTimelineEvent(
                    date: nil,
                    timeText: "Сейчас",
                    title: activeState.title,
                    action: activeState.applied
                )
            )
        }

        events.append(contentsOf: deterministicEvents(settings: settings, collections: collections, date: date))
        return events.prefix(8).map { $0 }
    }

    private static func deterministicEvents(
        settings: WallpaperAutomationSettings,
        collections: [WallpaperCollection],
        date: Date
    ) -> [AutomationTimelineEvent] {
        let horizon = date.addingTimeInterval(24 * 60 * 60)
        var events: [AutomationTimelineEvent] = []

        if settings.scheduleByTimeOfDay {
            for (slot, hour) in [
                (AutomationTimeSlot.morning, 6),
                (.day, 12),
                (.evening, 18),
                (.night, 23)
            ] {
                guard let eventDate = nextDate(hour: hour, after: date),
                      eventDate <= horizon else {
                    continue
                }

                let profile = settings.slotProfiles[slot] ?? slot.defaultProfile
                events.append(
                    AutomationTimelineEvent(
                        date: eventDate,
                        timeText: timeString(eventDate),
                        title: slot.title,
                        action: "Применить профиль \(profile.title)"
                    )
                )
            }
        }

        if settings.homeWorkProfilesEnabled {
            for (hour, profile) in [(9, WallpaperProfile.work), (19, WallpaperProfile.cinematic)] {
                guard let eventDate = nextDate(hour: hour, after: date),
                      eventDate <= horizon else {
                    continue
                }

                events.append(
                    AutomationTimelineEvent(
                        date: eventDate,
                        timeText: timeString(eventDate),
                        title: "\(profile.title) hours",
                        action: "Применить профиль \(profile.title)"
                    )
                )
            }
        }

        if settings.scheduleByWeekday,
           let eventDate = nextDate(hour: 0, after: date),
           eventDate <= horizon {
            let weekday = calendar.component(.weekday, from: eventDate)
            let profile = (weekday == 1 || weekday == 7) ? WallpaperProfile.cinematic : .work
            let collection = collectionName(for: weekday, settings: settings, collections: collections)
            let action = collection.map { "Применить профиль \(profile.title) и коллекцию \($0)" }
                ?? "Применить профиль \(profile.title)"
            events.append(
                AutomationTimelineEvent(
                    date: eventDate,
                    timeText: timeString(eventDate),
                    title: "New day",
                    action: action
                )
            )
        }

        return events.sorted { left, right in
            switch (left.date, right.date) {
            case let (leftDate?, rightDate?):
                return leftDate < rightDate
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            case (nil, nil):
                return false
            }
        }
    }

    private static func nextOverrideChangeText(_ overrideDescription: String) -> String {
        overrideDescription
    }

    private static func currentSlot(_ date: Date) -> AutomationTimeSlot {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 6..<12:
            return .morning
        case 12..<18:
            return .day
        case 18..<23:
            return .evening
        default:
            return .night
        }
    }

    private static func slotRange(_ slot: AutomationTimeSlot) -> String {
        switch slot {
        case .morning:
            return "06:00-12:00"
        case .day:
            return "12:00-18:00"
        case .evening:
            return "18:00-23:00"
        case .night:
            return "23:00-06:00"
        }
    }

    private static func isWorkHour(_ date: Date) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return (9...18).contains(hour)
    }

    private static func nextDate(hour: Int, after date: Date) -> Date? {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: 0, second: 0),
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func collectionName(
        for weekday: Int,
        settings: WallpaperAutomationSettings,
        collections: [WallpaperCollection]
    ) -> String? {
        if let collectionID = settings.weekdayCollectionIDs[weekday],
           let collection = collections.first(where: { $0.id == collectionID }) {
            return collection.name
        }

        guard !collections.isEmpty else {
            return nil
        }

        let collectionIndex = max(0, weekday - 1) % collections.count
        return collections[collectionIndex].name
    }
}

struct AppPreferences: Codable {
    var playback = WallpaperPlaybackSettings()
    var behavior = WallpaperBehaviorSettings()
    var displays = WallpaperDisplaySettings()
    var automation = WallpaperAutomationSettings()
    var collections: [WallpaperCollection] = []
    var favorites: [WallpaperSourceSnapshot] = []
    var recentSources: [WallpaperSourceSnapshot] = []
    var videoPositions: [String: Double] = [:]
    var lastSource: WallpaperSourceSnapshot?
    var activeCollectionID: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playback = try container.decodeIfPresent(WallpaperPlaybackSettings.self, forKey: .playback) ?? WallpaperPlaybackSettings()
        behavior = try container.decodeIfPresent(WallpaperBehaviorSettings.self, forKey: .behavior) ?? WallpaperBehaviorSettings()
        displays = try container.decodeIfPresent(WallpaperDisplaySettings.self, forKey: .displays) ?? WallpaperDisplaySettings()
        automation = try container.decodeIfPresent(WallpaperAutomationSettings.self, forKey: .automation) ?? WallpaperAutomationSettings()
        collections = try container.decodeIfPresent([WallpaperCollection].self, forKey: .collections) ?? []
        favorites = try container.decodeIfPresent([WallpaperSourceSnapshot].self, forKey: .favorites) ?? []
        recentSources = try container.decodeIfPresent([WallpaperSourceSnapshot].self, forKey: .recentSources) ?? []
        videoPositions = try container.decodeIfPresent([String: Double].self, forKey: .videoPositions) ?? [:]
        lastSource = try container.decodeIfPresent(WallpaperSourceSnapshot.self, forKey: .lastSource)
        activeCollectionID = try container.decodeIfPresent(String.self, forKey: .activeCollectionID)
    }
}

enum WallpaperSource {
    case video(URL)
    case image(URL)

    var displayName: String {
        switch self {
        case .video(let url):
            return url.lastPathComponent
        case .image(let url):
            return url.lastPathComponent
        }
    }
}

struct WallpaperConfiguration {
    let source: WallpaperSource
    let settings: WallpaperPlaybackSettings
    let resumePositionSeconds: Double?
}

final class WallpaperController {
    private var windows: [WallpaperWindow] = []
    private var playlist: [URL] = []
    private var playlistFolderURL: URL?
    private var folderMonitorSource: DispatchSourceFileSystemObject?
    private var folderMonitorFileDescriptor: CInt = -1
    private var imageURL: URL?
    private var currentIndex = 0
    private var rotationTimer: Timer?
    private var automationTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var fullscreenPauseMonitor: FullscreenPauseMonitor?
    private var systemActivityPauseMonitor: SystemActivityPauseMonitor?
    private var powerStatePauseMonitor: PowerStatePauseMonitor?
    private var desktopCoveragePauseMonitor: DesktopCoveragePauseMonitor?
    private var activeAppPauseMonitor: ActiveAppPauseMonitor?
    private var thermalPressureMonitor: ThermalPressureMonitor?
    private var screenLockPauseMonitor: ScreenLockPauseMonitor?
    private var audioOutputRouteMonitor: AudioOutputRouteMonitor?
    private var audioOutputRecoveryWorkItem: DispatchWorkItem?
    private var pauseReasons: Set<PlaybackPauseReason> = []
    private var wallpaperEnabled = true
    private var latestFullscreenState = false
    private var latestPowerState = PowerStateReader.current()
    private var latestDesktopCoveredState = false
    private var latestGameOrCallState = false
    private var latestThermalState = ProcessInfo.processInfo.thermalState
    private var latestScreenLockedState = false
    private var lastAutomationSignature: String?
    private var automationOverrideUntil: Date?
    private var automationOverrideLabel: String?
    private(set) var settings = WallpaperPlaybackSettings()
    private(set) var behaviorSettings = WallpaperBehaviorSettings()
    private(set) var displaySettings = WallpaperDisplaySettings()
    private(set) var automationSettings = WallpaperAutomationSettings()
    private let systemWallpaperController = SystemWallpaperController()
    private let preferencesStore = AppPreferencesStore()
    private var preferences = AppPreferences()

    init() {
        preferences = preferencesStore.load()
        sanitizeLegacySourceState()
        settings = preferences.playback
        behaviorSettings = preferences.behavior
        displaySettings = preferences.displays
        automationSettings = preferences.automation
        LaunchAtLoginManager.repairIfEnabled()
        behaviorSettings.launchAtLogin = LaunchAtLoginManager.isEnabled
        savePreferences()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyExternalDisplayAutomationIfNeeded()
            self?.rebuildForCurrentVideo()
        }
        scheduleAutomationTimerIfNeeded()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    var isUserPaused: Bool {
        pauseReasons.contains(.userPaused)
    }

    var isWallpaperEnabled: Bool {
        wallpaperEnabled
    }

    var canSelectPreviousOrNext: Bool {
        imageURL == nil && playlist.count > 1
    }

    var trim: VideoTrim {
        settings.trim
    }

    var favorites: [WallpaperSourceSnapshot] {
        preferences.favorites
    }

    var recentSources: [WallpaperSourceSnapshot] {
        preferences.recentSources
    }

    var collections: [WallpaperCollection] {
        preferences.collections
    }

    var currentAutomationPreset: AutomationPreset {
        guard automationSettings.isEnabled else {
            return .manual
        }

        if automationSettings.scheduleByTimeOfDay,
           automationSettings.scheduleByWeekday,
           automationSettings.changeOnPowerChange,
           automationSettings.changeOnExternalDisplay,
           automationSettings.homeWorkProfilesEnabled {
            return .smart
        }

        if automationSettings.changeOnPowerChange,
           automationSettings.changeOnExternalDisplay {
            return .displayAware
        }

        if automationSettings.changeOnPowerChange {
            return .batteryAware
        }

        if automationSettings.scheduleByTimeOfDay || automationSettings.homeWorkProfilesEnabled {
            return .workday
        }

        return .manual
    }

    var automationSchedulePresentation: AutomationSchedulePresentation {
        _ = clearExpiredAutomationOverrideIfNeeded()
        return AutomationSchedulePresenter.presentation(
            settings: automationSettings,
            collections: preferences.collections,
            powerState: latestPowerState,
            screenCount: NSScreen.screens.count,
            overrideDescription: automationOverrideDescription()
        )
    }

    func shouldOfferManualAutomationOverride() -> Bool {
        _ = clearExpiredAutomationOverrideIfNeeded()
        return automationSettings.isEnabled && automationOverrideUntil == nil
    }

    var canEditCurrentWallpaperWeight: Bool {
        activeCollectionIndex != nil && currentVideoURL != nil
    }

    var currentWallpaperWeight: Int? {
        guard let collectionIndex = activeCollectionIndex,
              let currentVideoURL else {
            return nil
        }

        return max(1, preferences.collections[collectionIndex].weights[currentVideoURL.path] ?? 1)
    }

    var isCurrentFavorite: Bool {
        guard let snapshot = currentSnapshot else {
            return false
        }

        return preferences.favorites.contains(snapshot)
    }

    var statusText: String {
        guard wallpaperEnabled else {
            return "Live Wallpapers for Mac: обои выключены"
        }

        guard let currentSource else {
            return "Live Wallpapers for Mac"
        }

        if case .video = currentSource, playlist.count > 1 {
            return "Live Wallpapers for Mac: \(currentSource.displayName) (\(currentIndex + 1)/\(playlist.count))"
        }

        return "Live Wallpapers for Mac: \(currentSource.displayName)"
    }

    private var currentSource: WallpaperSource? {
        if let imageURL {
            return .image(imageURL)
        }

        guard let currentVideoURL else {
            return nil
        }

        return .video(currentVideoURL)
    }

    private var currentVideoURL: URL? {
        guard playlist.indices.contains(currentIndex) else {
            return nil
        }

        return playlist[currentIndex]
    }

    private var activeCollectionIndex: Int? {
        guard let activeCollectionID = preferences.activeCollectionID else {
            return nil
        }

        return preferences.collections.firstIndex { $0.id == activeCollectionID }
    }

    private var currentSnapshot: WallpaperSourceSnapshot? {
        if let imageURL {
            return WallpaperSourceSnapshot(kind: .image, path: imageURL.path)
        }

        guard let currentVideoURL else {
            return nil
        }

        return WallpaperSourceSnapshot(kind: .singleVideo, path: currentVideoURL.path)
    }

    func restoreLastWallpaperIfNeeded() -> Bool {
        guard behaviorSettings.restoreLastWallpaperOnLaunch,
              let lastSource = preferences.lastSource else {
            return false
        }

        switch lastSource.kind {
        case .singleVideo:
            let url = URL(fileURLWithPath: lastSource.path)
            guard VideoFileInspector.isPlayableVideo(url) else {
                return false
            }

            setSingleVideo(url, rememberSource: false)
            return true

        case .folder:
            let folderURL = URL(fileURLWithPath: lastSource.path, isDirectory: true)
            let urls = VideoPicker.videoURLs(in: folderURL).filter(VideoFileInspector.isPlayableVideo(_:))
            guard !urls.isEmpty else {
                return false
            }

            setPlaylist(urls, sourceFolder: folderURL, rememberSource: false)
            return true

        case .image:
            let url = URL(fileURLWithPath: lastSource.path)
            guard ImageFileInspector.isReadableImage(url) else {
                return false
            }

            setImageWallpaper(url, rememberSource: false)
            return true

        case .collection:
            guard let collection = preferences.collections.first(where: { $0.id == lastSource.path }) else {
                preferences.lastSource = nil
                preferences.activeCollectionID = nil
                savePreferences()
                return false
            }

            applyCollection(collection, rememberAsLastSource: false)
            return true

        case .youtube, .web:
            preferences.lastSource = nil
            savePreferences()
            return false
        }
    }

    func setSingleVideo(_ url: URL, rememberSource: Bool = true) {
        guard VideoFileInspector.isPlayableVideo(url) else {
            AppLogger.log("Skipped unreadable video: \(url.path)")
            return
        }

        wallpaperEnabled = true
        imageURL = nil
        preferences.activeCollectionID = nil
        stopFolderMonitor()
        startPauseMonitorsIfNeeded()
        playlist = [url]
        currentIndex = 0
        if rememberSource {
            rememberLastSource(.singleVideo, path: url.path)
        }
        recordRecent(WallpaperSourceSnapshot(kind: .singleVideo, path: url.path))
        rebuildForCurrentVideo()
        scheduleRotationTimerIfNeeded()
    }

    func setPlaylist(_ urls: [URL], sourceFolder: URL? = nil, rememberSource: Bool = true) {
        let playableURLs = urls.filter(VideoFileInspector.isPlayableVideo(_:))
        guard !playableURLs.isEmpty else {
            AppLogger.log("Skipped playlist without playable videos.")
            return
        }

        wallpaperEnabled = true
        imageURL = nil
        preferences.activeCollectionID = nil
        startPauseMonitorsIfNeeded()
        playlist = playableURLs
        playlistFolderURL = sourceFolder
        currentIndex = 0
        if rememberSource, let sourceFolder {
            rememberLastSource(.folder, path: sourceFolder.path)
            recordRecent(WallpaperSourceSnapshot(kind: .folder, path: sourceFolder.path))
        }
        if let sourceFolder {
            startFolderMonitor(for: sourceFolder)
        } else {
            stopFolderMonitor()
        }
        rebuildForCurrentVideo()
        scheduleRotationTimerIfNeeded()
    }

    @discardableResult
    func setImageWallpaper(_ url: URL, rememberSource: Bool = true) -> Bool {
        guard ImageFileInspector.isReadableImage(url) else {
            AppLogger.log("Skipped unreadable image wallpaper: \(url.path)")
            return false
        }

        wallpaperEnabled = true
        imageURL = url
        preferences.activeCollectionID = nil
        stopFolderMonitor()
        playlist.removeAll()
        currentIndex = 0
        rotationTimer?.invalidate()
        rotationTimer = nil
        startPauseMonitorsIfNeeded()
        if rememberSource {
            rememberLastSource(.image, path: url.path)
        }
        recordRecent(WallpaperSourceSnapshot(kind: .image, path: url.path))
        rebuildForCurrentVideo()
        return true
    }

    func toggleCurrentFavorite() {
        guard let snapshot = currentSnapshot else {
            return
        }

        if let index = preferences.favorites.firstIndex(of: snapshot) {
            preferences.favorites.remove(at: index)
        } else {
            preferences.favorites.insert(snapshot, at: 0)
        }

        savePreferences()
    }

    func applyFavorite(at index: Int) {
        guard preferences.favorites.indices.contains(index) else {
            return
        }

        applySnapshot(preferences.favorites[index])
    }

    func applyRecent(at index: Int) {
        guard preferences.recentSources.indices.contains(index) else {
            return
        }

        applySnapshot(preferences.recentSources[index])
    }

    func saveCurrentAsCollection(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        let items: [WallpaperSourceSnapshot]
        if !playlist.isEmpty {
            items = playlist.map { WallpaperSourceSnapshot(kind: .singleVideo, path: $0.path) }
        } else if let snapshot = currentSnapshot {
            items = [snapshot]
        } else {
            items = []
        }

        guard !items.isEmpty else {
            return
        }

        let weights = Dictionary(items.map { ($0.path, 1) }, uniquingKeysWith: { first, _ in first })
        let collection = WallpaperCollection(name: trimmedName, items: items, weights: weights)
        preferences.collections.insert(collection, at: 0)
        preferences.activeCollectionID = collection.id
        preferences.lastSource = WallpaperSourceSnapshot(kind: .collection, path: collection.id)
        savePreferences()
    }

    func applyCollection(at index: Int) {
        guard preferences.collections.indices.contains(index) else {
            return
        }

        applyCollection(preferences.collections[index], rememberAsLastSource: true)
    }

    func setCurrentWallpaperWeight(_ weight: Int) {
        guard let collectionIndex = activeCollectionIndex,
              let currentVideoURL else {
            return
        }

        preferences.collections[collectionIndex].weights[currentVideoURL.path] = max(1, min(weight, 100))
        savePreferences()
    }

    func currentSourceInformation() -> String {
        guard let currentSource else {
            return "Источник ещё не выбран."
        }

        var lines: [String] = ["Источник: \(currentSource.displayName)"]
        if let activeCollectionIndex {
            let collection = preferences.collections[activeCollectionIndex]
            lines.append("Коллекция: \(collection.name)")
            lines.append("Фонов в коллекции: \(collection.items.count)")
            if let weight = currentWallpaperWeight {
                lines.append("Вес текущего фона: \(weight)")
            }
        }

        switch currentSource {
        case .video(let url):
            lines.append("Путь: \(url.path)")
            lines.append(VideoFileInspector.metadata(for: url).displayDescription)
        case .image(let url):
            lines.append("Путь: \(url.path)")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber {
                lines.append("Размер файла: \(FileInfoFormatter.fileSize(size.int64Value))")
            }
            if let image = NSImage(contentsOf: url) {
                lines.append("Разрешение: \(FileInfoFormatter.dimensions(image.size))")
            }
        }

        lines.append("Пауза: \(isPlaybackPaused ? "да" : "нет")")
        return lines.joined(separator: "\n")
    }

    private func applyCollection(_ collection: WallpaperCollection, rememberAsLastSource: Bool) {
        let videoURLs = collection.items.compactMap { snapshot -> URL? in
            guard snapshot.kind == .singleVideo else {
                return nil
            }

            let url = URL(fileURLWithPath: snapshot.path)
            return VideoFileInspector.isPlayableVideo(url) ? url : nil
        }

        if videoURLs.count == collection.items.count, !videoURLs.isEmpty {
            setPlaylist(videoURLs, rememberSource: false)
            preferences.activeCollectionID = collection.id
            if rememberAsLastSource {
                preferences.lastSource = WallpaperSourceSnapshot(kind: .collection, path: collection.id)
            }
            savePreferences()
            return
        }

        guard let firstAvailableItem = collection.items.first(where: isAvailableCollectionItem(_:)) else {
            AppLogger.log("Collection has no available items: \(collection.name)")
            return
        }

        applySnapshot(firstAvailableItem)
        preferences.activeCollectionID = collection.id
        if rememberAsLastSource {
            preferences.lastSource = WallpaperSourceSnapshot(kind: .collection, path: collection.id)
        }
        savePreferences()
    }

    private func isAvailableCollectionItem(_ snapshot: WallpaperSourceSnapshot) -> Bool {
        switch snapshot.kind {
        case .singleVideo:
            return VideoFileInspector.isPlayableVideo(URL(fileURLWithPath: snapshot.path))
        case .image:
            return ImageFileInspector.isReadableImage(URL(fileURLWithPath: snapshot.path))
        case .folder, .collection, .youtube, .web:
            return false
        }
    }

    func importDroppedURLs(_ urls: [URL]) {
        let folders = urls.filter { $0.hasDirectoryPath }
        if let folder = folders.first {
            let videoURLs = VideoPicker.videoURLs(in: folder)
            if !videoURLs.isEmpty {
                setPlaylist(videoURLs, sourceFolder: folder)
                return
            }
        }

        let presetURL = urls.first { $0.pathExtension.lowercased() == "json" }
        if let presetURL, (try? importPreset(from: presetURL)) != nil {
            return
        }

        let videoURLs = urls
            .filter { VideoPicker.isSupportedVideoURL($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if videoURLs.count > 1 {
            setPlaylist(videoURLs)
        } else if let videoURL = videoURLs.first {
            setSingleVideo(videoURL)
        } else if let imageURL = urls.first(where: ImagePicker.isSupportedImageURL(_:)) {
            setImageWallpaper(imageURL)
        }
    }

    func exportPreset(to url: URL) throws {
        savePreferences()
        try preferencesStore.exportPreferences(to: url, preferences: preferences)
    }

    func importPreset(from url: URL) throws {
        preferences = try preferencesStore.importPreferences(from: url)
        sanitizeLegacySourceState()
        settings = preferences.playback
        behaviorSettings = preferences.behavior
        displaySettings = preferences.displays
        automationSettings = preferences.automation
        behaviorSettings.launchAtLogin = LaunchAtLoginManager.isEnabled
        savePreferences()
        if !restoreLastWallpaperIfNeeded() {
            refreshAllPauseReasons(applyPowerAutomation: true)
        }
    }

    func selectPrevious() {
        guard canSelectPreviousOrNext else {
            return
        }

        currentIndex = (currentIndex - 1 + playlist.count) % playlist.count
        rebuildForCurrentVideo()
        scheduleRotationTimerIfNeeded()
    }

    func selectNext() {
        guard canSelectPreviousOrNext else {
            return
        }

        currentIndex = nextIndex()
        rebuildForCurrentVideo()
        scheduleRotationTimerIfNeeded()
    }

    func setUserPaused(_ isPaused: Bool) {
        setPlaybackPauseReason(.userPaused, isActive: isPaused)
    }

    func setWallpaperEnabled(_ isEnabled: Bool) {
        guard wallpaperEnabled != isEnabled else {
            return
        }

        wallpaperEnabled = isEnabled
        if isEnabled {
            startPauseMonitorsIfNeeded()
            rebuildForCurrentVideo()
            scheduleRotationTimerIfNeeded()
        } else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            closeVideoWindows()
            systemWallpaperController.restoreOriginalWallpapers()
        }
    }

    func setDisplayMode(_ mode: WallpaperDisplayMode) {
        settings.displayMode = mode
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setContentScale(_ scale: Double) {
        settings.displayMode = .manual
        settings.contentScale = min(max(scale, 0.25), 3)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setContentOffsetX(_ offset: Double) {
        settings.displayMode = .manual
        settings.contentOffsetX = min(max(offset, -0.5), 0.5)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setContentOffsetY(_ offset: Double) {
        settings.displayMode = .manual
        settings.contentOffsetY = min(max(offset, -0.5), 0.5)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setPlaybackRate(_ rate: Double) {
        settings.playbackRate = min(max(rate, 0.25), 2)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setShuffle(_ isEnabled: Bool) {
        settings.isShuffleEnabled = isEnabled
        savePreferences()
    }

    func setRandomStart(_ isEnabled: Bool) {
        settings.startsAtRandomPosition = isEnabled
        savePreferences()
        rebuildForCurrentVideo()
    }

    func setRotationInterval(_ interval: WallpaperRotationInterval) {
        settings.rotationInterval = interval
        savePreferences()
        scheduleRotationTimerIfNeeded()
    }

    func setVolume(_ volume: Double) {
        settings.volume = min(max(volume, 0), 1)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setBrightness(_ brightness: Double) {
        settings.brightness = min(max(brightness, 0.1), 1)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setDimming(_ dimming: Double) {
        settings.dimming = min(max(dimming, 0), 0.85)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setContrast(_ contrast: Double) {
        settings.contrast = min(max(contrast, 0.5), 1.8)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setSaturation(_ saturation: Double) {
        settings.saturation = min(max(saturation, 0), 2)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setBlurRadius(_ radius: Double) {
        settings.blurRadius = min(max(radius, 0), 20)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setHueDegrees(_ degrees: Double) {
        settings.hueDegrees = min(max(degrees, -180), 180)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setVignette(_ vignette: Double) {
        settings.vignette = min(max(vignette, 0), 1)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setGrain(_ grain: Double) {
        settings.grain = min(max(grain, 0), 1)
        savePreferences()
        windows.forEach { $0.applySettings(settings, isPaused: isPlaybackPaused) }
    }

    func setContinueFromLastPosition(_ isEnabled: Bool) {
        settings.continuesFromLastPosition = isEnabled
        savePreferences()
        rebuildForCurrentVideo()
    }

    func setCinematicLoop(_ isEnabled: Bool) {
        settings.cinematicLoop = isEnabled
        savePreferences()
        rebuildForCurrentVideo()
    }

    func setFPSLimit(_ fpsLimit: WallpaperFPSLimit) {
        settings.fpsLimit = fpsLimit
        savePreferences()
        rebuildForCurrentVideo()
    }

    func setEconomyMode(_ isEnabled: Bool) {
        settings.isEconomyModeEnabled = isEnabled
        savePreferences()
        rebuildForCurrentVideo()
    }

    func setTrim(startSeconds: Double, endSeconds: Double) {
        settings.trim = VideoTrim(
            startSeconds: max(0, startSeconds),
            endSeconds: max(0, endSeconds)
        )
        savePreferences()
        rebuildForCurrentVideo()
    }

    func setPauseOnBattery(_ isEnabled: Bool) {
        behaviorSettings.pauseOnBattery = isEnabled
        savePreferences()
        refreshPowerPauseReasons()
    }

    func setPauseOnLowBattery(_ isEnabled: Bool) {
        behaviorSettings.pauseOnLowBattery = isEnabled
        savePreferences()
        refreshPowerPauseReasons()
    }

    func setPauseInFullscreen(_ isEnabled: Bool) {
        behaviorSettings.pauseInFullscreen = isEnabled
        savePreferences()
        refreshFullscreenPauseReason()
    }

    func setPauseWhenDesktopCovered(_ isEnabled: Bool) {
        behaviorSettings.pauseWhenDesktopCovered = isEnabled
        savePreferences()
        refreshDesktopCoveredPauseReason()
    }

    func setPauseOnScreenLock(_ isEnabled: Bool) {
        behaviorSettings.pauseOnScreenLock = isEnabled
        savePreferences()
        refreshScreenLockPauseReason()
    }

    func setPauseOnHighSystemLoad(_ isEnabled: Bool) {
        behaviorSettings.pauseOnHighSystemLoad = isEnabled
        savePreferences()
        refreshThermalPauseReason()
    }

    func setPauseDuringGamesOrCalls(_ isEnabled: Bool) {
        behaviorSettings.pauseDuringGamesOrCalls = isEnabled
        savePreferences()
        refreshGameOrCallPauseReason()
    }

    func setAutoLowerQualityOnLoad(_ isEnabled: Bool) {
        behaviorSettings.autoLowerQualityOnLoad = isEnabled
        savePreferences()
        refreshThermalPauseReason()
    }

    func setWarnAboutHeavyFiles(_ isEnabled: Bool) {
        behaviorSettings.warnAboutHeavyFiles = isEnabled
        savePreferences()
    }

    func setLaunchAtLogin(_ isEnabled: Bool) throws {
        try LaunchAtLoginManager.setEnabled(isEnabled)
        behaviorSettings.launchAtLogin = LaunchAtLoginManager.isEnabled
        savePreferences()
    }

    func setRestoreLastWallpaperOnLaunch(_ isEnabled: Bool) {
        behaviorSettings.restoreLastWallpaperOnLaunch = isEnabled
        savePreferences()
    }

    func setAppLanguage(_ language: AppLanguage) {
        behaviorSettings.appLanguage = language
        savePreferences()
    }

    func setDisplaySourceMode(_ mode: WallpaperDisplaySourceMode) {
        displaySettings.sourceMode = mode
        savePreferences()
        rebuildForCurrentVideo()
    }

    func setSynchronizePlayback(_ isEnabled: Bool) {
        displaySettings.synchronizePlayback = isEnabled
        savePreferences()
        rebuildForCurrentVideo()
    }

    func setAutomationEnabled(_ isEnabled: Bool) {
        automationSettings.isEnabled = isEnabled
        savePreferences()
        scheduleAutomationTimerIfNeeded()
        applyAutomationIfNeeded(force: true)
    }

    func setScheduleByTimeOfDay(_ isEnabled: Bool) {
        automationSettings.scheduleByTimeOfDay = isEnabled
        savePreferences()
        scheduleAutomationTimerIfNeeded()
        applyAutomationIfNeeded(force: true)
    }

    func setScheduleByWeekday(_ isEnabled: Bool) {
        automationSettings.scheduleByWeekday = isEnabled
        savePreferences()
        scheduleAutomationTimerIfNeeded()
        applyAutomationIfNeeded(force: true)
    }

    func setChangeOnPowerChange(_ isEnabled: Bool) {
        automationSettings.changeOnPowerChange = isEnabled
        savePreferences()
        applyPowerAutomationIfNeeded()
    }

    func setChangeOnExternalDisplay(_ isEnabled: Bool) {
        automationSettings.changeOnExternalDisplay = isEnabled
        savePreferences()
        applyExternalDisplayAutomationIfNeeded()
    }

    func setHomeWorkProfilesEnabled(_ isEnabled: Bool) {
        automationSettings.homeWorkProfilesEnabled = isEnabled
        savePreferences()
        applyAutomationIfNeeded(force: true)
    }

    func applyAutomationPreset(_ preset: AutomationPreset) {
        switch preset {
        case .manual:
            automationSettings.isEnabled = false
            automationSettings.scheduleByTimeOfDay = false
            automationSettings.scheduleByWeekday = false
            automationSettings.changeOnPowerChange = false
            automationSettings.changeOnExternalDisplay = false
            automationSettings.homeWorkProfilesEnabled = false

        case .workday:
            automationSettings.isEnabled = true
            automationSettings.scheduleByTimeOfDay = true
            automationSettings.scheduleByWeekday = false
            automationSettings.changeOnPowerChange = false
            automationSettings.changeOnExternalDisplay = false
            automationSettings.homeWorkProfilesEnabled = true

        case .batteryAware:
            automationSettings.isEnabled = true
            automationSettings.scheduleByTimeOfDay = false
            automationSettings.scheduleByWeekday = false
            automationSettings.changeOnPowerChange = true
            automationSettings.changeOnExternalDisplay = false
            automationSettings.homeWorkProfilesEnabled = false

        case .displayAware:
            automationSettings.isEnabled = true
            automationSettings.scheduleByTimeOfDay = false
            automationSettings.scheduleByWeekday = false
            automationSettings.changeOnPowerChange = true
            automationSettings.changeOnExternalDisplay = true
            automationSettings.homeWorkProfilesEnabled = false

        case .smart:
            automationSettings.isEnabled = true
            automationSettings.scheduleByTimeOfDay = true
            automationSettings.scheduleByWeekday = true
            automationSettings.changeOnPowerChange = true
            automationSettings.changeOnExternalDisplay = true
            automationSettings.homeWorkProfilesEnabled = true
        }

        lastAutomationSignature = nil
        savePreferences()
        scheduleAutomationTimerIfNeeded()
        applyAutomationIfNeeded(force: true)
        applyPowerAutomationIfNeeded()
        applyExternalDisplayAutomationIfNeeded()
    }

    func applyAutomationTemplate(_ template: AutomationTemplateKind) {
        automationOverrideUntil = nil
        automationOverrideLabel = nil
        switch template {
        case .dayNight:
            automationSettings.isEnabled = true
            automationSettings.scheduleByTimeOfDay = true
            automationSettings.scheduleByWeekday = false
            automationSettings.changeOnPowerChange = false
            automationSettings.changeOnExternalDisplay = false
            automationSettings.homeWorkProfilesEnabled = false

        case .workday:
            applyAutomationPreset(.workday)
            return

        case .batterySaver:
            applyAutomationPreset(.batteryAware)
            return

        case .gaming:
            automationSettings.isEnabled = false
            automationSettings.scheduleByTimeOfDay = false
            automationSettings.scheduleByWeekday = false
            automationSettings.changeOnPowerChange = false
            automationSettings.changeOnExternalDisplay = false
            automationSettings.homeWorkProfilesEnabled = false
            WallpaperProfile.gaming.apply(to: &settings, behavior: &behaviorSettings)
        }

        lastAutomationSignature = nil
        savePreferences()
        scheduleAutomationTimerIfNeeded()
        applyAutomationIfNeeded(force: true)
        applyPowerAutomationIfNeeded()
        applyExternalDisplayAutomationIfNeeded()
        if template == .gaming {
            refreshAllPauseReasons(applyPowerAutomation: false)
            rebuildForCurrentVideo()
        }
    }

    func setAutomationRule(_ kind: AutomationRuleKind, enabled: Bool) {
        automationOverrideUntil = nil
        automationOverrideLabel = nil
        if enabled {
            automationSettings.isEnabled = true
        }

        switch kind {
        case .externalDisplay:
            automationSettings.changeOnExternalDisplay = enabled
        case .power:
            automationSettings.changeOnPowerChange = enabled
        case .homeWork:
            automationSettings.homeWorkProfilesEnabled = enabled
        case .weekday:
            automationSettings.scheduleByWeekday = enabled
        case .timeOfDay:
            automationSettings.scheduleByTimeOfDay = enabled
        }

        lastAutomationSignature = nil
        savePreferences()
        scheduleAutomationTimerIfNeeded()
        applyAutomationIfNeeded(force: true)
        applyPowerAutomationIfNeeded()
        applyExternalDisplayAutomationIfNeeded()
    }

    func updateAutomationSlotProfiles(_ slotProfiles: [AutomationTimeSlot: WallpaperProfile]) {
        for (slot, profile) in slotProfiles {
            automationSettings.slotProfiles[slot] = profile
        }

        lastAutomationSignature = nil
        savePreferences()
        scheduleAutomationTimerIfNeeded()
        applyAutomationIfNeeded(force: true)
    }

    func applyManualAutomationOverride(_ option: AutomationOverrideOption) {
        switch option {
        case .untilNextChange:
            let nextDate = AutomationSchedulePresenter.nextScheduledChangeDate(settings: automationSettings)
                ?? Date().addingTimeInterval(30 * 60)
            automationOverrideUntil = nextDate
            automationOverrideLabel = "Ручной фон используется до следующего изменения"

        case .thirtyMinutes:
            automationOverrideUntil = Date().addingTimeInterval(30 * 60)
            automationOverrideLabel = "Ручной фон используется 30 минут"

        case .oneHour:
            automationOverrideUntil = Date().addingTimeInterval(60 * 60)
            automationOverrideLabel = "Ручной фон используется 1 час"

        case .disableSchedule:
            automationOverrideUntil = nil
            automationOverrideLabel = nil
            setAutomationEnabled(false)
            return
        }

        lastAutomationSignature = nil
        scheduleAutomationTimerIfNeeded()
    }

    func clearManualAutomationOverride() {
        automationOverrideUntil = nil
        automationOverrideLabel = nil
        lastAutomationSignature = nil
        scheduleAutomationTimerIfNeeded()
        applyAutomationIfNeeded(force: true)
        applyPowerAutomationIfNeeded()
        applyExternalDisplayAutomationIfNeeded()
    }

    func applyProfile(_ profile: WallpaperProfile) {
        profile.apply(to: &settings, behavior: &behaviorSettings)
        savePreferences()
        refreshAllPauseReasons(applyPowerAutomation: true)
        rebuildForCurrentVideo()
    }

    func restoreSystemWallpaperNow() {
        wallpaperEnabled = false
        rotationTimer?.invalidate()
        rotationTimer = nil
        closeVideoWindows()
        systemWallpaperController.restoreOriginalWallpapers()
    }

    func clearCache() {
        systemWallpaperController.cleanUpUnusedPosterFiles()
    }

    func resetAllSettings() {
        restoreSystemWallpaperNow()
        playlist.removeAll()
        imageURL = nil
        stopFolderMonitor()
        currentIndex = 0
        settings = WallpaperPlaybackSettings()
        behaviorSettings = WallpaperBehaviorSettings()
        displaySettings = WallpaperDisplaySettings()
        automationSettings = WallpaperAutomationSettings()
        behaviorSettings.launchAtLogin = LaunchAtLoginManager.isEnabled
        try? LaunchAtLoginManager.setEnabled(false)
        behaviorSettings.launchAtLogin = false
        preferences = AppPreferences()
        preferencesStore.clear()
        systemWallpaperController.cleanUpUnusedPosterFiles()
        pauseReasons.removeAll()
        latestFullscreenState = false
        latestPowerState = PowerStateReader.current()
        latestDesktopCoveredState = false
        latestGameOrCallState = false
        latestThermalState = ProcessInfo.processInfo.thermalState
        latestScreenLockedState = false
        automationOverrideUntil = nil
        automationOverrideLabel = nil
    }

    func stop() {
        fullscreenPauseMonitor?.stop()
        fullscreenPauseMonitor = nil
        systemActivityPauseMonitor?.stop()
        systemActivityPauseMonitor = nil
        powerStatePauseMonitor?.stop()
        powerStatePauseMonitor = nil
        desktopCoveragePauseMonitor?.stop()
        desktopCoveragePauseMonitor = nil
        activeAppPauseMonitor?.stop()
        activeAppPauseMonitor = nil
        thermalPressureMonitor?.stop()
        thermalPressureMonitor = nil
        screenLockPauseMonitor?.stop()
        screenLockPauseMonitor = nil
        audioOutputRouteMonitor?.stop()
        audioOutputRouteMonitor = nil
        audioOutputRecoveryWorkItem?.cancel()
        audioOutputRecoveryWorkItem = nil
        stopFolderMonitor()
        rotationTimer?.invalidate()
        rotationTimer = nil
        automationTimer?.invalidate()
        automationTimer = nil
        automationOverrideUntil = nil
        automationOverrideLabel = nil
        pauseReasons.removeAll()
        closeVideoWindows()
        systemWallpaperController.restoreOriginalWallpapers()
    }

    func cleanUpUnusedPosterFiles() {
        systemWallpaperController.cleanUpUnusedPosterFiles()
    }

    private func rebuildForCurrentVideo(forceResumePosition: Bool = false) {
        guard let currentSource else {
            return
        }

        guard wallpaperEnabled else {
            closeVideoWindows()
            return
        }

        closeVideoWindows()

        windows = NSScreen.screens.enumerated().map { index, screen in
            let source = source(forScreenAt: index) ?? currentSource
            let configuration = WallpaperConfiguration(
                source: source,
                settings: settings,
                resumePositionSeconds: resumePosition(for: source, force: forceResumePosition)
            )

            return WallpaperWindow(
                screen: screen,
                configuration: configuration,
                startsPaused: isPlaybackPaused
            )
        }

        windows.forEach { $0.show() }
        switch currentSource {
        case .video(let url):
            systemWallpaperController.applyPosterWallpaper(
                for: url,
                trimStartSeconds: settings.trim.startSeconds
            )
        case .image(let url):
            systemWallpaperController.applyImageWallpaper(for: url)
        }
    }

    private func closeVideoWindows() {
        capturePlaybackPositions()
        let closingWindows = windows
        windows.removeAll()
        closingWindows.forEach { window in
            window.stopPlayback()
            window.orderOut(nil)
            window.close()
        }
    }

    private func capturePlaybackPositions() {
        for window in windows {
            guard case .video(let url) = window.source,
                  let seconds = window.playbackPositionSeconds(),
                  seconds.isFinite,
                  seconds > 0 else {
                continue
            }

            preferences.videoPositions[url.path] = seconds
        }
        savePreferences()
    }

    private func resumePosition(for source: WallpaperSource, force: Bool = false) -> Double? {
        guard force || settings.continuesFromLastPosition,
              case .video(let url) = source else {
            return nil
        }

        return preferences.videoPositions[url.path]
    }

    private func source(forScreenAt index: Int) -> WallpaperSource? {
        guard displaySettings.sourceMode == .playlistItemPerDisplay,
              !playlist.isEmpty,
              imageURL == nil else {
            return currentSource
        }

        return .video(playlist[index % playlist.count])
    }

    private func nextIndex() -> Int {
        guard settings.isShuffleEnabled, playlist.count > 2 else {
            return (currentIndex + 1) % playlist.count
        }

        if let weightedIndex = weightedRandomNextIndex() {
            return weightedIndex
        }

        let availableIndices = playlist.indices.filter { $0 != currentIndex }
        return availableIndices.randomElement() ?? ((currentIndex + 1) % playlist.count)
    }

    private func weightedRandomNextIndex() -> Int? {
        guard let activeCollectionIndex else {
            return nil
        }

        let collection = preferences.collections[activeCollectionIndex]
        let weightedCandidates = playlist.indices
            .filter { $0 != currentIndex }
            .map { index in
                (index: index, weight: max(1, collection.weights[playlist[index].path] ?? 1))
            }
        let totalWeight = weightedCandidates.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else {
            return nil
        }

        var target = Int.random(in: 0..<totalWeight)
        for candidate in weightedCandidates {
            if target < candidate.weight {
                return candidate.index
            }
            target -= candidate.weight
        }

        return weightedCandidates.last?.index
    }

    private func scheduleRotationTimerIfNeeded() {
        rotationTimer?.invalidate()
        rotationTimer = nil

        guard playlist.count > 1,
              imageURL == nil,
              let interval = settings.rotationInterval.timeInterval else {
            return
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.selectNext()
        }
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    private func startFolderMonitor(for folderURL: URL) {
        stopFolderMonitor()
        playlistFolderURL = folderURL
        let descriptor = open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }

        folderMonitorFileDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reloadPlaylistFolder()
        }
        source.setCancelHandler { [weak self] in
            if let descriptor = self?.folderMonitorFileDescriptor,
               descriptor >= 0 {
                close(descriptor)
            }
            self?.folderMonitorFileDescriptor = -1
        }
        source.resume()
        folderMonitorSource = source
    }

    private func stopFolderMonitor() {
        folderMonitorSource?.cancel()
        folderMonitorSource = nil
        playlistFolderURL = nil
    }

    private func reloadPlaylistFolder() {
        guard let folderURL = playlistFolderURL else {
            return
        }

        let urls = VideoPicker.videoURLs(in: folderURL).filter(VideoFileInspector.isPlayableVideo(_:))
        guard !urls.isEmpty else {
            AppLogger.log("Playlist folder update ignored because no playable videos were found: \(folderURL.path)")
            return
        }

        playlist = urls
        currentIndex = min(currentIndex, max(0, playlist.count - 1))
        rebuildForCurrentVideo()
        scheduleRotationTimerIfNeeded()
    }

    private var isPlaybackPaused: Bool {
        !pauseReasons.isEmpty
    }

    private func startPauseMonitorsIfNeeded() {
        startFullscreenPauseMonitorIfNeeded()
        startSystemActivityPauseMonitorIfNeeded()
        startPowerStatePauseMonitorIfNeeded()
        startDesktopCoveragePauseMonitorIfNeeded()
        startActiveAppPauseMonitorIfNeeded()
        startThermalPressureMonitorIfNeeded()
        startScreenLockPauseMonitorIfNeeded()
        startAudioOutputRouteMonitorIfNeeded()
    }

    private func startFullscreenPauseMonitorIfNeeded() {
        guard fullscreenPauseMonitor == nil else { return }

        let monitor = FullscreenPauseMonitor { [weak self] isFullscreenActive in
            self?.latestFullscreenState = isFullscreenActive
            self?.refreshFullscreenPauseReason()
        }
        fullscreenPauseMonitor = monitor
        monitor.start()
    }

    private func startSystemActivityPauseMonitorIfNeeded() {
        guard systemActivityPauseMonitor == nil else { return }

        let monitor = SystemActivityPauseMonitor { [weak self] reason, isActive in
            self?.setPlaybackPauseReason(reason, isActive: isActive)
        }
        systemActivityPauseMonitor = monitor
        monitor.start()
    }

    private func startPowerStatePauseMonitorIfNeeded() {
        guard powerStatePauseMonitor == nil else { return }

        let monitor = PowerStatePauseMonitor { [weak self] powerState in
            self?.latestPowerState = powerState
            self?.refreshPowerPauseReasons()
        }
        powerStatePauseMonitor = monitor
        monitor.start()
    }

    private func startDesktopCoveragePauseMonitorIfNeeded() {
        guard desktopCoveragePauseMonitor == nil else { return }

        let monitor = DesktopCoveragePauseMonitor { [weak self] isCovered in
            self?.latestDesktopCoveredState = isCovered
            self?.refreshDesktopCoveredPauseReason()
        }
        desktopCoveragePauseMonitor = monitor
        monitor.start()
    }

    private func startActiveAppPauseMonitorIfNeeded() {
        guard activeAppPauseMonitor == nil else { return }

        let monitor = ActiveAppPauseMonitor { [weak self] isGameOrCall in
            self?.latestGameOrCallState = isGameOrCall
            self?.refreshGameOrCallPauseReason()
        }
        activeAppPauseMonitor = monitor
        monitor.start()
    }

    private func startThermalPressureMonitorIfNeeded() {
        guard thermalPressureMonitor == nil else { return }

        let monitor = ThermalPressureMonitor { [weak self] thermalState in
            self?.latestThermalState = thermalState
            self?.refreshThermalPauseReason()
        }
        thermalPressureMonitor = monitor
        monitor.start()
    }

    private func startScreenLockPauseMonitorIfNeeded() {
        guard screenLockPauseMonitor == nil else { return }

        let monitor = ScreenLockPauseMonitor { [weak self] isLocked in
            self?.latestScreenLockedState = isLocked
            self?.refreshScreenLockPauseReason()
        }
        screenLockPauseMonitor = monitor
        monitor.start()
    }

    private func startAudioOutputRouteMonitorIfNeeded() {
        guard audioOutputRouteMonitor == nil else { return }

        let monitor = AudioOutputRouteMonitor { [weak self] in
            self?.scheduleAudioOutputRecovery()
        }
        audioOutputRouteMonitor = monitor
        monitor.start()
    }

    private func scheduleAudioOutputRecovery() {
        guard wallpaperEnabled,
              case .video = currentSource else {
            return
        }

        audioOutputRecoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.wallpaperEnabled,
                  case .video = self.currentSource else {
                return
            }

            AppLogger.log("Audio output route changed; rebuilding video wallpaper to recover AVPlayer rendering.")
            self.rebuildForCurrentVideo(forceResumePosition: true)
        }

        audioOutputRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func refreshFullscreenPauseReason() {
        setPlaybackPauseReason(
            .fullscreenApp,
            isActive: behaviorSettings.pauseInFullscreen && latestFullscreenState
        )
    }

    private func refreshPowerPauseReasons(applyAutomation: Bool = true) {
        setPlaybackPauseReason(.lowPowerMode, isActive: latestPowerState.isLowPowerModeEnabled)
        setPlaybackPauseReason(
            .batteryPower,
            isActive: behaviorSettings.pauseOnBattery && latestPowerState.isOnBatteryPower
        )

        let lowBatteryActive = behaviorSettings.pauseOnLowBattery
            && latestPowerState.isOnBatteryPower
            && (latestPowerState.batteryPercentage ?? 101) <= behaviorSettings.lowBatteryThreshold
        setPlaybackPauseReason(.lowBattery, isActive: lowBatteryActive)
        if applyAutomation {
            applyPowerAutomationIfNeeded()
        }
    }

    private func refreshAllPauseReasons(applyPowerAutomation: Bool) {
        refreshPowerPauseReasons(applyAutomation: applyPowerAutomation)
        refreshFullscreenPauseReason()
        refreshDesktopCoveredPauseReason()
        refreshScreenLockPauseReason()
        refreshGameOrCallPauseReason()
        refreshThermalPauseReason()
    }

    private func refreshDesktopCoveredPauseReason() {
        setPlaybackPauseReason(
            .desktopCovered,
            isActive: behaviorSettings.pauseWhenDesktopCovered && latestDesktopCoveredState
        )
    }

    private func refreshScreenLockPauseReason() {
        setPlaybackPauseReason(
            .screenLocked,
            isActive: behaviorSettings.pauseOnScreenLock && latestScreenLockedState
        )
    }

    private func refreshGameOrCallPauseReason() {
        setPlaybackPauseReason(
            .gameOrCall,
            isActive: behaviorSettings.pauseDuringGamesOrCalls && latestGameOrCallState
        )
    }

    private func refreshThermalPauseReason() {
        let highLoad = latestThermalState == .serious || latestThermalState == .critical
        let shouldPause = behaviorSettings.pauseOnHighSystemLoad && highLoad
        setPlaybackPauseReason(.highSystemLoad, isActive: shouldPause)

        if behaviorSettings.autoLowerQualityOnLoad,
           latestThermalState == .serious || latestThermalState == .critical,
           !settings.isEconomyModeEnabled {
            settings.isEconomyModeEnabled = true
            savePreferences()
            rebuildForCurrentVideo()
        }
    }

    private func setPlaybackPauseReason(_ reason: PlaybackPauseReason, isActive: Bool) {
        let wasPaused = isPlaybackPaused

        if isActive {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }

        let shouldPause = isPlaybackPaused
        guard wasPaused != shouldPause else { return }

        windows.forEach { $0.setPlaybackPaused(shouldPause) }
    }

    private func rememberLastSource(_ kind: WallpaperSourceSnapshot.Kind, path: String) {
        preferences.lastSource = WallpaperSourceSnapshot(kind: kind, path: path)
        savePreferences()
    }

    @discardableResult
    private func clearExpiredAutomationOverrideIfNeeded() -> Bool {
        guard let automationOverrideUntil,
              automationOverrideUntil <= Date() else {
            return false
        }

        self.automationOverrideUntil = nil
        automationOverrideLabel = nil
        lastAutomationSignature = nil
        return true
    }

    private func automationOverrideDescription() -> String? {
        _ = clearExpiredAutomationOverrideIfNeeded()
        guard let automationOverrideUntil else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "HH:mm"
        let label = automationOverrideLabel ?? "Ручной фон используется"
        return "\(label) до \(formatter.string(from: automationOverrideUntil))"
    }

    private func scheduleAutomationTimerIfNeeded() {
        automationTimer?.invalidate()
        automationTimer = nil

        if clearExpiredAutomationOverrideIfNeeded() {
            applyAutomationIfNeeded(force: true)
            applyPowerAutomationIfNeeded()
            applyExternalDisplayAutomationIfNeeded()
        }

        if let automationOverrideUntil {
            let delay = max(1, automationOverrideUntil.timeIntervalSinceNow)
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.automationOverrideUntil = nil
                self.automationOverrideLabel = nil
                self.lastAutomationSignature = nil
                self.scheduleAutomationTimerIfNeeded()
                self.applyAutomationIfNeeded(force: true)
                self.applyPowerAutomationIfNeeded()
                self.applyExternalDisplayAutomationIfNeeded()
            }
            RunLoop.main.add(timer, forMode: .common)
            automationTimer = timer
            return
        }

        guard automationSettings.isEnabled,
              automationSettings.scheduleByTimeOfDay
                || automationSettings.scheduleByWeekday
                || automationSettings.homeWorkProfilesEnabled else {
            return
        }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.applyAutomationIfNeeded(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        automationTimer = timer
    }

    private func applyAutomationIfNeeded(force: Bool) {
        guard automationSettings.isEnabled else {
            return
        }

        if clearExpiredAutomationOverrideIfNeeded() {
            scheduleAutomationTimerIfNeeded()
        }

        guard automationOverrideUntil == nil else {
            return
        }

        var profile: WallpaperProfile?
        var collectionToApply: WallpaperCollection?
        var signatureParts: [String] = []

        if automationSettings.scheduleByTimeOfDay {
            let slot = currentTimeSlot()
            profile = automationSettings.slotProfiles[slot] ?? slot.defaultProfile
            signatureParts.append("slot:\(slot.rawValue)")
        }

        if automationSettings.scheduleByWeekday {
            let weekday = Calendar.current.component(.weekday, from: Date())
            profile = (weekday == 1 || weekday == 7) ? .cinematic : .work
            if let collectionID = automationSettings.weekdayCollectionIDs[weekday],
               let collection = preferences.collections.first(where: { $0.id == collectionID }) {
                collectionToApply = collection
            } else if !preferences.collections.isEmpty {
                let collectionIndex = max(0, weekday - 1) % preferences.collections.count
                collectionToApply = preferences.collections[collectionIndex]
            }
            signatureParts.append("weekday:\(weekday)")
        }

        if automationSettings.homeWorkProfilesEnabled {
            let hour = Calendar.current.component(.hour, from: Date())
            profile = (9...18).contains(hour) ? .work : .cinematic
            signatureParts.append("homework:\(hour)")
        }

        guard profile != nil || collectionToApply != nil else {
            return
        }

        if let collectionToApply {
            signatureParts.append("collection:\(collectionToApply.id)")
        }

        let signature = signatureParts.joined(separator: "|")
        guard force || signature != lastAutomationSignature else {
            return
        }

        lastAutomationSignature = signature
        if let profile {
            profile.apply(to: &settings, behavior: &behaviorSettings)
            savePreferences()
            refreshAllPauseReasons(applyPowerAutomation: false)
        }

        if let collectionToApply {
            applyCollection(collectionToApply, rememberAsLastSource: true)
        } else {
            rebuildForCurrentVideo()
        }
    }

    private func applyPowerAutomationIfNeeded() {
        guard automationSettings.isEnabled,
              automationSettings.changeOnPowerChange else {
            return
        }

        if clearExpiredAutomationOverrideIfNeeded() {
            scheduleAutomationTimerIfNeeded()
        }

        guard automationOverrideUntil == nil else {
            return
        }

        let signature = latestPowerState.isOnBatteryPower ? "power:battery" : "power:charger"
        guard signature != lastAutomationSignature else {
            return
        }

        lastAutomationSignature = signature
        let profile: WallpaperProfile = latestPowerState.isOnBatteryPower ? .batterySaver : .cinematic
        profile.apply(to: &settings, behavior: &behaviorSettings)
        savePreferences()
        refreshAllPauseReasons(applyPowerAutomation: false)
        rebuildForCurrentVideo()
    }

    private func applyExternalDisplayAutomationIfNeeded() {
        guard automationSettings.isEnabled,
              automationSettings.changeOnExternalDisplay else {
            return
        }

        if clearExpiredAutomationOverrideIfNeeded() {
            scheduleAutomationTimerIfNeeded()
        }

        guard automationOverrideUntil == nil else {
            return
        }

        let signature = "displays:\(NSScreen.screens.count)"
        guard signature != lastAutomationSignature else {
            return
        }

        lastAutomationSignature = signature
        let profile: WallpaperProfile = NSScreen.screens.count > 1 ? .performance : .cinematic
        profile.apply(to: &settings, behavior: &behaviorSettings)
        savePreferences()
        refreshAllPauseReasons(applyPowerAutomation: false)
        rebuildForCurrentVideo()
    }

    private func currentTimeSlot() -> AutomationTimeSlot {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<12:
            return .morning
        case 12..<18:
            return .day
        case 18..<23:
            return .evening
        default:
            return .night
        }
    }

    private func recordRecent(_ snapshot: WallpaperSourceSnapshot) {
        preferences.recentSources.removeAll { $0 == snapshot }
        preferences.recentSources.insert(snapshot, at: 0)
        preferences.recentSources = Array(preferences.recentSources.prefix(12))
        savePreferences()
    }

    private func applySnapshot(_ snapshot: WallpaperSourceSnapshot) {
        switch snapshot.kind {
        case .singleVideo:
            let url = URL(fileURLWithPath: snapshot.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            setSingleVideo(url)
        case .folder:
            let folderURL = URL(fileURLWithPath: snapshot.path, isDirectory: true)
            let urls = VideoPicker.videoURLs(in: folderURL).filter(VideoFileInspector.isPlayableVideo(_:))
            guard !urls.isEmpty else { return }
            setPlaylist(urls, sourceFolder: folderURL)
        case .image:
            let url = URL(fileURLWithPath: snapshot.path)
            guard ImageFileInspector.isReadableImage(url) else { return }
            setImageWallpaper(url)
        case .collection:
            guard let collection = preferences.collections.first(where: { $0.id == snapshot.path }) else { return }
            applyCollection(collection, rememberAsLastSource: true)
        case .youtube, .web:
            preferences.lastSource = nil
            sanitizeLegacySourceState()
            savePreferences()
        }
    }

    private func sanitizeLegacySourceState() {
        preferences.favorites.removeAll(where: isLegacySource(_:))
        preferences.recentSources.removeAll(where: isLegacySource(_:))
        preferences.collections = preferences.collections.compactMap { collection in
            var sanitizedCollection = collection
            sanitizedCollection.items.removeAll(where: isLegacySource(_:))
            sanitizedCollection.favoriteIDs = sanitizedCollection.favoriteIDs.filter { id in
                sanitizedCollection.items.contains { $0.path == id }
            }
            sanitizedCollection.weights = sanitizedCollection.weights.filter { key, _ in
                sanitizedCollection.items.contains { $0.path == key }
            }
            return sanitizedCollection.items.isEmpty ? nil : sanitizedCollection
        }

        if let lastSource = preferences.lastSource,
           isLegacySource(lastSource) {
            preferences.lastSource = nil
        }

        if let activeCollectionID = preferences.activeCollectionID,
           !preferences.collections.contains(where: { $0.id == activeCollectionID }) {
            preferences.activeCollectionID = nil
        }
    }

    private func isLegacySource(_ snapshot: WallpaperSourceSnapshot) -> Bool {
        snapshot.kind == .youtube || snapshot.kind == .web
    }

    private func savePreferences() {
        preferences.playback = settings
        preferences.behavior = behaviorSettings
        preferences.displays = displaySettings
        preferences.automation = automationSettings
        preferencesStore.save(preferences)
    }
}

enum PlaybackPauseReason: Hashable {
    case userPaused
    case fullscreenApp
    case sessionInactive
    case screensAsleep
    case lowPowerMode
    case batteryPower
    case lowBattery
    case desktopCovered
    case screenLocked
    case highSystemLoad
    case gameOrCall
}

struct GlobalHotkeyActions {
    let toggleWallpaper: () -> Void
    let togglePause: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let toggleEconomy: () -> Void
    let showMenu: () -> Void
}

final class GlobalHotkeyController {
    private enum HotkeyID: UInt32 {
        case toggleWallpaper = 1
        case togglePause = 2
        case previous = 3
        case next = 4
        case toggleEconomy = 5
        case showMenu = 6
    }

    private var actions: GlobalHotkeyActions?
    private var hotkeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?

    deinit {
        stop()
    }

    func start(actions: GlobalHotkeyActions) {
        stop()
        self.actions = actions

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        register(.toggleWallpaper, keyCode: UInt32(kVK_ANSI_W))
        register(.togglePause, keyCode: UInt32(kVK_Space))
        register(.previous, keyCode: UInt32(kVK_LeftArrow))
        register(.next, keyCode: UInt32(kVK_RightArrow))
        register(.toggleEconomy, keyCode: UInt32(kVK_ANSI_E))
        register(.showMenu, keyCode: UInt32(kVK_ANSI_Comma))
    }

    func stop() {
        for hotkeyRef in hotkeyRefs {
            if let hotkeyRef {
                UnregisterEventHotKey(hotkeyRef)
            }
        }

        hotkeyRefs.removeAll()

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        actions = nil
    }

    fileprivate func handleHotkey(id: UInt32) {
        switch HotkeyID(rawValue: id) {
        case .toggleWallpaper:
            actions?.toggleWallpaper()
        case .togglePause:
            actions?.togglePause()
        case .previous:
            actions?.previous()
        case .next:
            actions?.next()
        case .toggleEconomy:
            actions?.toggleEconomy()
        case .showMenu:
            actions?.showMenu()
        case .none:
            break
        }
    }

    private func register(_ id: HotkeyID, keyCode: UInt32) {
        let hotkeyID = EventHotKeyID(
            signature: OSType(UInt32(bigEndianFourCharCode("WLPH"))),
            id: id.rawValue
        )
        var hotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | optionKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr {
            hotkeyRefs.append(hotkeyRef)
        } else {
            NSLog("Live Wallpapers for Mac failed to register hotkey \(id.rawValue): \(status)")
        }
    }

    private static let eventHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef,
              let userData else {
            return noErr
        }

        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )

        guard status == noErr else {
            return status
        }

        let controller = Unmanaged<GlobalHotkeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            controller.handleHotkey(id: hotkeyID.id)
        }

        return noErr
    }
}

private func bigEndianFourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + FourCharCode(scalar.value)
    }
    return result
}

final class FullscreenPauseMonitor {
    private let onChange: (Bool) -> Void
    private var activeAppObserver: NSObjectProtocol?
    private var timer: Timer?
    private var lastFullscreenState = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        evaluate()

        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluate()
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
            self.activeAppObserver = nil
        }

        timer?.invalidate()
        timer = nil
    }

    private func evaluate() {
        let isFullscreenActive = FullscreenAppDetector.isFrontmostAppFullscreen()
        guard isFullscreenActive != lastFullscreenState else {
            return
        }

        lastFullscreenState = isFullscreenActive
        onChange(isFullscreenActive)
    }
}

final class SystemActivityPauseMonitor {
    private let onChange: (PlaybackPauseReason, Bool) -> Void
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping (PlaybackPauseReason, Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onChange(.sessionInactive, true)
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onChange(.sessionInactive, false)
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onChange(.screensAsleep, true)
        })

        observers.append(notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onChange(.screensAsleep, false)
        })
    }

    func stop() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
    }
}

final class ScreenLockPauseMonitor: NSObject {
    private let onChange: (Bool) -> Void
    private var isStarted = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init()
    }

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let notificationCenter = DistributedNotificationCenter.default()
        notificationCenter.addObserver(
            self,
            selector: #selector(screenLocked(_:)),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(screenUnlocked(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        onChange(Self.isScreenLockedNow())
    }

    func stop() {
        guard isStarted else { return }
        DistributedNotificationCenter.default().removeObserver(self)
        isStarted = false
    }

    @objc private func screenLocked(_ notification: Notification) {
        onChange(true)
    }

    @objc private func screenUnlocked(_ notification: Notification) {
        onChange(false)
    }

    private static func isScreenLockedNow() -> Bool {
        guard let sessionDictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
              let isLocked = sessionDictionary["CGSSessionScreenIsLocked"] as? Bool else {
            return false
        }

        return isLocked
    }
}

final class AudioOutputRouteMonitor {
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "\(AppBrand.bundleIdentifier).audio-output-monitor")
    private var listenerBlocks: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var isStarted = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        addListener(selector: kAudioHardwarePropertyDefaultOutputDevice)
        addListener(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    func stop() {
        guard isStarted else { return }

        for listener in listenerBlocks {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener.block
            )
        }

        listenerBlocks.removeAll()
        isStarted = false
    }

    private func addListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.onChange()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )

        if status == noErr {
            listenerBlocks.append((address: address, block: block))
        } else {
            AppLogger.log("Failed to observe audio route selector \(selector): \(status)")
        }
    }
}

struct PowerState: Equatable {
    let isLowPowerModeEnabled: Bool
    let isOnBatteryPower: Bool
    let batteryPercentage: Int?
}

enum PowerStateReader {
    static func current() -> PowerState {
        guard let powerSourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            AppLogger.log("IOKit power source info is unavailable.")
            return PowerState(
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                isOnBatteryPower: false,
                batteryPercentage: nil
            )
        }

        let powerSourceType = IOPSGetProvidingPowerSourceType(powerSourcesInfo)?
            .takeRetainedValue() as String? ?? ""

        return PowerState(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isOnBatteryPower: powerSourceType == kIOPSBatteryPowerValue,
            batteryPercentage: batteryPercentage(from: powerSourcesInfo)
        )
    }

    private static func batteryPercentage(from powerSourcesInfo: CFTypeRef) -> Int? {
        guard let sourceList = IOPSCopyPowerSourcesList(powerSourcesInfo)?
            .takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sourceList {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(
                powerSourcesInfo,
                source
            ),
                  let description = unmanagedDescription.takeUnretainedValue() as? [String: Any],
                  let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                  maxCapacity > 0 else {
                continue
            }

            return min(100, max(0, Int((Double(currentCapacity) / Double(maxCapacity)) * 100)))
        }

        return nil
    }
}

final class PowerStatePauseMonitor {
    private let onChange: (PowerState) -> Void
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var lastPowerState: PowerState?

    init(onChange: @escaping (PowerState) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        evaluate()

        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluate()
        }

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        timer?.invalidate()
        timer = nil
    }

    private func evaluate() {
        let powerState = PowerStateReader.current()
        guard powerState != lastPowerState else {
            return
        }

        lastPowerState = powerState
        onChange(powerState)
    }
}

final class DesktopCoveragePauseMonitor {
    private let onChange: (Bool) -> Void
    private var timer: Timer?
    private var lastState = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        evaluate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func evaluate() {
        let isCovered = DesktopCoverageDetector.isDesktopMostlyCovered()
        guard isCovered != lastState else {
            return
        }

        lastState = isCovered
        onChange(isCovered)
    }
}

final class ActiveAppPauseMonitor {
    private let onChange: (Bool) -> Void
    private var activeAppObserver: NSObjectProtocol?
    private var timer: Timer?
    private var lastState = false

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        evaluate()
        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluate()
        }

        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
            self.activeAppObserver = nil
        }
        timer?.invalidate()
        timer = nil
    }

    private func evaluate() {
        let isGameOrCall = ActiveAppClassifier.isGameOrCallApp(NSWorkspace.shared.frontmostApplication)
        guard isGameOrCall != lastState else {
            return
        }

        lastState = isGameOrCall
        onChange(isGameOrCall)
    }
}

final class ThermalPressureMonitor {
    private let onChange: (ProcessInfo.ThermalState) -> Void
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var lastState: ProcessInfo.ThermalState?

    init(onChange: @escaping (ProcessInfo.ThermalState) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        evaluate()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.evaluate()
        }

        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        timer?.invalidate()
        timer = nil
    }

    private func evaluate() {
        let state = ProcessInfo.processInfo.thermalState
        guard state != lastState else {
            return
        }

        lastState = state
        onChange(state)
    }
}

enum ActiveAppClassifier {
    static func isGameOrCallApp(_ app: NSRunningApplication?) -> Bool {
        guard let app else {
            return false
        }

        let bundleID = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        let markers = [
            "zoom", "facetime", "discord", "teams", "skype", "slack",
            "steam", "epic", "battle.net", "riot", "roblox", "minecraft",
            "unity", "unreal", "geforce", "game"
        ]

        return markers.contains { bundleID.contains($0) || name.contains($0) }
    }
}

enum DesktopCoverageDetector {
    static func isDesktopMostlyCovered() -> Bool {
        let ownPID = getpid()
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return NSScreen.screens.contains { screen in
            let screenFrame = screen.frame
            let coveredArea = windows.reduce(CGFloat(0)) { partialResult, windowInfo in
                guard ownerPID(from: windowInfo) != ownPID,
                      windowLayer(from: windowInfo) == 0,
                      windowAlpha(from: windowInfo) > 0.2,
                      let bounds = windowBounds(from: windowInfo),
                      !ignoredOwner(windowInfo),
                      bounds.width > 80,
                      bounds.height > 80 else {
                    return partialResult
                }

                let intersection = bounds.intersection(screenFrame)
                guard !intersection.isNull else {
                    return partialResult
                }

                return partialResult + (intersection.width * intersection.height)
            }

            return coveredArea >= (screenFrame.width * screenFrame.height * 0.88)
        }
    }

    private static func ignoredOwner(_ windowInfo: [String: Any]) -> Bool {
        let owner = (windowInfo[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        return owner == "dock"
            || owner == "windowmanager"
            || owner == "control center"
            || owner == "notificationcenter"
    }

    private static func ownerPID(from windowInfo: [String: Any]) -> pid_t? {
        (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    private static func windowLayer(from windowInfo: [String: Any]) -> Int? {
        (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    private static func windowAlpha(from windowInfo: [String: Any]) -> CGFloat {
        guard let alpha = windowInfo[kCGWindowAlpha as String] as? NSNumber else {
            return 1
        }

        return CGFloat(truncating: alpha)
    }

    private static func windowBounds(from windowInfo: [String: Any]) -> CGRect? {
        guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = cgFloat(from: bounds["X"]),
              let y = cgFloat(from: bounds["Y"]),
              let width = cgFloat(from: bounds["Width"]),
              let height = cgFloat(from: bounds["Height"]) else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cgFloat(from value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber else {
            return nil
        }

        return CGFloat(truncating: number)
    }
}

enum FullscreenAppDetector {
    static func isFrontmostAppFullscreen() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let frontmostPID = app.processIdentifier
        guard frontmostPID != getpid() else {
            return false
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let screenFrames = NSScreen.screens.map(\.frame)

        return windows.contains { windowInfo in
            guard ownerPID(from: windowInfo) == frontmostPID,
                  windowLayer(from: windowInfo) == 0,
                  let bounds = windowBounds(from: windowInfo),
                  windowAlpha(from: windowInfo) > 0 else {
                return false
            }

            return screenFrames.contains { screenFrame in
                isFullscreenWindow(bounds: bounds, on: screenFrame)
            }
        }
    }

    private static func isFullscreenWindow(bounds: CGRect, on screenFrame: CGRect) -> Bool {
        let widthMatches = bounds.width >= screenFrame.width * 0.98
        let heightMatches = bounds.height >= screenFrame.height * 0.98

        return widthMatches && heightMatches
    }

    private static func ownerPID(from windowInfo: [String: Any]) -> pid_t? {
        (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    private static func windowLayer(from windowInfo: [String: Any]) -> Int? {
        (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue
    }

    private static func windowAlpha(from windowInfo: [String: Any]) -> CGFloat {
        guard let alpha = windowInfo[kCGWindowAlpha as String] as? NSNumber else {
            return 1
        }

        return CGFloat(truncating: alpha)
    }

    private static func windowBounds(from windowInfo: [String: Any]) -> CGRect? {
        guard let bounds = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = cgFloat(from: bounds["X"]),
              let y = cgFloat(from: bounds["Y"]),
              let width = cgFloat(from: bounds["Width"]),
              let height = cgFloat(from: bounds["Height"]) else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func cgFloat(from value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber else {
            return nil
        }

        return CGFloat(truncating: number)
    }
}

final class SystemWallpaperController {
    private struct WallpaperSnapshot {
        let imageURL: URL?
        let options: [NSWorkspace.DesktopImageOptionKey: Any]
    }

    private var originalWallpapers: [String: WallpaperSnapshot] = [:]
    private var generatedPosterURLs: [URL] = []
    private let workspace = NSWorkspace.shared
    private let stateStore = WallpaperStateStore()

    func applyPosterWallpaper(for videoURL: URL, trimStartSeconds: Double) {
        do {
            let posterURL = try VideoPosterGenerator.makePoster(
                for: videoURL,
                trimStartSeconds: trimStartSeconds
            )
            try applyWallpaperImage(posterURL)
        } catch {
            NSLog("Live Wallpapers for Mac failed to set poster wallpaper: \(error.localizedDescription)")
        }
    }

    func applyImageWallpaper(for imageURL: URL) {
        do {
            let posterURL = try ImagePosterGenerator.makePoster(for: imageURL)
            try applyWallpaperImage(posterURL)
        } catch {
            NSLog("Live Wallpapers for Mac failed to set image wallpaper: \(error.localizedDescription)")
        }
    }

    func restoreOriginalWallpapers() {
        let persistedSnapshots = stateStore.load()
        guard !originalWallpapers.isEmpty || !persistedSnapshots.isEmpty else {
            cleanUpUnusedPosterFiles()
            return
        }

        let persistedByScreenID = Dictionary(
            persistedSnapshots.map { ($0.screenID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for screen in NSScreen.screens {
            let screenID = identifier(for: screen)
            let memorySnapshot = originalWallpapers[screenID]
            let persistedSnapshot = persistedByScreenID[screenID]

            guard let imageURL = memorySnapshot?.imageURL
                    ?? persistedSnapshot.map({ URL(fileURLWithPath: $0.imagePath) }) else {
                continue
            }

            do {
                try workspace.setDesktopImageURL(
                    imageURL,
                    for: screen,
                    options: memorySnapshot?.options ?? [:]
                )
            } catch {
                NSLog("Live Wallpapers for Mac failed to restore wallpaper: \(error.localizedDescription)")
            }
        }

        originalWallpapers.removeAll()
        stateStore.clear()
        removeGeneratedPosters()
        cleanUpUnusedPosterFiles()
    }

    func cleanUpUnusedPosterFiles() {
        restorePersistedWallpaperIfNeeded()
        removeUnusedPosterFiles()
        removeLegacyPosterIfUnused()
    }

    private func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screenNumber = screen.deviceDescription[key] as? NSNumber {
            return screenNumber.stringValue
        }

        return screen.localizedName
    }

    private func applyWallpaperImage(_ posterURL: URL) throws {
        generatedPosterURLs.append(posterURL)

        let screens = NSScreen.screens

        for screen in screens {
            let screenID = identifier(for: screen)
            let currentOptions = workspace.desktopImageOptions(for: screen) ?? [:]

            if originalWallpapers[screenID] == nil {
                let currentImageURL = workspace.desktopImageURL(for: screen)
                originalWallpapers[screenID] = WallpaperSnapshot(
                    imageURL: currentImageURL,
                    options: currentOptions
                )
            }
        }

        stateStore.saveIfNeeded(
            originalWallpapers.compactMap { screenID, snapshot in
                guard let imageURL = snapshot.imageURL,
                      !AppSupportDirectory.isAppPosterURL(imageURL) else {
                    return nil
                }

                return PersistedWallpaperSnapshot(
                    screenID: screenID,
                    imagePath: imageURL.path
                )
            }
        )

        for screen in screens {
            let currentOptions = workspace.desktopImageOptions(for: screen) ?? [:]

            var options = currentOptions
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
            options[.allowClipping] = true

            try workspace.setDesktopImageURL(posterURL, for: screen, options: options)
        }
    }

    private func removeGeneratedPosters() {
        for url in generatedPosterURLs {
            try? FileManager.default.removeItem(at: url)
        }

        generatedPosterURLs.removeAll()
    }

    private func restorePersistedWallpaperIfNeeded() {
        let persistedSnapshots = stateStore.load()
        let currentWallpaperURLs = NSScreen.screens.compactMap { workspace.desktopImageURL(for: $0) }
        guard currentWallpaperURLs.contains(where: AppSupportDirectory.isAppPosterURL) else {
            return
        }

        guard !persistedSnapshots.isEmpty else {
            restoreFallbackWallpaperForOrphanedPoster()
            return
        }

        let persistedByScreenID = Dictionary(
            persistedSnapshots.map { ($0.screenID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for screen in NSScreen.screens {
            let screenID = identifier(for: screen)
            guard let snapshot = persistedByScreenID[screenID] else {
                continue
            }

            do {
                try workspace.setDesktopImageURL(
                    URL(fileURLWithPath: snapshot.imagePath),
                    for: screen,
                    options: [:]
                )
            } catch {
                NSLog("Live Wallpapers for Mac failed to restore persisted wallpaper: \(error.localizedDescription)")
            }
        }

        stateStore.clear()
    }

    private func restoreFallbackWallpaperForOrphanedPoster() {
        guard let fallbackURL = AppSupportDirectory.defaultDesktopURL() else {
            return
        }

        for screen in NSScreen.screens {
            do {
                try workspace.setDesktopImageURL(fallbackURL, for: screen, options: [:])
            } catch {
                NSLog("Live Wallpapers for Mac failed to restore fallback wallpaper: \(error.localizedDescription)")
            }
        }
    }

    private func legacyPosterURL() -> URL {
        let supportDirectory = try? AppSupportDirectory.url(create: false)

        return (supportDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("current-poster.jpg")
    }

    private func removeLegacyPosterIfUnused() {
        let legacyURL = legacyPosterURL()
        let isInUse = NSScreen.screens.contains { screen in
            workspace.desktopImageURL(for: screen)?.path == legacyURL.path
        }

        if !isInUse {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }

    private func removeUnusedPosterFiles() {
        guard let supportDirectory = try? AppSupportDirectory.url(create: false),
              let files = try? FileManager.default.contentsOfDirectory(
                at: supportDirectory,
                includingPropertiesForKeys: nil
              ) else {
            return
        }

        let inUsePaths = Set(NSScreen.screens.compactMap { workspace.desktopImageURL(for: $0)?.path })

        for file in files where file.lastPathComponent.hasPrefix("poster-")
            && file.pathExtension.lowercased() == "jpg"
            && !inUsePaths.contains(file.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

enum VideoPosterGenerator {
    static func makePoster(for videoURL: URL, trimStartSeconds: Double) throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 2160)
        let tolerance = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let cgImage = try copyPosterImage(
            using: generator,
            preferredStartSeconds: trimStartSeconds
        )
        let destinationURL = try posterDestinationURL()

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: AppBrand.errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create poster image destination."]
            )
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: AppBrand.errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot write poster image."]
            )
        }

        return destinationURL
    }

    private static func copyPosterImage(
        using generator: AVAssetImageGenerator,
        preferredStartSeconds: Double
    ) throws -> CGImage {
        let targetSeconds = max(0, preferredStartSeconds) + 0.5

        do {
            return try generator.copyCGImage(
                at: CMTime(seconds: targetSeconds, preferredTimescale: 600),
                actualTime: nil
            )
        } catch {
            return try generator.copyCGImage(at: .zero, actualTime: nil)
        }
    }

    private static func posterDestinationURL() throws -> URL {
        try AppSupportDirectory.url(create: true)
            .appendingPathComponent("poster-\(UUID().uuidString).jpg")
    }
}

enum ImagePosterGenerator {
    static func makePoster(for imageURL: URL) throws -> URL {
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = cgImage(from: image) else {
            throw NSError(
                domain: AppBrand.errorDomain,
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Cannot read image."]
            )
        }

        let destinationURL = try posterDestinationURL()
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: AppBrand.errorDomain,
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create image poster destination."]
            )
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: AppBrand.errorDomain,
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Cannot write image poster."]
            )
        }

        return destinationURL
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return cgImage
        }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.cgImage
    }

    private static func posterDestinationURL() throws -> URL {
        try AppSupportDirectory.url(create: true)
            .appendingPathComponent("poster-\(UUID().uuidString).jpg")
    }
}

struct PersistedWallpaperSnapshot: Codable {
    let screenID: String
    let imagePath: String
}

final class WallpaperStateStore {
    private let fileName = "original-wallpaper.json"

    func load() -> [PersistedWallpaperSnapshot] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        do {
            return try JSONDecoder().decode([PersistedWallpaperSnapshot].self, from: data)
        } catch {
            AppLogger.log("Original wallpaper state is corrupted and will be ignored: \(error.localizedDescription)")
            backupCorruptFile(at: url)
            return []
        }
    }

    func saveIfNeeded(_ snapshots: [PersistedWallpaperSnapshot]) {
        guard !snapshots.isEmpty, load().isEmpty else {
            return
        }

        do {
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: fileURL(), options: .atomic)
        } catch {
            NSLog("Live Wallpapers for Mac failed to persist original wallpaper: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL())
    }

    private func fileURL() -> URL {
        do {
            return try AppSupportDirectory.url(create: true)
                .appendingPathComponent(fileName)
        } catch {
            return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        }
    }

    private func backupCorruptFile(at url: URL) {
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension(url.pathExtension)
        try? FileManager.default.moveItem(at: url, to: backupURL)
    }
}

final class AppPreferencesStore {
    private let fileName = "settings.json"

    func load() -> AppPreferences {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else {
            return AppPreferences()
        }

        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            AppLogger.log("Settings file is corrupted; backing it up and loading defaults: \(error.localizedDescription)")
            backupCorruptFile(at: url)
            return AppPreferences()
        }
    }

    func save(_ preferences: AppPreferences) {
        do {
            let data = try JSONEncoder().encode(preferences)
            try data.write(to: fileURL(), options: .atomic)
        } catch {
            NSLog("Live Wallpapers for Mac failed to persist settings: \(error.localizedDescription)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL())
    }

    func exportPreferences(to destinationURL: URL, preferences: AppPreferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: destinationURL, options: .atomic)
    }

    func importPreferences(from sourceURL: URL) throws -> AppPreferences {
        let data = try Data(contentsOf: sourceURL)
        return try JSONDecoder().decode(AppPreferences.self, from: data)
    }

    private func fileURL() -> URL {
        do {
            return try AppSupportDirectory.url(create: true)
                .appendingPathComponent(fileName)
        } catch {
            return FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        }
    }

    private func backupCorruptFile(at url: URL) {
        let backupURL = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension(url.pathExtension)
        try? FileManager.default.moveItem(at: url, to: backupURL)
    }
}

enum AppLogger {
    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        NSLog("Live Wallpapers for Mac: \(message)")

        do {
            let url = fileURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } else {
                try line.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Live Wallpapers for Mac failed to write log: \(error.localizedDescription)")
        }
    }

    static func fileURL() -> URL {
        (try? AppSupportDirectory.url(create: true).appendingPathComponent(AppBrand.logFileName))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(AppBrand.logFileName)
    }
}

enum LaunchAtLoginManager {
    private static let label = AppBrand.launchAgentLabel

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL(label: label).path)
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try installLaunchAgent()
        } else {
            try removeLaunchAgent()
        }
    }

    static func repairIfEnabled() {
        guard isEnabled else {
            return
        }

        try? installLaunchAgent()
    }

    private static func installLaunchAgent() throws {
        let programArguments: [String]
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            programArguments = ["/usr/bin/open", bundleURL.path]
        } else if let executableURL = Bundle.main.executableURL {
            programArguments = [executableURL.path]
        } else {
            throw NSError(
                domain: AppBrand.errorDomain,
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось определить путь к приложению."]
            )
        }

        let launchAgentsDirectory = launchAgentURL(label: label).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let url = launchAgentURL(label: label)
        try data.write(to: url, options: .atomic)
        try reloadLaunchAgent(at: url)
    }

    private static func removeLaunchAgent() throws {
        try removeLaunchAgent(label: label)
    }

    private static func removeLaunchAgent(label: String) throws {
        unloadLaunchAgent(label: label)

        let url = launchAgentURL(label: label)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try FileManager.default.removeItem(at: url)
    }

    private static func reloadLaunchAgent(at url: URL) throws {
        unloadLaunchAgent(label: label)
        try launchctl(["bootstrap", guiDomain, url.path])
        try? launchctl(["enable", "\(guiDomain)/\(label)"])
    }

    private static func unloadLaunchAgent(label: String) {
        try? launchctl(["bootout", "\(guiDomain)/\(label)"])
    }

    private static var guiDomain: String {
        "gui/\(getuid())"
    }

    private static func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: AppBrand.errorDomain,
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: errorMessage?.isEmpty == false
                        ? errorMessage!
                        : "launchctl завершился с кодом \(process.terminationStatus)."
                ]
            )
        }
    }

    private static func launchAgentURL(label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }
}

enum AppSupportDirectory {
    static func url(create: Bool) throws -> URL {
        let applicationSupportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let supportDirectory = applicationSupportDirectory
            .appendingPathComponent(AppBrand.supportDirectoryName, isDirectory: true)

        if create {
            migrateLegacyDirectoryIfNeeded(
                from: applicationSupportDirectory.appendingPathComponent(
                    AppBrand.legacySupportDirectoryName,
                    isDirectory: true
                ),
                to: supportDirectory
            )

            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
        }

        return supportDirectory
    }

    private static func migrateLegacyDirectoryIfNeeded(from legacyDirectory: URL, to supportDirectory: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: supportDirectory.path),
              fileManager.fileExists(atPath: legacyDirectory.path) else {
            return
        }

        do {
            try fileManager.copyItem(at: legacyDirectory, to: supportDirectory)
        } catch {
            NSLog("Live Wallpapers for Mac failed to migrate settings: \(error.localizedDescription)")
        }
    }

    static func isAppPosterURL(_ url: URL) -> Bool {
        guard let supportDirectory = try? self.url(create: false) else {
            return false
        }

        let fileName = url.lastPathComponent
        return url.deletingLastPathComponent().path == supportDirectory.path
            && ((fileName.hasPrefix("poster-") && url.pathExtension.lowercased() == "jpg")
                || fileName == "current-poster.jpg")
    }

    static func defaultDesktopURL() -> URL? {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum WallpaperContentLayout {
    static func frame(
        in bounds: CGRect,
        sourceSize: CGSize?,
        settings: WallpaperPlaybackSettings
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let sourceSize = normalizedSourceSize(sourceSize, fallback: bounds.size)

        let baseFrame: CGRect
        switch settings.displayMode {
        case .stretch:
            baseFrame = bounds
        case .fill, .crop:
            baseFrame = aspectFillFrame(for: sourceSize, in: bounds)
        case .fit:
            baseFrame = aspectFitFrame(for: sourceSize, in: bounds)
        case .center:
            let scale = min(1, min(bounds.width / sourceSize.width, bounds.height / sourceSize.height))
            baseFrame = centeredFrame(
                in: bounds,
                size: CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            )
        case .manual:
            let fitFrame = aspectFitFrame(for: sourceSize, in: bounds)
            let scale = settings.effectiveContentScale
            baseFrame = centeredFrame(
                in: bounds,
                size: CGSize(width: fitFrame.width * scale, height: fitFrame.height * scale)
            )
        }

        guard settings.displayMode == .manual else {
            return baseFrame
        }

        return baseFrame.offsetBy(
            dx: bounds.width * settings.effectiveContentOffsetX,
            dy: bounds.height * settings.effectiveContentOffsetY
        )
    }

    private static func normalizedSourceSize(_ sourceSize: CGSize?, fallback: CGSize) -> CGSize {
        guard let sourceSize,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return fallback
        }

        return sourceSize
    }

    private static func aspectFitFrame(for sourceSize: CGSize, in bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        return centeredFrame(
            in: bounds,
            size: CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        )
    }

    private static func aspectFillFrame(for sourceSize: CGSize, in bounds: CGRect) -> CGRect {
        let scale = max(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        return centeredFrame(
            in: bounds,
            size: CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        )
    }

    private static func centeredFrame(in bounds: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

enum WallpaperVisualEffects {
    static func configureOverlayLayers(_ layers: CALayer...) {
        for layer in layers {
            layer.backgroundColor = NSColor.black.cgColor
            layer.zPosition = 1_000
        }
    }

    static func applyContentFilters(to layer: CALayer?, settings: WallpaperPlaybackSettings) {
        var filters: [Any] = []

        if abs(settings.effectiveContrast - 1) > 0.001
            || abs(settings.effectiveSaturation - 1) > 0.001,
           let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(settings.effectiveContrast, forKey: kCIInputContrastKey)
            filter.setValue(settings.effectiveSaturation, forKey: kCIInputSaturationKey)
            filters.append(filter)
        }

        if abs(settings.effectiveHueRadians) > 0.001,
           let filter = CIFilter(name: "CIHueAdjust") {
            filter.setValue(settings.effectiveHueRadians, forKey: kCIInputAngleKey)
            filters.append(filter)
        }

        if settings.effectiveBlurRadius > 0.001,
           let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(settings.effectiveBlurRadius, forKey: kCIInputRadiusKey)
            filters.append(filter)
        }

        layer?.filters = filters.isEmpty ? nil : filters
        layer?.masksToBounds = true
    }

    static func applyOverlaySettings(
        dimmingLayer: CALayer,
        vignetteLayer: CAGradientLayer,
        settings: WallpaperPlaybackSettings,
        bounds: CGRect
    ) {
        dimmingLayer.frame = bounds
        dimmingLayer.opacity = Float(settings.effectiveDimming)

        vignetteLayer.frame = bounds
        vignetteLayer.type = .radial
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignetteLayer.endPoint = CGPoint(x: 1, y: 1)
        vignetteLayer.locations = [0.55, 1]
        vignetteLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor
        ]
        vignetteLayer.opacity = Float(settings.effectiveVignette)
    }

    static func applyGrainSettings(
        grainLayer: CALayer,
        settings: WallpaperPlaybackSettings,
        bounds: CGRect
    ) {
        grainLayer.frame = bounds
        grainLayer.zPosition = 1_001
        grainLayer.opacity = Float(settings.effectiveGrain * 0.28)
        grainLayer.contentsGravity = .resizeAspectFill
        if grainLayer.contents == nil {
            grainLayer.contents = makeGrainImage()
        }
    }

    private static func makeGrainImage() -> CGImage? {
        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = UInt8.random(in: 70...185)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

final class WallpaperWindow: NSWindow {
    private let wallpaperView: NSView & WallpaperContentView
    private let targetFrame: NSRect
    let source: WallpaperSource

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    init(screen: NSScreen, configuration: WallpaperConfiguration, startsPaused: Bool) {
        targetFrame = screen.frame
        source = configuration.source
        wallpaperView = WallpaperContentViewFactory.makeView(
            configuration: configuration,
            startsPaused: startsPaused
        )

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        configure(for: screen)
    }

    func show() {
        alphaValue = 0
        setFrame(targetFrame, display: true)
        orderBack(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            animator().alphaValue = 1
        }
    }

    func setPlaybackPaused(_ isPaused: Bool) {
        wallpaperView.setPlaybackPaused(isPaused)
    }

    func stopPlayback() {
        wallpaperView.stopPlayback()
    }

    func applySettings(_ settings: WallpaperPlaybackSettings, isPaused: Bool) {
        wallpaperView.applySettings(settings, isPaused: isPaused)
    }

    func playbackPositionSeconds() -> Double? {
        wallpaperView.playbackPositionSeconds()
    }

    override func close() {
        stopPlayback()
        contentView = nil
        super.close()
    }

    private func configure(for screen: NSScreen) {
        let desktopLevel = CGWindowLevelForKey(.desktopWindow)
        level = NSWindow.Level(rawValue: Int(desktopLevel) + 1)

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isMovable = false
        isOpaque = true
        isReleasedWhenClosed = false

        wallpaperView.frame = NSRect(origin: .zero, size: screen.frame.size)
        wallpaperView.autoresizingMask = [.width, .height]
        contentView = wallpaperView
    }
}

protocol WallpaperContentView: AnyObject {
    func setPlaybackPaused(_ isPaused: Bool)
    func stopPlayback()
    func applySettings(_ settings: WallpaperPlaybackSettings, isPaused: Bool)
    func playbackPositionSeconds() -> Double?
}

enum WallpaperContentViewFactory {
    static func makeView(configuration: WallpaperConfiguration, startsPaused: Bool) -> NSView & WallpaperContentView {
        switch configuration.source {
        case .video(let url):
            return VideoWallpaperView(
                videoURL: url,
                settings: configuration.settings,
                resumePositionSeconds: configuration.resumePositionSeconds,
                startsPaused: startsPaused
            )
        case .image(let url):
            return ImageWallpaperView(
                imageURL: url,
                settings: configuration.settings,
                startsPaused: startsPaused
            )
        }
    }
}

final class VideoWallpaperView: NSView, WallpaperContentView {
    private var player: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?
    private let dimmingLayer = CALayer()
    private let vignetteLayer = CAGradientLayer()
    private let grainLayer = CALayer()
    private var playerLooper: AVPlayerLooper?
    private var timeObserver: Any?
    private var activeTimeRange: CMTimeRange?
    private let resumePositionSeconds: Double?
    private var settings: WallpaperPlaybackSettings
    private var isPlaybackPaused: Bool
    private var isPlayerConfigured = false
    private var isStopped = false

    init(videoURL: URL, settings: WallpaperPlaybackSettings, resumePositionSeconds: Double?, startsPaused: Bool) {
        self.settings = settings
        self.resumePositionSeconds = resumePositionSeconds
        isPlaybackPaused = startsPaused

        super.init(frame: .zero)

        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
        layer = rootLayer

        WallpaperVisualEffects.configureOverlayLayers(dimmingLayer, vignetteLayer, grainLayer)
        rootLayer.addSublayer(dimmingLayer)
        rootLayer.addSublayer(vignetteLayer)
        rootLayer.addSublayer(grainLayer)

        applyVisualSettings(settings)
        configurePlayerAfterWindowCreation(videoURL: videoURL)
    }

    private func configurePlayerAfterWindowCreation(videoURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isStopped else {
                return
            }

            self.installPlayerLayerIfNeeded()
            let currentSettings = self.settings
            DispatchQueue.global(qos: .userInitiated).async {
                let playbackItem = VideoPlaybackItemFactory.makeTemplateItem(
                    for: videoURL,
                    settings: currentSettings
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          !self.isStopped else {
                        return
                    }

                    self.configurePlayer(with: playbackItem)
                }
            }
        }
    }

    private func installPlayerLayerIfNeeded() {
        guard !isStopped,
              player == nil,
              playerLayer == nil,
              let rootLayer = layer else {
            return
        }

        let player = AVQueuePlayer()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.insertSublayer(playerLayer, below: dimmingLayer)
        self.player = player
        self.playerLayer = playerLayer
        layout()
        applyVisualSettings(settings)
    }

    private func configurePlayer(
        with playbackItem: (item: AVPlayerItem, timeRange: CMTimeRange?, randomStartTime: CMTime?)
    ) {
        guard !isStopped,
              !isPlayerConfigured,
              let player else {
            return
        }

        isPlayerConfigured = true
        if let timeRange = playbackItem.timeRange {
            activeTimeRange = timeRange
        } else {
            let duration = playbackItem.item.asset.duration
            activeTimeRange = duration.isNumeric ? CMTimeRange(start: .zero, duration: duration) : nil
        }
        player.removeAllItems()

        if let timeRange = playbackItem.timeRange {
            playerLooper = AVPlayerLooper(
                player: player,
                templateItem: playbackItem.item,
                timeRange: timeRange
            )
        } else {
            playerLooper = AVPlayerLooper(player: player, templateItem: playbackItem.item)
        }

        if let randomStartTime = playbackItem.randomStartTime {
            player.seek(
                to: randomStartTime,
                toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600)
            )
        } else if let resumePositionSeconds,
                  resumePositionSeconds.isFinite,
                  resumePositionSeconds > 0 {
            let startSeconds = playbackItem.timeRange?.start.seconds ?? 0
            let durationSeconds = playbackItem.timeRange?.duration.seconds
            let maxSeconds = durationSeconds.map { startSeconds + max(0, $0 - 1) }
            let targetSeconds = min(max(resumePositionSeconds, startSeconds), maxSeconds ?? resumePositionSeconds)
            player.seek(
                to: CMTime(seconds: targetSeconds, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600)
            )
        }

        applyAudioSettings(settings)
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true

        applyVisualSettings(settings)
        installCinematicLoopObserverIfNeeded()

        if !isPlaybackPaused {
            resumePlayback()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = WallpaperContentLayout.frame(
            in: bounds,
            sourceSize: nil,
            settings: settings
        )
        WallpaperVisualEffects.applyOverlaySettings(
            dimmingLayer: dimmingLayer,
            vignetteLayer: vignetteLayer,
            settings: settings,
            bounds: bounds
        )
        WallpaperVisualEffects.applyGrainSettings(
            grainLayer: grainLayer,
            settings: settings,
            bounds: bounds
        )
        CATransaction.commit()
    }

    func applySettings(_ settings: WallpaperPlaybackSettings, isPaused: Bool) {
        guard !isStopped else {
            return
        }

        self.settings = settings
        applyVisualSettings(settings)
        applyAudioSettings(settings)
        setPlaybackPaused(isPaused)
        installCinematicLoopObserverIfNeeded()

        if !isPaused {
            resumePlayback()
        }
    }

    func setPlaybackPaused(_ isPaused: Bool) {
        guard !isStopped else {
            return
        }

        guard isPlaybackPaused != isPaused else {
            return
        }

        isPlaybackPaused = isPaused

        if isPaused {
            player?.pause()
        } else {
            resumePlayback()
        }
    }

    private func applyVisualSettings(_ settings: WallpaperPlaybackSettings) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.videoGravity = settings.displayMode.videoGravity
        playerLayer?.opacity = Float(settings.effectiveBrightness)
        WallpaperVisualEffects.applyContentFilters(to: playerLayer, settings: settings)
        WallpaperVisualEffects.applyOverlaySettings(
            dimmingLayer: dimmingLayer,
            vignetteLayer: vignetteLayer,
            settings: settings,
            bounds: bounds
        )
        WallpaperVisualEffects.applyGrainSettings(
            grainLayer: grainLayer,
            settings: settings,
            bounds: bounds
        )
        CATransaction.commit()
        needsLayout = true
    }

    private func applyAudioSettings(_ settings: WallpaperPlaybackSettings) {
        player?.isMuted = settings.volume <= 0.001
        player?.volume = Float(settings.volume)
    }

    private func resumePlayback() {
        guard !isStopped else {
            return
        }

        player?.playImmediately(atRate: Float(settings.effectivePlaybackRate))
    }

    func playbackPositionSeconds() -> Double? {
        guard !isStopped else {
            return nil
        }

        guard let seconds = player?.currentTime().seconds,
              seconds.isFinite else {
            return nil
        }

        return seconds
    }

    func stopPlayback() {
        guard !isStopped else {
            return
        }

        isStopped = true

        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        playerLooper = nil
        player?.pause()
        player?.removeAllItems()
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
    }

    private func installCinematicLoopObserverIfNeeded() {
        guard let player else {
            return
        }

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        guard settings.cinematicLoop else {
            applyVisualSettings(settings)
            return
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.applyCinematicFade(at: time)
        }
    }

    private func applyCinematicFade(at time: CMTime) {
        guard settings.cinematicLoop,
              let playerLayer else {
            return
        }

        let seconds = time.seconds
        guard seconds.isFinite else {
            return
        }

        let start = activeTimeRange?.start.seconds ?? 0
        let duration = activeTimeRange?.duration.seconds
        let end = duration.map { start + $0 }
        let fadeDuration = 1.0

        var fade = 1.0
        if seconds - start < fadeDuration {
            fade = max(0.2, (seconds - start) / fadeDuration)
        }
        if let end, end - seconds < fadeDuration {
            fade = min(fade, max(0.2, (end - seconds) / fadeDuration))
        }

        playerLayer.opacity = Float(settings.effectiveBrightness * fade)
    }

    deinit {
        stopPlayback()
    }
}

struct AnimatedImageFrame {
    let image: CGImage
    let duration: TimeInterval
}

struct AnimatedImageSequence {
    let frames: [AnimatedImageFrame]
    let size: CGSize

    static func load(from url: URL) -> AnimatedImageSequence? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            return nil
        }

        var frames: [AnimatedImageFrame] = []
        frames.reserveCapacity(count)

        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }

            frames.append(
                AnimatedImageFrame(
                    image: image,
                    duration: frameDuration(source: source, index: index)
                )
            )
        }

        guard frames.count > 1,
              let firstImage = frames.first?.image else {
            return nil
        }

        return AnimatedImageSequence(
            frames: frames,
            size: CGSize(width: firstImage.width, height: firstImage.height)
        )
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }

        let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
        let delay = gifProperties[kCGImagePropertyGIFDelayTime] as? NSNumber
        let seconds = (unclampedDelay ?? delay)?.doubleValue ?? 0.1
        return seconds < 0.02 ? 0.1 : seconds
    }
}

enum RasterImageLoader {
    static func load(from url: URL) -> (image: CGImage, size: CGSize)? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return (
                image,
                CGSize(width: image.width, height: image.height)
            )
        }

        guard let image = NSImage(contentsOf: url) else {
            return nil
        }

        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        return (cgImage, image.size)
    }
}

final class ImageWallpaperView: NSView, WallpaperContentView {
    private let imageLayer = CALayer()
    private let dimmingLayer = CALayer()
    private let vignetteLayer = CAGradientLayer()
    private let grainLayer = CALayer()
    private let animatedSequence: AnimatedImageSequence?
    private let staticImage: CGImage?
    private let sourceSize: CGSize?
    private var frameIndex = 0
    private var playbackTimer: Timer?
    private var settings: WallpaperPlaybackSettings
    private var isPlaybackPaused: Bool

    init(imageURL: URL, settings: WallpaperPlaybackSettings, startsPaused: Bool) {
        let sequence = AnimatedImageSequence.load(from: imageURL)
        let staticImageData = sequence == nil ? RasterImageLoader.load(from: imageURL) : nil

        animatedSequence = sequence
        staticImage = staticImageData?.image
        sourceSize = sequence?.size ?? staticImageData?.size
        self.settings = settings
        isPlaybackPaused = startsPaused

        super.init(frame: .zero)

        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.masksToBounds = true
        wantsLayer = true
        layer = rootLayer

        imageLayer.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.masksToBounds = true
        imageLayer.contents = animatedSequence?.frames.first?.image ?? staticImage
        rootLayer.addSublayer(imageLayer)

        if imageLayer.contents == nil {
            AppLogger.log("Image wallpaper could not be decoded: \(imageURL.path)")
        }

        WallpaperVisualEffects.configureOverlayLayers(dimmingLayer, vignetteLayer, grainLayer)
        rootLayer.addSublayer(dimmingLayer)
        rootLayer.addSublayer(vignetteLayer)
        rootLayer.addSublayer(grainLayer)

        applyVisualSettings(settings)
        if !startsPaused {
            scheduleNextFrame()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = WallpaperContentLayout.frame(
            in: bounds,
            sourceSize: sourceSize,
            settings: settings
        )
        WallpaperVisualEffects.applyOverlaySettings(
            dimmingLayer: dimmingLayer,
            vignetteLayer: vignetteLayer,
            settings: settings,
            bounds: bounds
        )
        WallpaperVisualEffects.applyGrainSettings(
            grainLayer: grainLayer,
            settings: settings,
            bounds: bounds
        )
        CATransaction.commit()
    }

    func setPlaybackPaused(_ isPaused: Bool) {
        isPlaybackPaused = isPaused
        if isPaused {
            playbackTimer?.invalidate()
            playbackTimer = nil
        } else {
            scheduleNextFrame()
        }
    }

    func applySettings(_ settings: WallpaperPlaybackSettings, isPaused: Bool) {
        let rateChanged = abs(self.settings.effectivePlaybackRate - settings.effectivePlaybackRate) > 0.001
        self.settings = settings
        applyVisualSettings(settings)
        setPlaybackPaused(isPaused)
        if rateChanged, !isPaused {
            scheduleNextFrame()
        }
    }

    func playbackPositionSeconds() -> Double? {
        nil
    }

    func stopPlayback() {
        isPlaybackPaused = true
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func applyVisualSettings(_ settings: WallpaperPlaybackSettings) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.opacity = Float(settings.effectiveBrightness)
        WallpaperVisualEffects.applyContentFilters(to: imageLayer, settings: settings)
        WallpaperVisualEffects.applyOverlaySettings(
            dimmingLayer: dimmingLayer,
            vignetteLayer: vignetteLayer,
            settings: settings,
            bounds: bounds
        )
        WallpaperVisualEffects.applyGrainSettings(
            grainLayer: grainLayer,
            settings: settings,
            bounds: bounds
        )
        CATransaction.commit()
        needsLayout = true
    }

    private func scheduleNextFrame() {
        playbackTimer?.invalidate()
        playbackTimer = nil

        guard !isPlaybackPaused,
              let animatedSequence,
              animatedSequence.frames.count > 1 else {
            return
        }

        let currentFrame = animatedSequence.frames[frameIndex]
        let rate = max(settings.effectivePlaybackRate, 0.05)
        let timer = Timer(timeInterval: currentFrame.duration / rate, repeats: false) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    private func advanceFrame() {
        guard let animatedSequence,
              !animatedSequence.frames.isEmpty else {
            return
        }

        frameIndex = (frameIndex + 1) % animatedSequence.frames.count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = animatedSequence.frames[frameIndex].image
        CATransaction.commit()
        scheduleNextFrame()
    }

    deinit {
        stopPlayback()
    }
}

enum VideoPlaybackItemFactory {
    static func makeTemplateItem(
        for videoURL: URL,
        settings: WallpaperPlaybackSettings
    ) -> (item: AVPlayerItem, timeRange: CMTimeRange?, randomStartTime: CMTime?) {
        let asset = AVURLAsset(url: videoURL)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition(for: asset, fpsLimit: settings.effectiveFPSLimit)
        let timeRange = trimmedTimeRange(for: asset, trim: settings.trim)
        return (
            item,
            timeRange,
            randomStartTime(for: asset, settings: settings, timeRange: timeRange)
        )
    }

    private static func videoComposition(for asset: AVAsset, fpsLimit: WallpaperFPSLimit) -> AVVideoComposition? {
        guard fpsLimit != .source else {
            return nil
        }

        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fpsLimit.rawValue))
        return composition
    }

    private static func trimmedTimeRange(for asset: AVAsset, trim: VideoTrim) -> CMTimeRange? {
        let trimStart = max(0, trim.startSeconds)
        let trimEnd = max(0, trim.endSeconds)
        guard trimStart > 0.001 || trimEnd > 0.001 else {
            return nil
        }

        guard let durationSeconds = durationSeconds(for: asset),
              durationSeconds > 0.2 else {
            return nil
        }

        let endSeconds = durationSeconds - trimEnd
        guard endSeconds - trimStart > 0.2 else {
            return nil
        }

        let start = CMTime(seconds: trimStart, preferredTimescale: 600)
        let trimmedDuration = CMTime(seconds: endSeconds - trimStart, preferredTimescale: 600)
        return CMTimeRange(start: start, duration: trimmedDuration)
    }

    private static func randomStartTime(
        for asset: AVAsset,
        settings: WallpaperPlaybackSettings,
        timeRange: CMTimeRange?
    ) -> CMTime? {
        guard settings.startsAtRandomPosition else {
            return nil
        }

        let startSeconds = timeRange?.start.seconds ?? max(0, settings.trim.startSeconds)
        let durationSeconds = timeRange?.duration.seconds
            ?? durationSeconds(for: asset).map { max(0, $0 - settings.trim.startSeconds - settings.trim.endSeconds) }

        guard let durationSeconds,
              durationSeconds.isFinite,
              durationSeconds > 1 else {
            return nil
        }

        let randomOffset = Double.random(in: 0..<durationSeconds)
        return CMTime(seconds: startSeconds + randomOffset, preferredTimescale: 600)
    }

    private static func durationSeconds(for asset: AVAsset) -> Double? {
        let duration = asset.duration
        guard duration.isValid,
              duration.isNumeric,
              duration.seconds.isFinite else {
            return nil
        }

        return duration.seconds
    }
}

private let appDelegate = AppDelegate()
private let application = NSApplication.shared
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
