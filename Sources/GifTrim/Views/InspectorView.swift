import AppKit
import GifTrimCore
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $editor.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Image(systemName: tab.symbol).help(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Text(editor.inspectorTab.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            Divider().padding(.top, 8)
            ScrollView {
                Group {
                    switch editor.inspectorTab {
                    case .output: OutputPanel(editor: editor)
                    case .crop: CropPanel(editor: editor)
                    case .text: TextPanel(editor: editor)
                    case .image: ImagePanel(editor: editor)
                    case .filter: FilterPanel(editor: editor)
                    case .frames: FramesPanel(editor: editor)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Shared controls

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            // Quantize in the binding instead of Slider(step:), which draws a tick per step.
            Slider(value: Binding(get: { value }, set: { v in
                if let step { value = (v / step).rounded() * step } else { value = v }
            }), in: range) { editing in if !editing { onCommit() } }
        }
    }
}

/// Toggle-like button with a clearly visible selected state.
struct ChipButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

extension Binding where Value == Double {
    init(int: Binding<Int>) {
        self.init(get: { Double(int.wrappedValue) }, set: { int.wrappedValue = Int($0.rounded()) })
    }
}

// MARK: - Output

private struct OutputPanel: View {
    @Bindable var editor: EditorModel
    @State private var targetKB: String = ""
    @State private var fitting = false

    var body: some View {
        let maxWidth = Double(editor.project.crop.clamped().pixelRect(in: editor.source.size).width)
        VStack(alignment: .leading, spacing: 14) {
            Menu("预设") {
                ForEach(ExportPreset.all) { preset in
                    Button(preset.name) { apply(preset, maxWidth: Int(maxWidth)) }
                }
            }

            SectionHeader(title: "尺寸")
            LabeledSlider(title: "宽度", value: Binding(int: $editor.project.settings.width),
                          range: min(32, maxWidth)...max(33, maxWidth), step: 1,
                          format: { "\(Int($0)) px" }, onCommit: editor.projectDidChange)
            Text("输出 \(Int(editor.outputSize.width)) × \(Int(editor.outputSize.height))")
                .font(.caption).foregroundStyle(.secondary)

            SectionHeader(title: "时间")
            if editor.source.isDiscrete {
                Toggle("保留原始帧时长", isOn: $editor.project.settings.useSourceTiming)
                    .onChange(of: editor.project.settings.useSourceTiming) { editor.projectDidChange() }
            }
            if !(editor.source.isDiscrete && editor.project.settings.useSourceTiming) {
                LabeledSlider(title: "帧率", value: $editor.project.settings.fps, range: 1...ExportSettings.maxFPS, step: 1,
                              format: { "\(Int($0)) fps" }, onCommit: editor.projectDidChange)
            }
            LabeledSlider(title: "速度", value: $editor.project.settings.speed, range: 0.25...4, step: 0.05,
                          format: { String(format: "%.2fx", $0) }, onCommit: editor.projectDidChange)
            Picker("播放方式", selection: $editor.project.settings.playbackMode) {
                Text("正放").tag(PlaybackMode.forward)
                Text("倒放").tag(PlaybackMode.reverse)
                Text("来回").tag(PlaybackMode.bounce)
            }
            .pickerStyle(.segmented)
            .onChange(of: editor.project.settings.playbackMode) { editor.projectDidChange() }
            Picker("循环", selection: $editor.project.settings.repeatCount) {
                Text("无限循环").tag(0)
                Text("只播一次").tag(-1)
                ForEach([1, 2, 3, 5], id: \.self) { n in Text("重复 \(n) 次").tag(n) }
            }
            .onChange(of: editor.project.settings.repeatCount) { editor.projectDidChange() }

            SectionHeader(title: "质量")
            LabeledSlider(title: "画质", value: Binding(int: $editor.project.settings.quality), range: 1...100, step: 1,
                          format: { "\(Int($0))" }, onCommit: editor.projectDidChange)
            optionalSlider(title: "有损压缩（越低越小）", value: $editor.project.settings.lossyQuality)
            optionalSlider(title: "运动质量（越低越小）", value: $editor.project.settings.motionQuality)
            Toggle("快速编码（质量略低）", isOn: $editor.project.settings.fast)
                .onChange(of: editor.project.settings.fast) { editor.projectDidChange() }

            SectionHeader(title: "目标大小")
            HStack {
                TextField("例如 2048", text: $targetKB)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Text("KB")
                Button(fitting ? "计算中…" : "自动调整宽度") { fit() }
                    .disabled(fitting || Int64(targetKB) == nil)
            }
            Text("通过试编码搜索最合适的宽度。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func optionalSlider(title: String, value: Binding<Int?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil },
                                        set: { value.wrappedValue = $0 ? 80 : nil; editor.projectDidChange() }))
            if value.wrappedValue != nil {
                LabeledSlider(title: "", value: Binding(get: { Double(value.wrappedValue ?? 80) },
                                                        set: { value.wrappedValue = Int($0) }),
                              range: 1...100, step: 1, format: { "\(Int($0))" }, onCommit: editor.projectDidChange)
            }
        }
    }

    private func apply(_ preset: ExportPreset, maxWidth: Int) {
        editor.project.settings.width = min(preset.width ?? maxWidth, maxWidth)
        editor.project.settings.fps = preset.fps
        editor.project.settings.quality = preset.quality
        editor.projectDidChange()
    }

    private func fit() {
        guard let kb = Int64(targetKB) else { return }
        fitting = true
        let project = editor.project
        let source = editor.source
        Task {
            defer { fitting = false }
            if let r = try? await Exporter.fitWidth(project: project, source: source, targetBytes: kb * 1024) {
                editor.project.settings.width = r.width
                editor.projectDidChange()
            }
        }
    }
}

// MARK: - Crop

private struct CropPanel: View {
    @Bindable var editor: EditorModel

    private let ratios: [(String, Double?)] = [
        ("自由", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("2:1", 2),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在画面上拖动裁剪框和控制点。").font(.callout).foregroundStyle(.secondary)
            SectionHeader(title: "比例")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], spacing: 6) {
                ForEach(ratios, id: \.0) { name, ratio in
                    ChipButton(title: name, selected: editor.cropAspect == ratio) { setAspect(ratio) }
                }
            }
            let px = editor.project.crop.clamped().pixelRect(in: editor.source.size)
            SectionHeader(title: "区域（像素）")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    pixelField("X", value: px.minX, max: editor.source.size.width) { v in
                        editor.project.crop.x = v / editor.source.size.width
                    }
                    pixelField("Y", value: px.minY, max: editor.source.size.height) { v in
                        editor.project.crop.y = v / editor.source.size.height
                    }
                }
                GridRow {
                    pixelField("宽", value: px.width, max: editor.source.size.width) { v in
                        editor.project.crop.width = v / editor.source.size.width
                    }
                    pixelField("高", value: px.height, max: editor.source.size.height) { v in
                        editor.project.crop.height = v / editor.source.size.height
                    }
                }
            }
            Text("原始尺寸 \(Int(editor.source.size.width)) × \(Int(editor.source.size.height))")
                .font(.caption).foregroundStyle(.secondary)
            Button("重置裁剪") {
                editor.project.crop = .full
                editor.cropAspect = nil
                editor.projectDidChange()
            }
        }
    }

    private func pixelField(_ label: String, value: CGFloat, max: CGFloat, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).frame(width: 18, alignment: .leading)
            TextField(label, value: Binding(get: { Int(value) }, set: { v in
                set(Double(Swift.min(Swift.max(0, CGFloat(v)), max)))
                editor.project.crop = editor.project.crop.clamped()
                editor.projectDidChange()
            }), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
        }
    }

    private func setAspect(_ ratio: Double?) {
        editor.cropAspect = ratio
        if let ratio {
            editor.project.crop = .centered(aspect: ratio, in: editor.source.size)
        }
        editor.projectDidChange()
    }
}

// MARK: - Text

private struct TextPanel: View {
    @Bindable var editor: EditorModel
    @FocusState private var focused: Bool

    private static let fonts: [(String, String)] = [
        ("Helvetica Neue 粗体", "HelveticaNeue-Bold"),
        ("Impact", "Impact"),
        ("苹方 中粗", "PingFangSC-Semibold"),
        ("苹方 常规", "PingFangSC-Regular"),
        ("Arial Black", "Arial-Black"),
        ("Futura 粗体", "Futura-Bold"),
        ("Avenir Next 粗体", "AvenirNext-Bold"),
        ("Menlo", "Menlo-Bold"),
        ("Marker Felt", "MarkerFelt-Wide"),
        ("Chalkboard", "ChalkboardSE-Bold"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { editor.addText() } label: { Label("添加文字", systemImage: "plus") }
                Spacer()
            }
            if editor.project.texts.isEmpty {
                Text("还没有文字。添加后可在画面上拖动位置。").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("图层", selection: $editor.selectedTextID) {
                    ForEach(editor.project.texts) { t in
                        Text(t.text.split(separator: "\n").first.map(String.init) ?? "（空）").tag(Optional(t.id))
                    }
                }
            }
            if let i = editor.project.texts.firstIndex(where: { $0.id == editor.selectedTextID }) {
                editorFor(index: i)
            }
        }
        .onAppear {
            if editor.selectedTextID == nil { editor.selectedTextID = editor.project.texts.first?.id }
        }
    }

    @ViewBuilder
    private func editorFor(index i: Int) -> some View {
        let t = $editor.project.texts[i]
        TextEditor(text: t.text)
            .font(.body)
            .frame(height: 64)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .focused($focused)
            .onChange(of: t.wrappedValue.text) { editor.projectDidChange() }
            .onChange(of: editor.focusTextEditor) {
                if editor.focusTextEditor { focused = true; editor.focusTextEditor = false }
            }
            .onAppear {
                if editor.focusTextEditor { focused = true; editor.focusTextEditor = false }
            }

        Picker("字体", selection: t.fontName) {
            ForEach(Self.fonts, id: \.1) { name, ps in Text(name).tag(ps) }
        }
        .onChange(of: t.wrappedValue.fontName) { editor.projectDidChange() }

        LabeledSlider(title: "字号", value: t.fontSize, range: 0.03...0.4,
                      format: { "\(Int($0 * 100))%" }, onCommit: editor.projectDidChange)

        HStack {
            ColorPicker("颜色", selection: colorBinding(t.color))
            Spacer()
            ColorPicker("描边", selection: colorBinding(t.strokeColor))
        }
        LabeledSlider(title: "描边粗细", value: t.strokeWidth, range: 0...0.25,
                      format: { "\(Int($0 * 100))%" }, onCommit: editor.projectDidChange)
        Toggle("阴影", isOn: t.shadow)
            .onChange(of: t.wrappedValue.shadow) { editor.projectDidChange() }
        Picker("对齐", selection: t.alignment) {
            Image(systemName: "text.alignleft").tag(TextAlignmentMode.left)
            Image(systemName: "text.aligncenter").tag(TextAlignmentMode.center)
            Image(systemName: "text.alignright").tag(TextAlignmentMode.right)
        }
        .pickerStyle(.segmented)
        .onChange(of: t.wrappedValue.alignment) { editor.projectDidChange() }

        HStack {
            Text("位置")
            Button("顶部") { t.wrappedValue.position = NormalizedPoint(x: 0.5, y: 0.13); editor.projectDidChange() }
            Button("居中") { t.wrappedValue.position = NormalizedPoint(x: 0.5, y: 0.5); editor.projectDidChange() }
            Button("底部") { t.wrappedValue.position = NormalizedPoint(x: 0.5, y: 0.87); editor.projectDidChange() }
        }
        .controlSize(.small)

        TimeRangeEditor(editor: editor, start: t.startTime, end: t.endTime)

        Button(role: .destructive) { editor.removeText(t.wrappedValue.id) } label: {
            Label("删除这段文字", systemImage: "trash")
        }
    }

    private func colorBinding(_ c: Binding<RGBAColor>) -> Binding<Color> {
        Binding(get: { Color(cgColor: c.wrappedValue.cgColor) },
                set: { new in
                    if let cg = NSColor(new).usingColorSpace(.sRGB)?.cgColor {
                        c.wrappedValue = RGBAColor(cgColor: cg)
                        editor.projectDidChange()
                    }
                })
    }
}

/// Edits an optional [start, end] visibility range in source time.
struct TimeRangeEditor: View {
    let editor: EditorModel
    @Binding var start: Double?
    @Binding var end: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("只在部分时间显示", isOn: Binding(get: { start != nil || end != nil }, set: { on in
                if on {
                    start = editor.project.trimStart
                    end = editor.project.trimEnd
                } else {
                    start = nil
                    end = nil
                }
                editor.projectDidChange()
            }))
            if start != nil || end != nil {
                HStack {
                    Text("\(formatTime(start ?? 0)) – \(formatTime(end ?? editor.source.duration))")
                        .monospacedDigit()
                    Spacer()
                }
                .font(.callout)
                HStack {
                    Button("开始 = 播放头") { start = editor.currentTime; editor.projectDidChange() }
                    Button("结束 = 播放头") { end = editor.currentTime; editor.projectDidChange() }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Image overlay

private struct ImagePanel: View {
    @Bindable var editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { pick() } label: { Label("添加图片 / Logo", systemImage: "plus") }
            if editor.project.images.isEmpty {
                Text("可添加 PNG（支持透明）作为水印或贴纸，在画面上拖动位置。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("图层", selection: $editor.selectedImageID) {
                    ForEach(editor.project.images) { img in
                        Text(img.name.isEmpty ? "图片" : img.name).tag(Optional(img.id))
                    }
                }
            }
            if let i = editor.project.images.firstIndex(where: { $0.id == editor.selectedImageID }) {
                let img = $editor.project.images[i]
                LabeledSlider(title: "大小", value: img.width, range: 0.03...1,
                              format: { "\(Int($0 * 100))%" }, onCommit: editor.projectDidChange)
                LabeledSlider(title: "不透明度", value: img.opacity, range: 0.05...1,
                              format: { "\(Int($0 * 100))%" }, onCommit: editor.projectDidChange)
                TimeRangeEditor(editor: editor, start: img.startTime, end: img.endTime)
                Button(role: .destructive) { editor.removeImage(img.wrappedValue.id) } label: {
                    Label("删除图片", systemImage: "trash")
                }
            }
        }
        .onAppear {
            if editor.selectedImageID == nil { editor.selectedImageID = editor.project.images.first?.id }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor.addImage(url: url)
    }
}

// MARK: - Filters

private struct FilterPanel: View {
    @Bindable var editor: EditorModel

    private static let effects: [(ColorEffect, String)] = [
        (.none, "无"), (.mono, "单色"), (.noir, "黑白"), (.tonal, "色调"), (.sepia, "怀旧"),
        (.chrome, "铬黄"), (.fade, "褪色"), (.instant, "拍立得"), (.process, "冲印"), (.transfer, "转印"),
        (.invert, "反相"), (.posterize, "色调分离"), (.comic, "漫画"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "效果")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) {
                ForEach(Self.effects, id: \.0) { effect, name in
                    ChipButton(title: name, selected: editor.project.adjustments.effect == effect) {
                        editor.project.adjustments.effect = effect
                        editor.projectDidChange()
                    }
                }
            }
            SectionHeader(title: "调整")
            LabeledSlider(title: "亮度", value: $editor.project.adjustments.brightness, range: -0.5...0.5,
                          onCommit: editor.projectDidChange)
            LabeledSlider(title: "对比度", value: $editor.project.adjustments.contrast, range: 0.5...1.5,
                          onCommit: editor.projectDidChange)
            LabeledSlider(title: "饱和度", value: $editor.project.adjustments.saturation, range: 0...2,
                          onCommit: editor.projectDidChange)
            LabeledSlider(title: "锐化", value: $editor.project.adjustments.sharpness, range: 0...2,
                          onCommit: editor.projectDidChange)
            LabeledSlider(title: "暗角", value: $editor.project.adjustments.vignette, range: 0...2,
                          onCommit: editor.projectDidChange)
            Button("全部重置") {
                editor.project.adjustments = Adjustments()
                editor.projectDidChange()
            }
        }
    }
}

// MARK: - Frames

private struct FramesPanel: View {
    @Bindable var editor: EditorModel
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let frames = editor.project.customFrames {
                HStack {
                    Text("\(frames.count) 帧 · \(String(format: "%.2f", frames.reduce(0) { $0 + $1.delay })) 秒")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Button("退出逐帧编辑") { editor.endFrameEditing(); selection.removeAll() }
                }
                HStack {
                    Button("删除所选") { delete() }.disabled(selection.isEmpty)
                    Button("复制所选") { duplicate() }.disabled(selection.isEmpty)
                    Menu("所选时长") {
                        ForEach([0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0], id: \.self) { d in
                            Button("\(Int(d * 1000)) ms") { setDelay(d) }
                        }
                    }
                    .disabled(selection.isEmpty)
                }
                .controlSize(.small)
                Text("点按选择，⌘ 点按多选。拖动可排序。")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                    ForEach(Array(frames.enumerated()), id: \.element.id) { i, f in
                        FrameCell(editor: editor, index: i, frame: f, selected: selection.contains(f.id))
                            .onTapGesture { toggle(f.id) }
                            .onDrag { NSItemProvider(object: f.id.uuidString as NSString) }
                            .onDrop(of: [.text], delegate: FrameDropDelegate(editor: editor, target: f.id))
                    }
                }
            } else {
                Text("逐帧编辑会把当前设置（截取范围、帧率、速度、播放方式）展开成帧列表，之后可以单独删除、复制、调整每帧时长或重新排序。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("当前将生成 \(editor.plannedFrames.count) 帧。")
                    .font(.callout)
                Button("开始逐帧编辑") { editor.beginFrameEditing() }
                    .disabled(editor.plannedFrames.count > 2000)
                if editor.plannedFrames.count > 2000 {
                    Text("帧数过多（>2000），请先缩短截取范围或降低帧率。").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        if let f = editor.project.customFrames?.first(where: { $0.id == id }) {
            editor.pause()
            editor.seek(to: f.sourceTime)
        }
    }

    private func delete() {
        guard var frames = editor.project.customFrames else { return }
        frames.removeAll { selection.contains($0.id) }
        if frames.isEmpty { return }
        editor.project.customFrames = frames
        selection.removeAll()
        editor.projectDidChange()
    }

    private func duplicate() {
        guard let frames = editor.project.customFrames else { return }
        var out: [FrameEdit] = []
        for f in frames {
            out.append(f)
            if selection.contains(f.id) { out.append(FrameEdit(sourceTime: f.sourceTime, delay: f.delay)) }
        }
        editor.project.customFrames = out
        editor.projectDidChange()
    }

    private func setDelay(_ d: Double) {
        guard var frames = editor.project.customFrames else { return }
        for i in frames.indices where selection.contains(frames[i].id) { frames[i].delay = d }
        editor.project.customFrames = frames
        editor.projectDidChange()
    }
}

private struct FrameCell: View {
    let editor: EditorModel
    let index: Int
    let frame: FrameEdit
    let selected: Bool

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Color.black
                if let img = editor.frameThumbnail(for: frame.sourceTime) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(editor.source.size.width / max(1, editor.source.size.height), contentMode: .fit)
            .frame(maxHeight: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 2) {
                Text("\(index + 1)").bold()
                Spacer()
                Text("\(Int((frame.delay * 1000).rounded()))ms")
            }
            .font(.system(size: 9).monospacedDigit())
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

private struct FrameDropDelegate: DropDelegate {
    let editor: EditorModel
    let target: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let item = info.itemProviders(for: [.text]).first else { return false }
        _ = item.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let source = UUID(uuidString: s) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard var frames = editor.project.customFrames,
                          let from = frames.firstIndex(where: { $0.id == source }),
                          let to = frames.firstIndex(where: { $0.id == target }), from != to else { return }
                    let f = frames.remove(at: from)
                    frames.insert(f, at: to)
                    editor.project.customFrames = frames
                    editor.projectDidChange()
                }
            }
        }
        return true
    }
}
