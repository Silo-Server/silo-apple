#!/usr/bin/env python3
"""Run actual tvOS gate/timeline function bodies with a virtual clock.

SwiftUI, Nuke, networking and the native focus engine are not simulated here.
These checks cover cancellation and frame math; physical TV checks cover UX.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "iosApp/iosApp"


def function(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


marquee = (APP / "tvOS/Components/TVFocusMarquee.swift").read_text()
splash = (APP / "Components/StartupSplashView.swift").read_text()
theme = (APP / "Theme/SiloTheme.swift").read_text()
frames = (APP / "Components/StartupSplashAnimation.swift").read_text()
isolated = re.search(r"marqueeBackdropIsolatedRestMilliseconds = (\d+)", theme)[1]
rolling = re.search(r"marqueeBackdropRollRestMilliseconds = (\d+)", theme)[1]
fps = re.search(r"framesPerSecond: Double = (\d+)", frames)[1]
methods = "\n".join(function(marquee, s) for s in [
    "func seed(_ candidate:", "func preview(_ candidate:", "func suspend()", "func resume()",
]).replace("Task.sleep(for:", "VirtualClock.sleep(for:")
start = splash.index("    private static let stackStart")
end = splash.index("    var body:", start)
timeline = splash[start:end]
complete = function(splash, "private func towerIsComplete(at date:") .replace("private func", "func")
finish = function(splash, "private func finishIfReady()") .replace("private func", "func").replace("Date()", "now")
source = r'''
import Foundation
struct TVMarqueeContent: Equatable { let id: String }
enum SiloTheme { enum Skyline {
    static let marqueeBackdropIsolatedRestMilliseconds = ISOLATED
    static let marqueeBackdropRollRestMilliseconds = ROLLING
} }
enum StartupSplashAnimation { static let framesPerSecond: Double = FPS }
@MainActor enum VirtualClock {
    static var now = 0
    static var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    static func sleep(for duration: Duration) async throws {
        let parts = duration.components
        let ms = Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        await withCheckedContinuation { waiters.append((now + ms, $0)) }
    }
    static func advance(_ ms: Int) async {
        now += ms
        let due = waiters.filter { $0.0 <= now }
        waiters.removeAll { $0.0 <= now }
        due.forEach { $0.1.resume() }
        await drain()
    }
    static func drain() async { for _ in 0..<20 { await Task.yield() } }
}
@MainActor final class MarqueeHarness {
    var content: TVMarqueeContent?
    var backdropTask: Task<Void, Never>?
    var enrichTask: Task<Void, Never>?
    var tintTask: Task<Void, Never>?
    var isBackdropRoll = false
    var backdropContentID: String?
    var isActive = true
    var lastSampledTintURL: String?
    var displayed: [String] = []
    func loadEnrichment(for candidate: TVMarqueeContent, deferNetwork: Bool = false) {}
    func updateBackdropIfReady() { if let backdropContentID { displayed.append(backdropContentID) } }
    METHODS
}
enum StartupSplashCanvas { TIMELINE }
@MainActor final class CompletionHarness {
    var repeatsTowerWhileWaiting = true
    var reduceMotion = false
    var waitingStartDate: Date? = Date(timeIntervalSince1970: 0)
    var completionCycle: Int?
    var now = Date(timeIntervalSince1970: 0)
    var didFinish = false
    var didFinishIntro = false
    var isContentReady = false
    var completionTask: Task<Void, Never>?
    var finishes = 0
    func onFinished() { finishes += 1 }
    COMPLETE
    FINISH
}
@main struct Checks {
    @MainActor static func main() async {
        let a = TVMarqueeContent(id: "a"), b = TVMarqueeContent(id: "b"), c = TVMarqueeContent(id: "c")
        let m = MarqueeHarness()
        m.seed(a)
        precondition(m.displayed == ["a"], "cold seed must paint immediately")
        m.preview(b)
        precondition(m.content == b && m.displayed == ["a"], "focus must move before backdrop")
        await VirtualClock.drain()
        await VirtualClock.advance(ISOLATED - 1)
        precondition(m.displayed == ["a"], "isolated gate must hold")
        await VirtualClock.advance(1)
        precondition(m.displayed == ["a", "b"] && !m.isBackdropRoll, "isolated gate must release")
        m.preview(a)
        await VirtualClock.drain()
        await VirtualClock.advance(100)
        m.preview(c)
        await VirtualClock.drain()
        await VirtualClock.advance(ROLLING - 1)
        precondition(m.displayed == ["a", "b"] && m.isBackdropRoll, "obsolete selection must not paint")
        await VirtualClock.advance(1)
        precondition(m.displayed == ["a", "b", "c"] && !m.isBackdropRoll, "only final roll selection may paint")
        m.preview(b)
        await VirtualClock.drain()
        m.suspend()
        await VirtualClock.advance(ROLLING)
        precondition(m.displayed == ["a", "b", "c"], "offscreen work must not publish")
        m.resume()
        precondition(m.displayed.last == "b", "return must restore current selection")
        m.preview(a)
        await VirtualClock.drain()
        await VirtualClock.advance(ISOLATED)
        precondition(m.displayed.last == "a", "new isolated click must not inherit roll delay")
        let duration = StartupSplashCanvas.cycleDuration
        for i in 0...180 {
            let t = Double(i) / StartupSplashAnimation.framesPerSecond
            let frame = StartupSplashCanvas.waitingTowerFrame(elapsed: t)
            precondition(frame >= 2 && frame <= 92, "tower frame escaped source bounds")
            let reverse = StartupSplashCanvas.waitingTowerFrame(elapsed: duration - t)
            precondition(abs(frame - reverse) < 0.000001, "unstack/restack pace must match")
        }
        precondition(StartupSplashCanvas.waitingTowerFrame(elapsed: 0) == 92)
        precondition(StartupSplashCanvas.waitingTowerFrame(elapsed: duration / 2) == 2)
        precondition(StartupSplashCanvas.waitingTowerFrame(elapsed: duration) == 92)
        let gate = CompletionHarness()
        gate.didFinishIntro = true
        gate.completionCycle = 1
        gate.now = Date(timeIntervalSince1970: duration)
        gate.finishIfReady()
        precondition(gate.finishes == 0, "stack alone cannot reveal unready Home")
        gate.isContentReady = true
        gate.now = Date(timeIntervalSince1970: duration - 0.001)
        gate.finishIfReady()
        precondition(gate.finishes == 0, "ready Home cannot interrupt unfinished stack")
        gate.now = Date(timeIntervalSince1970: duration)
        gate.finishIfReady(); gate.finishIfReady()
        precondition(gate.finishes == 1, "ready Home reveals once on completed stack")
        let reduced = CompletionHarness()
        reduced.reduceMotion = true
        reduced.didFinishIntro = true
        reduced.isContentReady = true
        reduced.finishIfReady()
        precondition(reduced.finishes == 1, "Reduce Motion cannot wait for an animated cycle")
        print("PASS: actual rolling-gate cancellation, suspension/reset, source-frame timing and ready-Home completion bodies")
    }
}
'''
for key, value in {"ISOLATED": isolated, "ROLLING": rolling, "FPS": fps,
                   "METHODS": methods, "TIMELINE": timeline, "COMPLETE": complete, "FINISH": finish}.items():
    source = source.replace(key, value)
with tempfile.TemporaryDirectory(prefix="silo-tvos-gates-") as folder:
    path = Path(folder)
    (path / "Checks.swift").write_text(source)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(path / "Checks.swift"),
                    "-o", str(path / "checks")], check=True, timeout=60)
    subprocess.run([str(path / "checks")], check=True, timeout=20)
