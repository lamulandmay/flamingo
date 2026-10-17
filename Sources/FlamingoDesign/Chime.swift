import AppKit

/// The sound and feel of a thought landing or two files connecting: soft mallet notes, one
/// more per strength level (0 spark, 1 solid, 2 woven), each with a trackpad tap. Notes sound
/// only while macOS's "Play user interface sound effects" is on; taps are felt only with a
/// finger on a Force Touch trackpad, as with every Mac haptic.
@MainActor
public enum Chime {
    /// G5, D6, G6: root, fifth, octave. Open intervals, so any run of them resolves.
    nonisolated static let frequencies: [Double] = [783.99, 1174.66, 1567.98]
    /// Between the notes of one run.
    nonisolated public static let spacing: TimeInterval = 0.09

    private static let sounds: [NSSound?] = frequencies.map { NSSound(data: wav(frequency: $0)) }

    /// The whole run for `level`, starting now. For a save with nothing to watch.
    public static func play(level: Int) {
        let count = min(max(level, 0), 2) + 1
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(i)) {
                note(i)
                tap(final: i == count - 1)
            }
        }
    }

    /// A connection's run split around its motion: the first note as the line leaves, the
    /// rest as it arrives.
    public static func depart() { note(0); tap(final: false) }
    public static func arrive(level: Int) {
        let count = min(max(level, 0), 2)
        guard count > 0 else { return tap(final: true) }
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(i)) {
                note(i + 1)
                tap(final: i == count - 1)
            }
        }
    }

    static func note(_ i: Int) {
        guard soundsEnabled, sounds.indices.contains(i), let sound = sounds[i] else { return }
        sound.stop()
        sound.play()
    }

    static func tap(final: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(final ? .levelChange : .alignment, performanceTime: .now)
    }

    static var soundsEnabled: Bool {
        (UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int).map { $0 != 0 } ?? true
    }

    /// A mallet on a small bar: the fundamental rings, the fourth partial gives the wood, a
    /// faint tenth is the strike. 16-bit mono WAV, quiet (peak about −13 dBFS).
    nonisolated static func wav(frequency f: Double, duration: Double = 0.45, rate: Double = 44_100) -> Data {
        let n = Int(duration * rate)
        var samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            let attack = min(1, t / 0.003)
            let tail = min(1, (duration - t) / 0.03)
            let w = 2 * Double.pi * f * t
            let v = sin(w) * exp(-t / 0.16)
                + 0.30 * sin(4 * w) * exp(-t / 0.035)
                + 0.06 * sin(10 * w) * exp(-t / 0.010)
            samples[i] = Int16(max(-1, min(1, 0.19 * attack * tail * v)) * Double(Int16.max))
        }
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(n * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate) * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        samples.forEach { put($0) }
        return data
    }
}
