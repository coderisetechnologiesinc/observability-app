import ShazamKit
import AVFAudio

struct CircularBuffer<T> {
    private var buffer: [T?]
    private var head = 0
    private var count = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = Array<T?>(repeating: nil, count: capacity)
    }

    mutating func append(_ element: T) {
        buffer[head] = element
        head = (head + 1) % capacity
        if count < capacity {
            count += 1
        }
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }
}

@MainActor
class AudioMatcher: NSObject, ObservableObject, SHSessionDelegate {
    private let audioQueue = DispatchQueue(label: "audio.processing", qos: .userInteractive)
    private let calculationQueue = DispatchQueue(label: "sync.calculations", qos: .userInteractive)
    private var session: SHSession?
    private let audioEngine = AVAudioEngine()
    private var catalogManager = ShazamCatalogManager()
    private var sessionStartTime: Date?

    private var listeningStartTime: Date?
    private var matchFoundTime: Date?
    private var restartTimer: Timer?
    @Published var isListening = false
    @Published var isCurrentlyListening: Bool = false
    @Published var matchCount: Int = 0
    @Published var pauseCountdown: Int = 0
    private var hasFoundMatchThisSession: Bool = false
    @Published var isCycleEnabled: Bool = false

    private var firstListeningStartTime: Date?
    private var firstMatchFoundTime: Date?
    @Published var startToFirstMatchSeconds: Double = 0.0
    @Published var matchToSeekLatencyMs: Double = 0.0
    @Published var currentPlayerTimeAtMatch: Double = 0.0

    private var bufferProcessingStartTime: Date?
    @Published var measuredProcessingDelayMs: Double = 0.0
    @Published var inputBufferDelayMs: Double = 0.0
    @Published var playerSeekDelayMs: Double = 0.0
    @Published var audioOutputLatencyMs: Double = 0.0
    @Published var audioInputLatencyMs: Double = 0.0

    @Published var consoleLog: String = "System ready\n"
    private var logBuffer: [String] = []
    private let maxLogEntries = 100
    @Published var matchTime: Double = 0.0
    @Published var matchHistory: [Double] = []
    @Published var isPerformanceGood: Bool = true

    private var currentMatchStartTime: UInt64 = 0
    private var matchToSeekTimes = CircularBuffer<Double>(capacity: 20)
    @Published var matchToSeekTime: Double = 0.0

    var getCurrentPlayerTime: (() -> Double)?
    var seekWithTimestamp: ((Double, UInt64) -> Void)?

    var formattedMatchTime: String {
        let hours = Int(matchTime) / 3600
        let minutes = Int(matchTime) % 3600 / 60
        let seconds = Int(matchTime) % 60
        let milliseconds = Int((matchTime.truncatingRemainder(dividingBy: 1)) * 1000)

        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        } else if minutes > 0 {
            return String(format: "%d:%02d.%03d", minutes, seconds, milliseconds)
        } else {
            return String(format: "%.3fs", matchTime)
        }
    }
    
    func prepare() async {
        log("Preparing catalog...")

        do {
            try await catalogManager.loadCatalog()
            log("Catalog prepared successfully")
        } catch {
            log("Catalog error: \(error.localizedDescription)")
        }
    }

    func clearLog() {
        consoleLog = "System ready\n"
    }
    
    func startListening() async {
        guard !isListening else { return }

        isListening = true
        sessionStartTime = Date()
        matchCount = 0
        hasFoundMatchThisSession = false
        listeningStartTime = Date()
        isCurrentlyListening = true

        if firstListeningStartTime == nil {
            firstListeningStartTime = Date()
            log("ECHO DEBUG: First listening session started at \(timestamp())")
        }

        await startSingleListeningSession()
        log("Continuous cycle started - waiting for first offset...")
    }
    
    private func startSingleListeningSession() async {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)

            // Measure device audio latencies
            let outputLatency = audioSession.outputLatency
            let inputLatency = audioSession.inputLatency
            audioOutputLatencyMs = outputLatency * 1000
            audioInputLatencyMs = inputLatency * 1000
            log("DEVICE LATENCIES: Input \(String(format: "%.1f", audioInputLatencyMs))ms, Output \(String(format: "%.1f", audioOutputLatencyMs))ms")

            let catalog = catalogManager.getCatalog()
            session = SHSession(catalog: catalog)
            session?.delegate = self

            audioEngine.stop()
            audioEngine.reset()

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format,
                block: { [weak self] buffer, time in
                    self?.processAudioBuffer(buffer, at: time)
                }
            )

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            log("Single session start error: \(error.localizedDescription)")
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard let audioTime = time, !hasFoundMatchThisSession else { return }

        audioQueue.async { [weak self] in
            guard let self = self else { return }

            _ = mach_absolute_time() // Processing start timestamp

            // Pre-calculate timing values
            let audioTimestamp = audioTime.audioTimeStamp
            let currentSystemTime = mach_absolute_time()
            let inputBufferDelay = Double(currentSystemTime - audioTimestamp.mHostTime) / 1_000_000_000.0

            Task { @MainActor in
                self.bufferProcessingStartTime = Date()
                self.inputBufferDelayMs = inputBufferDelay * 1000
            }

            self.session?.matchStreamingBuffer(buffer, at: audioTime)
        }
    }
    
    func stopListening() async {
        guard isListening else { return }

        restartTimer?.invalidate()
        restartTimer = nil
        isListening = false
        isCurrentlyListening = false
        pauseCountdown = 0

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        session = nil

        consoleLog += "[\(timestamp())] Continuous cycle stopped\n"

        log("Session Summary:")
        log("   Total matches found: \(matchCount)")
        log("   Continuous cycle approach")
        log("   80ms threshold active")
    }
    
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        _ = mach_absolute_time() // Match found timestamp

        Task { @MainActor in
            guard let matchedItem = match.mediaItems.first else { return }

            let referenceMatchTime = matchedItem.matchOffset
            let syncStartTime = mach_absolute_time()

            // Calculate processing delay using high-precision timing
            var measuredProcessingDelay = 0.0008 // 0.8ms default
            if let bufferStart = self.bufferProcessingStartTime {
                let currentTime = Date()
                measuredProcessingDelay = currentTime.timeIntervalSince(bufferStart)
            }

            self.matchFoundTime = Date()
            self.measuredProcessingDelayMs = measuredProcessingDelay * 1000
            self.log("PROCESSING DELAY: \(String(format: "%.1f", self.measuredProcessingDelayMs))ms")
            self.log("INPUT BUFFER DELAY: \(String(format: "%.1f", self.inputBufferDelayMs))ms")

            if self.firstMatchFoundTime == nil {
                self.firstMatchFoundTime = Date()
                if let firstStart = self.firstListeningStartTime {
                    self.startToFirstMatchSeconds = Date().timeIntervalSince(firstStart)
                    self.log("ECHO DEBUG: Start-to-first-match: \(String(format: "%.3f", self.startToFirstMatchSeconds))s")
                }
            }

            self.currentMatchStartTime = mach_absolute_time()


            guard let startTime = self.listeningStartTime else {
                self.log("ERROR: No listening start time available")
                return
            }

            let timeElapsed = Date().timeIntervalSince(startTime)
            let currentPlayerTime = self.getCurrentPlayerTime?() ?? 0.0

            // Calculate sync on background queue
            let syncResult = await withCheckedContinuation { continuation in
                calculationQueue.async {
                    let inputBufferDelaySeconds = self.inputBufferDelayMs / 1000.0
                    let playerSeekDelaySeconds = self.playerSeekDelayMs / 1000.0
                    let deviceLatencySeconds = (self.audioInputLatencyMs + self.audioOutputLatencyMs) / 1000.0

                    // Dynamic buffer based on processing speed
                    let dynamicBuffer = max(0.001, measuredProcessingDelay * 0.1)

                    let currentTheaterTime = referenceMatchTime + timeElapsed +
                                           measuredProcessingDelay + inputBufferDelaySeconds +
                                           playerSeekDelaySeconds + deviceLatencySeconds + dynamicBuffer + 0.1

                    let timeDifference = abs(currentPlayerTime - currentTheaterTime)
                    let shouldSeek = timeDifference > 0.08

                    continuation.resume(returning: (shouldSeek: shouldSeek, targetTime: currentTheaterTime, timeDifference: timeDifference))
                }
            }

            let currentTheaterTime = syncResult.targetTime

            if self.isCycleEnabled {
                await self.stopCurrentListeningSession()
            } else {
                self.isListening = false
                self.isCurrentlyListening = false
                self.pauseCountdown = 0

                self.audioEngine.stop()
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.session = nil
            }

            self.log("SINGLE-MATCH CALCULATION:")
            self.log("   Match found at: \(String(format: "%.3f", referenceMatchTime))s in reference")
            self.log("   Time since start: \(String(format: "%.3f", timeElapsed))s")
            self.log("   Measured processing delay: \(String(format: "%.3f", measuredProcessingDelay))s")
            self.log("   Current theater time: \(String(format: "%.3f", currentTheaterTime))s")
            self.log("   Single-match approach with measured processing compensation")
            if self.isCycleEnabled {
                self.log("   Cycle enabled - restarting in 5 seconds")
            } else {
                self.log("   Session paused automatically after match")
            }

            self.hasFoundMatchThisSession = true
            self.matchCount += 1

            self.log("SYNC VALIDATION:")
            self.log("   Theater calculated at: \(String(format: "%.3f", currentTheaterTime))s")
            self.log("   Player currently at: \(String(format: "%.3f", currentPlayerTime))s")
            self.log("   Difference: \(String(format: "%.0f", syncResult.timeDifference * 1000))ms")

            if !syncResult.shouldSeek {
                self.log("   ALREADY IN SYNC: Difference \(String(format: "%.0f", syncResult.timeDifference * 1000))ms ≤ 80ms")
                self.log("   Skipping player adjustment - maintaining current position")

                self.matchHistory.append(currentTheaterTime)
                self.matchTime = 0.0
            } else {
                self.log("   NEEDS SYNC: Difference \(String(format: "%.0f", syncResult.timeDifference * 1000))ms > 80ms")
                self.log("   Triggering player seek to theater position")

                let seekStartTime = mach_absolute_time()
                if let seekWithTimestamp = self.seekWithTimestamp {
                    seekWithTimestamp(currentTheaterTime, seekStartTime)
                }

                self.matchTime = currentTheaterTime
                self.matchHistory.append(currentTheaterTime)
            }

            let syncLogEntry = "[\(timestamp())] SINGLE-MATCH SYNC\nTitle: \(matchedItem.title ?? "Unknown")\nMatch #\(self.matchCount) • Elapsed: \(String(format: "%.1f", timeElapsed))s\nTheater NOW: \(String(format: "%.3f", currentTheaterTime))s\n"

            logBuffer.append(syncLogEntry)
            if logBuffer.count > maxLogEntries {
                logBuffer.removeFirst(logBuffer.count - maxLogEntries)
            }
            consoleLog = logBuffer.joined()
        }
    }
    
    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        Task { @MainActor in
            consoleLog += "[\(timestamp())] No match: \(error?.localizedDescription ?? "Unknown error")\n"
        }
    }

    private func stopCurrentListeningSession() async {
        hasFoundMatchThisSession = true
        isCurrentlyListening = false
        pauseCountdown = 5

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        session = nil

        log("Match found - pausing 5 seconds before next cycle")

        self.restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.handlePauseCountdown()
            }
        }
    }

    private func handlePauseCountdown() async {
        pauseCountdown -= 1

        if pauseCountdown <= 0 {
            restartTimer?.invalidate()
            restartTimer = nil

            if isListening {
                log("5-second pause complete - restarting listening...")
                hasFoundMatchThisSession = false
                listeningStartTime = Date()
                isCurrentlyListening = true
                await startSingleListeningSession()
            }
        }
    }

    func recordPlayerSeekDelay(seekStartTime: UInt64, seekCompletionTime: UInt64) {
        Task { @MainActor in
            let seekDelaySeconds = Double(seekCompletionTime - seekStartTime) / 1_000_000_000.0
            self.playerSeekDelayMs = seekDelaySeconds * 1000
            self.log("PLAYER SEEK DELAY: \(String(format: "%.1f", self.playerSeekDelayMs))ms")
        }
    }

    func trackSeekCommand(startTime: UInt64, currentPlayerTime: Double) {
        Task { @MainActor in
            if self.currentMatchStartTime > 0 {
                guard startTime >= self.currentMatchStartTime else {
                    self.log("Timing anomaly: seek command before match")
                    return
                }

                let matchToSeekDuration = Double(startTime - self.currentMatchStartTime) / 1_000_000_000.0

                guard matchToSeekDuration < 20.0 else {
                    self.log(" Unreasonable match-to-seek time: \(String(format: "%.1f", matchToSeekDuration * 1000))ms")
                    return
                }

                self.matchToSeekTimes.append(matchToSeekDuration)

                self.matchToSeekTime = matchToSeekDuration
                self.matchToSeekLatencyMs = matchToSeekDuration * 1000
                self.currentPlayerTimeAtMatch = currentPlayerTime

                self.log("ECHO DEBUG - SEEK COMMAND:")
                self.log("   Match to Seek latency: \(String(format: "%.1f", matchToSeekDuration * 1000))ms")
                self.log("   Player time when match found: \(String(format: "%.3f", currentPlayerTime))s")
                self.log("   Time difference analysis:")
                self.log("     - Start-to-first-match: \(String(format: "%.3f", self.startToFirstMatchSeconds))s")
                self.log("     - Match-to-seek latency: \(String(format: "%.1f", self.matchToSeekLatencyMs))ms")
            }
        }
    }
    
    func trackSeekCompletion(completionTime: UInt64) {
        Task { @MainActor in
            if self.currentMatchStartTime > 0 {
                let totalDuration = Double(completionTime - self.currentMatchStartTime) / 1_000_000_000.0

                self.isPerformanceGood = totalDuration < 0.08

                self.log("SEEK COMPLETED - Final Timing:")
                self.log("   Total end-to-end: \(String(format: "%.1f", totalDuration * 1000))ms")

                if totalDuration > 0.1 {
                    self.log("   ACCESSIBILITY ALERT: Total time > 100ms!")
                } else if totalDuration > 0.08 {
                    self.log("   MODERATE: Total time 80-100ms")
                } else {
                    self.log("   EXCELLENT: Total time < 80ms")
                }

                self.currentMatchStartTime = 0
            }
        }
    }

    func shouldPerformSeek(targetTime: Double, currentPlayerTime: Double) -> Bool {
        let timeDifference = abs(currentPlayerTime - targetTime)
        return timeDifference > 0.08
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }

    private func log(_ message: String) {
        let timestampedMessage = "[\(timestamp())] \(message)\n"

        logBuffer.append(timestampedMessage)
        if logBuffer.count > maxLogEntries {
            logBuffer.removeFirst(logBuffer.count - maxLogEntries)
        }

        consoleLog = logBuffer.joined()
        print("[DEBUG] \(message)")
    }
}
