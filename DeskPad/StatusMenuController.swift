import Cocoa
import ServiceManagement

/// Menu bar control: orientation, resolution and the Deskreen phone connection.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let screen: ScreenViewController
    private let window: NSWindow
    private let deskreen = DeskreenController()

    /// Auto accept only runs for a short window after the user asks to connect,
    /// so a stranger on the same Wi-Fi who guesses the link is never let in silently.
    private static let armDuration: TimeInterval = 180
    private var armedUntil: Date?
    private var armTask: Task<Void, Never>?
    private var lastMessage: String? {
        didSet {
            if let lastMessage { log(lastMessage) }
            writeStatus()
        }
    }

    private var lastLink: String?

    private var devices: [DeskreenController.Device] = []

    /// Which modes macOS marks usable shifts with the display's history, so try these in order
    /// and fall back to the closest sharp mode. 924x1224@2 is the Fold's portrait panel 1:1;
    /// 800x600@2 matches the Fold's landscape aspect (2448:1848) so it fills the screen.
    private static let preferredModes = [
        "portrait": ["924x1224@2", "768x1024@2", "900x1440@2"],
        "landscape": ["800x600@2", "960x600@2", "1280x800@2"],
    ]

    init(screen: ScreenViewController, window: NSWindow) {
        self.screen = screen
        self.window = window
        super.init()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleCommand(_:)),
            name: Notification.Name("com.joonlab.DeskPadFold.command"), object: nil
        )
        // The display needs a moment before its new modes can be selected.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.applySavedMode()
        }
    }

    private var isPortrait: Bool {
        UserDefaults.standard.bool(forKey: "portrait")
    }

    private var orientationKey: String {
        isPortrait ? "portrait" : "landscape"
    }

    private func updateIcon() {
        let symbol = isPortrait ? "ipad" : "ipad.landscape"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DeskPad Fold")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = devices.isEmpty && armedUntil == nil
        writeStatus()
    }

    /// Snapshot for other front ends (the Raycast extension reads it).
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func writeStatus() {
        let modes = usableModes().map { mode in
            ["key": key(of: mode), "title": title(of: mode), "current": isCurrent(mode)] as [String: Any]
        }
        let status: [String: Any] = [
            "orientation": orientationKey,
            "mode": CGDisplayCopyDisplayMode(screen.displayID).map { key(of: $0) } ?? "",
            "modeTitle": currentModeTitle,
            "modes": modes,
            "devices": devices.map {
                ["ip": $0.ip, "os": $0.os, "browser": $0.browser, "width": $0.screenWidth, "height": $0.screenHeight]
            },
            "armedUntil": armedUntil.map { Self.timestampFormatter.string(from: $0) } ?? NSNull(),
            "deskreenRunning": deskreen.isRunning,
            "link": lastLink ?? NSNull(),
            "message": lastMessage ?? NSNull(),
            "updatedAt": Self.timestampFormatter.string(from: Date()),
        ]
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeskPad Fold")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        }
    }

    /// Scriptable entry point, e.g. from `deskpad-ctl` or the Raycast extension:
    /// arm | copy | disconnect | portrait | landscape | status | quit | mode:<WxH@scale>
    @objc private func handleCommand(_ notification: Notification) {
        let command = notification.object as? String ?? ""
        if command.hasPrefix("mode:") {
            let wanted = String(command.dropFirst("mode:".count))
            if let mode = usableModes().first(where: { key(of: $0) == wanted }), apply(mode) {
                UserDefaults.standard.set(wanted, forKey: "mode.\(orientationKey)")
            }
            writeStatus()
            return
        }
        switch command {
        case "status":
            Task { @MainActor in await refreshDevices() }
        case "quit":
            NSApp.terminate(nil)
        case "arm": if armedUntil == nil { toggleArm() }
        case "copy": copyLinkOnly()
        case "disconnect": disconnectAll()
        case "portrait": setOrientation(portrait: true)
        case "landscape": setOrientation(portrait: false)
        default: break
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
        Task { @MainActor in
            await refreshDevices()
            rebuild(menu)
        }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(connectionSummary))
        if let lastMessage {
            menu.addItem(disabled(lastMessage))
        }
        let connectTitle = devices.isEmpty ? "폰 연결 — 링크 복사 + 자동 수락" : "폰 다시 연결 — 지금 연결 끊고 새 링크"
        menu.addItem(item(armedUntil == nil ? connectTitle : "연결 대기 취소",
                          #selector(toggleArm), key: "l"))
        menu.addItem(item("링크만 복사", #selector(copyLinkOnly)))
        let disconnect = item("연결 끊기", #selector(disconnectAll))
        disconnect.isEnabled = !devices.isEmpty
        menu.addItem(disconnect)

        menu.addItem(.separator())
        let landscape = item("가로", #selector(setLandscape))
        landscape.state = isPortrait ? .off : .on
        let portrait = item("세로", #selector(setPortrait))
        portrait.state = isPortrait ? .on : .off
        menu.addItem(landscape)
        menu.addItem(portrait)

        let resolution = NSMenuItem(title: "해상도  \(currentModeTitle)", action: nil, keyEquivalent: "")
        let resolutionMenu = NSMenu()
        for mode in usableModes() {
            let modeItem = item(title(of: mode), #selector(chooseMode(_:)))
            modeItem.representedObject = key(of: mode)
            modeItem.state = isCurrent(mode) ? .on : .off
            resolutionMenu.addItem(modeItem)
        }
        resolution.submenu = resolutionMenu
        menu.addItem(resolution)

        menu.addItem(.separator())
        menu.addItem(item(window.isVisible ? "미러 창 숨기기" : "미러 창 보이기 (화면 기록 권한 필요)", #selector(toggleWindow)))
        let login = item("로그인 시 자동 실행", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("종료", #selector(NSApp.terminate), key: "q", target: NSApp))
    }

    private var connectionSummary: String {
        if let device = devices.first {
            let size = device.screenWidth > 0 ? " · \(device.screenWidth)×\(device.screenHeight)" : ""
            return "● 연결됨  \(device.ip) \(device.os)\(size)"
        }
        if let armedUntil {
            let seconds = max(0, Int(armedUntil.timeIntervalSinceNow))
            return "◌ 폰 접속 대기 중… \(seconds / 60):" + String(format: "%02d", seconds % 60)
        }
        return deskreen.isRunning ? "○ 연결된 기기 없음" : "○ Deskreen 꺼짐"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = target ?? self
        return menuItem
    }

    @MainActor
    private func refreshDevices() async {
        guard deskreen.isRunning else {
            devices = []
            updateIcon()
            return
        }
        devices = (try? await deskreen.connectedDevices()) ?? []
        updateIcon()
    }

    // MARK: - Deskreen

    @objc private func toggleArm() {
        if armedUntil != nil {
            disarm(message: nil)
            return
        }
        lastMessage = "Deskreen 준비 중…"
        armTask = Task { @MainActor in
            do {
                try await deskreen.ensureReady()
                // Deskreen CE serves one viewer and only offers a new link once it is gone,
                // including a stale one whose display vanished.
                if try await !deskreen.connectedDevices().isEmpty {
                    try await deskreen.disconnectAll()
                }
                guard let link = try await deskreen.waitForViewerLink() else {
                    disarm(message: "링크를 못 읽었습니다")
                    return
                }
                copy(link)
                lastLink = link
                armedUntil = Date().addingTimeInterval(Self.armDuration)
                lastMessage = "복사됨: \(link)"
                updateIcon()
                await runAutoAccept()
            } catch {
                disarm(message: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func runAutoAccept() async {
        while let armedUntil, armedUntil > Date(), !Task.isCancelled {
            do {
                let result = try await deskreen.advanceConnection(targetDisplayID: screen.displayID)
                switch result {
                case .confirmed:
                    await refreshDevices()
                    // The new stream starts capped at Deskreen's point-sized guess; give it full pixels.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await fitStreamToDisplay()
                    disarm(message: "폰에 DeskPad 화면 공유 시작")
                    NSSound(named: "Glass")?.play()
                    return
                case .targetNotFound:
                    lastMessage = "Deskreen 목록에 DeskPad 화면이 없습니다"
                default:
                    break
                }
            } catch {
                lastMessage = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        if armedUntil != nil {
            disarm(message: "대기 시간이 지나 자동 수락을 껐습니다")
        }
    }

    private func disarm(message: String?) {
        armTask?.cancel()
        armTask = nil
        armedUntil = nil
        lastMessage = message
        updateIcon()
    }

    @objc private func copyLinkOnly() {
        Task { @MainActor in
            do {
                try await deskreen.ensureReady()
                if let link = try await deskreen.waitForViewerLink() {
                    copy(link)
                    lastLink = link
                    lastMessage = "복사됨: \(link)"
                } else {
                    lastMessage = "링크를 못 읽었습니다"
                }
            } catch {
                lastMessage = error.localizedDescription
            }
        }
    }

    @objc private func disconnectAll() {
        Task { @MainActor in
            try? await deskreen.disconnectAll()
            await refreshDevices()
            lastMessage = "연결을 끊었습니다"
        }
    }

    private func log(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DeskPad Fold.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Share of the display's pixels sent to the phone. At 100% (1848x2448, ~4.5 MP) the Mac keeps
    /// ~20 fps with no encoder or network limit, yet the phone lags and stutters decoding it; 75% was
    /// both smooth and sharp in an A/B on the Fold 8.
    /// Overridable with `defaults write com.joonlab.DeskPadFold streamScale -float 0.6` (0.25–1.0).
    private static let streamScale: Double = {
        let value = UserDefaults.standard.double(forKey: "streamScale")
        return (0.25 ... 1.0).contains(value) ? value : 0.75
    }()

    /// Keeps a connected phone's stream near the display's real pixel size (see `fitStreams`).
    @MainActor
    private func fitStreamToDisplay() async {
        guard deskreen.isRunning, let mode = CGDisplayCopyDisplayMode(screen.displayID) else { return }
        let even = { (value: Int) in Int((Double(value) * Self.streamScale / 2).rounded()) * 2 }
        do {
            let sizes = try await deskreen.fitStreams(pixelWidth: even(mode.pixelWidth), pixelHeight: even(mode.pixelHeight))
            if !sizes.isEmpty {
                log("스트림 해상도 \(sizes.joined(separator: ", "))")
            }
        } catch {
            log("스트림 해상도 조정 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Orientation & resolution

    @objc private func setLandscape() {
        setOrientation(portrait: false)
    }

    @objc private func setPortrait() {
        setOrientation(portrait: true)
    }

    private func setOrientation(portrait: Bool) {
        guard portrait != isPortrait else { return }
        screen.applyOrientation(portrait: portrait)
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.applySavedMode()
        }
    }

    private func usableModes() -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(screen.displayID, options) as? [CGDisplayMode]) ?? []
        var seen = Set<String>()
        return modes
            .filter { $0.isUsableForDesktopGUI() && ($0.height > $0.width) == isPortrait }
            .sorted { ($0.width, $0.pixelWidth) > ($1.width, $1.pixelWidth) }
            .filter { seen.insert(key(of: $0)).inserted }
    }

    private func key(of mode: CGDisplayMode) -> String {
        "\(mode.width)x\(mode.height)@\(mode.pixelWidth / max(mode.width, 1))"
    }

    private func title(of mode: CGDisplayMode) -> String {
        let hiDPI = mode.pixelWidth > mode.width
        var title = "\(mode.width) × \(mode.height)"
        if hiDPI { title += "  선명" }
        let aspect = Double(max(mode.width, mode.height)) / Double(max(min(mode.width, mode.height), 1))
        if hiDPI, Set([mode.pixelWidth, mode.pixelHeight]) == Set([1848, 2448]) {
            title += " · 폴드 1:1"
        } else if abs(aspect - 2448.0 / 1848.0) < 0.03 {
            title += " · 폴드 비율"
        }
        return title
    }

    private func isCurrent(_ mode: CGDisplayMode) -> Bool {
        guard let current = CGDisplayCopyDisplayMode(screen.displayID) else { return false }
        return key(of: current) == key(of: mode)
    }

    private var currentModeTitle: String {
        CGDisplayCopyDisplayMode(screen.displayID).map { title(of: $0) } ?? ""
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard
            let wanted = sender.representedObject as? String,
            let mode = usableModes().first(where: { key(of: $0) == wanted })
        else {
            return
        }
        if apply(mode) {
            UserDefaults.standard.set(key(of: mode), forKey: "mode.\(orientationKey)")
        }
    }

    private func applySavedMode() {
        let preferred = Self.preferredModes[orientationKey]!
        let saved = UserDefaults.standard.string(forKey: "mode.\(orientationKey)")
        let modes = usableModes()
        for wanted in [saved].compactMap({ $0 }) + preferred {
            if let mode = modes.first(where: { key(of: $0) == wanted }) {
                apply(mode)
                return
            }
        }
        let targetWidth = Int(preferred[0].split(separator: "x")[0]) ?? 0
        if let closest = modes
            .filter({ $0.pixelWidth > $0.width })
            .min(by: { abs($0.width - targetWidth) < abs($1.width - targetWidth) })
        {
            apply(closest)
        }
    }

    @discardableResult
    private func apply(_ mode: CGDisplayMode) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, screen.displayID, mode, nil)
        let applied = CGCompleteDisplayConfiguration(config, .permanently) == .success
        writeStatus()
        if applied {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await fitStreamToDisplay()
            }
        }
        return applied
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastMessage = "자동 실행 설정 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - Window

    @objc private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
            screen.setMirrorEnabled(false)
        } else {
            screen.setMirrorEnabled(true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
