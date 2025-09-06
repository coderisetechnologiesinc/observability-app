import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var audioPlayer: AVAudioPlayer?
    
    // CONTINUOUS SYNC: Track theater position for speed adjustment 
    @State private var lastKnownTheaterTime: Double = 0
    @State private var lastUpdateTime: Date = Date()
    @State private var targetPlaybackRate: Float = 1.0
    @State private var syncHistory: [(theaterTime: Double, phoneTime: Double, timestamp: Date)] = []
    
    // Theater tracking
    @State private var theaterStartTime: Date?
    @State private var theaterStartOffset: Double = 0
    @State private var timer: Timer?
    @State private var volume: Float = 0.5
    
    // External control properties
    @Binding var shouldSeekTo: Double?
    @Binding var shouldAutoPlay: Bool
    
    // Timing integration
    var audioMatcher: AudioMatcher?
    
    var body: some View {
        VStack(spacing: 16) {
            // Play/Pause Button
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(Color.blue)
                    .clipShape(Circle())
            }
            
            // Progress Slider
            Slider(value: $currentTime, in: 0...duration) { editing in
                if !editing {
                    seekToPosition(currentTime)
                }
            }
            .accentColor(.blue)
            
            // Volume Control
            HStack {
                Image(systemName: "speaker.fill")
                    .foregroundColor(.gray)
                    .font(.caption)
                
                Slider(value: $volume, in: 0...1) { _ in
                    updateVolume()
                }
                .accentColor(.orange)
                
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundColor(.gray)
                    .font(.caption)
            }
            
            // Time Display
            HStack {
                Text(formatTime(currentTime))
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Spacer()
                Text(formatTime(duration))
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
        }
        .padding()
        .onAppear {
            setupAudioPlayer()
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: shouldSeekTo) { newValue in
            if let theaterTime = newValue {
                updateTheaterSync(theaterTime: theaterTime)
                
                if shouldAutoPlay && !isPlaying {
                    startPlayback()
                }
                
                // Reset the binding
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    shouldSeekTo = nil
                }
            }
        }
    }
    
    private func setupAudioPlayer() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
        
        guard let url = Bundle.main.url(forResource: "Seasame_Street", withExtension: "wav") else {
            print("Could not find Seasame_Street.wav")
            return
        }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            audioPlayer?.volume = volume
            duration = audioPlayer?.duration ?? 0
            print("Audio loaded: \(duration) seconds")
        } catch {
            print("Error setting up audio player: \(error)")
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }
    
    private func startPlayback() {
        guard let player = audioPlayer else { return }
        
        if player.play() {
            startTimer()
            isPlaying = true
        }
    }
    
    private func pausePlayback() {
        audioPlayer?.pause()
        stopTimer()
        isPlaying = false
    }
    
    private func seekToPosition(_ time: Double) {
        guard let player = audioPlayer else { return }
        
        // Track seek timing for sync analysis
        let seekStartTime = mach_absolute_time()
        
        let wasPlaying = isPlaying
        
        if wasPlaying {
            player.pause()
        }
        
        // CRITICAL: Seek to exact position
        player.currentTime = time
        
        // Track seek completion time
        let seekCompletionTime = mach_absolute_time()
        let seekDuration = Double(seekCompletionTime - seekStartTime) / 1_000_000_000.0
        
        print("🎯 SEEK COMPLETED: \(String(format: "%.2f", time))s in \(String(format: "%.1f", seekDuration * 1000))ms")
        
        // Inform AudioMatcher about seek completion
        audioMatcher?.trackSeekCompletion(completionTime: seekCompletionTime)
        
        if wasPlaying {
            let playStartTime = mach_absolute_time()
            player.play()
            let totalSeekPlayTime = Double(playStartTime - seekStartTime) / 1_000_000_000.0
            print("🎵 PLAYBACK RESUMED: Total seek+play delay \(String(format: "%.1f", totalSeekPlayTime * 1000))ms")
        }
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            currentTime = audioPlayer?.currentTime ?? 0
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func updateVolume() {
        audioPlayer?.volume = volume
    }
    
    // MICRO-SYNC: Small adjustments without noticeable interruption
    private func microAdjustSync(targetTime: Double) {
        guard let player = audioPlayer else { return }
        
        let currentPos = player.currentTime
        let difference = targetTime - currentPos
        
        if abs(difference) < 0.05 { // Less than 50ms - ignore
            return
        }
        
        // For differences between 50ms-2s, do a quick gentle seek
        let wasPlaying = isPlaying
        
        if wasPlaying {
            // Brief pause for micro-adjustment
            player.pause()
        }
        
        // Gentle adjustment
        player.currentTime = targetTime
        print("🔧 MICRO-ADJUSTED: \(String(format: "%.0f", difference * 1000))ms correction")
        
        if wasPlaying {
            // Resume immediately
            player.play()
        }
    }
    
    // PREDICTIVE SYNC: Use AudioMatcher's smart seeking with look-ahead
    private func updateTheaterSync(theaterTime: Double) {
        let phoneTime = currentTime
        let difference = theaterTime - phoneTime
        
        print("🎯 SYNC DECISION ANALYSIS:")
        print("   📱 Phone audio at: \(String(format: "%.3f", phoneTime))s")
        print("   🎬 Theater calculated at: \(String(format: "%.3f", theaterTime))s")
        print("   📊 Difference: \(String(format: "%.3f", difference))s")
        
        // 80MS THRESHOLD: Don't adjust if difference is too small
        let absDifference = abs(difference)
        if absDifference < 0.08 { // 80ms threshold
            print("   ✅ MICRO-DIFF: Only \(String(format: "%.0f", absDifference * 1000))ms - no adjustment needed")
            return
        }
        
        if difference > 0 {
            print("   ⏩ Theater is AHEAD - Phone needs to seek FORWARD")
        } else {
            print("   ⏪ Theater is BEHIND - Phone needs to seek BACKWARD")
        }
        
        print("   🔍 Seeking to: \(String(format: "%.3f", theaterTime))s")
        
        // Use AudioMatcher's intelligent seeking decision
        if let audioMatcher = audioMatcher {
            let shouldSeek = audioMatcher.shouldPerformSeek(targetTime: theaterTime, currentPlayerTime: phoneTime)
            
            if shouldSeek {
                print("🚀 PRECISE SEEK:")
                print("   Target: \(String(format: "%.3f", theaterTime))s")
                print("   No look-ahead - using exact theater position")
                
                // CRITICAL: Track when we START the seek command for latency measurement
                let seekCommandTime = mach_absolute_time()
                audioMatcher.trackSeekCommand(startTime: seekCommandTime)
                
                seekToPosition(theaterTime)
            } else {
                print("✅ SMART SKIP: Within acceptable threshold, no seek needed")
            }
        } else {
            // Fallback if no AudioMatcher available
            if abs(theaterTime - phoneTime) > 0.2 {
                print("🚀 FALLBACK SEEK: Phone to \(String(format: "%.3f", theaterTime))s")
                seekToPosition(theaterTime)
            } else {
                print("✅ EXCELLENT SYNC: Only \(String(format: "%.0f", abs(theaterTime - phoneTime) * 1000))ms off")
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let seconds = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    AudioPlayerView(
        shouldSeekTo: .constant(nil),
        shouldAutoPlay: .constant(true),
        audioMatcher: nil
    )
}
