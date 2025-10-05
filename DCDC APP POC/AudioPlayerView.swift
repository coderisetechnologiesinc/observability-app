import SwiftUI

import AVFoundation



struct AudioPlayerView: View {

    @State private var isPlaying = false

    @State private var currentTime: Double = 0

    @State private var duration: Double = 0

    @State private var audioPlayer: AVAudioPlayer?



    @State private var lastKnownTheaterTime: Double = 0

    @State private var lastUpdateTime: Date = Date()

    @State private var targetPlaybackRate: Float = 1.0

    @State private var syncHistory: [(theaterTime: Double, phoneTime: Double, timestamp: Date)] = []


    @State private var theaterStartTime: Date?

    @State private var theaterStartOffset: Double = 0

    @State private var timer: Timer?

    @State private var volume: Float = 0.5

    private struct Constants {
        static let defaultVolume: Float = 0.5
        static let timerInterval: TimeInterval = 0.1
        static let microSyncThreshold: Double = 0.05
        static let syncThreshold: Double = 0.08
        static let fallbackSyncThreshold: Double = 0.2
    }




    @Binding var shouldSeekTo: Double?

    @Binding var shouldAutoPlay: Bool




    var audioMatcher: AudioMatcher?



    var body: some View {

        VStack(spacing: 12) {


            Button(action: togglePlayback) {

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")

                    .font(.title2)

                    .foregroundColor(.white)

                    .frame(width: 44, height: 44)

                    .background(Color.blue)

                    .clipShape(Circle())

            }

   


            Slider(value: $currentTime, in: 0...duration) { editing in

                if !editing {

                    seekToPosition(currentTime)

                }

            }

            .accentColor(.blue)

   


            HStack {

                Image(systemName: "speaker.fill")

                    .foregroundColor(.gray)

                    .font(.caption2)

       

                Slider(value: $volume, in: 0...1) { _ in

                    updateVolume()

                }

                .accentColor(.orange)

                .frame(height: 20)

       

                Image(systemName: "speaker.wave.3.fill")

                    .foregroundColor(.gray)

                    .font(.caption2)

            }

   


            HStack {

                Text(formatTime(currentTime))

                    .font(.title3)

                    .fontWeight(.bold)

                    .foregroundColor(.primary)

                    .background(Color.gray.opacity(0.1))

                    .cornerRadius(4)

                    .padding(.horizontal, 8)

                    .padding(.vertical, 2)

                Spacer()

                Text("/")

                    .font(.title3)

                    .foregroundColor(.secondary)

                Spacer()

                Text(formatTime(duration))

                    .font(.title3)

                    .fontWeight(.bold)

                    .foregroundColor(.primary)

                    .background(Color.gray.opacity(0.1))

                    .cornerRadius(4)

                    .padding(.horizontal, 8)

                    .padding(.vertical, 2)

            }

        }

        .padding(.horizontal)

        .padding(.vertical, 8)

        .onAppear {

            setupAudioPlayer()

            setupAudioMatcherCallback()

        }

        .onDisappear {
            cleanup()
        }

        .onChange(of: shouldSeekTo) { newValue in

            if let theaterTime = newValue {

                updateTheaterSync(theaterTime: theaterTime)

       

                if shouldAutoPlay && !isPlaying {

                    startPlayback()

                }

       

                shouldSeekTo = nil

            }

        }

    }



    private func setupAudioPlayer() {

        do {

            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])

            try AVAudioSession.sharedInstance().setActive(true)

        } catch {

            print("Audio session error: \(error)")

        }

    

        guard let url = Bundle.main.url(forResource: "KING OF THE PECOS", withExtension: "wav") else {

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
        seekToPositionWithTimestamp(time, nil)
    }

    private func seekToPositionWithTimestamp(_ time: Double, _ startTime: UInt64?) {
        guard let player = audioPlayer, time >= 0, time <= duration else { return }

        let seekStartTime = startTime ?? mach_absolute_time()

        let wasPlaying = isPlaying

        if wasPlaying {
            player.pause()
        }

        player.currentTime = time

        let seekCompletionTime = mach_absolute_time()
        let seekDuration = Double(seekCompletionTime - seekStartTime) / 1_000_000_000.0

        print("🎯 SEEK COMPLETED: \(String(format: "%.2f", time))s in \(String(format: "%.1f", seekDuration * 1000))ms")

        // Report seek delay to AudioMatcher
        if let startTime = startTime {
            audioMatcher?.recordPlayerSeekDelay(seekStartTime: startTime, seekCompletionTime: seekCompletionTime)
        }

        if wasPlaying {
            let playStartTime = mach_absolute_time()
            player.play()
            let totalSeekPlayTime = Double(playStartTime - seekStartTime) / 1_000_000_000.0
            print("🎵 PLAYBACK RESUMED: Total seek+play delay \(String(format: "%.1f", totalSeekPlayTime * 1000))ms")
        }
    }



    private func startTimer() {

        timer = Timer.scheduledTimer(withTimeInterval: Constants.timerInterval, repeats: true) { _ in

            currentTime = audioPlayer?.currentTime ?? 0

        }

    }



    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func cleanup() {
        stopTimer()
        audioPlayer?.stop()
        audioPlayer = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Error deactivating audio session: \(error)")
        }
    }



    private func updateVolume() {

        audioPlayer?.volume = volume

    }




    private func microAdjustSync(targetTime: Double) {

        guard let player = audioPlayer else { return }

    

        let currentPos = player.currentTime

        let difference = targetTime - currentPos

    

        if abs(difference) < Constants.microSyncThreshold {
            return
        }

    


        let wasPlaying = isPlaying

        if wasPlaying {
            player.pause()
        }

        player.currentTime = targetTime
        print("🔧 MICRO-ADJUSTED: \(String(format: "%.0f", difference * 1000))ms correction")

        if wasPlaying {
            player.play()

        }

    }




    private func updateTheaterSync(theaterTime: Double) {

        let phoneTime = currentTime

        let difference = theaterTime - phoneTime

    

        print("🎯 SYNC DECISION ANALYSIS:")

        print("   📱 Phone audio at: \(String(format: "%.3f", phoneTime))s")

        print("   🎬 Theater calculated at: \(String(format: "%.3f", theaterTime))s")

        print("   📊 Difference: \(String(format: "%.3f", difference))s")

    


        let absDifference = abs(difference)

        if absDifference < Constants.syncThreshold {

            print("   ✅ MICRO-DIFF: Only \(String(format: "%.0f", absDifference * 1000))ms - no adjustment needed")

            return

        }

    

        if difference > 0 {

            print("   ⏩ Theater is AHEAD - Phone needs to seek FORWARD")

        } else {

            print("   ⏪ Theater is BEHIND - Phone needs to seek BACKWARD")

        }

    

        print("   🔍 Seeking to: \(String(format: "%.3f", theaterTime))s")

    


        if let audioMatcher = audioMatcher {

            let shouldSeek = audioMatcher.shouldPerformSeek(targetTime: theaterTime, currentPlayerTime: phoneTime)

   

            if shouldSeek {

                print("🚀 PRECISE SEEK:")

                print("   Target: \(String(format: "%.3f", theaterTime))s")

                print("   No look-ahead - using exact theater position")

       

    
                let seekCommandTime = mach_absolute_time()




                seekToPositionWithTimestamp(theaterTime, seekCommandTime)

            } else {

                print("✅ SMART SKIP: Within acceptable threshold, no seek needed")

            }

        } else {


            if abs(theaterTime - phoneTime) > Constants.fallbackSyncThreshold {

                print("🚀 FALLBACK SEEK: Phone to \(String(format: "%.3f", theaterTime))s")

                seekToPosition(theaterTime)

            } else {

                print("✅ EXCELLENT SYNC: Only \(String(format: "%.0f", abs(theaterTime - phoneTime) * 1000))ms off")

            }

        }

    }



    private func setupAudioMatcherCallback() {

        audioMatcher?.getCurrentPlayerTime = {

            return self.currentTime

        }

        audioMatcher?.seekWithTimestamp = { time, startTime in
            self.seekToPositionWithTimestamp(time, startTime)
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
