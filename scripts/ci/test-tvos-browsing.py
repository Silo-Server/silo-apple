#!/usr/bin/env python3
"""Run actual tvOS gate, timeline and focus-lifecycle bodies with a virtual clock.

SwiftUI, Nuke, networking and the native focus engine are not simulated here.
These checks cover cancellation, callback ownership and frame math; TV checks cover UX.
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "iosApp/iosApp"


def app_source(path):
    # Run these same regressions against a specified baseline without a checkout.
    if ref := os.environ.get("SILO_TV_TEST_SOURCE_REF"):
        return subprocess.check_output(
            ["git", "show", f"{ref}:iosApp/iosApp/{path}"], cwd=ROOT, text=True)
    return (APP / path).read_text()


def function(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


marquee = app_source("tvOS/Components/TVFocusMarquee.swift")
splash = app_source("Components/StartupSplashView.swift")
theme = app_source("Theme/SiloTheme.swift")
frames = app_source("Components/StartupSplashAnimation.swift")
row = app_source("Components/MediaRow.swift")
cast = app_source("tvOS/Screens/Detail/TVDetailCastRail.swift")
series = app_source("tvOS/Screens/Detail/TVSeriesDetailView.swift")
favorite = function(row, "private func favoriteToggleAction(").replace("private func", "func")
favorite = favorite.replace("#if os(tvOS)", "").replace("#endif", "")
cast_task = function(cast, '.task(id: "\\(focusRequest):')
cast_body = cast_task[cast_task.index("{") + 1:-1].replace("Task.sleep(for:", "VirtualClock.sleep(for:")
cancel = function(series, "private func cancelSupportingHandoff()").replace("private func", "func")
# The baseline passed cancelSupportingHandoff directly; preserve that wiring.
failure_callback = "{ parent.cancelSupportingHandoff() }"
failure_method = ""
if "private func failSupportingHandoff(" in series:
    failure_method = function(series, "private func failSupportingHandoff(").replace("private func", "func")
    callback_start = series.index("onFocusRequestFailed: {")
    callback = function(series[callback_start:], "onFocusRequestFailed:").split(": ", 1)[1]
    failure_callback = callback.replace("supportingRailFocusGeneration", "parent.supportingRailFocusGeneration").replace(
        "supportingRailFocusRequest", "parent.supportingRailFocusRequest").replace(
        "failSupportingHandoff(", "parent.failSupportingHandoff(")
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
        try Task.checkCancellation()
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
struct SectionItem { let id: String }
@MainActor final class FavoriteState {
    var onSetFavorite: ((SectionItem, Bool) async -> Bool)?
    var events: [String] = []
}
@MainActor struct FavoriteHarness {
    let state = FavoriteState()
    var onSetFavorite: ((SectionItem, Bool) async -> Bool)? {
        get { state.onSetFavorite }
        nonmutating set { state.onSetFavorite = newValue }
    }
    var events: [String] {
        get { state.events }
        nonmutating set { state.events = newValue }
    }
    func preserveFocusForContextMutation(on item: SectionItem) { events.append("preserve:" + item.id) }
    FAVORITE
}
@MainActor final class HandoffHarness {
    var supportingHandoffPending = true
    var supportingRailFocusGeneration = 1
    var supportingRailFocusRequest = 1
    CANCEL
    FAILURE_METHOD
}
@MainActor final class CastHarness {
    struct Proxy {
        enum Anchor { case leading }
        func scrollTo(_ id: String, anchor: Anchor) {}
    }
    let proxy = Proxy()
    var focusRequest = 1
    var focusRequestIsActive = true
    var defaultFocusId: String? = "first"
    var acceptsFocus = false
    private var storedFocus: String?
    var focusedCastId: String? {
        get { storedFocus }
        set { if acceptsFocus { storedFocus = newValue } }
    }
    var onFocusRequestFailed: (() -> Void)?
    func runRequest() async { CAST_BODY }
}
@main struct Checks {
    @MainActor static func failureCallback(_ parent: HandoffHarness) -> () -> Void {
        FAILURE_CALLBACK
    }
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
        var failures = 0
        func expect(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let favorite = FavoriteHarness()
        let item = SectionItem(id: "card")
        expect(favorite.favoriteToggleAction(for: item) == nil, "missing favourite handler stays unavailable")
        for result in [false, true] {
            favorite.events = []
            favorite.onSetFavorite = { item, value in
                favorite.events.append("mutation:" + item.id)
                return result
            }
            let returned = await favorite.favoriteToggleAction(for: item)!(result)
            expect(favorite.events == ["preserve:card", "mutation:card"] && returned == result,
                   "favourite preserves focus before mutation and returns \(result)")
        }
        for cancelAtEnd in [false, true] {
            let rail = CastHarness(), parent = HandoffHarness()
            rail.onFocusRequestFailed = failureCallback(parent)
            let task = Task { await rail.runRequest() }
            await VirtualClock.drain()
            if cancelAtEnd { for _ in 0..<12 { await VirtualClock.advance(50) } }
            task.cancel()
            await VirtualClock.advance(50)
            await task.value
            expect(!parent.supportingHandoffPending && parent.supportingRailFocusGeneration == 2,
                   "cancellation releases pending handoff during \(cancelAtEnd ? "final" : "first") wait")
        }
        for replacement in ["generation", "request"] {
            let rail = CastHarness(), parent = HandoffHarness()
            rail.onFocusRequestFailed = failureCallback(parent)
            let staleFailure = rail.onFocusRequestFailed!
            let task = Task { await rail.runRequest() }
            await VirtualClock.drain()
            if replacement == "generation" { parent.supportingRailFocusGeneration += 1 }
            else { parent.supportingRailFocusRequest += 1 }
            task.cancel()
            await VirtualClock.advance(50)
            await task.value
            expect(parent.supportingHandoffPending, "old cancellation preserves replacement \(replacement)")
            staleFailure()
            expect(parent.supportingHandoffPending, "old timeout preserves replacement \(replacement)")
            failureCallback(parent)()
            expect(!parent.supportingHandoffPending, "replacement \(replacement) can still release its own handoff")
        }
        for outcome in ["success", "timeout", "inactive"] {
            let rail = CastHarness()
            var callbacks = 0
            rail.onFocusRequestFailed = { callbacks += 1 }
            rail.acceptsFocus = outcome == "success"
            rail.focusRequestIsActive = outcome != "inactive"
            let task = Task { await rail.runRequest() }
            await VirtualClock.drain()
            for _ in 0..<13 { await VirtualClock.advance(50) }
            await task.value
            expect(callbacks == (outcome == "timeout" ? 1 : 0), "cast \(outcome) preserves callback behaviour")
        }
        let completed = HandoffHarness()
        completed.supportingHandoffPending = false
        failureCallback(completed)()
        expect(completed.supportingRailFocusGeneration == 1, "completed handoff ignores late failure")
        if failures > 0 { exit(1) }
    }
}
'''
for key, value in {"ISOLATED": isolated, "ROLLING": rolling, "FPS": fps,
                   "METHODS": methods, "TIMELINE": timeline, "COMPLETE": complete, "FINISH": finish,
                   "FAVORITE": favorite, "CAST_BODY": cast_body, "CANCEL": cancel,
                   "FAILURE_METHOD": failure_method, "FAILURE_CALLBACK": failure_callback}.items():
    source = source.replace(key, value)
with tempfile.TemporaryDirectory(prefix="silo-tvos-gates-") as folder:
    path = Path(folder)
    (path / "Checks.swift").write_text(source)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(path / "Checks.swift"),
                    "-o", str(path / "checks")], check=True, timeout=60)
    subprocess.run([str(path / "checks")], check=True, timeout=20)
