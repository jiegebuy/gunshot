import SwiftUI
import GoToHPActivity

struct GSRateSparkline: Shape {
    var values: [Int64]
    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        let peak = max(1, Double(values.max() ?? 1))
        return Path { path in
            for (i, value) in values.enumerated() {
                let point = CGPoint(x: rect.minX + rect.width * Double(i) / Double(values.count - 1), y: rect.maxY - rect.height * min(1, Double(value) / peak))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}

struct GSFileProgressTile: View {
    let file: GSUploadFileState
    let language: String
    let stale: Bool
    let dense: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: String? {
        if stale { return GSUploadText.text("Stale", language: language) }
        switch file.phase {
        case 1: return GSUploadText.text("Preparing", language: language)
        case 2: return GSUploadText.text("Confirming", language: language)
        case 3: return GSUploadText.text("Retrying", language: language)
        case 4: return GSUploadText.text("Source", language: language)
        default: return nil
        }
    }
    private var tint: Color { stale || file.phase == 3 ? .secondary : file.acknowledged ? .mint : .cyan }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(file.name).font(.system(size: dense ? 10 : 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(file.percent.map { "\($0)%" } ?? "—").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            }
            HStack(spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.10))
                        if let fraction = file.fraction {
                            Capsule().fill(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                }.frame(height: 4)
                Text(phase ?? GSUploadText.rate(file.speed))
                    .font(.system(size: dense ? 8 : 9, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .frame(height: 26)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: file.uploaded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(file.name), \(file.percent.map { "\($0)%" } ?? GSUploadText.text("Unknown", language: language)), \(GSUploadText.text(file.acknowledged ? "Received" : "Sent", language: language)) \(ByteCountFormatter.string(fromByteCount: file.uploaded, countStyle: .file)), \(phase ?? GSUploadText.rate(file.speed))")
    }
}

struct GSUploadCard: View {
    let state: GSUploadVisualState
    let language: String
    var stale = false
    var glass = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var unavailable: Bool { stale || state.status == 3 }
    private var columns: Int { state.files.count > 8 ? 3 : state.files.count > 4 ? 2 : 1 }
    private var caption: String {
        if unavailable { return GSUploadText.text("Stale", language: language) }
        if state.status == 1 { return GSUploadText.text("Finished", language: language) }
        if state.status == 2 { return GSUploadText.text("Stopped", language: language) }
        return "\(state.files.count) \(GSUploadText.text("files", language: language)) · \(GSUploadText.text("Waiting", language: language)) \(state.waiting)"
    }
    private var contents: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill").symbolRenderingMode(.hierarchical)
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(unavailable ? Color.secondary : .mint)
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : state.movement)
                VStack(alignment: .leading, spacing: 1) {
                    Text("GoToHP").font(.system(size: 13, weight: .semibold))
                    Text(caption).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 2)
                GSRateSparkline(values: state.history).stroke(unavailable ? Color.secondary : .mint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 48, height: 20).accessibilityHidden(true)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(GSUploadText.rate(unavailable ? nil : state.speed)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.75)
                    Text(GSUploadText.text("Recent 12 seconds", language: language)).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            if state.files.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack").foregroundStyle(.secondary)
                    Text(GSUploadText.text(unavailable ? "Stale" : "No transfers", language: language)).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }.frame(height: 25)
            } else {
                Grid(horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(0..<((state.files.count + columns - 1) / columns), id: \.self) { row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { column in
                                let index = row * columns + column
                                if index < state.files.count {
                                    GSFileProgressTile(file: state.files[index], language: language, stale: unavailable, dense: columns == 3)
                                } else { Color.clear.frame(height: 26) }
                            }
                        }
                    }
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }
    var body: some View {
        if !glass { contents }
        else if reduceTransparency { contents.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24)) }
        else if #available(iOS 26.0, *) { contents.glassEffect(.regular, in: .rect(cornerRadius: 24)) }
        else { contents.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous)) }
    }
}
