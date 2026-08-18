import SwiftUI

/// The Creative Editor window: a live preview of the vertical composition on
/// the left, controls on the right, and a render that replaces the video.
struct CreativeEditorView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CreativeEditorModel
    @State private var isDragging = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
                .frame(width: 300)
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 560)
        .background(VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow))
        .onDisappear { model.teardown() }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let box = fittedBox(in: geo.size)
                ZStack {
                    Color.black.opacity(0.25)
                    if model.isLoading {
                        ProgressView("Building preview…")
                            .font(.cueCaption)
                    } else if let error = model.loadError {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(error).font(.cueCaption).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Theme.secondaryText)
                        .padding()
                    } else {
                        ZStack {
                            EditorPlayerView(player: model.player)
                            if model.hasCamera { personHandle(in: box) }
                        }
                        .frame(width: box.width, height: box.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Text("Drag yourself anywhere in the frame. What you see here is what gets rendered.")
                .font(.cueCaption)
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
    }

    /// The preview box, letterboxed inside the available space at the output's
    /// own aspect ratio.
    private func fittedBox(in size: CGSize) -> CGSize {
        let aspect = max(0.1, model.previewAspect)
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGSize(width: max(1, width), height: max(1, height))
    }

    /// A grab puck on the person, plus a dashed outline showing where they sit.
    /// The cut-out is mostly transparent, so without this there'd be nothing to
    /// take hold of.
    ///
    /// Only the puck is interactive: a full-size grab area would cover the
    /// player's own controls, and dragging from anywhere would make a stray
    /// click on Play fling the person across the frame.
    private func personHandle(in box: CGSize) -> some View {
        let placement = model.placement
        let height = box.height * CGFloat(placement.size)
        let width = height * model.cameraAspect
        let center = CGPoint(x: CGFloat(placement.centerX) * box.width,
                             y: CGFloat(placement.centerY) * box.height)
        let puck: CGFloat = 44

        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: isDragging ? 2 : 1.5,
                                                 dash: isDragging ? [] : [6, 4]))
                .foregroundStyle(Theme.accent.opacity(isDragging ? 0.95 : 0.55))
                .frame(width: width, height: height)
                .position(center)
                .allowsHitTesting(false)

            Circle()
                .fill(Theme.accent.opacity(isDragging ? 0.9 : 0.65))
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .overlay(
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                )
                .frame(width: puck, height: puck)
                // Keep the puck on the preview even when the person is framed
                // past the bottom edge, so it can always be grabbed back.
                .position(x: min(max(center.x, puck / 2), box.width - puck / 2),
                          y: min(max(center.y, puck / 2), box.height - puck / 2))
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            isDragging = true
                            model.movePerson(toCenterX: value.location.x / box.width,
                                             centerY: value.location.y / box.height)
                        }
                        .onEnded { _ in isDragging = false }
                )
                .help("Drag to move yourself around the frame")
        }
    }

    // MARK: Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                layoutCard
                if model.hasCamera { personCard }
                captionCard
                renderCard
            }
        }
        .scrollIndicators(.never)
    }

    private var layoutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Layout")
                ForEach(CreativeLayout.allCases) { layout in
                    // "Just me" with no camera would render an empty frame.
                    let available = layout != .personOnly || model.hasCamera
                    Button {
                        model.setLayout(layout)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: layout.systemImage)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(layout.title).font(.system(size: 12.5, weight: .semibold))
                                Text(available ? layout.detail : "This recording has no camera.")
                                    .font(.cueCaption)
                                    .foregroundStyle(Theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            if model.layout == layout {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background {
                            if model.layout == layout {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Theme.accent.opacity(0.10))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                    .opacity(available ? 1 : 0.45)
                }
            }
        }
    }

    private var personCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("You")
                    Spacer()
                    Button("Reset") { model.resetPlacement() }
                        .buttonStyle(.plain)
                        .font(.cueCaption)
                        .foregroundStyle(Theme.accent)
                }
                HStack(spacing: 10) {
                    Text("Size").font(.cueCaption).foregroundStyle(Theme.secondaryText)
                    Slider(
                        value: Binding(get: { model.placement.size },
                                       set: { model.resizePerson(to: $0) }),
                        in: 0.2...1.2
                    )
                }
                Toggle("Mirror me", isOn: Binding(get: { model.plan.mirrored },
                                                  set: { model.setMirrored($0) }))
                    .toggleStyle(.switch)
                    .font(.system(size: 12.5))
                Text("Your background is removed automatically, so only you appear over the screen.")
                    .font(.cueCaption)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var captionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Captions")
                if model.hasCaptions {
                    Toggle("Show captions", isOn: Binding(get: { model.plan.captionsEnabled == true },
                                                          set: { model.setCaptionsEnabled($0) }))
                        .toggleStyle(.switch)
                        .font(.system(size: 12.5))
                    CaptionStylePicker(
                        selection: Binding(get: { model.plan.captionStyle ?? .boldOutline },
                                           set: { model.setCaptionStyle($0) })
                    )
                    .disabled(model.plan.captionsEnabled != true)
                    .opacity(model.plan.captionsEnabled == true ? 1 : 0.45)
                } else {
                    Text("Add captions so people watching without sound still follow along.")
                        .font(.cueCaption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await model.generateCaptions() }
                    } label: {
                        Label(app.captionGenerator.phase.title ?? "Add captions",
                              systemImage: "captions.bubble")
                    }
                    .buttonStyle(.glassControl)
                    .disabled(app.captionGenerator.phase != .idle)
                }
            }
        }
    }

    private var renderCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    Task { await model.renderAndReplace() }
                } label: {
                    Label(model.isRendering ? "Rendering…" : "Render & Replace",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.prominentGlass)
                .disabled(model.isRendering || model.isLoading)

                Text("Replaces this recording's video. If it was already shared, the link is taken down so you can upload the new cut.")
                    .font(.cueCaption)
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Swatch grid of caption presets, each drawn with its own style.
struct CaptionStylePicker: View {
    @Binding var selection: CaptionStyle

    private let columns = [GridItem(.adaptive(minimum: 118), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(CaptionStyle.allCases) { style in
                Button {
                    selection = style
                } label: {
                    VStack(spacing: 5) {
                        CaptionStyleSwatch(style: style)
                            .frame(height: 42)
                        Text(style.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(selection == style ? Theme.accent : Theme.secondaryText)
                    }
                    .padding(5)
                    .background {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selection == style ? Theme.accent.opacity(0.12) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(selection == style ? Theme.accent.opacity(0.5) : .white.opacity(0.08))
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A miniature of what a caption looks like in this style, rendered with the
/// same code the video uses so the preview can't drift from the result.
struct CaptionStyleSwatch: View {
    let style: CaptionStyle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [.gray.opacity(0.55), .black.opacity(0.75)],
                                         startPoint: .top, endPoint: .bottom))
                if let image = sample(width: geo.size.width * 2) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func sample(width: CGFloat) -> NSImage? {
        let cue = CaptionCue(text: "Like this", start: 0, end: 1, words: nil)
        // A square-ish frame keeps the sampled font size close to what a real
        // portrait frame produces.
        let frame = CGSize(width: max(120, width), height: max(120, width))
        guard let ciImage = CaptionRenderer.rasterize(cue: cue,
                                                      activeWordIndex: style.highlightsSpokenWord ? 1 : nil,
                                                      style: style, renderSize: frame)
        else { return nil }
        let rep = NSCIImageRep(ciImage: ciImage)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
