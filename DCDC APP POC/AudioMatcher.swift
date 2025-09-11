import ShazamKit // Apple's audio recognition framework
import AVFAudio // Audio engine and session management

// Main class that handles audio matching using Shazam technology
class AudioMatcher: NSObject, ObservableObject, SHSessionDelegate {
    // MARK: - Properties
    private var session: SHSession? // Shazam session for audio matching
    private let audioEngine = AVAudioEngine() // Audio input engine
    private var catalogManager = ShazamCatalogManager() // Manages reference audio signatures
    private var sessionStartTime: Date? // When overall session started
    
    // CONTINUOUS CYCLE: Listen → Match → Pause 5s → Repeat
    private var listeningStartTime: Date? // When current listening cycle started
    private var matchFoundTime: Date? // When last match was found
    private var restartTimer: Timer? // Timer for 5-second pause between cycles
    @MainActor @Published var isListening = false // Overall listening state (UI binding)
    @MainActor @Published var isCurrentlyListening: Bool = false // Currently recording audio
    @MainActor @Published var matchCount: Int = 0 // Total matches found
    @MainActor @Published var pauseCountdown: Int = 0 // Seconds left in pause
    private var hasFoundMatchThisSession: Bool = false // Prevents duplicate matches
    @MainActor @Published var isCycleEnabled: Bool = false // Auto-restart after match
    
    // ECHO DEBUGGING: Precise timing measurements
    private var firstListeningStartTime: Date? // Very first time listening started
    private var firstMatchFoundTime: Date? // When first match ever was found
    @MainActor @Published var startToFirstMatchSeconds: Double = 0.0 // Time to first match
    @MainActor @Published var matchToSeekLatencyMs: Double = 0.0 // Match-to-seek delay
    @MainActor @Published var currentPlayerTimeAtMatch: Double = 0.0 // Player position at match
    
    // Processing delay measurement
    private var bufferProcessingStartTime: Date? // When we sent buffer to Shazam
    @MainActor @Published var measuredProcessingDelayMs: Double = 0.0 // Shazam processing time
    
    
    // UI Properties
    @MainActor @Published var consoleLog: String = "System ready\n" // Debug console output
    @MainActor @Published var matchTime: Double = 0.0 // Theater time to sync to
    @MainActor @Published var matchHistory: [Double] = [] // All match timestamps
    @MainActor @Published var isPerformanceGood: Bool = true // Performance indicator
    
    // Timing tracking for UI
    private var currentMatchStartTime: UInt64 = 0 // High-precision match timestamp
    private var matchToSeekTimes: [Double] = [] // History of seek latencies
    @MainActor @Published var matchToSeekTime: Double = 0.0 // Current seek latency
    
    // Player sync validation callback
    var getCurrentPlayerTime: (() -> Double)? // Gets current audio player position
    
    // Computed property for formatted time display
    @MainActor var formattedMatchTime: String {
        let hours = Int(matchTime) / 3600 // Extract hours
        let minutes = Int(matchTime) % 3600 / 60 // Extract minutes
        let seconds = Int(matchTime) % 60 // Extract seconds
        let milliseconds = Int((matchTime.truncatingRemainder(dividingBy: 1)) * 1000) // Extract ms
        
        if hours > 0 { // Format as H:MM:SS.mmm
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        } else if minutes > 0 { // Format as M:SS.mmm
            return String(format: "%d:%02d.%03d", minutes, seconds, milliseconds)
        } else { // Format as S.sss
            return String(format: "%.3fs", matchTime)
        }
    }
    
    // MARK: - Public Methods
    func prepare() async {
        await log("Preparing catalog...") // Log start of preparation
        
        do {
            try await catalogManager.loadCatalog() // Load reference audio signature
            await log("Catalog prepared successfully") // Success message
        } catch {
            await log("Catalog error: \(error.localizedDescription)") // Error handling
        }
    }
    
    @MainActor
    func clearLog() {
        consoleLog = "System ready\n" // Reset console to initial state
    }
    
    func startListening() async {
        guard !(await isListening) else { return } // Exit if already listening
        
        await MainActor.run {
            isListening = true // Set overall listening state
            sessionStartTime = Date() // Record session start
            matchCount = 0 // Reset match counter
            hasFoundMatchThisSession = false // Allow new matches
            listeningStartTime = Date() // Record listening cycle start
            isCurrentlyListening = true // Set active listening state
            
            // ECHO DEBUGGING: Record first listening start time
            if firstListeningStartTime == nil { // Only for very first session
                firstListeningStartTime = Date() // Record for timing analysis
                log("ECHO DEBUG: First listening session started at \(timestamp())") // Debug log
            }
        }
        
        // Start single listening session
        await startSingleListeningSession() // Begin audio capture
        await log("Continuous cycle started - waiting for first offset...") // Status update
    }
    
    // SINGLE-MATCH SESSION: Listen until we get one match
    private func startSingleListeningSession() async {
        do {
            let audioSession = AVAudioSession.sharedInstance() // Get shared audio session
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth]) // Allow recording + playback
            try audioSession.setActive(true) // Activate audio session
            
            let catalog = catalogManager.getCatalog() // Get reference audio signatures
            session = SHSession(catalog: catalog) // Create new Shazam session
            session?.delegate = self // Set this class as delegate for callbacks
            
            audioEngine.stop() // Stop any previous audio engine
            audioEngine.reset() // Reset engine state
            
            let inputNode = audioEngine.inputNode // Get microphone input
            let format = inputNode.outputFormat(forBus: 0) // Get audio format
            
            inputNode.removeTap(onBus: 0) // Remove any existing audio tap
            inputNode.installTap( // Install new audio capture
                onBus: 0, // Input bus
                bufferSize: 1024, // Buffer size in frames
                format: format, // Audio format
                block: { [weak self] buffer, time in // Audio callback
                    // Only process if we haven't found a match yet
                    if self?.hasFoundMatchThisSession == false { // Prevent processing after match
                        self?.processAudioBuffer(buffer, at: time) // Send to Shazam
                    }
                }
            )
            
            audioEngine.prepare() // Prepare audio engine
            try audioEngine.start() // Start capturing audio
        } catch {
            await log("Single session start error: \(error.localizedDescription)") // Log any errors
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        guard let audioTime = time else { return } // Exit if no timestamp
        
        // Record when we start sending buffer to Shazam for processing delay measurement
        bufferProcessingStartTime = Date() // Mark start of Shazam processing
        
        // Send to Shazam for processing
        session?.matchStreamingBuffer(buffer, at: audioTime) // Submit audio for matching
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
        
        // Reset session to clear buffer accumulation
        session = nil
        
        // Keep audio session active for continuous operation
        // Don't deactivate to avoid interrupting playback
        
        await MainActor.run {
            consoleLog += "[\(timestamp())] Continuous cycle stopped\n"
            
            log("Session Summary:")
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
            
            // ECHO DEBUGGING: Record match found time and calculate delays
            let matchTime = Date()
            self.matchFoundTime = matchTime
            
            // Measure processing delay from buffer processing start to match callback
            var measuredProcessingDelay = 0.8 // Default fallback
            if let bufferStart = self.bufferProcessingStartTime {
                measuredProcessingDelay = matchTime.timeIntervalSince(bufferStart)
                self.measuredProcessingDelayMs = measuredProcessingDelay * 1000
                self.log("PROCESSING DELAY: \(String(format: "%.1f", self.measuredProcessingDelayMs))ms")
            }
            
            // Calculate start-to-first-match delay (only for first match)
            if self.firstMatchFoundTime == nil {
                self.firstMatchFoundTime = matchTime
                if let firstStart = self.firstListeningStartTime {
                    self.startToFirstMatchSeconds = matchTime.timeIntervalSince(firstStart)
                    self.log("ECHO DEBUG: Start-to-first-match: \(String(format: "%.3f", self.startToFirstMatchSeconds))s")
                }
            }
            
            // Set match start time for seek tracking
            self.currentMatchStartTime = mach_absolute_time()
            
            // SINGLE-MATCH APPROACH: Simple, accurate calculation
            guard let startTime = self.listeningStartTime else {
                self.log("ERROR: No listening start time available")
                return
            }
            
            // Calculate theater time: match offset + time elapsed since listening started + measured processing delay
            let timeElapsed = matchTime.timeIntervalSince(startTime)
            let currentTheaterTime = referenceMatchTime + timeElapsed + measuredProcessingDelay
            
            // Handle post-match behavior based on cycle setting
            if self.isCycleEnabled {
                // Continue cycle: stop current session and restart after 5s
                await self.stopCurrentListeningSession()
            } else {
                // Stop completely after match - direct UI update
                self.isListening = false
                self.isCurrentlyListening = false
                self.pauseCountdown = 0
                
                // Stop audio engine and reset session
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
            if await self.isCycleEnabled {
                self.log("   Cycle enabled - restarting in 5 seconds")
            } else {
                self.log("   Session paused automatically after match")
            }
            
            // Mark session as complete
            self.hasFoundMatchThisSession = true
            self.matchCount += 1
            
            // SYNC VALIDATION: Check current player position before seeking
            let currentPlayerTime = self.getCurrentPlayerTime?() ?? 0.0
            let syncDifference = abs(currentTheaterTime - currentPlayerTime)
            
            self.log("SYNC VALIDATION:")
            self.log("   Theater calculated at: \(String(format: "%.3f", currentTheaterTime))s")
            self.log("   Player currently at: \(String(format: "%.3f", currentPlayerTime))s")
            self.log("   Difference: \(String(format: "%.0f", syncDifference * 1000))ms")
            
            if syncDifference <= 0.008 { // 8ms threshold
                self.log("   ALREADY IN SYNC: Difference \(String(format: "%.0f", syncDifference * 1000))ms ≤ 8ms")
                self.log("   Skipping player adjustment - maintaining current position")
                
                // Still record the match for tracking but don't trigger seek
                self.matchHistory.append(currentTheaterTime)
                self.matchTime = 0.0 // Don't trigger onChange in ContentView
            } else {
                self.log("   NEEDS SYNC: Difference \(String(format: "%.0f", syncDifference * 1000))ms > 8ms")
                self.log("   Triggering player seek to theater position")
                
                // Send the theater time for sync
                self.matchTime = currentTheaterTime
                self.matchHistory.append(currentTheaterTime)
            }
            
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
        
        // Reset session to clear buffer accumulation after each match
        session = nil
        
        // Don't deactivate audio session to avoid interrupting playback
        // The session stays active for continuous play+record
        
        await log("Match found - pausing 5 seconds before next cycle")
        
        // Start 5-second restart timer
        await MainActor.run {
            self.restartTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.handlePauseCountdown()
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
                await log("5-second pause complete - restarting listening...")
                hasFoundMatchThisSession = false
                listeningStartTime = Date()
                isCurrentlyListening = true
                await startSingleListeningSession()
            }
        }
    }
    
    // Track seek command timing with current player position
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
                if self.matchToSeekTimes.count > 20 {
                    self.matchToSeekTimes.removeFirst()
                }
                
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
                
                self.isPerformanceGood = totalDuration < 0.08 // < 80ms for accessibility
                
                self.log("SEEK COMPLETED - Final Timing:")
                self.log("   Total end-to-end: \(String(format: "%.1f", totalDuration * 1000))ms")
                
                if totalDuration > 0.1 {
                    self.log("   ACCESSIBILITY ALERT: Total time > 100ms!")
                } else if totalDuration > 0.08 {
                    self.log("   MODERATE: Total time 80-100ms")
                } else {
                    self.log("   EXCELLENT: Total time < 80ms")
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
            self.log("SMART SKIP: Player at \(String(format: "%.2f", currentPlayerTime))s, target \(String(format: "%.2f", targetTime))s")
            self.log("   Difference: \(String(format: "%.0f", timeDifference * 1000))ms ≤ 80ms threshold")
        } else {
            self.log("PRECISE SEEK:")
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
