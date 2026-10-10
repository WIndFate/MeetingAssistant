import Combine
import Foundation

/// Live text of the paragraphs being spoken. Separate object so ~5 partial
/// updates per second re-render only the draft bubbles, not the whole list.
@MainActor
final class LiveTranscript: ObservableObject {
    @Published fileprivate(set) var text = ""
    @Published fileprivate(set) var mine = ""
}

/// The single entry point for the UI: listening, per-paragraph translation,
/// and reply hints when the user is addressed by name.
@MainActor
final class MeetingViewModel: ObservableObject {
    @Published private(set) var turns: [MeetingTurn] = [] {
        didSet { scheduleHistorySave() }
    }
    @Published private(set) var isListening = false
    @Published private(set) var statusText = "Idle."
    @Published private(set) var lastError: String?
    @Published private(set) var language: TranscriptionLanguage
    @Published private(set) var callAlertText: String?
    @Published var isStealthEnabled = true
    /// Also transcribe the user's microphone. Off on every launch.
    @Published private(set) var isMicEnabled = false
    // Set by a name call or a manual hint: every later paragraph from the
    // other side gets a hint until the user stops it (or stops listening).
    @Published private(set) var isFollowingUp = false

    let live = LiveTranscript()
    let settings: SettingsViewModel

    private let transcription = SpeechTranscriptionService(source: .system)
    private let myTranscription = SpeechTranscriptionService(source: .microphone)
    // Paragraphs of each source already turned into turns.
    private var systemParagraphCount = 0
    private var micParagraphCount = 0
    private var translationTasks: [MeetingTurn.ID: Task<Void, Never>] = [:]
    private var hintTask: Task<Void, Never>?
    // Turns at or below this index have been answered by a hint.
    private var handledCallThroughIndex = -1
    private var callCheckTask: Task<Void, Never>?
    private var shortCallGraceIndex: Int?
    private var callAlertTask: Task<Void, Never>?
    // The meeting being recorded: starts with the first paragraph after
    // launch or Clear, ends at the next Clear or quit.
    // ponytail: a meeting spans until Clear; split on long idle if one record ever covers two meetings.
    private var record: MeetingRecord?
    private var historySaveTask: Task<Void, Never>?
    private var lastMicRestart = Date.distantPast

    private static let languageKey = "MeetingAssistant.Language"
    // Tokens stream far faster than the eye reads; every turns mutation
    // re-renders the list, so streamed text is pushed at most ~16 times/s.
    private static let renderInterval: TimeInterval = 0.06
    private let translationContextCount = 3
    // "Any questions?" at the end of a long talk needs the whole talk, so
    // the hint gets the newest paragraphs up to this many characters:
    // about 35 min of Japanese or 13 min of English speech, at most ~12k
    // tokens. Hints are rare, so the extra input cost is small.
    private let hintCharacterLimit = 12_000
    // The question usually follows the name; fire once the speaker pauses.
    // A closed paragraph already implies a pause, so this only debounces.
    private let callSettleDelay: Duration = .milliseconds(300)
    // A paragraph that is little more than "セキさん、" was cut at a breath
    // before the actual question; give the rest a moment to arrive.
    private let shortCallParagraphLength = 10
    private let shortCallGraceDelay: Duration = .milliseconds(1500)
    // Saves are throttled, not debounced: a busy meeting streams changes
    // continuously, so a debounce could postpone the write indefinitely.
    // At most this much is lost if the app crashes.
    private let historySaveInterval: Duration = .seconds(5)
    // A device change restarts the mic once it settles; a second change
    // within the cooldown means the device is unusable, so the mic turns off.
    private let micRestartDelay: Duration = .milliseconds(500)
    private let micRestartCooldown: TimeInterval = 5

    init(settings: SettingsViewModel? = nil) {
        self.settings = settings ?? SettingsViewModel()
        language = UserDefaults.standard.string(forKey: Self.languageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .japanese
        transcription.onStateChange = { [weak self] state in
            self?.accept(state)
        }
        myTranscription.onStateChange = { [weak self] state in
            self?.acceptMine(state)
        }
    }

    // MARK: - Intents

    func toggleListening() {
        if isListening {
            myTranscription.stop()
            transcription.stop()
        } else {
            clearMicrophoneError()
            configureCaptureForMicrophone()
            Task {
                await transcription.start(language: language)
                if isMicEnabled, isListening {
                    // The mic may have been switched on during the start.
                    configureCaptureForMicrophone()
                    await myTranscription.start(language: language)
                }
            }
        }
    }

    /// The mic follows listening: toggling it while stopped only sets what
    /// the next start does. The first switch-on in a session opens the mic
    /// (and voice processing on speakers); after that the button only mutes,
    /// because rebuilding the capture each time cut the meeting audio and
    /// made the ducking come and go. Stopping listening releases the mic.
    func toggleMicrophone() {
        isMicEnabled.toggle()
        clearMicrophoneError()
        guard isListening else { return }
        if myTranscription.state.isListening {
            myTranscription.setPaused(!isMicEnabled)
        } else if isMicEnabled {
            configureCaptureForMicrophone()
            Task { await myTranscription.start(language: language) }
        }
    }

    func setLanguage(_ newLanguage: TranscriptionLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: Self.languageKey)
        Task {
            await transcription.switchLanguage(to: newLanguage)
            await myTranscription.switchLanguage(to: newLanguage)
        }
    }

    func toggleLanguage() {
        setLanguage(language.next)
    }

    func toggleStealth() {
        isStealthEnabled.toggle()
    }

    /// Clear ends the current meeting: it is saved, and the next paragraph
    /// starts a new record.
    func clear() {
        saveHistoryNow()
        record = nil
        translationTasks.values.forEach { $0.cancel() }
        translationTasks = [:]
        hintTask?.cancel()
        hintTask = nil
        handledCallThroughIndex = -1
        isFollowingUp = false
        cancelShortCallGrace()
        clearCallAlert()
        turns = []
        transcription.clear()
        myTranscription.clear()
        systemParagraphCount = 0
        micParagraphCount = 0
    }

    /// Hotkey / button: reply hint from the recent transcript, name or not.
    func requestHintNow() {
        Task {
            await transcription.commitLiveText()
            await myTranscription.commitLiveText()
            guard !turns.isEmpty else {
                showCallAlert("无可回答内容")
                return
            }
            requestHint(reason: "manual")
        }
    }

    /// Toolbar hint button: while following up it ends the follow-up,
    /// otherwise hint now.
    func toggleFollowUp() {
        guard isFollowingUp else {
            requestHintNow()
            return
        }
        isFollowingUp = false
        print("[MeetingViewModel] follow-up end reason=user")
    }

    var transcriptText: String {
        MeetingRecord.plainText(MeetingRecord.entries(from: turns))
    }

    /// Writes the current meeting to disk now (Clear, quit, opening history).
    func saveHistoryNow() {
        historySaveTask?.cancel()
        historySaveTask = nil
        guard var record, !turns.isEmpty else { return }
        record.endedAt = Date()
        record.entries = MeetingRecord.entries(from: turns)
        self.record = record
        do {
            try MeetingHistoryStore.save(record, in: MeetingHistoryStore.defaultFolder)
        } catch {
            print("[MeetingViewModel] history save failed error=\(error.localizedDescription)")
        }
    }

    var isAnyHintStreaming: Bool {
        turns.contains(where: \.isHintStreaming)
    }

    // MARK: - Transcription

    private func accept(_ state: TranscriptionState) {
        if isListening != state.isListening {
            isListening = state.isListening
            // Also when the system side fails: the mic follows listening.
            if !state.isListening {
                myTranscription.stop()
                isFollowingUp = false
            }
        }
        if statusText != state.statusText { statusText = state.statusText }
        syncError()
        if live.text != state.partialTranscript { live.text = state.partialTranscript }
        appendTurns(from: state.paragraphs, count: &systemParagraphCount, isMine: false)

        // Only other participants can call the user.
        if callAlertText == nil, MeetingCallDetector.containsCall(state.partialTranscript, aliases: settings.aliases) {
            showCallAlert("被点名了 · 等对方说完")
        }
        scheduleCallCheck()
    }

    private func acceptMine(_ state: TranscriptionState) {
        if live.mine != state.partialTranscript { live.mine = state.partialTranscript }
        syncError()
        // Muted while the mic was still starting.
        if state.isListening { myTranscription.setPaused(!isMicEnabled) }
        appendTurns(from: state.paragraphs, count: &micParagraphCount, isMine: true)
        guard isMicEnabled, !state.isListening, state.lastError != nil else { return }
        if case MicrophoneCaptureError.deviceChanged? = myTranscription.lastFailure,
           Date().timeIntervalSince(lastMicRestart) > micRestartCooldown {
            restartMicrophone()
        } else {
            // Permission denied, no input, or a device that keeps changing.
            isMicEnabled = false
            configureCaptureForMicrophone()
        }
    }

    /// Call apps reconfigure the mic when they join or unmute, and plugging in
    /// headphones changes whether echo cancellation is needed: let the device
    /// settle, then start again with a fresh decision.
    private func restartMicrophone() {
        lastMicRestart = Date()
        myTranscription.clearError()
        syncError()
        let delay = micRestartDelay
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.isMicEnabled, self.isListening else { return }
            print("[MeetingViewModel] microphone restart reason=device_changed")
            self.configureCaptureForMicrophone()
            await self.myTranscription.start(language: self.language)
        }
    }

    private func clearMicrophoneError() {
        myTranscription.clearError()
        syncError()
    }

    /// Paragraphs from both sources join one timeline in the order they close.
    private func appendTurns(from paragraphs: [String], count: inout Int, isMine: Bool) {
        count = min(count, paragraphs.count)
        while count < paragraphs.count {
            turns.append(MeetingTurn(text: paragraphs[count], isMine: isMine))
            count += 1
            // The user knows what they said; only the other side is translated.
            if !isMine { translate(turnAt: turns.count - 1) }
        }
    }

    private func syncError() {
        let error = transcription.state.lastError ?? myTranscription.state.lastError
        if lastError != error { lastError = error }
    }

    /// Voice processing on the mic takes over the built-in output and stops an
    /// output-anchored system capture, so the system side switches to a
    /// tap-only capture while it runs. Headphones need neither.
    private func configureCaptureForMicrophone() {
        let echoCancellation = isMicEnabled && MicrophoneCaptureService.currentOutputNeedsEchoCancellation()
        myTranscription.usesEchoCancellation = echoCancellation
        transcription.setAnchorsToOutputDevice(!echoCancellation)
    }

    // MARK: - Translation

    private func translate(turnAt index: Int) {
        let turn = turns[index]
        let context = turns[max(0, index - translationContextCount)..<index].map(\.text)
        let knowledge = MeetingKnowledge.load(from: settings.knowledgeFolderURL)
        let system = MeetingPrompts.translationSystem(knowledge)
        let user = MeetingPrompts.translationUser(text: turn.text, context: context, language: language)
        turns[index].isTranslating = true

        let source = language
        translationTasks[turn.id] = Task { [weak self] in
            guard let self else { return }
            do {
                var text = ""
                // The model occasionally returns a tidied-up copy of the
                // source instead of Chinese; that one gets a single retry.
                for attempt in 1...2 {
                    text = ""
                    var lastRender = Date.distantPast
                    for try await delta in try self.client().stream(
                        model: self.settings.translationModel,
                        system: system,
                        user: user,
                        maxTokens: 800,
                        temperature: 0.2
                    ) {
                        text += delta
                        guard Date().timeIntervalSince(lastRender) >= Self.renderInterval else { continue }
                        lastRender = Date()
                        self.updateTurn(turn.id) { $0.translation = text; $0.isTranslating = false }
                    }
                    guard attempt == 1, MeetingTranslationCleanup.isUntranslated(text, source: source) else { break }
                    print("[MeetingViewModel] translation retry reason=source_language_output")
                    self.updateTurn(turn.id) { $0.translation = ""; $0.isTranslating = true }
                }
                self.updateTurn(turn.id) {
                    $0.translation = MeetingTranslationCleanup.trimmingDanglingTail(text)
                    $0.isTranslating = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.updateTurn(turn.id) {
                    $0.isTranslating = false
                    $0.translationError = error.localizedDescription
                }
            }
            self.translationTasks[turn.id] = nil
        }
    }

    // MARK: - Name call / follow-up → reply hint

    private func scheduleCallCheck() {
        callCheckTask?.cancel()
        let delay = callSettleDelay
        callCheckTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestHintIfCallSettled()
        }
    }

    private func requestHintIfCallSettled() {
        let firstUnhandled = handledCallThroughIndex + 1
        guard firstUnhandled < turns.count else { return }
        let unhandled = firstUnhandled..<turns.count
        let callIndex = unhandled.last(where: {
            !turns[$0].isMine && MeetingCallDetector.containsCall(turns[$0].text, aliases: settings.aliases)
        })
        let needsFollowUp = isFollowingUp && unhandled.contains(where: { !turns[$0].isMine })
        guard callIndex != nil || needsFollowUp else { return }
        // Still talking: the question is not finished yet.
        guard transcription.state.partialTranscript.count < 2 else { return }
        guard let callIndex else {
            requestHint(reason: "follow_up")
            return
        }

        let lastRemoteIndex = turns.lastIndex(where: { !$0.isMine })
        let callText = turns[callIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if callIndex == lastRemoteIndex, callText.count <= shortCallParagraphLength, shortCallGraceIndex != callIndex {
            shortCallGraceIndex = callIndex
            let delay = shortCallGraceDelay
            callCheckTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.requestHintIfCallSettled()
            }
            return
        }
        requestHint(reason: "name_call")
    }

    private func cancelShortCallGrace() {
        callCheckTask?.cancel()
        shortCallGraceIndex = nil
    }

    private func requestHint(reason: String) {
        cancelShortCallGrace()
        guard !turns.isEmpty else { return }
        handledCallThroughIndex = turns.count - 1
        let isFollowUp = reason == "follow_up"
        if !isFollowUp { isFollowingUp = true }

        let transcript = MeetingPrompts.hintTranscript(
            turns.map { MeetingPrompts.hintLine($0.text, isMine: $0.isMine) },
            characterLimit: hintCharacterLimit
        )
        // The hint answers the other side, so it hangs under their latest turn.
        let index = turns.lastIndex(where: { !$0.isMine }) ?? turns.count - 1
        if !turns[index].hint.isEmpty {
            turns[index].archivedHints.append(turns[index].hint)
            turns[index].hint = ""
        }
        turns[index].isHintStreaming = true
        let turnID = turns[index].id
        switch reason {
        case "manual": showCallAlert("生成回答提示中")
        case "follow_up": showCallAlert("跟进对话 · 生成回答提示中")
        default: showCallAlert("被点名了 · 生成回答提示中")
        }

        let knowledge = MeetingKnowledge.load(from: settings.knowledgeFolderURL)
        let system = MeetingPrompts.hintSystem(knowledge)
        let user = MeetingPrompts.hintUser(
            transcript: transcript,
            language: language,
            userName: settings.aliases.first ?? "",
            isFollowUp: isFollowUp
        )
        print("[MeetingViewModel] hint request reason=\(reason) paragraphs=\(transcript.count)")

        hintTask?.cancel()
        hintTask = Task { [weak self] in
            guard let self else { return }
            do {
                var text = ""
                var lastRender = Date.distantPast
                for try await delta in try self.client().stream(
                    model: self.settings.hintModel,
                    system: system,
                    user: user,
                    maxTokens: 900,
                    temperature: 0.4
                ) {
                    text += delta
                    guard Date().timeIntervalSince(lastRender) >= Self.renderInterval else { continue }
                    lastRender = Date()
                    self.updateTurn(turnID) { $0.hint = text }
                }
                self.updateTurn(turnID) { $0.hint = text }
            } catch {
                if !Task.isCancelled {
                    self.updateTurn(turnID) { $0.hint = "Reply hint failed: \(error.localizedDescription)" }
                }
            }
            self.updateTurn(turnID) { $0.isHintStreaming = false }
            self.clearCallAlert()
        }
    }

    // MARK: - History

    private func scheduleHistorySave() {
        guard !turns.isEmpty else { return }
        if record == nil {
            let now = Date()
            record = MeetingRecord(id: UUID(), startedAt: now, endedAt: now, entries: [])
        }
        guard historySaveTask == nil else { return }
        let interval = historySaveInterval
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.saveHistoryNow()
        }
    }

    // MARK: - Helpers

    private func client() throws -> OpenAIChatClient {
        guard let key = settings.apiKey else { throw OpenAIChatError.missingAPIKey }
        return OpenAIChatClient(apiKey: key)
    }

    private func updateTurn(_ id: MeetingTurn.ID, _ mutate: (inout MeetingTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&turns[index])
    }

    // Visual only: a chime plays through the system output, where a
    // speakerphone mic or "share computer sound" would send it to the meeting.
    private func showCallAlert(_ text: String) {
        callAlertTask?.cancel()
        callAlertText = text
        // Safety net: never leave the banner up if no hint follows.
        callAlertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.callAlertText = nil
        }
    }

    private func clearCallAlert() {
        callAlertTask?.cancel()
        callAlertTask = nil
        callAlertText = nil
    }
}
