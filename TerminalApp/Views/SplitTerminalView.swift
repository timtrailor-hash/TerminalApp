import SwiftUI
import UIKit
import TimSharedKit
import os

private let splitLog = Logger(subsystem: "com.timtrailor.terminal", category: "splitView")

/// Split-screen terminal view: scrollable output on top, text input on bottom.
private struct SelectablePaneView: UIViewRepresentable {
    let attributedText: NSAttributedString
    @Binding var autoScroll: Bool

    func makeCoordinator() -> Coordinator { Coordinator(autoScroll: $autoScroll) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.dataDetectorTypes = []
        tv.showsVerticalScrollIndicator = true
        tv.alwaysBounceVertical = true
        tv.adjustsFontForContentSizeCategory = false
        tv.textContainer.maximumNumberOfLines = 0
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Skip the update entirely if the attributed content is identical.
        // Every  rewrite forces a full re-layout and
        // flashes the visible text — with a 1.5s poll tick that was
        // making the pane strobe.
        if let current = tv.attributedText, current.isEqual(to: attributedText) {
            return
        }
        let wasAtBottom = Self.isScrolledToBottom(tv)
        let savedRange = tv.selectedRange
        let hadSelection = savedRange.length > 0
        // Use textStorage begin/endEditing for in-place update — smoother
        // than reassigning attributedText because UITextView coalesces the
        // layout invalidation into a single pass.
        tv.textStorage.beginEditing()
        tv.textStorage.setAttributedString(attributedText)
        tv.textStorage.endEditing()
        if hadSelection && savedRange.location + savedRange.length <= tv.attributedText.length {
            tv.selectedRange = savedRange
        }
        if autoScroll && wasAtBottom {
            DispatchQueue.main.async { Self.scrollToBottom(tv) }
        }
    }

    fileprivate static func isScrolledToBottom(_ tv: UITextView) -> Bool {
        let visibleBottom = tv.contentOffset.y + tv.bounds.size.height
        let distance = tv.contentSize.height - visibleBottom
        return distance < 24
    }

    fileprivate static func scrollToBottom(_ tv: UITextView) {
        let y = max(0, tv.contentSize.height - tv.bounds.size.height)
        tv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var autoScroll: Binding<Bool>
        init(autoScroll: Binding<Bool>) { self.autoScroll = autoScroll }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tv = scrollView as? UITextView else { return }
            let atBottom = SelectablePaneView.isScrolledToBottom(tv)
            if autoScroll.wrappedValue != atBottom {
                autoScroll.wrappedValue = atBottom
            }
        }
    }
}


struct PromptOption: Identifiable, Equatable {
    let number: Int
    let label: String
    var id: Int { number }
}

/// Server-supplied pane option (parsed from /tmux-windows response).
/// When non-empty, drives the rich card's button count + labels so
/// hook-driven asks (2 options) and native asks (3 options) both render
/// correctly without iOS hardcoding either count.
struct PaneOption: Codable, Hashable, Identifiable {
    let number: Int
    let label: String
    var id: Int { number }
}


struct SplitTerminalView: View {
    @ObservedObject var commandRunner: SSHCommandRunner
    @ObservedObject var ssh: SSHTerminalService
    @ObservedObject var model: TerminalSessionModel
    @EnvironmentObject var server: ServerConnection

    /// The tmux window index the user is currently viewing. Defaults to 1.
    let activeWindowIndex: Int
    /// JSONL-based pending-approval state from /tmux-windows. When true,
    /// Claude Code is waiting for a tool-use permission response — show
    /// fixed Yes/Allow/No buttons without any pane-text parsing.
    var pendingApproval: Bool = false
    var pendingToolName: String = ""
    /// Monotonic counter from /tmux-windows. Bar is shown when
    /// pendingApproval is true AND promptId > lastAnsweredPromptId.
    /// Server increments this each time a fresh prompt opens so a tap
    /// answering the previous prompt doesn't pollute the next one.
    var promptId: Int = 0
    var pendingIntent: String = ""
    var pendingRisk: String = ""
    var pendingBlastRadius: String = ""
    var pendingCommandPreview: String = ""
    /// "native" (Claude Code's own permission prompt — 3 options) or
    /// "hook" (Bash safety hook ASK card — typically 2 options). Drives
    /// whether the rich card renders 2 or 3 buttons. Empty = legacy.
    var pendingPromptType: String = ""
    /// Actual options parsed from the pane (number + label). When
    /// non-empty, the rich card renders these instead of the hardcoded
    /// 3-button layout. Empty = legacy 3-button layout.
    var pendingOptions: [PaneOption] = []
    var onCapturedText: ((String) -> Void)?
    /// Set by TerminalView after a successful upload. Watched here via
    /// .onChange — when a non-empty list arrives, combine the paths with
    /// any prose typed into the active tab's input field and submit the
    /// whole thing as one message. Empty prose falls back to pasting
    /// paths to the pane (legacy "drop a file alone" workflow).
    /// Fixes the "type prose + attach + upload loses prose" bug Tim
    /// flagged 2026-05-04.
    @Binding var pendingPathsToConsume: [String]
    var tmuxWindowIndices: Set<Int> = []

    /// Highest promptId the user has already answered. Bar stays hidden
    /// while `promptId <= lastAnsweredPromptId` — prevents the "tap
    /// approves old prompt, new prompt has same buttons, looks stuck"
    /// visual glitch and the "tap lands as a digit in the text buffer
    /// when no prompt is live" pollution that caused the 22 situation.
    @State private var lastAnsweredPromptId: Int = 0

    @State private var perTabLines: [Int: [PaneLine]] = [:]
    @State private var promptOptions: [PromptOption] = []
    @State private var showQueueEditButton: Bool = false
    /// Per-tab stack of texts the user submitted from iOS. Used by the
    /// queue-edit button to restore the most recent send into the iOS
    /// input field, since Claude Code's queue lives in the tmux pane and
    /// is not directly readable from iOS. Capped to keep memory bounded.
    @State private var sentTextStack: [Int: [String]] = [:]
    @State private var isRecalling: Bool = false
    @State private var lastLoggedReasonKey: String = ""
    @State private var lastLoggedReasonTime: Date = .distantPast

    /// Every call to the prompt-option detector ends here. Logs the
    /// transition (APPEAR/DISAPPEAR/CHANGE) with the reason code from the
    /// detector to both os_log and the conversation-server /debug-log
    /// endpoint. Dedup: the same (kind, reason, tab, options) does not
    /// spam the log twice in a row. Tim 2026-04-18: "add some logging so
    /// you can see every time they appear and every time they disappear
    /// and why".
    private func logButtonTransition(
        prev: [PromptOption], next: [PromptOption],
        reason: String, evidence: String, activeTab: Int
    ) {
        let kind: String
        if prev.isEmpty && !next.isEmpty { kind = "APPEAR" }
        else if !prev.isEmpty && next.isEmpty { kind = "DISAPPEAR" }
        else if prev != next { kind = "CHANGE" }
        else { return }
        let key = "\(kind):\(reason):\(activeTab):\(next.map{String($0.number)}.joined(separator: ","))"
        let now = Date()
        if key == lastLoggedReasonKey && now.timeIntervalSince(lastLoggedReasonTime) < 3 { return }
        lastLoggedReasonKey = key
        lastLoggedReasonTime = now
        let prevDesc = prev.isEmpty ? "empty" : prev.map { "\($0.number).\($0.label)" }.joined(separator: ",")
        let nextDesc = next.isEmpty ? "empty" : next.map { "\($0.number).\($0.label)" }.joined(separator: ",")
        splitLog.info("[button] \(kind, privacy: .public) tab=\(activeTab) reason=\(reason, privacy: .public) prev=[\(prevDesc, privacy: .public)] next=[\(nextDesc, privacy: .public)]")
        let baseURL = server.baseURL
        Task.detached(priority: .utility) {
            guard let url = URL(string: "\(baseURL)/debug-log") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "source": "SplitTerminalView.detectPromptOptions",
                "kind": kind,
                "tab": activeTab,
                "reason": reason,
                "prev": prevDesc,
                "next": nextDesc,
                "evidence": evidence,
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Result of a single detector run — options PLUS reason code and
    /// evidence string explaining the decision.
    /// Must be `private` (same level as `PromptOption`) so Swift's
    /// access-control rule is satisfied.
    private struct DetectResult: Equatable {
        let options: [PromptOption]
        let reason: String
        let evidence: String
    }
    // Drafts survive app suspension / termination (phone lock, backgrounding,
    // iOS eviction). Without persistence, @State is wiped when the app
    // process dies and the user loses typed-but-unsent prompts.
    @State private var perTabInput: [Int: String] = SplitTerminalView.loadDrafts()
    @State private var perTabPaneHash: [Int: Int] = [:]
    @State private var hasLoadedOnce: Bool = false

    private static let draftsDefaultsKey = "SplitTerminalView.perTabInputDrafts.v1"

    private static func loadDrafts() -> [Int: String] {
        guard let data = UserDefaults.standard.data(forKey: draftsDefaultsKey),
              let dict = try? JSONDecoder().decode([Int: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func saveDrafts() {
        let nonEmpty = perTabInput.filter { !$0.value.isEmpty }
        if nonEmpty.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.draftsDefaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(nonEmpty) {
            UserDefaults.standard.set(data, forKey: Self.draftsDefaultsKey)
        }
    }

    private var paneLines: [PaneLine] {
        perTabLines[activeWindowIndex] ?? []
    }
    @State private var pollTask: Task<Void, Never>?
    @State private var isSending = false
    @State private var fastPollUntil: Date = .distantPast
    @State private var isUserScrolledUp = false
    @State private var toastMessage: String?
    @FocusState private var inputFocused: Bool

    /// @State mirror of `activeWindowIndex`. The parent passes
    /// `activeWindowIndex` as a plain `let`, which means each time the
    /// parent rebuilds SplitTerminalView (e.g. on tab change) the struct
    /// instance captured by long-lived closures (like the polling Task)
    /// keeps reading the OLD value. Reads through `@State` always go to
    /// the shared backing store, so they reflect the latest value even
    /// when the closure captured a stale struct.
    @State private var pollTarget: Int = 0

    // Last pane size we told the server about. The server defaults to 80x23 which
    // is way wider than the iPhone's ~48-col display, so Claude Code CLI wraps
    // its TUI at 78 and we then re-wrap visually → mid-paragraph breaks. We
    // recompute on every GeometryReader pass and push to /tmux-resize whenever
    // it changes (rotation, keyboard show/hide).
    @State private var lastPushedCols: Int = 0
    @State private var lastPushedRows: Int = 0

    // Font metrics for the output text. Keep in sync with the Text modifier below.
    private static let outputFontSize: CGFloat = 12
    private static let outputFontCellWidth: CGFloat = {
        let f = UIFont.monospacedSystemFont(ofSize: outputFontSize, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: f]).width
    }()
    private static let outputFontLineHeight: CGFloat = {
        let f = UIFont.monospacedSystemFont(ofSize: outputFontSize, weight: .regular)
        return f.lineHeight
    }()

    // HTTP helpers live in TerminalSessionModel. All calls go through model.httpXxx().

    /// Called from GeometryReader whenever the output pane's size changes.
    /// Recomputes tmux cols/rows from the monospace cell metrics and pushes
    /// them to the server — but only when they actually change, so rotation
    /// or keyboard toggles are handled without flooding the server.
    private func updateTmuxPaneSize(outputSize: CGSize) {
        // Output pane has 8pt horizontal padding on each side (see `.padding(.horizontal, 8)`
        // on each Text row). Subtract both sides before dividing by cell width.
        let usableWidth = max(outputSize.width - 16, 0)
        let cols = max(20, Int(floor(usableWidth / Self.outputFontCellWidth)))
        // Use a STABLE row count based on screen height, not the current
        // pane height. When the keyboard opens, outputSize.height shrinks
        // → we'd push a smaller row count → SIGWINCH → every TUI running
        // in the pane (zsh, Claude Code) redraws → the pre-resize UI
        // lands in scrollback → pane shows duplicate banners/prompts.
        // Peg rows to the full screen so keyboard show/hide doesn't
        // trigger resize churn.
        let screen = UIScreen.main.bounds.size
        let referenceHeight = max(screen.height, screen.width) * 0.68
        let rows = max(10, Int(floor(referenceHeight / Self.outputFontLineHeight)))
        if cols == lastPushedCols && rows == lastPushedRows { return }
        lastPushedCols = cols
        lastPushedRows = rows
        // Stash for createTmuxWindow in TerminalView so it can create the
        // window at the right size from the start (avoids zsh redrawing
        // its prompt on SIGWINCH and leaving stale prompts in scrollback).
        UserDefaults.standard.set(cols, forKey: "TerminalApp.lastPaneCols")
        UserDefaults.standard.set(rows, forKey: "TerminalApp.lastPaneRows")
        Task {
            await model.httpTmuxResize(cols: cols, rows: rows)
            // Immediately refetch so the user sees reflowed content without waiting
            // for the next 1.5s poll tick.
            await refreshPane()
        }
    }

    private var inputText: Binding<String> {
        Binding(
            get: { perTabInput[activeWindowIndex] ?? "" },
            set: {
                perTabInput[activeWindowIndex] = $0
                saveDrafts()
            }
        )
    }

    private var tmuxTarget: String {
        "mobile:\(activeWindowIndex)"
    }

    struct PaneLine: Identifiable {
        let id: Int
        let text: String
        let lineType: LineType
    }

    enum LineType {
        case userInput     // Lines the user typed (prompt lines)
        case claudeText    // Claude's response text
        case system        // Tool use, system info, etc.
        case superseded    // Rejected response-gate retry turn (strikethrough dimmed)
    }

    var body: some View {
        outputSection
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.keyboard)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { updateTmuxPaneSize(outputSize: geo.size) }
                        .onReceive(NotificationCenter.default.publisher(
                            for: UIDevice.orientationDidChangeNotification
                        )) { _ in
                            updateTmuxPaneSize(outputSize: geo.size)
                        }
                }
            )
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if !effectivePromptOptions.isEmpty {
                        promptOptionsRow
                    }

                    if showQueueEditButton && effectivePromptOptions.isEmpty {
                        queueEditRow
                    }

                    Divider()
                        .background(AppTheme.accent.opacity(0.3))

                    inputSection
                        .frame(minHeight: 56, maxHeight: 120)
                }
            }
        .background(AppTheme.background)
        .overlay(alignment: .top) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.85).cornerRadius(8))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            withAnimation { toastMessage = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
        .onAppear {
            pollTarget = activeWindowIndex
            startPolling()
        }
        .onDisappear { stopPolling() }
        .onChange(of: pendingPathsToConsume) { _, newPaths in
            consumeUploadedPaths(newPaths)
        }
        .onChange(of: activeWindowIndex) { _, newIndex in
            // Keep per-tab cached content; just refresh in background.
            isUserScrolledUp = false
            // Update the @State mirror so the polling Task (which captured
            // the initial struct and therefore reads the stale `let
            // activeWindowIndex`) picks up the new tab on its next tick.
            pollTarget = newIndex
            // `promptOptions` is view-scoped (not per-tab). Re-evaluate it
            // against the new tab's cached lines immediately so the previous
            // tab's button row doesn't flash on this one while refreshPane is
            // in flight. If the new tab's cache is empty, this harmlessly
            // clears; refreshPane will fill it in.
            let tabResult = detectPromptOptionsWithReason(perTabLines[newIndex] ?? [])
            let prevOpts = promptOptions
            promptOptions = tabResult.options
            logButtonTransition(prev: prevOpts, next: tabResult.options,
                reason: "tab-switch/\(tabResult.reason)",
                evidence: tabResult.evidence, activeTab: newIndex)
            Task { await refreshPane() }
        }
        .onChange(of: tmuxWindowIndices) { _, liveIndices in
            for key in perTabLines.keys where !liveIndices.contains(key) {
                perTabLines.removeValue(forKey: key)
            }
            for key in perTabInput.keys where !liveIndices.contains(key) {
                perTabInput.removeValue(forKey: key)
            }
            for key in sentTextStack.keys where !liveIndices.contains(key) {
                sentTextStack.removeValue(forKey: key)
            }
            for key in perTabPaneHash.keys where !liveIndices.contains(key) {
                perTabPaneHash.removeValue(forKey: key)
            }
            saveDrafts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .paneRefreshRequested)) { note in
            // Silent push or notification tap requested a fresh capture.
            // If it's for this tab, pull now; if it's for another tab,
            // invalidate that tab's hash so the next switch refreshes.
            let targetWindow = (note.userInfo?["window"] as? Int) ?? activeWindowIndex
            if targetWindow == activeWindowIndex {
                Task { await refreshPane() }
            } else {
                perTabPaneHash[targetWindow] = 0
            }
        }
    }

    // MARK: - Output Section

    /// Detect an ACTIVE Claude Code permission prompt in the current pane.
    /// Must satisfy all of:
    ///   1. Options appear in the last 25 lines (not older scrollback).
    ///   2. Everything between the options and the pane bottom is "chrome"
    ///      — empty, box border, status bar, or empty ❯ input prompt.
    ///      ANY substantive line below the options (shell output, user
    ///      text, `❯ 2` etc) means the prompt has been dismissed and we
    ///      return empty so the clickable button row disappears.
    ///   3. At least 2 contiguous options numbered 1…N.
    private func detectPromptOptionsWithReason(_ lines: [PaneLine]) -> DetectResult {
        let tail = Array(lines.suffix(25))
        let tailSample = tail.suffix(6).map { $0.text }.joined(separator: " | ")

        if let w = tail.first(where: { isWorkingIndicator($0.text) }) {
            return DetectResult(options: [], reason: "working-indicator",
                evidence: "matched='\(w.text.prefix(60))' tail=[\(tailSample)]")
        }

        var lastOptIdx: Int? = nil
        for i in stride(from: tail.count - 1, through: 0, by: -1) {
            let raw = tail[i].text
            if parsePromptOptionLine(raw) != nil {
                lastOptIdx = i; break
            }
            if !isPromptChromeLine(raw) {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                let leadingSpaces = raw.prefix(while: { $0 == " " }).count
                if leadingSpaces >= 4 && !trimmed.isEmpty && !(trimmed.first?.isNumber ?? false) {
                    continue
                }
                return DetectResult(options: [], reason: "substantive-line-below",
                    evidence: "aborted-at='\(raw.prefix(60))' tail=[\(tailSample)]")
            }
        }
        guard let endIdx = lastOptIdx else {
            return DetectResult(options: [], reason: "no-option-lines-in-tail",
                evidence: "tail=[\(tailSample)]")
        }

        // Walk back from endIdx to find the top of the option block. We
        // accept option lines AND wrap continuations (4+ leading spaces,
        // non-digit, non-empty). startIdx may end up *one above* the real
        // first option if a wrap-shaped line sits immediately above option
        // 1 — the validation pass below handles that via its
        // `guard !collected.isEmpty` bail when the first line in the range
        // fails to parse.
        var startIdx = endIdx
        while startIdx > 0 {
            let prevText = tail[startIdx - 1].text
            if parsePromptOptionLine(prevText) != nil { startIdx -= 1; continue }
            let trimmed = prevText.trimmingCharacters(in: .whitespaces)
            let leadingSpaces = prevText.prefix(while: { $0 == " " }).count
            if leadingSpaces >= 4 && !trimmed.isEmpty && !(trimmed.first?.isNumber ?? false) {
                startIdx -= 1; continue
            }
            break
        }

        var collected: [(Int, String)] = []
        var anyActive = false
        var activeLine = ""
        for i in startIdx...endIdx {
            if let parsed = parsePromptOptionLine(tail[i].text) {
                collected.append(parsed)
                if hasActiveSelector(tail[i].text) { anyActive = true; activeLine = tail[i].text }
                continue
            }
            // Wrap continuation of the previous option's label. The walk-up
            // only let us land here on a line with 4+ leading spaces that
            // doesn't start with a digit — i.e. a wrapped tail of the option
            // immediately above. Merge it into that option's label so the
            // 1…N contiguity check below still passes.
            guard !collected.isEmpty else {
                return DetectResult(options: [], reason: "unparseable-option-in-block",
                    evidence: "failed='\(tail[i].text.prefix(60))'")
            }
            let cont = tail[i].text.trimmingCharacters(in: .whitespaces)
            if cont.isEmpty { continue }
            let last = collected.removeLast()
            // Defer the 60-char cap to the final map below so multi-line
            // wraps accumulate cleanly without compound truncation.
            collected.append((last.0, last.1 + " " + cont))
        }
        guard collected.count >= 2 else {
            return DetectResult(options: [], reason: "too-few-options-\(collected.count)", evidence: "")
        }
        for (i, entry) in collected.enumerated() where entry.0 != i + 1 {
            return DetectResult(options: [], reason: "non-contiguous-numbering",
                evidence: "collected=\(collected.map{"\($0.0).\($0.1)"}.joined(separator: ", "))")
        }
        if !anyActive {
            return DetectResult(options: [], reason: "no-active-selector",
                evidence: "collected=\(collected.map{"\($0.0).\($0.1)"}.joined(separator: ", ")) tail=[\(tailSample)]")
        }
        let opts = collected.map { (num, label) -> PromptOption in
            let capped = label.count > 60 ? String(label.prefix(57)) + "…" : label
            return PromptOption(number: num, label: capped)
        }
        return DetectResult(options: opts, reason: "active-prompt",
            evidence: "selector-on='\(activeLine.prefix(60))'")
    }

    /// True if this line begins (after optional box-draw border) with the
    /// active-selection marker Claude Code puts on the highlighted option.
    private func hasActiveSelector(_ raw: String) -> Bool {
        var t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("│") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard let first = t.first else { return false }
        return first == "❯" || first == ">"
    }

    /// Lines allowed between the options block and the pane bottom without
    /// invalidating the prompt detection. Everything else (user text,
    /// shell prompts with actual content, task list items) counts as real
    /// content and dismisses the buttons.
    private func isPromptChromeLine(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if t.hasPrefix("╭") || t.hasPrefix("╰") || t.hasPrefix("─") { return true }
        if t.hasPrefix("│") && t.hasSuffix("│") {
            // A box-drawn row is only chrome if its interior is blank.
            let inner = String(t.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            return inner.isEmpty
        }
        let lower = t.lowercased()
        if lower.contains("esc to") { return true }
        if lower.contains("tab to") { return true }
        if lower.contains("press up") { return true }
        if lower.contains("ctrl+") { return true }
        if lower.contains("shift+") { return true }
        if lower.contains("for shortcuts") { return true }
        if lower.contains("? for") { return true }
        // An input prompt with nothing in it is still "waiting"; a prompt
        // with content after it (like `❯ 2`) is real user input and should
        // disqualify the detection.
        if t == "❯" || t == ">" { return true }
        return false
    }

    /// Indicators that Claude is currently working (not awaiting input).
    /// When any of these are visible in the pane tail, a scrollback prompt
    /// is stale — don't resurrect its buttons.
    private func isWorkingIndicator(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        let lower = t.lowercased()
        // "esc to interrupt" is the unambiguous active-work footer.
        if lower.contains("esc to interrupt") { return true }
        // "Crafting…" appears mid-response; "thought for Ns" appears briefly
        // at completion but before a new prompt.
        if lower.contains("crafting") { return true }
        if lower.contains("thinking") && (lower.contains("token") || lower.contains("thought for")) {
            return true
        }
        // Claude Code's thinking spinner glyphs — presence of any of these
        // in an otherwise non-chrome line signals ongoing work.
        let spinnerGlyphs: [Character] = ["✢", "✶", "✽", "✳", "⚒", "✻"]
        if spinnerGlyphs.contains(where: { t.contains($0) }) {
            // Only treat as working if it's next to a time/tokens metric
            // (guards against decorative glyphs inside rendered content).
            if lower.contains("token") || lower.contains("s ·") || lower.contains("s |") {
                return true
            }
        }
        return false
    }

    private func parsePromptOptionLine(_ raw: String) -> (Int, String)? {
        var body = raw.trimmingCharacters(in: .whitespaces)
        // Strip Claude Code's leading markers: box-drawing │, selection ❯,
        // ASCII > and bullet variants that might appear before the number.
        let markerChars: Set<Character> = ["│", "❯", "\u{203A}", ">", "•", "·"]
        while let first = body.first, markerChars.contains(first) {
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // Trailing box-drawing on the right (Claude Code's prompt box).
        while let last = body.last, last == "│" {
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        // Match "N. label" (dot, permission prompt) or "N: label" (colon,
        // session feedback survey). Both are single-keystroke handlers in
        // Claude Code and should get the bare-key treatment.
        var separatorIdx: String.Index? = nil
        if let dotIdx = body.firstIndex(of: ".") {
            let numStr = body[..<dotIdx]
            if let _ = Int(numStr) { separatorIdx = dotIdx }
        }
        if separatorIdx == nil, let colonIdx = body.firstIndex(of: ":") {
            let numStr = body[..<colonIdx]
            if let _ = Int(numStr) { separatorIdx = colonIdx }
        }
        guard let sepIdx = separatorIdx,
              let num = Int(body[..<sepIdx]),
              (0...9).contains(num) else { return nil }
        let rest = body[body.index(after: sepIdx)...]
            .trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        // Label cap is applied in detectPromptOptionsWithReason after any
        // wrap-continuation merge so multi-line options don't compound truncate.
        return (num, String(rest))
    }

    private func sendPromptChoice(_ number: Int) {
        let window = activeWindowIndex
        // Bump lastAnsweredPromptId optimistically so the bar hides instantly
        // on tap (can't re-render the same prompt's buttons before the
        // next poll). If the server rejects the tap as stale (HTTP 409),
        // revert so the bar returns and the user can tap the real prompt.
        let answeredId = promptId
        promptOptions = []
        let previousAnswered = lastAnsweredPromptId
        lastAnsweredPromptId = max(lastAnsweredPromptId, answeredId)
        Task {
            // Send the digit + promptId. Server validates promptId against
            // its current tracker and rejects with 409 if stale —
            // prevents the "digit-lands-in-text-buffer" pollution that
            // happened before this fix.
            let accepted = await model.httpSendKey("\(number)", window: window, promptId: answeredId)
            if !accepted {
                // Tap was stale. Undo the optimistic hide so the bar
                // comes back and the user sees the current prompt.
                await MainActor.run {
                    lastAnsweredPromptId = previousAnswered
                }
            }
            fastPollUntil = Date().addingTimeInterval(10)
            await refreshPane()
        }
    }

    private func uiColorFor(_ type: LineType) -> UIColor {
        switch type {
        case .userInput:
            return UIColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1)
        case .claudeText:
            return UIColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1)
        case .system:
            return UIColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        case .superseded:
            return UIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.5)
        }
    }

    private func buildPaneNSAttributed(_ lines: [PaneLine]) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 1
        para.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString()
        for (idx, line) in lines.enumerated() {
            let raw = line.text.isEmpty ? " " : line.text
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: uiColorFor(line.lineType),
                .paragraphStyle: para,
            ]
            if line.lineType == .superseded {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = UIColor.gray.withAlphaComponent(0.6)
            }
            result.append(NSAttributedString(string: raw, attributes: attrs))
            if idx < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        return result
    }

    private var outputSection: some View {
        Group {
            if paneLines.isEmpty {
                VStack(alignment: .leading) {
                    Text(hasLoadedOnce ? "" : "Loading...")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AppTheme.dimText)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SelectablePaneView(
                    attributedText: buildPaneNSAttributed(paneLines),
                    autoScroll: Binding(
                        get: { !isUserScrolledUp },
                        set: { isUserScrolledUp = !$0 }
                    )
                )
            }
        }
        .background(AppTheme.background)
    }

    // MARK: - Color coding

    /// Classify a full pane in one pass so prompt-continuation lines inherit the
    /// userInput colour. Per-line classification breaks colouring when Claude
    /// Code wraps a prompt across multiple visual rows — only the first row
    /// starts with `❯ `; the rest are indented continuations that used to be
    /// rendered as `.claudeText` (grey) and leak out of the highlight.
    private func classifyLines(_ lines: [String]) -> [LineType] {
        var result: [LineType] = []
        result.reserveCapacity(lines.count)
        var inPrompt = false
        var gateMarkerIndices: [Int] = []
        for (lineIdx, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("SUPERSEDED") {
                inPrompt = false
                result.append(.superseded)
                continue
            }

            if trimmed.contains("[response_gate]") {
                gateMarkerIndices.append(lineIdx)
            }

            // Claude Code renders the user prompt as ❯ (U+276F) followed
            // by U+00A0 or a space. Do NOT match "> " or "$ " — those are
            // ambiguous (markdown blockquotes, shell output) and cause Claude
            // responses to render as user input (cyan).
            let startsWithChevron = trimmed.hasPrefix("❯")
            if startsWithChevron {
                let afterMarker = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                let isThinkingPlaceholder = afterMarker.hasSuffix("\u{2026}") && (
                    afterMarker.contains("Thinking") ||
                    afterMarker.contains("Working") ||
                    afterMarker.contains("Considering") ||
                    afterMarker.contains("Analysing") ||
                    afterMarker.contains("Analyzing") ||
                    afterMarker.contains("Planning") ||
                    afterMarker.contains("still working")
                )
                if isThinkingPlaceholder {
                    inPrompt = false
                    result.append(.system)
                    continue
                }
                inPrompt = true
                result.append(.userInput)
                continue
            }

            // Tool indicators / box drawing reset the prompt-continuation mode
            // and are classified as system.
            if trimmed.hasPrefix("⏺") || trimmed.hasPrefix("●") ||
               trimmed.hasPrefix("─") || trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰") ||
               trimmed.hasPrefix("│") || trimmed.hasPrefix("├") ||
               trimmed.hasPrefix("\u{2022}") ||
               trimmed.hasPrefix("*") || trimmed.hasPrefix("\u{00B7}") ||
               trimmed.hasPrefix("\u{23BF}") || trimmed.hasPrefix("\u{2514}") ||
               trimmed.hasPrefix("\u{2570}") {
                inPrompt = false
                result.append(.system)
                continue
            }

            if inPrompt {
                // A prompt continuation is either an indented wrap of the
                // previous user line, or a blank line inside a multi-line
                // prompt. It must start with actual prose (a letter or
                // common opening punctuation) — Claude Code's streaming
                // "Thinking..." placeholders start with special indicator
                // chars like `›`, `*`, `·`, `⎿` and must NOT be coloured as
                // user input even when indented.
                let leadingWhitespace = raw.prefix(while: { $0 == " " }).count
                if trimmed.isEmpty {
                    result.append(.userInput)
                    continue
                }
                let first = trimmed.first
                let looksLikeProse = first.map { ch -> Bool in
                    if ch.isLetter || ch.isNumber { return true }
                    return "\"'(\u{201C}\u{2018}[-".contains(ch)
                } ?? false
                if leadingWhitespace >= 2 && looksLikeProse {
                    result.append(.userInput)
                    continue
                }
                inPrompt = false
            }

            result.append(.claudeText)
        }

        for markerIdx in gateMarkerIndices {
            result[markerIdx] = .superseded
            var j = markerIdx - 1
            while j >= 0 {
                if result[j] == .userInput { break }
                result[j] = .superseded
                j -= 1
            }
        }

        return result
    }

    private var hasEnrichedPrompt: Bool {
        pendingApproval && promptId > lastAnsweredPromptId && !pendingIntent.isEmpty
    }

    /// Whether the pending prompt comes from a hook (Bash safety hook
    /// emitting permissionDecision: ask) vs a native Claude Code prompt
    /// (tool not in the allowlist). Hook prompts have 2 options; native
    /// prompts have 3.
    private var isHookPrompt: Bool {
        pendingPromptType == "hook"
    }

    private var effectivePromptOptions: [PromptOption] {
        if pendingApproval && promptId > lastAnsweredPromptId {
            // If the server gave us the actual pane options, prefer them.
            // Falls back to the legacy 3-button native layout when empty
            // (e.g. older server that doesn't send pendingOptions).
            if !pendingOptions.isEmpty {
                return pendingOptions.map { PromptOption(number: $0.number, label: $0.label) }
            }
            return [
                PromptOption(number: 1, label: "Approve \(pendingToolName)"),
                PromptOption(number: 2, label: "Allow \(pendingToolName) for session"),
                PromptOption(number: 3, label: "Deny"),
            ]
        }
        return promptOptions
    }

    // MARK: - Prompt Option Colour Semantic

    /// Colour-code basic prompt option buttons by semantic intent.
    /// Affirmative buttons (Yes / Approve) take their colour from the
    /// RISK of the underlying operation — not from approve/deny
    /// semantics. Read-only is green, write-local is amber, external is
    /// orange, destructive is red. When risk data isn't available
    /// (e.g. older server, no pendingApproval), affirmative falls back
    /// to neutral accent so we never imply "safe" by accident.
    /// Decline buttons (No / Deny / Cancel) stay neutral grey because
    /// declining is always the safe path. Tim 2026-05-04: "Colour isn't
    /// driven by approve/deny but by the risk of the decision."
    private struct OptionStyle {
        let foreground: Color
        let stroke: Color
        let fill: Color
    }

    private func promptOptionSemantic(_ label: String) -> OptionStyle {
        let lower = label.lowercased()
        if lower == "yes" || lower.hasPrefix("approve") {
            // Risk-coloured affirmative. If we have no risk data, use
            // accent — never green by default, since "no risk known" is
            // not the same as "read-only".
            let risk = pendingRisk
            if !risk.isEmpty {
                let c = riskColor(risk)
                return OptionStyle(
                    foreground: c,
                    stroke: c.opacity(0.5),
                    fill: c.opacity(0.12)
                )
            }
            return OptionStyle(
                foreground: AppTheme.accent,
                stroke: AppTheme.accent.opacity(0.5),
                fill: AppTheme.accent.opacity(0.12)
            )
        }
        if lower == "no" || lower == "deny" || lower == "cancel" || lower == "reject" {
            return OptionStyle(
                foreground: .gray,
                stroke: Color.gray.opacity(0.5),
                fill: Color.gray.opacity(0.12)
            )
        }
        return OptionStyle(
            foreground: AppTheme.accent,
            stroke: AppTheme.accent.opacity(0.4),
            fill: AppTheme.cardBackground
        )
    }

    // MARK: - Enriched-card button styling

    private enum EnrichedButtonRole {
        case primary    // First / Approve / Yes — green-on-fill
        case secondary  // Middle option — accent outline
        case decline    // Last / Deny / No — red outline
    }

    /// Decide button role from option label + position. The label is
    /// authoritative when it's a recognised verb (Approve/Yes/Deny/No);
    /// otherwise position governs (1st = primary, last = decline,
    /// middle = secondary).
    private func enrichedButtonRole(for label: String, total: Int, number: Int) -> EnrichedButtonRole {
        let lower = label.lowercased()
        if lower == "yes" || lower.hasPrefix("approve") {
            return .primary
        }
        if lower == "no" || lower == "deny" || lower == "cancel" || lower == "reject" {
            return .decline
        }
        if number == 1 {
            return .primary
        }
        if number == total {
            return .decline
        }
        return .secondary
    }

    /// Re-label option text where it improves clarity. "Yes" alone reads
    /// thin on a permission card; show "Approve" for the primary slot of
    /// a 2-option hook prompt.
    private func enrichedButtonText(for opt: PaneOption, role: EnrichedButtonRole) -> String {
        let lower = opt.label.lowercased()
        if role == .primary && lower == "yes" {
            return "Approve"
        }
        if role == .decline && lower == "no" {
            return "Deny"
        }
        return opt.label
    }

    private func enrichedButtonForeground(role: EnrichedButtonRole) -> Color {
        switch role {
        case .primary: return .black
        case .secondary: return AppTheme.accent
        case .decline: return .gray
        }
    }

    /// The Approve button is colour-coded by the RISK of the underlying
    /// operation, not by the affirmative/decline semantic. Read-only is
    /// green, local write is amber, external is orange, destructive is
    /// red. Tim 2026-05-04: "Colour isn't driven by approve/deny but by
    /// the risk of the decision."
    @ViewBuilder
    private func enrichedButtonBackground(role: EnrichedButtonRole) -> some View {
        switch role {
        case .primary:
            RoundedRectangle(cornerRadius: 8).fill(riskColor(pendingRisk))
        case .secondary:
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(AppTheme.accent.opacity(0.5), lineWidth: 1)
        case .decline:
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.gray.opacity(0.5), lineWidth: 1)
        }
    }

    // MARK: - Risk Badge

    private func riskColor(_ risk: String) -> Color {
        switch risk {
        case "read": return .green
        case "write_local": return .yellow
        case "external": return .orange
        case "destructive": return .red
        case "neutral": return .gray
        default: return .gray
        }
    }

    private func riskLabel(_ risk: String) -> String {
        switch risk {
        case "read": return "READ ONLY"
        case "write_local": return "LOCAL WRITE"
        case "external": return "EXTERNAL"
        case "destructive": return "DESTRUCTIVE"
        case "neutral": return "NEUTRAL"
        default: return risk.uppercased()
        }
    }

    // MARK: - Enriched Prompt Card

    private var enrichedPromptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(riskLabel(pendingRisk))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(riskColor(pendingRisk).cornerRadius(4))

                if !pendingBlastRadius.isEmpty {
                    Text(pendingBlastRadius)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            Text(pendingIntent)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !pendingCommandPreview.isEmpty {
                Text(pendingCommandPreview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Render N buttons matching the actual prompt options. For
            // hook-driven asks this is 2 buttons (Yes -> green Approve,
            // No -> red Deny). For native Claude Code permissions it's 3
            // (Approve / Allow for session / Deny). Falls back to legacy
            // 3-button hardcoded layout when pendingOptions is empty.
            HStack(spacing: 8) {
                if !pendingOptions.isEmpty {
                    ForEach(pendingOptions) { opt in
                        let role = enrichedButtonRole(for: opt.label, total: pendingOptions.count, number: opt.number)
                        Button {
                            sendPromptChoice(opt.number)
                        } label: {
                            Text(enrichedButtonText(for: opt, role: role))
                                .font(.system(size: role == .primary ? 13 : 12, weight: role == .primary ? .bold : .medium))
                                .foregroundColor(enrichedButtonForeground(role: role))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(enrichedButtonBackground(role: role))
                        }
                    }
                } else {
                    // Legacy fallback (server didn't send pendingOptions).
                    Button {
                        sendPromptChoice(1)
                    } label: {
                        Text("Approve")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(AppTheme.accent.cornerRadius(8))
                    }
                    Button {
                        sendPromptChoice(2)
                    } label: {
                        Text("Allow for session")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(AppTheme.accent.opacity(0.5), lineWidth: 1)
                            )
                    }
                    Button {
                        sendPromptChoice(3)
                    } label: {
                        Text("Deny")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(riskColor(pendingRisk).opacity(0.4), lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Queue Edit Button (A2b — iPhone has no up-arrow key)

    private var queueEditRow: some View {
        HStack {
            Button {
                guard !isRecalling else { return }
                isRecalling = true
                let window = activeWindowIndex
                var stack = sentTextStack[window] ?? []
                let recalled = stack.popLast()
                sentTextStack[window] = stack
                if let recalled {
                    perTabInput[window] = recalled
                    saveDrafts()
                }
                inputFocused = true
                Task {
                    _ = await model.httpSendKey("Up", window: window)
                    if recalled != nil {
                        _ = await model.httpSendKey("C-u", window: window)
                    } else {
                        // Stack empty (post-restart, or messages sent before
                        // this build). Up has populated Claude Code's
                        // box-bordered prompt area in tmux; scrape it back
                        // into iOS so the user can edit. Capture twice in
                        // case the first poll lands before tmux re-renders.
                        var scraped = ""
                        for delayMs in [250, 400] {
                            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                            if let pane = await captureRecentPane(window: window) {
                                if let text = extractRecalledPrompt(from: pane), !text.isEmpty {
                                    scraped = text
                                    break
                                }
                            }
                        }
                        if !scraped.isEmpty {
                            await MainActor.run {
                                perTabInput[window] = scraped
                                saveDrafts()
                            }
                            _ = await model.httpSendKey("C-u", window: window)
                        }
                    }
                    fastPollUntil = Date().addingTimeInterval(5)
                    await refreshPane()
                    await MainActor.run { isRecalling = false }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11))
                    Text("Edit queued messages")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(AppTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(AppTheme.accent.opacity(0.4), lineWidth: 1)
                )
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Pull the tail of the tmux pane via the conversation server's
    /// HTTP capture endpoint. The HTTP path is the same one the polling
    /// loop already uses, so it works regardless of SSH state and
    /// without the OS-default 75s TCP timeout cliff that an SSH-first
    /// design has on a stale-but-`isConnected` socket.
    private func captureRecentPane(window: Int) async -> String? {
        await model.httpCaptureTmux(window: window)
    }

    /// Strip ANSI CSI escape sequences (colours, cursor moves) from a
    /// pane line so prefix/suffix checks against the box-drawing
    /// characters work even when Claude Code emits coloured borders.
    /// Pattern: ESC `[` … final-byte where the final byte is in the
    /// 0x40-0x7E range. We deliberately do not handle every CSI variant
    /// — just the SGR / cursor cases tmux capture-pane is likely to
    /// produce.
    private static let ansiCSIRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[\\x40-\\x7E]")
    }()

    private func stripANSI(_ raw: String) -> String {
        guard let regex = Self.ansiCSIRegex else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    /// Find the recalled-prompt text inside Claude Code's box-bordered
    /// input area. The TUI renders queued messages as
    ///   ╭───────────────────╮
    ///   │ > some queued msg │
    ///   ╰───────────────────╯
    /// after Up is pressed. Walk the pane bottom-up; require a `│ > … │`
    /// line that has a `╰` border within 3 lines below it (anchors the
    /// match to a real prompt frame, not arbitrary tool-output rows
    /// that happen to start with `>`). Returns nil if no anchored prompt
    /// is present.
    private func extractRecalledPrompt(from pane: String) -> String? {
        let lines = pane.components(separatedBy: "\n").map(stripANSI)
        for idx in (0..<lines.count).reversed() {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("│"), trimmed.hasSuffix("│") else { continue }
            var inner = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespaces)
            if inner.hasPrefix("> ") {
                inner = String(inner.dropFirst(2))
            } else if inner.hasPrefix(">") {
                inner = String(inner.dropFirst())
            } else if inner.hasPrefix("❯ ") {
                inner = String(inner.dropFirst(2))
            } else if inner.hasPrefix("❯") {
                inner = String(inner.dropFirst())
            } else {
                continue
            }
            // Anchor: a real prompt frame has `╰` within the next few
            // lines. Without this, any `│ > foo │`-shaped row in tool
            // output would match.
            let lookahead = min(idx + 4, lines.count)
            var anchored = false
            if idx + 1 < lookahead {
                for j in (idx + 1)..<lookahead {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("╰") { anchored = true; break }
                }
            }
            guard anchored else { continue }
            let text = inner.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - Prompt Option Buttons

    private var promptOptionsRow: some View {
        Group {
            if hasEnrichedPrompt {
                enrichedPromptCard
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(effectivePromptOptions) { opt in
                            let semantic = promptOptionSemantic(opt.label)
                            Button {
                                sendPromptChoice(opt.number)
                            } label: {
                                HStack(spacing: 6) {
                                    Text("\(opt.number)")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(semantic.foreground)
                                    Text(opt.label)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(semantic.fill)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(semantic.stroke, lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(AppTheme.background)
                .frame(maxHeight: 52)
            }
        }
    }

    // MARK: - Input Section

    private var inputSection: some View {
        let currentInput = perTabInput[activeWindowIndex] ?? ""
        let isEmpty = currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                // Esc button — clears local input AND sends Escape to tmux
                // (unblocks stuck Claude Code TUI state)
                Button {
                    perTabInput[activeWindowIndex] = ""
                    saveDrafts()
                    Task { await model.httpSendEscape(window: activeWindowIndex) }
                } label: {
                    Text("esc")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(AppTheme.dimText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(AppTheme.cardBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(AppTheme.dimText.opacity(0.4), lineWidth: 1)
                                )
                        )
                }

                TextEditor(text: inputText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .background(AppTheme.cardBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(AppTheme.accent.opacity(0.3), lineWidth: 1)
                    )
                    .focused($inputFocused)

                Button {
                    sendInput()
                } label: {
                    if isSending {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(AppTheme.background)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(isEmpty ? AppTheme.dimText : AppTheme.accent)
                    }
                }
                .disabled(isSending || isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(AppTheme.cardBackground.opacity(0.95))
    }

    // MARK: - Actions

    /// Combine uploaded file paths with any prose typed into the active
    /// tab's input field and submit them as one message. If no prose is
    /// pending, paste the paths to the tmux pane unconditionally
    /// (preserves the old "drop a file alone" workflow). Either way,
    /// clears the consumption queue so the same paths don't fire twice.
    private func consumeUploadedPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let consumed = paths
        pendingPathsToConsume = []
        let pathsText = consumed.joined(separator: " ")
        let currentInput = perTabInput[activeWindowIndex] ?? ""
        let prose = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prose.isEmpty {
            perTabInput[activeWindowIndex] = pathsText + " " + prose
            sendInput()
        } else {
            let window = activeWindowIndex
            Task {
                let ok = await model.httpSendText(pathsText + " ", window: window)
                if !ok {
                    toastMessage = "Upload paths failed to send"
                }
            }
        }
    }

    private func sendInput() {
        let current = perTabInput[activeWindowIndex] ?? ""
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        var stack = sentTextStack[activeWindowIndex] ?? []
        stack.append(text)
        if stack.count > 20 { stack.removeFirst(stack.count - 20) }
        sentTextStack[activeWindowIndex] = stack

        isSending = true
        let textToSend = text
        let window = activeWindowIndex
        perTabInput[activeWindowIndex] = ""
        saveDrafts()
        // Submitting any text resolves whatever prompt the buttons belonged to
        // (either CC consumes the keys as a permission response, or the user
        // has moved past the prompt). Clear optimistically so the button row
        // disappears immediately instead of waiting for the next poll.
        promptOptions = []
        isUserScrolledUp = false // auto-scroll to see response

        // Kick a local Live Activity scoped to THIS tab (mobile-<windowIndex>)
        // so multiple concurrent tabs each get their own Island + lock-screen
        // card rather than fighting over a single aggregated activity. This
        // matches Apple's recommended pattern (Uber/Clock/sports apps all
        // use one Activity per discrete task).
        let laSessionLabel = "mobile-\(window)"
        Task { @MainActor in
            if #available(iOS 16.2, *) {
                _ = LiveActivityManager.shared.startLocalActivity(
                    sessionLabel: laSessionLabel,
                    headline: "Working…"
                )
            }
        }

        Task {
            let textOk = await model.httpSendText(textToSend, window: window)
            let enterOk = textOk ? await model.httpSendEnter(window: window) : false
            isSending = false
            if !textOk || !enterOk {
                perTabInput[activeWindowIndex] = textToSend
                toastMessage = "Send failed — check connection"
                return
            }
            fastPollUntil = Date().addingTimeInterval(30)
            await refreshPane()
            triggerResponseWatch()
        }
    }

    private func triggerResponseWatch() {
        guard let url = URL(string: "\(server.baseURL)/watch-tmux") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.authToken.isEmpty {
            request.setValue("Bearer \(server.authToken)", forHTTPHeaderField: "Authorization")
        }
        // session = "mobile-<window>" so the tmux watcher + Live Activity
        // fallback both scope to this specific tab.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "session": "mobile",                              // actual tmux session name
            "label": "mobile-\(activeWindowIndex)",           // LA session label
        ])
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        // Structured async loop instead of a RunLoop Timer. Timers on
        // RunLoop.main — even in .common mode — were still going silent on
        // device, leaving the pane stale until a view-lifecycle event
        // (tab switch / app foreground) forced a refresh. Task.sleep uses
        // the cooperative scheduler, not RunLoop, so it can't be starved
        // by UIKit interactions. iOS still suspends the task when the app
        // backgrounds; onAppear restarts it.
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await refreshPane()
                let ns: UInt64 = (Date() < fastPollUntil) ? 400_000_000 : 1_500_000_000
                try? await Task.sleep(nanoseconds: ns)
            }
        }
        splitLog.info("Polling started (async loop; 400ms fast / 1.5s idle)")
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refreshPane() async {
        // Read through `@State pollTarget`, NOT the `let activeWindowIndex`
        // parameter. The polling Task captured the initial struct; its
        // `self.activeWindowIndex` is frozen to whatever tab was active
        // when startPolling ran, and never updates. @State goes through
        // a shared backing store, so stale struct captures still read
        // current values.
        let capturedIndex = pollTarget
        guard let content = await model.httpCaptureTmux(window: capturedIndex) else {
            splitLog.debug("refreshPane: capture failed for window \(capturedIndex)")
            return
        }

        hasLoadedOnce = true

        let hash = content.hashValue
        let prev = perTabPaneHash[capturedIndex] ?? 0
        let contentChanged = hash != prev

        if contentChanged {
            perTabPaneHash[capturedIndex] = hash
            let lines = content.components(separatedBy: "\n")
            let types = classifyLines(lines)
            let paneLineObjects = zip(lines, types).enumerated().map { idx, pair in
                PaneLine(id: idx, text: pair.0, lineType: pair.1)
            }
            perTabLines[capturedIndex] = paneLineObjects

            // Notify parent of captured text (only for the visible tab)
            if capturedIndex == pollTarget {
                onCapturedText?(lines.joined(separator: "\n"))
            }
        }

        // Re-run prompt-option detection on the active tab, but only when
        // the typed contract (pendingApproval) is not active. When the server
        // supplies a structured prompt via /tmux-windows, the typed contract
        // is the single source of truth — the scraper would only produce
        // stale or conflicting results.
        if capturedIndex == pollTarget && !pendingApproval {
            let result = detectPromptOptionsWithReason(perTabLines[capturedIndex] ?? [])
            let prevOpts = promptOptions
            if result.options != promptOptions {
                promptOptions = result.options
            }
            logButtonTransition(prev: prevOpts, next: result.options,
                reason: "poll/\(result.reason)",
                evidence: result.evidence, activeTab: capturedIndex)

            let lines = perTabLines[capturedIndex] ?? []
            let hasQueueHint = lines.suffix(10).contains {
                $0.text.lowercased().contains("press up")
            }
            if hasQueueHint != showQueueEditButton {
                showQueueEditButton = hasQueueHint
            }
        }
    }
}
