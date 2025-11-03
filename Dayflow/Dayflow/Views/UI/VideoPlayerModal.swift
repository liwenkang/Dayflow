//
//  VideoPlayerModal.swift
//  Dayflow
//
//  Custom video timeline player with activity segments
//

import SwiftUI
import AVKit
import AppKit

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct VideoSegment: Identifiable {
    let id = UUID()
    let title: String
    let startTime: Double // in seconds
    let endTime: Double
    let color: Color
    let activityType: ActivityType
    
    var duration: Double {
        endTime - startTime
    }
    
    var durationString: String {
        let minutes = Int(duration / 60)
        let seconds = Int(duration) % 60
        return minutes > 0 ? "\(minutes) min" : "\(seconds) sec"
    }
}

enum ActivityType {
    case brainstorming
    case browsing
    case coding
    case email
    case meeting
    case breaks
    case other(String)
    
    var color: Color {
        switch self {
        case .brainstorming, .coding:
            return Color.orange
        case .browsing:
            return Color.red
        case .email, .meeting:
            return Color.blue
        case .breaks:
            return Color.yellow
        case .other:
            return Color.gray
        }
    }
}

class VideoPlayerViewModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var isPlaying: Bool = false
    @Published var playbackSpeed: Float = 1.0
    @Published var currentSegment: VideoSegment?
    @Published var segments: [VideoSegment] = []
    @Published var isDragging: Bool = false
    @Published var hoverTime: Double? = nil
    @Published var timelineOffset: CGFloat = 0
    @Published var videoAspect: CGFloat = 16.0/9.0

    // Playback speed options shown in the chip (mapped to 20x, 40x, 60x labels)
    let speedOptions: [Float] = [1.0, 2.0, 3.0]
    
    var player: AVPlayer?
    private var timeObserver: Any?
    
    func setupPlayer(url: URL) {
        player = AVPlayer(url: url)
        
        // Get video duration and aspect
        player?.currentItem?.asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { [weak self] in
            guard let asset = self?.player?.currentItem?.asset else { return }
            let duration = asset.duration
            DispatchQueue.main.async {
                self?.duration = CMTimeGetSeconds(duration)
                if let track = asset.tracks(withMediaType: .video).first {
                    let natural = track.naturalSize
                    let transform = track.preferredTransform
                    let transformed = natural.applying(transform)
                    let w = abs(transformed.width) > 0 ? abs(transformed.width) : max(1, natural.width)
                    let h = abs(transformed.height) > 0 ? abs(transformed.height) : max(1, natural.height)
                    let aspect = max(0.1, CGFloat(w / h))
                    self?.videoAspect = aspect
                }
                self?.loadSegments()
            }
        }
        
        // Observe playback time
        let interval = CMTime(seconds: 1.0/60.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, !self.isDragging else { return }
            self.currentTime = CMTimeGetSeconds(time)
            self.updateCurrentSegment()
        }
    }
    
    func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player?.pause()
        player = nil
    }
    
    func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
            player?.rate = playbackSpeed
        }
        isPlaying.toggle()
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
        updateCurrentSegment()
    }
    
    func setPlaybackSpeed(_ speed: Float) {
        playbackSpeed = speed
        if isPlaying {
            player?.rate = speed
        }
    }

    func cycleSpeed() {
        guard let idx = speedOptions.firstIndex(of: playbackSpeed) else {
            setPlaybackSpeed(speedOptions.first ?? 1.0)
            return
        }
        let next = speedOptions[(idx + 1) % speedOptions.count]
        setPlaybackSpeed(next)
    }
    
    private func updateCurrentSegment() {
        currentSegment = segments.first { segment in
            currentTime >= segment.startTime && currentTime < segment.endTime
        }
    }
    
    private func loadSegments() {
        // Dummy data for now
        segments = [
            VideoSegment(title: "Brainstorming with Chat GPT", startTime: 0, endTime: 420, color: .orange, activityType: .brainstorming),
            VideoSegment(title: "Browsing TripAdvisor", startTime: 420, endTime: 660, color: .red, activityType: .browsing),
            VideoSegment(title: "Comparing flights", startTime: 660, endTime: 780, color: .blue, activityType: .other("travel")),
            VideoSegment(title: "Break", startTime: 780, endTime: 840, color: .yellow, activityType: .breaks),
            VideoSegment(title: "Email responses", startTime: 840, endTime: 1020, color: .blue, activityType: .email),
            VideoSegment(title: "Coding session", startTime: 1020, endTime: 1680, color: .orange, activityType: .coding),
            VideoSegment(title: "Research", startTime: 1680, endTime: 1980, color: .orange, activityType: .brainstorming),
            VideoSegment(title: "Planning", startTime: 1980, endTime: duration, color: .blue, activityType: .other("planning"))
        ]
    }
}

struct VideoPlayerModal: View {
    let videoURL: String
    var title: String? = nil
    var startTime: Date? = nil
    var endTime: Date? = nil
    var containerSize: CGSize? = nil
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel = VideoPlayerViewModel()
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var keyMonitor: Any?
    @State private var isHoveringVideo = false
    @State private var didStartPlay = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            if title != nil || (startTime != nil && endTime != nil) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title = title {
                            Text(title)
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        if let startTime = startTime, let endTime = endTime {
                            Text("\(timeFormatter.string(from: startTime)) to \(timeFormatter.string(from: endTime))")
                                .font(.caption)
                                .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                        }
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Color.black.opacity(0.5))
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white)
                .overlay(
                    Rectangle().stroke(Color.gray.opacity(0.25), lineWidth: 1)
                )
            }

            // Video area + overlays sized by aspect (fill available height)
            GeometryReader { geo in
                let a = max(0.1, viewModel.videoAspect)
                let h = geo.size.height
                let wFitHeight = h * a
                let fitsWidth = wFitHeight <= geo.size.width
                let vw = fitsWidth ? wFitHeight : geo.size.width
                let vh = fitsWidth ? h : (geo.size.width / a)

                ZStack {
                    Color.white
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ZStack {
                            if let _ = viewModel.player {
                                WhiteBGVideoPlayer(player: viewModel.player)
                                    .disabled(true)
                            } else {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                            }

                            // Center play/pause overlay relative to video frame
                            if !viewModel.isPlaying {
                                Button(action: { viewModel.togglePlayPause() }) {
                                    ZStack {
                                        Circle()
                                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                                            .frame(width: 64, height: 64)
                                            .background(Circle().fill(Color.black.opacity(0.35)))
                                        Image(systemName: "play.fill")
                                            .foregroundColor(.white)
                                            .font(.system(size: 24, weight: .bold))
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .frame(width: vw, height: vh)
                        .overlay(alignment: .bottomTrailing) {
                            // Playback speed chip (bottom-right of the video frame)
                            if isHoveringVideo {
                                Button(action: { viewModel.cycleSpeed() }) {
                                    Text("\(Int(viewModel.playbackSpeed * 20))x")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.black.opacity(0.85))
                                        .cornerRadius(2)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .padding(12)
                                .accessibilityLabel("Playback speed")
                            }
                        }
                        .onHover { hovering in isHoveringVideo = hovering }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { viewModel.togglePlayPause() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Scrubber
            VStack(spacing: 12) {
                if let url = scrubberURL {
                    ScrubberView(
                        url: url,
                        duration: max(0.001, viewModel.duration),
                        currentTime: viewModel.currentTime,
                        onSeek: { t in
                            let from = viewModel.currentTime
                            AnalyticsService.shared.throttled("seek_event", minInterval: 0.5) {
                                AnalyticsService.shared.capture("seek_performed", [
                                    "from_s_bucket": AnalyticsService.shared.secondsBucket(from),
                                    "to_s_bucket": AnalyticsService.shared.secondsBucket(t)
                                ])
                            }
                            viewModel.seek(to: t)
                        },
                        onScrubStateChange: { dragging in viewModel.isDragging = dragging },
                        absoluteStart: startTime,
                        absoluteEnd: endTime
                    )
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
            .background(Color.white) // underneath video area edge
        }
        // Size modal to 90% of the presenting window if available
        .frame(
            width: (containerSize?.width ?? 800) * 0.9,
            height: (containerSize?.height ?? 600) * 0.9
        )
        .onAppear {
            // Modal opened
            AnalyticsService.shared.capture("video_modal_opened", [
                "source": title != nil ? "activity_card" : "unknown",
                "duration_bucket": AnalyticsService.shared.secondsBucket(max(0.0, viewModel.duration))
            ])
            setupPlayer()
            startControlsTimer()
            // Capture spacebar to toggle play/pause while the modal is active
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Check if any text input field is focused (AppKit or SwiftUI)
                if let responder = NSApp.keyWindow?.firstResponder {
                    // Check for AppKit text fields
                    if responder is NSTextField || responder is NSTextView || responder is NSText {
                        return event
                    }
                    // Check for SwiftUI text fields (use class name string matching)
                    let className = NSStringFromClass(type(of: responder))
                    if className.contains("TextField") || className.contains("TextEditor") || className.contains("TextInput") {
                        return event
                    }
                }

                // 49 is the keyCode for Space on macOS
                if event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    viewModel.togglePlayPause()
                    return nil // swallow the event when not editing text
                }
                return event
            }
        }
        .onDisappear {
            viewModel.cleanup()
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor); keyMonitor = nil }
            // Completion (approximate)
            let pct = viewModel.duration > 0 ? (viewModel.currentTime / viewModel.duration) : 0
            AnalyticsService.shared.capture("video_completed", [
                "watch_time_bucket": AnalyticsService.shared.secondsBucket(viewModel.currentTime),
                "completion_pct_bucket": AnalyticsService.shared.pctBucket(pct)
            ])
        }
        .onChange(of: viewModel.isPlaying) { oldValue, playing in
            if playing {
                if didStartPlay {
                    AnalyticsService.shared.capture("video_resumed")
                } else {
                    AnalyticsService.shared.capture("video_play_started", [
                        "speed": String(format: "%.1fx", viewModel.playbackSpeed)
                    ])
                    didStartPlay = true
                }
            } else {
                if didStartPlay {
                    AnalyticsService.shared.capture("video_paused")
                }
            }
        }
        .onChange(of: viewModel.playbackSpeed) {
            if didStartPlay {
                AnalyticsService.shared.capture("video_playback_speed_changed", ["speed": String(format: "%.1fx", viewModel.playbackSpeed)])
            }
        }
    }
    
    private func setupPlayer() {
        let processedURL = videoURL.hasPrefix("file://") ? videoURL : "file://" + videoURL
        guard let url = URL(string: processedURL) else { return }
        if url.isFileURL {
            let path = url.path
            guard FileManager.default.fileExists(atPath: path) else { return }
        }
        viewModel.setupPlayer(url: url)
    }

    private var scrubberURL: URL? {
        let processedURL = videoURL.hasPrefix("file://") ? videoURL : "file://" + videoURL
        guard let url = URL(string: processedURL) else { return nil }
        return url
    }
    
    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            if viewModel.isPlaying && !viewModel.isDragging {
                showControls = false
            }
        }
    }
    
    private func showControlsTemporarily() {
        showControls = true
        startControlsTimer()
    }
}

extension VideoPlayerModal {
    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }
}
