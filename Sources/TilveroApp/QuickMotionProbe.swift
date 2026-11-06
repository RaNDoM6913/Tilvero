import AppKit
import QuartzCore

/// Development-only frame-time probe for quick-menu motion. It records display-link frame intervals, the popover
/// window height per frame and main-thread busy time per run-loop iteration. Active only when the process runs
/// from the laboratory bundle with TILVERO_MOTION_PROBE=<output.json>; production bundles ignore it.
@MainActor final class MotionRecorder: NSObject {
    private(set) var frameStamps: [CFTimeInterval] = []
    private(set) var popoverHeights: [CGFloat] = []
    private(set) var busy: [Double] = []   // ms of main-thread work per run-loop iteration
    private var observer: CFRunLoopObserver?
    private var iterationStart: CFAbsoluteTime = 0
    private var link: CADisplayLink?
    var sampleHeight: (() -> CGFloat)?

    func start(view: NSView) {
        frameStamps = []; popoverHeights = []; busy = []
        link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            guard let self else { return }
            if activity == .afterWaiting { self.iterationStart = CFAbsoluteTimeGetCurrent() }
            else if self.iterationStart > 0 { self.busy.append((CFAbsoluteTimeGetCurrent() - self.iterationStart) * 1000); self.iterationStart = 0 }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }
    func stop() {
        link?.invalidate(); link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }
    @objc private func tick(_ link: CADisplayLink) {
        frameStamps.append(link.timestamp)
        if let sampleHeight { popoverHeights.append(sampleHeight()) }
    }
    func summary() -> [String: Any] {
        let intervals = zip(frameStamps.dropFirst(), frameStamps).map { ($0 - $1) * 1000 }
        let sortedBusy = busy.sorted()
        let nominal = intervals.sorted().first ?? 16.7
        let distinctHeights = Array(NSOrderedSet(array: popoverHeights.map { Double($0) })) as? [Double] ?? []
        return [
            "frames": frameStamps.count,
            "frameIntervalMsMedian": intervals.sorted().isEmpty ? 0 : intervals.sorted()[intervals.count / 2],
            "frameIntervalMsMax": intervals.max() ?? 0,
            "hitches(>1.5x nominal)": intervals.filter { $0 > nominal * 1.5 }.count,
            "mainBusyMsMax": sortedBusy.last ?? 0,
            "mainBusyMsP95": sortedBusy.isEmpty ? 0 : sortedBusy[Int(Double(sortedBusy.count - 1) * 0.95)],
            "mainBusyMsTotal": busy.reduce(0, +),
            "iterations>8ms": busy.filter { $0 > 8 }.count,
            "iterations>16ms": busy.filter { $0 > 16 }.count,
            "busySeriesMsOver1": busy.filter { $0 > 1 }.prefix(40).map { ($0 * 10).rounded() / 10 },
            "popoverHeightSteps": distinctHeights.count,
            "popoverHeights": distinctHeights.map { Int($0.rounded()) },
        ]
    }
}


@MainActor extension TilveroAppDelegate {
    static var motionProbeOutputPath: String? {
        guard Bundle.main.infoDictionary?["TilveroDataScope"] as? String == "laboratory" else { return nil }
        return ProcessInfo.processInfo.environment["TILVERO_MOTION_PROBE"]
    }

    func runMotionProbeIfRequested() {
        guard let path = Self.motionProbeOutputPath else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            popover.behavior = .applicationDefined   // the probe must not be dismissed by focus changes
            togglePopover()
            try? await Task.sleep(for: .seconds(2))
            guard let host = popover.contentViewController as? QuickPanelHostingController else { return }
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            @MainActor func tabs(_ count: Int) -> NSSegmentedControl? { all(host.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == count } }
            let recorder = MotionRecorder()
            recorder.sampleHeight = { host.view.window?.frame.height ?? 0 }
            var results: [String: Any] = ["popoverShown": popover.isShown]
            @MainActor func switchTo(_ label: String, _ count: Int, _ index: Int) async {
                guard let control = tabs(count) else { results[label] = "control missing"; return }
                recorder.start(view: host.view)
                try? await Task.sleep(for: .milliseconds(200))
                control.selectedSegment = index
                _ = control.sendAction(control.action, to: control.target)
                try? await Task.sleep(for: .milliseconds(900))
                recorder.stop()
                results[label] = recorder.summary()
            }
            for round in 1...2 {
                await switchTo("r\(round) 1 overview->charge", 4, 1)
                await switchTo("r\(round) 2 charge->modes", 4, 2)
                await switchTo("r\(round) 3 modes->sleep", 4, 3)
                await switchTo("r\(round) 4 sleep timer->keep awake", 2, 1)
                await switchTo("r\(round) 5 sleep->overview", 4, 0)
            }
            if ProcessInfo.processInfo.environment["TILVERO_MOTION_LOOP"] != nil {
                for i in 0..<60 {
                    if let control = tabs(4) { control.selectedSegment = [1, 2, 0, 3][i % 4]; _ = control.sendAction(control.action, to: control.target) }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
