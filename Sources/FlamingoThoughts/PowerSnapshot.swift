import Foundation
import IOKit.ps
import CoreGraphics

/// What the night shift asks of the Mac before it works: plugged in, not in Low Power Mode,
/// not hot. A value, so the gate can be tested with any combination.
public struct PowerSnapshot: Sendable, Equatable {
    public var onAC: Bool
    /// 0...100 when the Mac has a battery.
    public var batteryPercent: Int?
    public var lowPowerMode: Bool
    public var thermal: ProcessInfo.ThermalState

    public init(onAC: Bool, batteryPercent: Int? = nil, lowPowerMode: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) {
        self.onAC = onAC; self.batteryPercent = batteryPercent; self.lowPowerMode = lowPowerMode; self.thermal = thermal
    }

    /// Plugged in, cool, full power: the night shift's own conditions.
    public static let pluggedIn = PowerSnapshot(onAC: true, batteryPercent: 100)

    public var isHot: Bool { thermal == .serious || thermal == .critical }

    public static func current(_ info: ProcessInfo = .processInfo) -> PowerSnapshot {
        var onAC = true
        var percent: Int?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? {
                onAC = type == kIOPSACPowerValue
            }
            if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
                for source in list {
                    guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                          let capacity = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                    percent = capacity * 100 / max
                }
            }
        }
        return PowerSnapshot(onAC: onAC, batteryPercent: percent, lowPowerMode: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }
}

/// Seconds since the person last touched the keyboard, mouse or trackpad.
public enum UserIdle {
    public static func seconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
