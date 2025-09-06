import ShazamKit
import AVFAudio

class AudioMatcher: NSObject, ObservableObject, SHSessionDelegate {
    // MARK: - Properties
    private var session: SHSession?
    private let audioEngine = AVAudioEngine()
    private var catalogManager = ShazamCatalogManager()
    private var sessionStartTime: Date?
    
    // CONTINUOUS CYCLE: Listen → Match → Pause 5s → Repeat
    private var listeningStartTime: Date?
    private var matchFoundTime: Date?
    private var restartTimer: Timer?
    @MainActor @Published var isListening = false
    @MainActor @Published var isCurrentlyListening: Bool = false
    @MainActor @Published var matchCount: Int = 0
    @MainActor @Published var pauseCountdown: Int = 0
    private var hasFoundMatchThisSession: Bool = false
    
    // UI Properties
    @MainActor @Published var consoleLog: String = "System ready\n"
    @MainActor @Published var matchTime: Double = 0.0
    @MainActor @Published var matchHistory: [Double] = []
    @MainActor @Published var isPerformanceGood: Bool = true
    
    // Timing tracking for UI
    private var currentMatchStartTime: UInt64 = 0
    private var matchToSeekTimes: [Double] = []
    @MainActor @Published var matchToSeekTime: Double = 0.0
    
    // Computed property for formatted time display
    @MainActor var formattedMatchTime: String {
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
    
    // MARK: - Public Methods
    func prepare() async {
        await log("Preparing catalog...")
        
        do {
            try await catalogManager.loadCatalog()
            await log("Catalog prepared successfully")
        } catch {
            await log("Catalog error: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    func clearLog() {
        consoleLog = "System ready\n"
    }
    
    func startListening() async {
        guard !(await isListening) else { return }
        
        await MainActor.run {
            isListening = true
            sessionStartTime = Date()
            matchCount = 0
            hasFoundMatchThisSession = false
            listeningStartTime = Date()
            isCurrentlyListening = true
        }
        
        // Start single listening session
        await startSingleListeningSession()
        await log("Continuous cycle started - waiting for first offset...")
    }
    
    // SINGLE-MATCH SESSION: Listen until we get one match
    private func startSingleListeningSession() async {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record)
            try audioSession.setActive(true)
            
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
                    // Only process if we haven't found a match yet
                    if self?.hasFoundMatchThisSession == false {
                        self?.processAudioBuffer(buffer, at: time)
                    }
                }
            )
            
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            await log("Single session start error: \(error.localizedDescription)")
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard let audioTime = time else { return }
        
        // Send to Shazam for processing
        session?.matchStreamingBuffer(buffer, at: audioTime)
    }
    
    func stopListening() async {
        guard await isListening else { return }
        
        // Stop all timers  
        await MainActor.run {
            restartTimer?.invalidate()
            restartTimer = nil
            isListening = false
            isCurrentlyListening = false
            pauseCountdown = 0
        }
        
        // Actually stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            await log("Audio session stop error: \(error.localizedDescription)")
        }
        
        await MainActor.run {
            consoleLog += "[\(timestamp())] Continuous cycle stopped\n"
            
            log("📈 Session Summary:")
            log("   Total matches found: \(matchCount)")
            log("   Continuous cycle approach")
            log("   80ms threshold active")
        }
    }
    
    // MARK: - Shazam Delegates - Simplified for Single-Match Approach
    func session(_ session: SHSession, didFind match: SHMatch) {
        Task { @MainActor in
            guard let matchedItem = match.mediaItems.first else { return }
            
            // Get the match offset from reference audio
            let referenceMatchTime = matchedItem.matchOffset
            
            // Set match start time for seek tracking
            self.currentMatchStartTime = mach_absolute_time()
            
            // SINGLE-MATCH APPROACH: Simple, accurate calculation
            guard let startTime = self.listeningStartTime else {
                self.log("❌ No listening start time available")
                return
            }
            
            // Record when match was found
            let matchTime = Date()
            self.matchFoundTime = matchTime
            
            // Calculate theater time: match offset + time elapsed since listening started  
            let timeElapsed = matchTime.timeIntervalSince(startTime)
            let currentTheaterTime = referenceMatchTime + timeElapsed
            
            // STOP listening immediately to prevent duplicate matches
            await self.stopCurrentListeningSession()
            
            self.log("🎯 SINGLE-MATCH CALCULATION:")
            self.log("   Match found at: \(String(format: "%.3f", referenceMatchTime))s in reference")
            self.log("   Time since start: \(String(format: "%.3f", timeElapsed))s")
            self.log("   🎬 Current theater time: \(String(format: "%.3f", currentTheaterTime))s")
            self.log("   📝 Single-match approach: Simple and accurate")
            self.log("   ⏹️ Stopping listening to prevent duplicates")
            
            // Mark session as complete
            self.hasFoundMatchThisSession = true
            self.matchCount += 1
            
            // Send the theater time for sync (will be checked for 80ms threshold)
            self.matchTime = currentTheaterTime
            self.matchHistory.append(currentTheaterTime)
            
            consoleLog += """
            [\(timestamp())] SINGLE-MATCH SYNC
            Title: \(matchedItem.title ?? "Unknown")
            Match #\(self.matchCount) • Elapsed: \(String(format: "%.1f", timeElapsed))s
            Theater NOW: \(String(format: "%.3f", currentTheaterTime))s
            \n
            """
        }
    }
    
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        Task { @MainActor in
            consoleLog += "[\(timestamp())] No match: \(error?.localizedDescription ?? "Unknown error")\n"
        }
    }
    
    // CONTINUOUS CYCLE: Stop listening and start 5-second pause timer
    private func stopCurrentListeningSession() async {
        await MainActor.run {
            hasFoundMatchThisSession = true
            isCurrentlyListening = false
            pauseCountdown = 5
        }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            await log("Session stop error: \(error.localizedDescription)")
        }
        
        await log("✅ Match found - pausing 5 seconds before next cycle")
        
        // Start 5-second restart timer
        await MainActor.run {
            self.restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.handlePauseCountdown()
                }
            }
        }
    }
    
    @MainActor
    private func handlePauseCountdown() async {
        pauseCountdown -= 1
        
        if pauseCountdown <= 0 {
            // Stop the timer
            restartTimer?.invalidate()
            restartTimer = nil
            
            // Restart listening if still in overall listening mode
            if isListening {
                await log("🔄 5-second pause complete - restarting listening...")
                hasFoundMatchThisSession = false
                listeningStartTime = Date()
                isCurrentlyListening = true
                await startSingleListeningSession()
            }
        }
    }
    
    // Track seek command timing
    func trackSeekCommand(startTime: UInt64) {
        Task { @MainActor in
            if self.currentMatchStartTime > 0 {
                guard startTime >= self.currentMatchStartTime else {
                    self.log("⚠️ Timing anomaly: seek command before match")
                    return
                }
                
                let matchToSeekDuration = Double(startTime - self.currentMatchStartTime) / 1_000_000_000.0
                
                guard matchToSeekDuration < 20.0 else {
                    self.log("⚠️ Unreasonable match-to-seek time: \(String(format: "%.1f", matchToSeekDuration * 1000))ms")
                    return
                }
                
                self.matchToSeekTimes.append(matchToSeekDuration)
                if self.matchToSeekTimes.count > 20 {
                    self.matchToSeekTimes.removeFirst()
                }
                
                self.matchToSeekTime = matchToSeekDuration
                
                self.log("🎮 SEEK COMMAND ISSUED:")
                self.log("   Match→Seek latency: \(String(format: "%.1f", matchToSeekDuration * 1000))ms")
            }
        }
    }
    
    func trackSeekCompletion(completionTime: UInt64) {
        Task { @MainActor in
            if self.currentMatchStartTime > 0 {
                let totalDuration = Double(completionTime - self.currentMatchStartTime) / 1_000_000_000.0
                
                self.isPerformanceGood = totalDuration < 0.1 // < 100ms for accessibility
                
                self.log("🏁 SEEK COMPLETED - Final Timing:")
                self.log("   Total end-to-end: \(String(format: "%.1f", totalDuration * 1000))ms")
                
                if totalDuration > 0.1 {
                    self.log("   🚨 ACCESSIBILITY ALERT: Total time > 100ms!")
                } else if totalDuration > 0.05 {
                    self.log("   ⚠️ MODERATE: Total time 50-100ms")
                } else {
                    self.log("   ✅ EXCELLENT: Total time < 50ms")
                }
                
                // Reset for next match
                self.currentMatchStartTime = 0
            }
        }
    }
    
    // Smart seek optimization - checks if seek is necessary (NO LOOK-AHEAD)
    @MainActor func shouldPerformSeek(targetTime: Double, currentPlayerTime: Double) -> Bool {
        let timeDifference = abs(currentPlayerTime - targetTime)
        
        if timeDifference <= 0.08 { // 80ms threshold
            self.log("🎯 SMART SKIP: Player at \(String(format: "%.2f", currentPlayerTime))s, target \(String(format: "%.2f", targetTime))s")
            self.log("   Difference: \(String(format: "%.0f", timeDifference * 1000))ms ≤ 80ms threshold")
        } else {
            self.log("🎯 PRECISE SEEK:")
            self.log("   Player current: \(String(format: "%.3f", currentPlayerTime))s")
            self.log("   Target: \(String(format: "%.3f", targetTime))s")
            self.log("   Difference: \(String(format: "%.0f", timeDifference * 1000))ms")
        }
        
        return timeDifference > 0.08
    }
    
    // MARK: - Private Helpers
    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }
    
    @MainActor
    private func log(_ message: String) {
        consoleLog += "[\(timestamp())] \(message)\n"
        print("[DEBUG] \(message)")
    }
}
