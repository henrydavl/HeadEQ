import EQCore
import SwiftUI

struct EQView: View {
    @ObservedObject var model: AppModel
    @State private var selected = 5

    var body: some View {
        VStack(spacing: 14) {
            Header(model: model)

            ResponseGraph(eq: $model.eq, selected: $selected)
                .frame(height: 210)
                .opacity(model.enabled ? 1 : 0.5)

            BandPicker(bands: model.eq.bands, selected: $selected)

            BandEditor(band: $model.eq.bands[selected], eq: $model.eq)

            HStack {
                Text("Drag a point to set frequency and gain")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit HeadEQ") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 540)
    }
}

// MARK: - Header

private struct Header: View {
    @ObservedObject var model: AppModel
    @State private var renaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button { model.enabled.toggle() } label: {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(model.enabled ? Color.white : Color.secondary)
                    .background(model.enabled ? Color.accentColor : Color.secondary.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .help(model.enabled ? "Turn EQ off" : "Turn EQ on")
            .accessibilityLabel(model.enabled ? "Turn EQ off" : "Turn EQ on")

            VStack(alignment: .leading, spacing: 2) {
                Label(model.deviceName, systemImage: "headphones")
                    .font(.headline).lineLimit(1)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.status.hasPrefix("Error") ? Color.red : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if renaming {
                TextField("Profile name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
            } else {
                profileMenu
            }
        }
    }

    private var profileMenu: some View {
        Menu {
            Picker("Profile", selection: $model.profiles.selectedID) {
                ForEach(model.profiles.profiles) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Profile") { model.profiles.addProfile() }
            Button("Rename…") {
                draftName = model.profiles.selected.name
                renaming = true
                nameFocused = true
            }
            Button("Restore Default") { model.profiles.restoreDefault() }
            Divider()
            Button("Delete Profile", role: .destructive) { model.profiles.deleteSelected() }
                .disabled(model.profiles.profiles.count < 2)
        } label: {
            Label(model.profiles.selected.name, systemImage: "slider.horizontal.3")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Profiles for \(model.deviceName)")
    }

    private func commitRename() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { model.profiles.selected.name = name }
        renaming = false
    }
}

// MARK: - Graph

private struct ResponseGraph: View {
    @Binding var eq: EQSettings
    @Binding var selected: Int
    @State private var dragging: Int?
    @State private var dragActive = false

    private let range = 18.0 // ±dB visible

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in draw(&ctx, size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !dragActive {
                                dragActive = true
                                dragging = nearestBand(to: drag.startLocation, in: size)
                                if let dragging { selected = dragging }
                            }
                            guard let i = dragging else { return }
                            let f = freq(atX: drag.location.x, size)
                            eq.bands[i].freq = min(max(f < 1000 ? f.rounded() : (f / 10).rounded() * 10, Band.freqRange.lowerBound), Band.freqRange.upperBound)
                            eq.bands[i].gainDB = min(max((gain(atY: drag.location.y, size) * 10).rounded() / 10, Band.gainRange.lowerBound), Band.gainRange.upperBound)
                        }
                        .onEnded { _ in dragActive = false; dragging = nil }
                )
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement()
        .accessibilityLabel("EQ response graph")
        .accessibilityValue("Band \(selected + 1): \(formatFreq(eq.bands[selected].freq)) hertz, \(String(format: "%+.1f", eq.bands[selected].gainDB)) dB")
    }

    // Mapping between pixels and frequency (log, 20 Hz – 20 kHz) / gain.
    private func x(_ f: Double, _ s: CGSize) -> CGFloat { s.width * log10(f / 20) / 3 }
    private func y(_ db: Double, _ s: CGSize) -> CGFloat { s.height / 2 * (1 - db / range) }
    private func freq(atX x: CGFloat, _ s: CGSize) -> Double { 20 * pow(10, 3 * Double(x / s.width)) }
    private func gain(atY y: CGFloat, _ s: CGSize) -> Double { range * (1 - 2 * Double(y / s.height)) }
    private func point(_ b: Band, _ s: CGSize) -> CGPoint { CGPoint(x: x(b.freq, s), y: y(eq.magnitudeDB(at: b.freq) - eq.preampDB, s)) }

    private func nearestBand(to p: CGPoint, in s: CGSize) -> Int? {
        let hits = eq.bands.indices.map { ($0, hypot(point(eq.bands[$0], s).x - p.x, point(eq.bands[$0], s).y - p.y)) }
        guard let best = hits.min(by: { $0.1 < $1.1 }), best.1 < 22 else { return nil }
        return best.0
    }

    private func draw(_ ctx: inout GraphicsContext, _ s: CGSize) {
        // Grid
        var grid = Path()
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            grid.move(to: CGPoint(x: x(f, s), y: 0)); grid.addLine(to: CGPoint(x: x(f, s), y: s.height))
        }
        for db in [-12.0, -6, 6, 12] {
            grid.move(to: CGPoint(x: 0, y: y(db, s))); grid.addLine(to: CGPoint(x: s.width, y: y(db, s)))
        }
        ctx.stroke(grid, with: .color(.primary.opacity(0.06)))
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: y(0, s))); zero.addLine(to: CGPoint(x: s.width, y: y(0, s)))
        ctx.stroke(zero, with: .color(.primary.opacity(0.18)))

        for (f, t) in [(50.0, "50"), (100, "100"), (200, "200"), (500, "500"), (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k")] {
            ctx.draw(Text(t).font(.system(size: 9)).foregroundStyle(.tertiary), at: CGPoint(x: x(f, s), y: s.height - 8))
        }
        for db in [-12.0, -6, 6, 12] {
            ctx.draw(Text(String(format: "%+.0f", db)).font(.system(size: 9)).foregroundStyle(.tertiary),
                     at: CGPoint(x: 6, y: y(db, s)), anchor: .leading)
        }

        // Curve (bands only; preamp shown separately) with a soft fill to 0 dB
        var curve = Path()
        for i in 0...240 {
            let f = 20 * pow(1000, Double(i) / 240)
            let db = max(-range, min(range, eq.magnitudeDB(at: f) - eq.preampDB))
            let p = CGPoint(x: x(f, s), y: y(db, s))
            i == 0 ? curve.move(to: p) : curve.addLine(to: p)
        }
        var fill = curve
        fill.addLine(to: CGPoint(x: s.width, y: y(0, s)))
        fill.addLine(to: CGPoint(x: 0, y: y(0, s)))
        fill.closeSubpath()
        ctx.fill(fill, with: .color(.accentColor.opacity(0.14)))
        ctx.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        // Nodes
        for (i, band) in eq.bands.enumerated() {
            let p = point(band, s)
            let isSel = i == selected
            let r: CGFloat = isSel ? 10 : 8
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            if band.enabled {
                ctx.fill(Path(ellipseIn: rect), with: .color(isSel ? .accentColor : Color(nsColor: .windowBackgroundColor)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.accentColor), lineWidth: 1.5)
            } else {
                ctx.stroke(Path(ellipseIn: rect), with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            ctx.draw(Text("\(i + 1)").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSel && band.enabled ? Color.white : band.enabled ? Color.accentColor : Color.secondary),
                     at: p)
        }
    }
}

// MARK: - Band picker

private struct BandPicker: View {
    let bands: [Band]
    @Binding var selected: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(bands) { band in
                let isSel = band.id == selected
                Button { selected = band.id } label: {
                    VStack(spacing: 1) {
                        Text(formatFreq(band.freq)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        Text(band.enabled ? String(format: "%+.1f", band.gainDB) : "off")
                            .font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(isSel ? Color.white.opacity(0.85) : Color.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .foregroundStyle(isSel ? Color.white : band.enabled ? Color.primary : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 7).fill(isSel ? Color.accentColor : Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Band \(band.id + 1), \(formatFreq(band.freq)) hertz")
            }
        }
    }
}

// MARK: - Selected band editor

private struct BandEditor: View {
    @Binding var band: Band
    @Binding var eq: EQSettings

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Band \(band.id + 1)").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Reset Band") {
                    band = Band(id: band.id, freq: EQSettings.defaultFreqs[band.id])
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                Toggle(band.enabled ? "On" : "Off", isOn: $band.enabled)
                    .toggleStyle(.switch).controlSize(.mini).font(.caption)
                    .accessibilityLabel("Band \(band.id + 1) enabled")
            }

            HStack(alignment: .top, spacing: 18) {
                Control(title: "Frequency", unit: "Hz", value: $band.freq, range: Band.freqRange, digits: 0, logarithmic: true)
                Control(title: "Gain", unit: "dB", value: $band.gainDB, range: Band.gainRange, digits: 1)
                Control(title: "Q", unit: "", value: $band.q, range: Band.qRange, digits: 2, logarithmic: true)
            }
            .disabled(!band.enabled)
            .opacity(band.enabled ? 1 : 0.5)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                Control(title: "Preamp", unit: "dB", value: $eq.preampDB, range: EQSettings.preampRange, digits: 1)
                    .frame(width: 150)
                clipHint
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
    }

    /// Positive peak of the whole curve; above 0 dB music can clip.
    @ViewBuilder private var clipHint: some View {
        let peak = (0...120).map { eq.magnitudeDB(at: 20 * pow(1000, Double($0) / 120)) }.max() ?? 0
        VStack(alignment: .leading, spacing: 3) {
            Text("Peak").font(.caption).foregroundStyle(.secondary)
            if peak > 0.1 {
                Label(String(format: "%+.1f dB — lower preamp to %.1f", peak, eq.preampDB - peak), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("No clipping", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Label, editable value and slider. Typed values are clamped so the filter stays stable.
private struct Control: View {
    let title: String
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let digits: Int
    var logarithmic = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(unit)
            }
            .font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(digits)).grouping(.never))
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .medium).monospacedDigit())
            Slider(value: sliderBinding, in: sliderRange).controlSize(.small).accessibilityLabel(title)
        }
    }

    private var sliderRange: ClosedRange<Double> { logarithmic ? log10(range.lowerBound)...log10(range.upperBound) : range }
    private var sliderBinding: Binding<Double> {
        guard logarithmic else { return $value }
        let scale = pow(10, Double(digits))
        return Binding(get: { log10(value) }, set: { value = (pow(10, $0) * scale).rounded() / scale })
    }
}

private func formatFreq(_ f: Double) -> String {
    guard f >= 1000 else { return "\(Int(f.rounded()))" }
    let k = f / 1000
    return k.truncatingRemainder(dividingBy: 1) < 0.05 ? "\(Int(k))k" : String(format: "%.1fk", k)
}
