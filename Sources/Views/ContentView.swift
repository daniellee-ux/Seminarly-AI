import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DatabaseState.self) private var databaseState
    @Environment(AppState.self) private var appState
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @State private var selectedMeeting: Meeting?
    @State private var showingRecording = false
    // Bumped every time a *new* recording is started, to re-key RecordingView so
    // SwiftUI rebuilds it fresh (see presentRecording()).
    @State private var recordingSessionID = 0
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
    @State private var cliOfferConfirmation: String?
    @State private var cliOfferError: String?

    @StateObject private var transcriptionEngine = TranscriptionEngine()
    @StateObject private var diarizationEngine = NeuralDiarizationEngine()
    @StateObject private var audioMonitor = AudioSourceMonitor()
    @StateObject private var updateChecker = UpdateChecker.shared

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
                    // Banners are hidden while viewing RecordingView — it handles audio
                    // detections silently, and an update notice shouldn't cover a live
                    // recording. Stacked so both can appear at once.
                    VStack(spacing: Spacing.xs) {
                        if !viewingRecording, let process = audioMonitor.detectedProcess {
                            AudioDetectionBanner(
                                process: process,
                                onRecord: {
                                    preSelectedProcess = audioMonitor.accept()
                                    selectedMeeting = nil
                                    presentRecording()
                                },
                                onDismiss: {
                                    audioMonitor.dismiss()
                                }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if !viewingRecording, let release = updateChecker.availableUpdate {
                            UpdateBannerView(
                                versionTitle: UpdateChecker.displayName(for: release),
                                onDownload: { updateChecker.openDownload() },
                                onDismiss: { updateChecker.dismissBanner() }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.top, Spacing.sm)
                    .padding(.horizontal, Spacing.xl)
                }
                .animation(.easeInOut(duration: 0.3), value: audioMonitor.detectedProcess != nil)
                .animation(.easeInOut(duration: 0.3), value: updateChecker.availableUpdate != nil)
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
                                preSelectedProcess = nil
                                presentRecording()
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
        .task {
            // Opt-in, default-off, throttled to once a day. A found update appears
            // as the banner above; up-to-date / errors stay silent on this path.
            if UpdateSettings.shared.isDueForAutomaticCheck() {
                updateChecker.checkForUpdates(mode: .automatic)
            }
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
                .id(recordingSessionID)
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
                    preSelectedProcess = nil
                    presentRecording()
                },
                accessory: { cliOffer }
            )
        }
    }

    /// A quiet, secondary offer shown beneath Start Recording — only when the CLI
    /// isn't installed yet *and* the user runs a coding agent (a `~/.claude`,
    /// `~/.codex`, … dir exists). Installs the bundled `seminarly-cli` + skill in
    /// one click (symlinks only — the PATH edit stays a separate Settings opt-in),
    /// then self-hides. No dismiss control: the offer is already narrow and the
    /// empty state is transient.
    @ViewBuilder
    private var cliOffer: some View {
        if let cliOfferConfirmation {
            Label(cliOfferConfirmation, systemImage: "checkmark.circle")
                .font(Typography.caption)
                .foregroundStyle(SeminarlyColors.success)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .transition(.opacity)
        } else if cliOfferVisible {
            VStack(spacing: Spacing.xxs) {
                Button {
                    installCLIFromOffer()
                } label: {
                    Label("Let your coding agent read your sessions", systemImage: "terminal")
                        .font(Typography.bodyMedium)
                        .foregroundStyle(SeminarlyColors.accent)
                }
                .buttonStyle(.plain)
                .help("Installs the seminarly-cli command and agent skill")

                if let cliOfferError {
                    Text(cliOfferError)
                        .font(Typography.caption)
                        .foregroundStyle(SeminarlyColors.destructive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
            }
            .transition(.opacity)
        }
    }

    private var cliOfferVisible: Bool {
        let installer = SeminarlyCLIInstaller.bundled
        return !installer.isInstalled && installer.hasAgentConfigDir
    }

    private func installCLIFromOffer() {
        let installer = SeminarlyCLIInstaller.bundled
        do {
            try installer.install()
            cliOfferError = nil
            // Honest about PATH: install never edits the shell, so if ~/.local/bin
            // isn't reachable, point the user to Settings where that opt-in lives.
            let message = installer.localBinOnPath
                ? "Installed — your coding agent can now read your sessions"
                : "Installed — finish PATH setup in Settings"
            withAnimation { cliOfferConfirmation = message }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation { cliOfferConfirmation = nil }
            }
        } catch {
            cliOfferError = error.localizedDescription
        }
    }

    /// Brings the recording view forward. If a *finished* recording is still
    /// mounted — because the user navigated away from the saved screen (tapping
    /// another session / Settings) without pressing Done, which leaves
    /// `showingRecording` true — bumping `recordingSessionID` re-keys RecordingView
    /// so SwiftUI rebuilds it from scratch; otherwise the stale "Recording saved"
    /// screen would just be re-revealed instead of a new recording.
    ///
    /// We re-key *only* in that saved state (`appState.recordingSaved`). A setup
    /// view (unsaved notes/chip selections), an active capture, and a stopped
    /// session still finalizing on its background Task (which shares
    /// transcriptionEngine) are all left mounted and merely re-revealed, never
    /// torn down mid-flight.
    private func presentRecording() {
        if appState.recordingSaved {
            recordingSessionID += 1
        }
        showingRecording = true
        viewingRecording = true
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func deleteMeeting(_ meeting: Meeting) {
        let isDeletingSelectedMeeting = selectedMeeting == meeting

        if isDeletingSelectedMeeting {
            selectedMeeting = nil
        }

        if isDeletingSelectedMeeting, showingRecording, !appState.isRecording {
            showingRecording = false
            viewingRecording = false
            preSelectedProcess = nil
            audioMonitor.reseedAfterRecording()
        }

        meeting.deleteAudioFiles()
        modelContext.delete(meeting)
        try? modelContext.save()
        meetingToDelete = nil
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
