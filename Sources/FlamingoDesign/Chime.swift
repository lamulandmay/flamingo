import AppKit

/// The sound and feel of a thought landing or two files connecting: soft bell notes, one more
/// per strength level (0 spark, 1 solid, 2 woven), each with a trackpad tap. Notes sound only
/// while macOS's "Play user interface sound effects" is on; taps are felt only with a finger on
/// a Force Touch trackpad, as with every Mac haptic.
@MainActor
public enum Chime {
    /// D5, A5, D6: root, fifth, octave. Open intervals, so any run of them resolves, and a
    /// fourth lower than a glockenspiel, so they sit under speech instead of over it.
    nonisolated static let frequencies: [Double] = [587.33, 880.0, 1174.66]
    /// Between the notes of one run: a quick upward run reads as "yes".
    nonisolated public static let spacing: TimeInterval = 0.085

    /// Three voices per note, taken in turn, so a note retriggered while it still rings never
    /// cuts itself off (a stopped sample clicks).
    private static let voices: [[NSSound]] = frequencies.enumerated().map { i, f in
        (0..<3).compactMap { _ in
            let s = NSSound(data: wav(frequency: f, pan: [-0.25, 0, 0.25][i]))
            s?.volume = 1
            return s
        }
    }
    private static var nextVoice = [Int](repeating: 0, count: frequencies.count)

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

    /// One soft note and a tap, for a small decision such as marking a thought done. The note
    /// is the one `level` would end on (0 spark, 1 solid, 2 woven). Silent when the Mac's
    /// interface sounds are off.
    public static func tick(level: Int) {
        note(min(max(level, 0), 2))
        tap(final: true)
    }

    static func note(_ i: Int) {
        guard soundsEnabled, voices.indices.contains(i), !voices[i].isEmpty else { return }
        let v = nextVoice[i] % voices[i].count
        nextVoice[i] = v + 1
        let sound = voices[i][v]
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    static func tap(final: Bool) {
        Feedback.haptic(final ? .threshold : .detent)
    }

    nonisolated static var soundsEnabled: Bool {
        (UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Int).map { $0 != 0 } ?? true
    }

    /// A soft mallet on a small bell. The fundamental rings for about a second; a quiet
    /// octave gives it presence and fades fast; a faint high partial is the touch of the
    /// mallet, gone in 10ms. A copy of the fundamental 1.1 Hz off, a little to each side, makes
    /// it breathe instead of beep. The onset is a 5ms raised cosine (no click, still crisp) and
    /// the pitch settles from 4 cents sharp, as a struck bar does. 16-bit stereo WAV, quiet
    /// (peak about −16 dBFS). `pan` −1…1 places the note.
    nonisolated static func wav(frequency f: Double, pan: Double = 0, duration: Double = 0.9, rate: Double = 44_100) -> Data {
        let n = Int(duration * rate)
        var left = [Double](repeating: 0, count: n), right = left
        var peak = 0.0
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            let attack = t < 0.005 ? 0.5 - 0.5 * cos(Double.pi * t / 0.005) : 1
            let tail = min(1, (duration - t) / 0.08)
            let bend = 1 + 0.0023 * exp(-t / 0.03)
            phase += 2 * Double.pi * f * bend / rate
            let body = sin(phase) * exp(-t / 0.32)
            let octave = 0.22 * sin(2 * phase) * exp(-t / 0.09)
            let touch = 0.05 * sin(6.27 * phase) * exp(-t / 0.010)
            let shimmerL = 0.18 * sin(2 * Double.pi * (f + 1.1) * t) * exp(-t / 0.36)
            let shimmerR = 0.18 * sin(2 * Double.pi * (f - 1.1) * t) * exp(-t / 0.36)
            let core = (body + octave + touch) * attack * tail
            left[i] = core * (1 - max(0, pan)) + shimmerL * attack * tail
            right[i] = core * (1 + min(0, pan)) + shimmerR * attack * tail
            peak = max(peak, abs(left[i]), abs(right[i]))
        }
        let gain = peak > 0 ? 0.16 / peak : 0
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(n * 4)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(2))
        put(UInt32(rate)); put(UInt32(rate) * 4); put(UInt16(4)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for i in 0..<n {
            put(Int16(max(-1, min(1, left[i] * gain)) * Double(Int16.max)))
            put(Int16(max(-1, min(1, right[i] * gain)) * Double(Int16.max)))
        }
        return data
    }
}
