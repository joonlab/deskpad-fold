import Cocoa
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClickOnScreen)))
    }

    private var display: CGVirtualDisplay!
    private var stream: CGDisplayStream?
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "DeskPad Display"
        // One display holds both orientations so rotating keeps its ID (and any Deskreen stream).
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 3840
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001

        let display = CGVirtualDisplay(descriptor: descriptor)
        store.dispatch(ScreenViewAction.setDisplayID(display.displayID))
        self.display = display

        applyOrientation(portrait: UserDefaults.standard.bool(forKey: "portrait"))
    }

    var displayID: CGDirectDisplayID {
        display.displayID
    }

    private static let landscapeSizes: [(Int, Int)] = [
        // Galaxy Z Fold 8 inner display (2448x1848 native)
        (2448, 1848), (1836, 1386), (1632, 1232), (1224, 924),
        // 16:9
        (3840, 2160), (2560, 1440), (1920, 1080), (1600, 900), (1366, 768), (1280, 720),
        // 16:10
        (2560, 1600), (1920, 1200), (1680, 1050), (1440, 900), (1280, 800),
    ]
    private static let portraitOnlySizes: [(Int, Int)] = [
        // 3:4
        (1536, 2048), (1200, 1600), (1080, 1440), (960, 1280), (768, 1024),
    ]

    func applyOrientation(portrait: Bool) {
        UserDefaults.standard.set(portrait, forKey: "portrait")
        let sizes = portrait
            ? Self.landscapeSizes.map { ($0.1, $0.0) } + Self.portraitOnlySizes
            : Self.landscapeSizes
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = sizes.map { width, height in
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60)
        }
        display.apply(settings)
    }

    /// The mirror window is optional: the phone shows the display through Deskreen,
    /// so capturing (and the screen recording prompt) only happens while it is shown.
    private(set) var isMirrorEnabled = false
    private var latestViewData: ScreenViewData?

    func setMirrorEnabled(_ enabled: Bool) {
        isMirrorEnabled = enabled
        previousResolution = nil
        previousScaleFactor = nil
        stream = nil
        if let latestViewData {
            update(with: latestViewData)
        }
    }

    override func update(with viewData: ScreenViewData) {
        latestViewData = viewData
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor(named: "TitleBarActive")
                : NSColor(named: "TitleBarInactive")
            if isWindowHighlighted, isMirrorEnabled {
                view.window?.orderFrontRegardless()
            }
        }

        if
            isMirrorEnabled,
            viewData.resolution != .zero,
            viewData.resolution != previousResolution
            || viewData.scaleFactor != previousScaleFactor
        {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor
            stream = nil
            view.window?.setContentSize(viewData.resolution)
            view.window?.contentAspectRatio = viewData.resolution
            // Keep the mirror on the main screen, never on the virtual display it shows.
            if let main = NSScreen.screens.first, let window = view.window {
                let frame = main.visibleFrame
                window.setFrameOrigin(NSPoint(
                    x: frame.midX - window.frame.width / 2,
                    y: max(frame.minY, frame.maxY - window.frame.height)
                ))
            }
            let stream = CGDisplayStream(
                dispatchQueueDisplay: display.displayID,
                outputWidth: Int(viewData.resolution.width * viewData.scaleFactor),
                outputHeight: Int(viewData.resolution.height * viewData.scaleFactor),
                pixelFormat: 1_111_970_369,
                properties: [
                    CGDisplayStream.showCursor: true,
                ] as CFDictionary,
                queue: .main,
                handler: { [weak self] _, _, frameSurface, _ in
                    if let surface = frameSurface {
                        self?.view.layer?.contents = surface
                    }
                }
            )
            self.stream = stream
            stream?.start()
        }
    }

    func windowWillClose(_: Notification) {
        setMirrorEnabled(false)
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        guard
            let screenResolution = previousResolution,
            abs(contentSize.width - screenResolution.width) < snappingOffset
        else {
            return frameSize
        }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: screenResolution)).size
    }

    @objc private func didClickOnScreen(_ gestureRecognizer: NSGestureRecognizer) {
        guard let screenResolution = previousResolution else {
            return
        }
        let clickedPoint = gestureRecognizer.location(in: view)
        let onScreenPoint = NSPoint(
            x: clickedPoint.x / view.frame.width * screenResolution.width,
            y: (view.frame.height - clickedPoint.y) / view.frame.height * screenResolution.height
        )
        store.dispatch(MouseLocationAction.requestMove(toPoint: onScreenPoint))
    }
}
