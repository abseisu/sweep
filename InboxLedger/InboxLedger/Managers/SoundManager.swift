// SoundManager.swift
// Ledger
//
// Synthesized sounds that match the app's calm, editorial ethos.
// All buffers are pre-generated at init. Playback is instant with zero main-thread work.
// To swap in recorded samples later, load .caf files into the buffers dict instead.

import Foundation
import AVFoundation
import UIKit
import UserNotifications

final class SoundManager {
    static let shared = SoundManager()

    /// Whether sounds are enabled (user preference)
    var soundsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ledger_sounds_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ledger_sounds_enabled") }
    }

    /// Whether haptics are enabled alongside sounds
    var hapticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ledger_haptics_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ledger_haptics_enabled") }
    }

    // MARK: - Sound Types

    enum Sound: CaseIterable {
        case dismiss        // Soft paper-slide
        case send           // Gentle seal chime
        case snooze         // Wooden "tok"
        case notification   // Warm marimba chime
        case tap            // Light tap
        case undoSend       // Gentle reverse chime
    }

    // MARK: - Audio Engine (persistent, started once)

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let sampleRate: Double = 44100
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    /// Pre-generated PCM buffers for each sound — created once at init
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]

    /// Serial queue for all audio operations — never touches main thread
    private let audioQueue = DispatchQueue(label: "com.ledger.sound", qos: .userInteractive)

    private var engineReady = false

    // MARK: - Init

    private init() {
        // Pre-generate all sound buffers (fast — just math, no I/O)
        for sound in Sound.allCases {
            buffers[sound] = generateBuffer(for: sound)
        }

        // Set up persistent engine on audio queue
        audioQueue.async { [weak self] in
            self?.setupEngine()
        }
    }

    private func setupEngine() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)

            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            try engine.start()
            engineReady = true
        } catch {
            print("⚠️ SoundManager engine setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Play (zero-latency)

    func play(_ sound: Sound) {
        // Haptics on main thread (UIKit requirement) — this is instant
        if hapticsEnabled {
            playHaptic(for: sound)
        }

        guard soundsEnabled else { return }
        guard let buffer = buffers[sound] else { return }

        // Schedule buffer on audio queue — never blocks main thread
        audioQueue.async { [weak self] in
            guard let self = self, self.engineReady else { return }

            // Restart engine if it stopped (e.g. after audio interruption)
            if !self.engine.isRunning {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try self.engine.start()
                } catch {
                    print("⚠️ SoundManager engine restart failed: \(error.localizedDescription)")
                    return
                }
            }

            // Stop any currently playing sound, schedule new one
            self.playerNode.stop()
            self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
            self.playerNode.play()
        }
    }

    // MARK: - Haptic Feedback

    private func playHaptic(for sound: Sound) {
        switch sound {
        case .dismiss:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .send:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .snooze:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .notification:
            break
        case .tap:
            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
        case .undoSend:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    // MARK: - Buffer Generation (runs once at init)

    private func generateBuffer(for sound: Sound) -> AVAudioPCMBuffer? {
        let params = toneParams(for: sound)
        let frameCount = Int(sampleRate * params.duration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let samples = buffer.floatChannelData?[0] else { return nil }

        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let normalizedT = t / params.duration
            let envelope = params.envelope(normalizedT)

            var sample: Double = 0
            for (harmonic, amplitude) in params.harmonics {
                sample += sin(2 * .pi * params.frequency * harmonic * t) * amplitude
            }
            samples[i] = Float(sample * envelope * params.volume)
        }

        return buffer
    }

    // MARK: - Tone Parameters

    private struct ToneParams {
        let frequency: Double
        let harmonics: [(Double, Double)]
        let duration: Double
        let volume: Double
        let envelope: (Double) -> Double
    }

    private func toneParams(for sound: Sound) -> ToneParams {
        switch sound {

        case .dismiss:
            // Soft paper slide: low-mid tone, fast fade, slight detuning for texture
            return ToneParams(
                frequency: 280,
                harmonics: [(1.0, 0.6), (2.0, 0.15), (1.01, 0.3)],
                duration: 0.18,
                volume: 0.12,
                envelope: { t in min(t / 0.02, 1.0) * exp(-t * 8) }
            )

        case .send:
            // Envelope seal: rising two-note chime, warm and satisfying
            return ToneParams(
                frequency: 523,
                harmonics: [(1.0, 0.5), (1.5, 0.35), (2.0, 0.12), (0.5, 0.08)],
                duration: 0.35,
                volume: 0.15,
                envelope: { t in min(t / 0.015, 1.0) * exp(-t * 4) }
            )

        case .snooze:
            // Wooden "tok": short, percussive, mid-low pitch
            return ToneParams(
                frequency: 196,
                harmonics: [(1.0, 0.7), (2.3, 0.2), (4.1, 0.08)],
                duration: 0.12,
                volume: 0.14,
                envelope: { t in min(t / 0.005, 1.0) * exp(-t * 18) }
            )

        case .notification:
            // Warm marimba chime: two-note, gentle, warm
            return ToneParams(
                frequency: 392,
                harmonics: [(1.0, 0.5), (1.335, 0.4), (2.0, 0.1), (0.5, 0.06)],
                duration: 0.6,
                volume: 0.18,
                envelope: { t in min(t / 0.008, 1.0) * exp(-t * 3.5) }
            )

        case .tap:
            // Light tactile tap: very short, neutral
            return ToneParams(
                frequency: 440,
                harmonics: [(1.0, 0.4), (2.0, 0.1)],
                duration: 0.06,
                volume: 0.06,
                envelope: { t in min(t / 0.003, 1.0) * exp(-t * 30) }
            )

        case .undoSend:
            // Gentle reverse chime: descending feel
            return ToneParams(
                frequency: 440,
                harmonics: [(1.0, 0.5), (1.5, 0.2), (0.75, 0.15)],
                duration: 0.25,
                volume: 0.12,
                envelope: { t in min(t / 0.01, 1.0) * exp(-t * 6) }
            )
        }
    }

    // MARK: - Notification Sound File

    /// Generates a .caf file for use as a custom push notification sound.
    /// Call once (e.g. on first launch). File goes to Library/Sounds/ for UNNotificationSound.
    func generateNotificationSoundFile() {
        let soundsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sounds")
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)

        let filePath = soundsDir.appendingPathComponent("ledger_chime.caf")
        if FileManager.default.fileExists(atPath: filePath.path) { return }

        guard let buffer = buffers[.notification] else { return }

        do {
            let audioFile = try AVAudioFile(forWriting: filePath, settings: format.settings)
            try audioFile.write(from: buffer)
            print("🔔 Notification sound generated at \(filePath.path)")
        } catch {
            print("⚠️ Failed to generate notification sound: \(error.localizedDescription)")
        }
    }

    /// The UNNotificationSound pointing to our custom chime
    static var notificationSound: UNNotificationSound {
        UNNotificationSound(named: UNNotificationSoundName("ledger_chime.caf"))
    }
}
