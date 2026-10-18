// Posts one synthetic two-finger trackpad scroll gesture (phased, pixel deltas) to a process,
// the way a horizontal swipe arrives when "Swipe between pages" is a two-finger scroll.
// Usage: qa-scroll <pid> <x> <y> <dx> <dy> <steps> [interval-ms] [began-dx began-dy]
//   x, y      global point (top-left origin, as `window-id --bounds` prints) the pointer is at
//   dx, dy    pixels per changed event (positive dx = fingers moving right = back)
//   steps     changed events between began and ended
//   began-dx/dy  deltas on the began event (default: dx dy)
// Compiled to build/qa-scroll by scripts/nav-qa.sh. The app gets these with no window (FLAMINGO_DEBUG
// lets the swipe monitor take them anyway). AppKit's swipe tracker answers them with its real
// callback sequence but won't move its amount past the first event's: to drive a whole swipe,
// use the QA hook's `swipe sim` verb (NavigationQA.swift).
import CoreGraphics
import Foundation

let a = Array(CommandLine.arguments.dropFirst())
guard a.count >= 6, let pid = Int32(a[0]), let x = Double(a[1]), let y = Double(a[2]),
      let dx = Int32(a[3]), let dy = Int32(a[4]), let steps = Int(a[5]) else {
    FileHandle.standardError.write(Data("usage: qa-scroll <pid> <x> <y> <dx> <dy> <steps> [interval-ms] [began-dx began-dy]\n".utf8))
    exit(2)
}
let interval = a.count > 6 ? (Double(a[6]) ?? 12) / 1000 : 0.012
let beganDX = a.count > 8 ? Int32(a[7]) ?? dx : dx
let beganDY = a.count > 8 ? Int32(a[8]) ?? dy : dy

/// kCGScrollWheelEventScrollPhase and kCGScrollWheelEventMomentumPhase values.
enum Phase: Int64 { case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128 }

func post(_ dx: Int32, _ dy: Int32, phase: Phase, momentum: Int64 = 0) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
    e.location = CGPoint(x: x, y: y)
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
    e.postToPid(pid_t(pid))
    Thread.sleep(forTimeInterval: interval)
}

post(0, 0, phase: .mayBegin)
post(beganDX, beganDY, phase: .began)
for _ in 0..<steps { post(dx, dy, phase: .changed) }
post(0, 0, phase: .ended)
// A little momentum, as a real flick leaves behind.
post(dx / 2, dy / 2, phase: .none, momentum: 1)
for _ in 0..<4 { post(dx / 3, dy / 3, phase: .none, momentum: 2) }
post(0, 0, phase: .none, momentum: 3)
