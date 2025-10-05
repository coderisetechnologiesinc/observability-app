//
//  AudioSyncService.swift
//  DCDC APP POC
//
//  Created by Umid Ghimire on 2025-09-29.
//


import Foundation
import Combine

@MainActor
final class AudioSyncService: ObservableObject {
    @Published var matchTime: Double = 0.0
    @Published var isListening: Bool = false
    @Published var matchHistory: [Double] = []

    let audioMatcher: AudioMatcher

    init() {
        self.audioMatcher = AudioMatcher()
        setupBindings()
    }

    private func setupBindings() {
        audioMatcher.$matchTime.assign(to: &$matchTime)
        audioMatcher.$isListening.assign(to: &$isListening)
        audioMatcher.$matchHistory.assign(to: &$matchHistory)
    }

    func startListening() async {
        await audioMatcher.startListening()
    }

    func stopListening() async {
        await audioMatcher.stopListening()
    }
}