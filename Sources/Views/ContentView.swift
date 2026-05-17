import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DatabaseState.self) private var databaseState
    @Environment(AppState.self) private var appState
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @State private var selectedMeeting: Meeting?
    @State private var showingRecording = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var showDeleteConfirmation = false
    @State private var meetingToDelete: Meeting?
    @State private var showRecoveryNoticeAlert = false
    @State private var preSelectedProcess: AudioProcess?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showSidebarTools = true
    @State private var showingSearch = false
    @State private var viewingRecording = false
    @State private var isNarrow = false
    @State private var windowWidth: CGFloat = 1000

    @StateObject private var transcriptionEngine = TranscriptionEngine()
    @StateObject private var diarizationEngine = NeuralDiarizationEngine()
    @StateObject private var audioMonitor = AudioSourceMonitor()

    private var filteredMeetings: [Meeting] {
        if searchText.isEmpty { return meetings }
        return meetings.filter { meeting in
            meeting.title.localizedCaseInsensitiveContains(searchText)
            || meeting.transcript?.rawText.localizedCaseInsensitiveContains(searchText) == true
            || meeting.structuredNote?.summary.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private var groupedMeetings: [(String, [Meeting])] {
        let calendar = Calendar.current
        let now = Date()
        var groups: [String: [Meeting]] = [:]
        let order = ["Today", "Yesterday", "This Week", "This Month", "Earlier"]

        for meeting in filteredMeetings {
            let key: String
            if calendar.isDateInToday(meeting.date) {
                key = "Today"
            } else if calendar.isDateInYesterday(meeting.date) {
                key = "Yesterday"
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      meeting.date > weekAgo {
                key = "This Week"
            } else if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now),
                      meeting.date > monthAgo {
                key = "This Month"
            } else {
                key = "Earlier"
            }
            groups[key, default: []].append(meeting)
        }

        return order.compactMap { key in
            guard let meetings = groups[key], !meetings.isEmpty else { return nil }
            return (key, meetings)
        }
    }

    var body: some View {
        if databaseState.isUsingInMemoryFallback {
            DatabaseErrorView()
                .environment(databaseState)
                .frame(minWidth: 400, minHeight: 500)
        } else {
            mainContent
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
                .overlay(alignment: .top) {
                    // Hide the banner while the user is viewing RecordingView — it
                    // handles detections silently (auto-selects the source in its
                    // dropdown) so a banner would be redundant and distracting.
                    if !viewingRecording, let process = audioMonitor.detectedProcess {
                        AudioDetectionBanner(
                            process: process,
                            onRecord: {
                                preSelectedProcess = audioMonitor.accept()
                                selectedMeeting = nil
                                showingRecording = true
                                viewingRecording = true
                            },
                            onDismiss: {
                                audioMonitor.dismiss()
                            }
                        )
                        .padding(.top, Spacing.sm)
                        .padding(.horizontal, Spacing.xl)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: audioMonitor.detectedProcess != nil)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if appState.isRecording && !viewingRecording {
                            Button {
                                viewingRecording = true
                            } label: {
                                HStack(spacing: Spacing.xxs + 2) {
                                    BreathingDot(isPaused: appState.isPaused)
                                    Text(formatTime(appState.recordingElapsedTime))
                                        .font(Typography.mono)
                                        .foregroundStyle(SeminarlyColors.textSecondary)
                                }
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, Spacing.xxs)
                                .background(SeminarlyColors.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Return to recording")
                        } else if !viewingRecording {
                            Button {
                                selectedMeeting = nil
                                showingRecording = true
                                viewingRecording = true
                            } label: {
                                Image(systemName: "record.circle")
                                    .foregroundStyle(SeminarlyColors.recording)
                            }
                            .help("Start recording")
                        }
                    }
                }
        }
        .background(SeminarlyColors.background)
        .onChange(of: appState.isRecording) { _, isRec in
            audioMonitor.isRecordingActive = isRec
        }
        .onChange(of: columnVisibility) { _, newValue in
            if newValue == .detailOnly {
                showSidebarTools = false
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showSidebarTools = true
                }
            }
        }
        .onChange(of: audioMonitor.detectedProcess) { _, newProcess in
            // Auto-collapse sidebar at narrow widths so the detection banner is visible
            if newProcess != nil && isNarrow && columnVisibility != .detailOnly {
                columnVisibility = .detailOnly
            }
        }
        .frame(minWidth: 400, minHeight: 500)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width) { _, newWidth in
                        windowWidth = newWidth
                        isNarrow = newWidth < 600
                    }
            }
        )
        .confirmationDialog(
            "Delete Session",
            isPresented: $showDeleteConfirmation,
            presenting: meetingToDelete
        ) { meeting in
            Button("Delete", role: .destructive) {
                deleteMeeting(meeting)
            }
        } message: { meeting in
            Text("Are you sure you want to delete \"\(meeting.title)\"? This cannot be undone.")
        }
        .alert("Database Recovered", isPresented: $showRecoveryNoticeAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            if case let .recoveredByQuarantine(quarantineURL) = databaseState.error {
                Text("The database was recovered after quarantining a damaged write-ahead log. Your data should be intact. Quarantined files are preserved at \(quarantineURL.path) for forensic recovery if needed.")
            } else {
                Text("The database was recovered from a temporary error. Your data should be intact.")
            }
        }
        .onAppear {
            if case .recoveredByQuarantine = databaseState.error {
                showRecoveryNoticeAlert = true
            }
        }
        .task {
            await transcriptionEngine.loadModel(name: TranscriptionSettings.shared.whisperModel)
            await diarizationEngine.prepareModels()
            audioMonitor.startMonitoring()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if showingSearch {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SeminarlyColors.textTertiary)
                    TextField("Search sessions...", text: $searchText)
                        .textFieldStyle(.plain)
                    Button {
                        searchText = ""
                        showingSearch = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SeminarlyColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)

                Divider()
                    .padding(.bottom, Spacing.sm)
            }

            List {
                ForEach(groupedMeetings, id: \.0) { group, meetings in
                    Section {
                        ForEach(meetings) { meeting in
                            MeetingRowView(meeting: meeting)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewingRecording = false
                                    showingSettings = false
                                    selectedMeeting = meeting
                                }
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedMeeting == meeting ? SeminarlyColors.sidebarSelection : Color.clear)
                                        .padding(.horizontal, 8)
                                )
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) {
                                        meetingToDelete = meeting
                                        showDeleteConfirmation = true
                                    }
                                }
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        meetingToDelete = meeting
                                        showDeleteConfirmation = true
                                    }
                                }
                        }
                    } header: {
                        Text(group)
                            .font(Typography.captionMedium)
                            .foregroundStyle(SeminarlyColors.textTertiary)
                    }
                }
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            if showSidebarTools {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSearch.toggle()
                        if !showingSearch { searchText = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Search sessions")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        viewingRecording = false
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                    .help("Settings")
                }
            }
        }
        .navigationSplitViewColumnWidth(
            min: isNarrow ? windowWidth : 200,
            ideal: isNarrow ? windowWidth : 250,
            max: isNarrow ? windowWidth : 350
        )
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            if !viewingRecording {
                otherDetailContent
            }

            if showingRecording {
                RecordingView(
                    selectedMeeting: $selectedMeeting,
                    transcriptionEngine: transcriptionEngine,
                    diarizationEngine: diarizationEngine,
                    audioMonitor: audioMonitor,
                    preSelectedProcess: preSelectedProcess,
                    isVisible: viewingRecording,
                    onDismiss: {
                        showingRecording = false
                        viewingRecording = false
                        preSelectedProcess = nil
                        audioMonitor.reseedAfterRecording()
                    },
                    onNavigateAway: {
                        viewingRecording = false
                    }
                )
                .opacity(viewingRecording ? 1 : 0)
                .allowsHitTesting(viewingRecording)
            }
        }
    }

    @ViewBuilder
    private var otherDetailContent: some View {
        if showingSettings {
            SettingsView(onDismiss: {
                showingSettings = false
            })
        } else if let meeting = selectedMeeting {
            MeetingDetailView(meeting: meeting)
        } else {
            SeminarlyEmptyState(
                symbol: "waveform.circle",
                title: "No session selected",
                subtitle: "Select a session from the sidebar or start a new recording",
                actionTitle: "Start Recording",
                action: {
                    selectedMeeting = nil
                    showingRecording = true
                    viewingRecording = true
                }
            )
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func deleteMeeting(_ meeting: Meeting) {
        if selectedMeeting == meeting {
            selectedMeeting = nil
        }
        meeting.deleteAudioFiles()
        modelContext.delete(meeting)
        try? modelContext.save()
    }
}

struct BreathingDot: View {
    let isPaused: Bool

    var body: some View {
        Circle()
            .fill(isPaused ? SeminarlyColors.accent : SeminarlyColors.recording)
            .frame(width: 8, height: 8)
            .shadow(color: (isPaused ? SeminarlyColors.accent : SeminarlyColors.recording).opacity(0.5), radius: 4)
            .opacity(isPaused ? 0.6 : 1.0)
    }
}

struct MeetingRowView: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(meeting.title)
                    .font(Typography.headline)
                    .foregroundStyle(SeminarlyColors.textPrimary)
                    .lineLimit(1)
                HStack {
                    Text(meeting.formattedDate)
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                    Spacer()
                    Text(meeting.formattedDuration)
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textSecondary)
                }
                if let note = meeting.structuredNote {
                    Text(note.summary)
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.textTertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}
