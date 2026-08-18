import SwiftUI

/// The script panel's contents: an editor before you record, and a scrolling
/// prompter while you do.
struct TeleprompterView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var controller: TeleprompterController

    /// The script is edited through local state and written back on change.
    /// Binding the field straight to `preferences.scriptDraft` made every
    /// keystroke republish Preferences — which AppState forwards — rebuilding
    /// the whole view tree under the cursor while typing.
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            switch controller.mode {
            case .editing: editor
            case .prompting: prompter
            }
            Divider().opacity(0.4)
            controls
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { draft = preferences.scriptDraft }
        .onChange(of: draft) { _, text in
            if preferences.scriptDraft != text { preferences.scriptDraft = text }
        }
        .onChange(of: preferences.scriptDraft) { _, text in
            if draft != text { draft = text }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.aligncenter")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Script")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Text("Not recorded")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .help("This panel never appears in your video.")
            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Editing

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.system(size: preferences.teleprompterFontSize * 0.7))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            if draft.isEmpty {
                Text("Write or paste your script…")
                    .font(.system(size: preferences.teleprompterFontSize * 0.7))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Prompting

    private var prompter: some View {
        TeleprompterScroller(
            text: preferences.scriptDraft,
            fontSize: preferences.teleprompterFontSize,
            speed: preferences.teleprompterSpeed,
            isScrolling: $controller.isScrolling
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if controller.mode == .prompting {
                Button {
                    controller.isScrolling.toggle()
                } label: {
                    Image(systemName: controller.isScrolling ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(controller.isScrolling ? "Stop scrolling" : "Scroll automatically")

                Image(systemName: "hare")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                Slider(value: $preferences.teleprompterSpeed, in: 10...120)
                    .frame(maxWidth: .infinity)
                    .help("Scrolling speed")
            } else {
                Text("\(preferences.scriptDraft.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
            }

            Button {
                preferences.teleprompterFontSize = max(14, preferences.teleprompterFontSize - 2)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(preferences.teleprompterFontSize <= 14)

            Button {
                preferences.teleprompterFontSize = min(48, preferences.teleprompterFontSize + 2)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(preferences.teleprompterFontSize >= 48)
        }
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Scrolls the script by itself at a steady pace, pausing while the pointer is
/// over it so you can catch up or re-read a line.
private struct TeleprompterScroller: View {
    let text: String
    let fontSize: Double
    let speed: Double
    @Binding var isScrolling: Bool

    @State private var offset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var hovering = false
    @State private var lastTick: Date?

    private var maxOffset: CGFloat { max(0, contentHeight - viewportHeight * 0.5) }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                Text(text)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineSpacing(fontSize * 0.35)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        GeometryReader { inner in
                            Color.clear
                                .onAppear { contentHeight = inner.size.height }
                                .onChange(of: inner.size.height) { _, new in contentHeight = new }
                        }
                    }
                    .offset(y: -offset)
            }
            .scrollIndicators(.never)
            .onAppear { viewportHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, new in viewportHeight = new }
        }
        .onHover { hovering = $0 }
        .overlay(alignment: .top) {
            if hovering && isScrolling {
                Text("Paused while you point at it")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 4)
            }
        }
        .background {
            // A timeline ticks the offset forward; hovering simply stops the
            // clock rather than jumping the text when you move away.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isScrolling || hovering)) { context in
                Color.clear.onChange(of: context.date) { _, now in
                    advance(to: now)
                }
            }
        }
        .onChange(of: isScrolling) { _, running in
            if !running { lastTick = nil }
        }
    }

    private func advance(to now: Date) {
        defer { lastTick = now }
        guard isScrolling, !hovering, let last = lastTick else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0, elapsed < 1 else { return }
        offset = min(maxOffset, offset + CGFloat(elapsed * speed))
    }
}
