import AppKit
import Foundation

/// Synthesizes and plays the classic gas station "ding-ding" bell.
///
/// The sound is generated entirely in code — no external audio files.
/// Models a small steel service bell with inharmonic overtones and fast decay,
/// struck twice in quick succession as a car drives over the hose.
///
/// Plays through the default system output at current system volume.
/// Respects mute and Focus modes — won't wake anyone at 3 AM.
@MainActor
enum FuelGaugeBell {

    // MARK: - Public API

    /// Plays two bell strikes separated by ~320ms — the classic gas station sound.
    static func play() {
        playStrike()
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            playStrike()
        }
    }

    // MARK: - Playback

    /// Holds a strong reference so the sound isn't deallocated mid-playback.
    private static var activeSound: NSSound?

    private static func playStrike() {
        // NSSound from in-memory WAV data
        guard let sound = NSSound(data: bellTone) else { return }
        // Stop any previous strike still decaying
        activeSound?.stop()
        activeSound = sound
        sound.play()
    }

    // MARK: - Synthesis

    /// A single bell strike, pre-rendered as a WAV byte buffer.
    ///
    /// Physics of a small steel bell:
    ///   - Fundamental at 1200 Hz
    ///   - Inharmonic overtones at 2.5x and 3.9x (not integer multiples — that's
    ///     what makes bells sound like bells instead of flutes)
    ///   - Fast exponential decay (~300ms) — small bell, quick ring-out
    ///   - Slight attack softening to avoid a click
    private static let bellTone: Data = {
        let sampleRate: UInt32 = 44100
        let duration: Double = 0.38                         // just under 400ms
        let numSamples = Int(Double(sampleRate) * duration)

        // --- Generate PCM samples (16-bit signed, mono, little-endian) ---
        var pcm = Data(capacity: numSamples * 2)

        for i in 0..<numSamples {
            let t = Double(i) / Double(sampleRate)

            // Amplitude envelope: 3ms attack ramp → exponential decay
            let attack = min(1.0, t / 0.003)
            let decay  = exp(-t * 14.0)
            let envelope = attack * decay

            // Bell timbre: fundamental + two inharmonic partials
            let fundamental = sin(2.0 * .pi * 1200.0 * t)
            let partial1    = sin(2.0 * .pi * 3000.0 * t) * 0.35   // 2.5x
            let partial2    = sin(2.0 * .pi * 4680.0 * t) * 0.15   // 3.9x

            let sample = (fundamental + partial1 + partial2) * envelope * 0.55
            var int16 = Int16(clamping: Int(sample * 32767.0))
            withUnsafeBytes(of: &int16) { pcm.append(contentsOf: $0) }
        }

        // --- Wrap in a WAV container ---
        return wav(pcm: pcm, sampleRate: sampleRate)
    }()

    // MARK: - WAV Encoding

    /// Builds a minimal WAV file (44-byte header + PCM data).
    private static func wav(pcm: Data, sampleRate: UInt32) -> Data {
        var w = Data(capacity: 44 + pcm.count)

        func put<T: FixedWidthInteger>(_ v: T) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { w.append(contentsOf: $0) }
        }

        // RIFF header
        w.append(contentsOf: [0x52, 0x49, 0x46, 0x46])    // "RIFF"
        put(UInt32(36 + pcm.count))                         // file size - 8
        w.append(contentsOf: [0x57, 0x41, 0x56, 0x45])    // "WAVE"

        // fmt sub-chunk
        w.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])    // "fmt "
        put(UInt32(16))                                     // sub-chunk size
        put(UInt16(1))                                      // PCM format
        put(UInt16(1))                                      // mono
        put(sampleRate)                                     // sample rate
        put(sampleRate * 2)                                 // byte rate (mono 16-bit)
        put(UInt16(2))                                      // block align
        put(UInt16(16))                                     // bits per sample

        // data sub-chunk
        w.append(contentsOf: [0x64, 0x61, 0x74, 0x61])    // "data"
        put(UInt32(pcm.count))
        w.append(pcm)

        return w
    }
}
