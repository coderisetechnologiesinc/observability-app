import SwiftUI

struct ContentView: View {
    @StateObject private var matcher = AudioMatcher()
    @State private var isListening = false
    @State private var shouldSeekTo: Double?
    @State private var shouldAutoPlay = true
    
    var body: some View {
        VStack(spacing: 0) {
            // TOP HALF - Current functionality + Timing Display
            TopSectionView(matcher: matcher, isListening: $isListening)
            
            // DIVIDER
            Divider()
                .background(Color.gray)
            
            // BOTTOM HALF - Audio Player with Timing Integration
            BottomSectionView(
                shouldSeekTo: $shouldSeekTo,
                shouldAutoPlay: $shouldAutoPlay,
                audioMatcher: matcher
            )
        }
        .task {
            try? await matcher.prepare()
        }
        .onChange(of: matcher.matchTime) { newMatchTime in
            if newMatchTime > 0 {
                print("TIMESTAMP SYNC: Theater exactly at \(newMatchTime) seconds right NOW")
                shouldSeekTo = newMatchTime
            }
        }
    }
}

// MARK: - Top Section with Enhanced Timing Display
struct TopSectionView: View {
    @ObservedObject var matcher: AudioMatcher
    @Binding var isListening: Bool
    
    var body: some View {
        VStack {
            // Control Buttons
            ControlButtonsView(isListening: $isListening, onToggle: toggleListening, onClear: clearLog)
            
            // ENHANCED: Real-Time Performance Dashboard
            PerformanceDashboardView(matcher: matcher)
            
            // Timestamp Display - Scrollable
            TimestampView(matchHistory: matcher.matchHistory)
            
            // Console Output
            ConsoleView(consoleLog: matcher.consoleLog)
        }
        .frame(maxHeight: .infinity)
    }
    
    private func toggleListening() {
        isListening.toggle()
        Task {
            if isListening {
                try? await matcher.startListening()
            } else {
                await matcher.stopListening()
            }
        }
    }
    
    private func clearLog() {
        Task { @MainActor in
            matcher.clearLog()
        }
    }
}

// MARK: - Performance Dashboard with Periodic Listening Status
struct PerformanceDashboardView: View {
    @ObservedObject var matcher: AudioMatcher
    
    var body: some View {
        VStack(spacing: 8) {
            // Continuous Cycle Status
            HStack {
                // Visual indicator for listening state
                Circle()
                    .fill(matcher.isCurrentlyListening ? Color.red : Color.blue)
                    .frame(width: 16, height: 16)
                    .scaleEffect(matcher.isCurrentlyListening ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: matcher.isCurrentlyListening)
                
                VStack(alignment: .leading) {
                    Text(matcher.isCurrentlyListening ? "🎧 LISTENING..." : "⏸️ PAUSED")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(matcher.isCurrentlyListening ? .red : .blue)
                    
                    if matcher.isCurrentlyListening {
                        Text("Waiting for match #\(matcher.matchCount + 1)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if matcher.pauseCountdown > 0 {
                        Text("Restarting in \(matcher.pauseCountdown)s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Ready to listen")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Accessibility indicator
                Circle()
                    .fill(matcher.isPerformanceGood ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                Text(matcher.isPerformanceGood ? "< 80ms" : "> 80ms")
                    .font(.caption)
                    .foregroundColor(matcher.isPerformanceGood ? .green : .red)
            }
            
            // Theater sync info
            HStack {
                Text("Theater Sync: \(matcher.matchHistory.count) matches")
                    .font(.subheadline)
                Spacer()
                Text("For blind users in movie theaters")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - Control Buttons
struct ControlButtonsView: View {
    @Binding var isListening: Bool
    let onToggle: () -> Void
    let onClear: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onToggle) {
                Text(isListening ? "Stop" : "Listen")
                    .padding()
                    .background(isListening ? Color.red : Color.blue)
                    .foregroundColor(.white)
            }
            
            Button("Clear Log", action: onClear)
        }
    }
}

// MARK: - Timestamp View
struct TimestampView: View {
    let matchHistory: [Double]
    
    var body: some View {
        VStack {
            Text("Detected Matches")
                .font(.headline)
                .padding(.bottom, 5)
            
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(matchHistory.enumerated()), id: \.offset) { index, timestamp in
                        MatchRowView(
                            timestamp: timestamp,
                            matchNumber: index + 1
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 100)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)
        }
    }
}

// MARK: - Match Row with Numbers
struct MatchRowView: View {
    let timestamp: Double
    let matchNumber: Int
    
    private var formattedTime: String {
        let hours = Int(timestamp) / 3600
        let minutes = Int(timestamp) % 3600 / 60
        let seconds = Int(timestamp) % 60
        let milliseconds = Int((timestamp.truncatingRemainder(dividingBy: 1)) * 1000)
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
        } else if minutes > 0 {
            return String(format: "%d:%02d.%03d", minutes, seconds, milliseconds)
        } else {
            return String(format: "%.3fs", timestamp)
        }
    }
    
    var body: some View {
        HStack {
            Text("#\(matchNumber)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .leading)
            
            Text("Match at: \(formattedTime)")
                .font(.system(size: 14, design: .monospaced))
            
            Spacer()
            Text("✅")
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.1))
        .cornerRadius(4)
    }
}

// MARK: - Console View
struct ConsoleView: View {
    let consoleLog: String
    
    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                Text(consoleLog)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("console")
                    .onChange(of: consoleLog) { _ in
                        proxy.scrollTo("console", anchor: .bottom)
                    }
            }
        }
        .padding()
        .background(Color.black.opacity(0.1))
        .frame(maxHeight: 200)
    }
}

// MARK: - Bottom Section with AudioMatcher Integration
struct BottomSectionView: View {
    @Binding var shouldSeekTo: Double?
    @Binding var shouldAutoPlay: Bool
    let audioMatcher: AudioMatcher
    
    var body: some View {
        VStack {
            HStack {
                Text("Reference Audio")
                    .font(.headline)
                Spacer()
                Toggle("Auto-play", isOn: $shouldAutoPlay)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.top)
            
            AudioPlayerView(
                shouldSeekTo: $shouldSeekTo,
                shouldAutoPlay: $shouldAutoPlay,
                audioMatcher: audioMatcher
            )
        }
        .frame(maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
