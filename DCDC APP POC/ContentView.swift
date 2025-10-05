import SwiftUI
import AVFoundation



struct ContentView: View {
    @StateObject private var syncService = AudioSyncService()
    @State private var shouldSeekTo: Double?
    @State private var shouldAutoPlay = true

 

 var body: some View {

 GeometryReader { geometry in

 VStack(spacing: 0) {


 ScrollView {

 TopSectionView(syncService: syncService)

 }

 .frame(height: geometry.size.height * 0.6)

 


 Divider()

 .background(Color.gray)

 


 BottomSectionView(

 shouldSeekTo: $shouldSeekTo,

 shouldAutoPlay: $shouldAutoPlay,

 audioMatcher: syncService.audioMatcher

 )

 .frame(height: geometry.size.height * 0.4)

 }

 }

 .task {

 await syncService.audioMatcher.prepare()

 }

 .onChange(of: syncService.matchTime) { newMatchTime in

 if newMatchTime > 0 {

 print("TIMESTAMP SYNC: Theater exactly at \(newMatchTime) seconds right NOW")

 shouldSeekTo = Double(newMatchTime)

 }

 }

 }

}




struct TopSectionView: View {
    @ObservedObject var syncService: AudioSyncService

 @State private var showMatches = false

 

 var body: some View {

 VStack {


 ControlButtonsView(isListening: $syncService.isListening, onToggle: toggleListening, showMatches: $showMatches, syncService: syncService)

 


 PerformanceDashboardView(matcher: syncService.audioMatcher)

 


 if showMatches {

 TimestampView(matchHistory: syncService.matchHistory)

 }

 }

 }

 

 private func toggleListening() {

 Task {

 if syncService.isListening {

 await syncService.stopListening()

 } else {

 await syncService.startListening()

 }

 }

 }

 

 

}




struct PerformanceDashboardView: View {

 @ObservedObject var matcher: AudioMatcher

 

 var body: some View {

 VStack(spacing: 8) {


 HStack {


 Circle()

 .fill(matcher.isCurrentlyListening ? Color.red : Color.blue)

 .frame(width: 16, height: 16)

 .scaleEffect(matcher.isCurrentlyListening ? 1.2 : 1.0)

 .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: matcher.isCurrentlyListening)

 

 VStack(alignment: .leading) {

 Text(matcher.isCurrentlyListening ? "LISTENING..." : "PAUSED")

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

 


 Circle()

 .fill(matcher.isPerformanceGood ? Color.green : Color.red)

 .frame(width: 12, height: 12)

 Text(matcher.isPerformanceGood ? "< 80ms" : "> 80ms")

 .font(.caption)

 .foregroundColor(matcher.isPerformanceGood ? .green : .red)

 }

 


 HStack {

 Text("Theater Sync: \(matcher.matchHistory.count) matches")

 .font(.subheadline)

 Spacer()

 }

 

 

 }

 .padding()

 .background(Color.gray.opacity(0.05))

 .cornerRadius(12)

 .padding(.horizontal)

 }

}




struct ControlButtonsView: View {
    @Binding var isListening: Bool
    let onToggle: () -> Void
    @Binding var showMatches: Bool
    @ObservedObject var syncService: AudioSyncService

 

 var body: some View {

 VStack(spacing: 20) {


 Button(action: onToggle) {

 Text(isListening ? "Stop" : "Listen")

 .font(.title2)

 .fontWeight(.bold)

 .foregroundColor(.white)

 .frame(width: 120, height: 120)

 .background(isListening ? Color.red : Color.blue)

 .clipShape(Circle())

 }

 


 HStack(spacing: 15) {

 Button("Matches", action: { showMatches.toggle() })

 .padding(.horizontal, 16)

 .padding(.vertical, 8)

 .background(Color.gray.opacity(0.2))

 .cornerRadius(8)

 

 Button(action: { syncService.audioMatcher.isCycleEnabled.toggle() }) {

 HStack(spacing: 4) {

 Image(systemName: syncService.audioMatcher.isCycleEnabled ? "repeat.circle.fill" : "repeat.circle")

 Text("Cycle")

 }

 .padding(.horizontal, 16)

 .padding(.vertical, 8)

 .background(syncService.audioMatcher.isCycleEnabled ? Color.green.opacity(0.3) : Color.gray.opacity(0.2))

 .cornerRadius(8)

 }

 }

 }

 }

}




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

 }

 .padding(.horizontal)

 .padding(.vertical, 2)

 .background(Color.green.opacity(0.1))

 .cornerRadius(4)

 }

}




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

 .frame(maxHeight: 120)

 }

}




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

 }

}



#Preview {

 ContentView()

}

