import Cocoa

/// Drives Deskreen CE through its Chrome DevTools port.
/// Deskreen is (re)launched with `--remote-debugging-port` so its renderer can be scripted:
/// read the viewer link, and walk the allow → entire screen → pick display → confirm flow.
final class DeskreenController {
    /// Overridable with `defaults write com.joonlab.DeskPadFold deskreenDebugPort -int <port>`
    /// (see config.example.env and tools/deskpad-config).
    static let port: Int = {
        let value = UserDefaults.standard.integer(forKey: "deskreenDebugPort")
        return value > 0 ? value : 9333
    }()

    /// Overridable with `defaults write com.joonlab.DeskPadFold deskreenAppPath "<path>.app"`.
    private let appURL = URL(fileURLWithPath:
        UserDefaults.standard.string(forKey: "deskreenAppPath") ?? "/Applications/Deskreen CE.app")
    private let bundleID = "com.deskreen-ce.app"

    enum DeskreenError: LocalizedError {
        case notInstalled, notReachable, evaluation(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Deskreen CE 앱을 찾지 못했습니다 (deskreenAppPath 설정 확인)"
            case .notReachable: return "Deskreen CE 에 연결하지 못했습니다"
            case let .evaluation(message): return "Deskreen 스크립트 오류: \(message)"
            }
        }
    }

    struct Device {
        let ip: String
        let os: String
        let browser: String
        let screenWidth: Int
        let screenHeight: Int
    }

    // MARK: - Lifecycle

    /// Returns the DevTools WebSocket URL of a Deskreen page (by default the main window).
    private func pageWebSocketURL(urlContains marker: String = "/renderer/index.html") async -> URL? {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }
        let page = targets.first {
            ($0["type"] as? String) == "page" && (($0["url"] as? String)?.contains(marker) ?? false)
        }
        return (page?["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:))
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Makes sure Deskreen runs with the debugging port, relaunching it if it runs without.
    func ensureReady() async throws {
        if await pageWebSocketURL() != nil { return }
        guard FileManager.default.fileExists(atPath: appURL.path) else { throw DeskreenError.notInstalled }

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
        for _ in 0 ..< 20 where isRunning {
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [
            "--remote-debugging-port=\(Self.port)",
            "--remote-allow-origins=http://127.0.0.1:\(Self.port)",
        ]
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)

        for _ in 0 ..< 60 {
            if await pageWebSocketURL() != nil {
                // Let React mount and create the waiting session.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw DeskreenError.notReachable
    }

    // MARK: - DevTools protocol

    /// One WebSocket to a page; commands are sent one at a time.
    private final class Session {
        private let task: URLSessionWebSocketTask
        private var nextID = 0

        init(url: URL) {
            task = URLSession.shared.webSocketTask(with: url)
            task.resume()
        }

        deinit {
            task.cancel(with: .normalClosure, reason: nil)
        }

        func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            nextID += 1
            let id = nextID
            let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            try await task.send(.string(String(decoding: payload, as: UTF8.self)))
            while true {
                let data: Data
                switch try await task.receive() {
                case let .string(text): data = Data(text.utf8)
                case let .data(raw): data = raw
                @unknown default: continue
                }
                guard
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    object["id"] as? Int == id
                else {
                    continue
                }
                if let error = object["error"] as? [String: Any] {
                    throw DeskreenError.evaluation(error["message"] as? String ?? "\(error)")
                }
                let result = object["result"] as? [String: Any] ?? [:]
                if let exception = result["exceptionDetails"] as? [String: Any] {
                    let text = ((exception["exception"] as? [String: Any])?["description"] as? String)
                        ?? (exception["text"] as? String) ?? "unknown"
                    throw DeskreenError.evaluation(text)
                }
                return result
            }
        }
    }

    private func evaluate(_ expression: String) async throws -> Any? {
        guard let wsURL = await pageWebSocketURL() else { throw DeskreenError.notReachable }
        let result = try await Session(url: wsURL).send("Runtime.evaluate", [
            "expression": expression, "awaitPromise": true, "returnByValue": true,
        ])
        return (result["result"] as? [String: Any])?["value"]
    }

    // MARK: - Stream quality

    /// Deskreen caps capture at the display size it saw when the viewer connected, in points
    /// (e.g. 800x600 for an 800x600@2 mode, and a later portrait mode gets squeezed into that box).
    /// Re-cap every live video track at the display's current pixel size instead.
    /// Returns the resulting track sizes.
    @discardableResult
    func fitStreams(pixelWidth: Int, pixelHeight: Int) async throws -> [String] {
        guard let wsURL = await pageWebSocketURL(urlContains: "peerConnectionHelper") else {
            throw DeskreenError.notReachable
        }
        let session = Session(url: wsURL)
        let proto = try await session.send("Runtime.evaluate", ["expression": "RTCPeerConnection.prototype"])
        guard let protoID = (proto["result"] as? [String: Any])?["objectId"] as? String else { return [] }
        let instances = try await session.send("Runtime.queryObjects", ["prototypeObjectId": protoID])
        guard let arrayID = (instances["objects"] as? [String: Any])?["objectId"] as? String else { return [] }
        let result = try await session.send("Runtime.callFunctionOn", [
            "objectId": arrayID,
            "functionDeclaration": """
            async function(width, height) {
              const sizes = [];
              for (const pc of this) {
                if (pc.connectionState !== 'connected') continue;
                for (const sender of pc.getSenders()) {
                  if (!sender.track || sender.track.kind !== 'video' || sender.track.readyState !== 'live') continue;
                  // A viewer left over from a display that no longer exists cannot restart; skip it.
                  try {
                    await sender.track.applyConstraints({
                      width: { min: Math.round(width / 2), max: width },
                      height: { min: Math.round(height / 2), max: height },
                      frameRate: { min: 15, max: 60 },
                    });
                    const s = sender.track.getSettings();
                    sizes.push(`${s.width}x${s.height}`);
                  } catch (error) {
                    sizes.push(`skipped (${error.name})`);
                  }
                }
              }
              return sizes;
            }
            """,
            "arguments": [["value": pixelWidth], ["value": pixelHeight]],
            "awaitPromise": true,
            "returnByValue": true,
        ])
        return (result["result"] as? [String: Any])?["value"] as? [String] ?? []
    }

    // MARK: - Queries

    /// The URL the phone opens, e.g. http://<mac-lan-ip>:3131/<room-id>
    func viewerLink() async throws -> String? {
        let value = try await evaluate("""
        (async () => {
          const ipc = window.electron.ipcRenderer;
          const [ip, port, room] = await Promise.all([
            ipc.invoke('get-local-lan-ip'),
            ipc.invoke('get-port'),
            ipc.invoke('get-waiting-for-connection-sharing-session-room-id'),
          ]);
          if (ip && port && room) return `http://${ip}:${port}/${room}`;
          const match = document.body.innerText.match(/https?:\\/\\/[0-9.]+:\\d+\\/\\d+/);
          return match ? match[0] : null;
        })()
        """)
        return value as? String
    }

    /// Right after a viewer disconnects Deskreen briefly has no waiting session, so retry.
    func waitForViewerLink() async throws -> String? {
        for _ in 0 ..< 16 {
            if let link = try await viewerLink() { return link }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    func connectedDevices() async throws -> [Device] {
        let value = try await evaluate("window.electron.ipcRenderer.invoke('get-connected-devices-list')")
        return (value as? [[String: Any]] ?? []).map {
            Device(
                ip: $0["deviceIP"] as? String ?? "?",
                os: $0["deviceOS"] as? String ?? "",
                browser: $0["deviceBrowser"] as? String ?? "",
                screenWidth: $0["deviceScreenWidth"] as? Int ?? 0,
                screenHeight: $0["deviceScreenHeight"] as? Int ?? 0
            )
        }
    }

    func disconnectAll() async throws {
        _ = try await evaluate("window.electron.ipcRenderer.invoke('disconnect-all-devices')")
    }

    // MARK: - Auto accept

    enum StepResult: String {
        case idle, allowed, choseEntireScreen, selected, confirmed, targetNotFound
    }

    /// Performs at most one UI step of the connection flow and reports what it did.
    /// Buttons are matched by Korean and English labels; screen cards by the display ID
    /// Deskreen reports for each capture source.
    func advanceConnection(targetDisplayID: CGDirectDisplayID) async throws -> StepResult {
        let value = try await evaluate("""
        (async (target) => {
          const ipc = window.electron.ipcRenderer;
          const buttons = [...document.querySelectorAll('button')];
          const byText = (...labels) => buttons.find(b => labels.includes(b.innerText.trim()));

          const allow = byText('허용합니다', 'Allow');
          if (allow) { allow.click(); return 'allowed'; }

          if (document.querySelector('.choose-app-or-screen-dialog')) {
            const cards = [...document.querySelectorAll('.preview-share-thumb-container')];
            const ids = await ipc.invoke('get-desktop-sharing-source-ids', { isEntireScreenToShareChosen: true });
            for (let i = 0; i < ids.length; i++) {
              const displayID = await ipc.invoke('get-source-display-id-by-desktop-capturer-source-id', ids[i]);
              if (String(displayID) === String(target) && cards[i]) { cards[i].click(); return 'selected'; }
            }
            return 'targetNotFound';
          }

          const confirm = buttons.find(b =>
            b.classList.contains('bp6-intent-success') && ['확인', 'Confirm'].includes(b.innerText.trim()));
          if (confirm) { confirm.click(); return 'confirmed'; }

          const entireScreen = byText('전체 화면', 'Entire Screen');
          if (entireScreen) { entireScreen.click(); return 'choseEntireScreen'; }

          return 'idle';
        })(\(targetDisplayID))
        """)
        return (value as? String).flatMap(StepResult.init(rawValue:)) ?? .idle
    }
}
