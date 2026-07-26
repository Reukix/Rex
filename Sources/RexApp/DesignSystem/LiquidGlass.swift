import SwiftUI

enum RexMetrics {
    static let cornerRadius: CGFloat = 16
    static let compactRadius: CGFloat = 11
    static let toolbarHeight: CGFloat = 44
    static let titlebarHeight: CGFloat = 50
    static let sidebarWidth: CGFloat = 264
    static let collapsedSidebarWidth: CGFloat = 58
    static let dividerHitWidth: CGFloat = 12
    static let popoverWidth: CGFloat = 350
}

enum BrowserWindowChromeLayout {
    static let windowEdgePadding: CGFloat = 8
    static let trafficLightClearance: CGFloat = 8
    static let fallbackTrafficLightTrailingEdge: CGFloat = 80

    static func toolbarLeadingInset(
        trafficLightTrailingEdge: CGFloat?,
        isFullScreen: Bool
    ) -> CGFloat {
        guard !isFullScreen else { return windowEdgePadding }
        let trailingEdge = trafficLightTrailingEdge ?? fallbackTrafficLightTrailingEdge
        return ceil(trailingEdge + trafficLightClearance)
    }
}

/// Chrome fills and strokes that stay visible in both appearances. The former
/// fixed `.white.opacity` values were nearly invisible in light mode.
enum RexChromeColor {
    static func fill(_ scheme: ColorScheme, pressed: Bool = false, hovered: Bool = false) -> Color {
        let base: Double = pressed ? 0.16 : (hovered ? 0.12 : 0.07)
        return scheme == .dark
            ? .white.opacity(base)
            : .black.opacity(base * 0.72)
    }

    static func stroke(_ scheme: ColorScheme, emphasized: Bool = false) -> Color {
        if emphasized {
            return scheme == .dark ? .white.opacity(0.26) : .black.opacity(0.18)
        }
        return scheme == .dark ? .white.opacity(0.1) : .black.opacity(0.08)
    }

    static func panelStroke(_ scheme: ColorScheme, increasedContrast: Bool) -> Color {
        if increasedContrast {
            return scheme == .dark ? .white.opacity(0.55) : .black.opacity(0.55)
        }
        return scheme == .dark ? .white.opacity(0.2) : .black.opacity(0.1)
    }
}

enum RexCoordinateSpace {
    static let window = "rex-window"
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(clean, radix: 16) ?? 0x7C6FF2
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

struct LiquidGlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    /// SwiftUI clipShape over CEF/NSViewRepresentable content can leave blank
    /// tiles on macOS. Prefer background-only chrome for live browser surfaces.
    let clipsContent: Bool
    let showsShadow: Bool
    @ViewBuilder var content: Content

    init(
        cornerRadius: CGFloat = RexMetrics.cornerRadius,
        clipsContent: Bool = true,
        showsShadow: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.clipsContent = clipsContent
        self.showsShadow = showsShadow
        self.content = content()
    }

    var body: some View {
        let chrome = content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.12), .clear, .indigo.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                RexChromeColor.panelStroke(colorScheme, increasedContrast: contrast == .increased),
                                lineWidth: contrast == .increased ? 1.5 : 0.75
                            )
                    }
                    .shadow(
                        color: showsShadow ? .black.opacity(0.14) : .clear,
                        radius: showsShadow ? 20 : 0,
                        y: showsShadow ? 8 : 0
                    )
            }

        if clipsContent {
            chrome.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            chrome
        }
    }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        LiquidGlassButtonChrome(configuration: configuration, isSelected: isSelected)
    }

    private struct LiquidGlassButtonChrome: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovered = false
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background {
                    RoundedRectangle(cornerRadius: RexMetrics.compactRadius, style: .continuous)
                        .fill(isSelected
                              ? Color.accentColor.opacity(isHovered ? 0.26 : 0.2)
                              : RexChromeColor.fill(
                                    colorScheme,
                                    pressed: configuration.isPressed,
                                    hovered: isHovered
                                ))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: RexMetrics.compactRadius, style: .continuous)
                        .strokeBorder(
                            RexChromeColor.stroke(colorScheme, emphasized: isSelected || isHovered),
                            lineWidth: 0.75
                        )
                }
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}

struct LiquidGlassIconButton: View {
    let systemName: String
    let label: String
    var isSelected = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(LiquidGlassButtonStyle(isSelected: isSelected))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct LiquidGlassProgressView: View {
    let value: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(RexChromeColor.fill(colorScheme))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(2, proxy.size.width * min(max(value, 0), 1)))
                }
        }
        .frame(height: 2)
        .accessibilityValue(Text("\(Int(value * 100))%"))
    }
}

/// Covers only the pixels outside a rounded viewport. Windowed CEF child views
/// must remain unclipped so Chromium can keep its native compositor path.
struct WindowedCEFViewportCornerMask: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
            style: .continuous
        )
        return path
    }
}

/// Paints the window backdrop over the square corners of a windowed CEF view.
/// Matching the root backdrop's coordinate system keeps the cover invisible while
/// preserving Chromium's non-layer-backed compositor path.
struct WindowedCEFViewportCornerCover: View {
    let cornerRadius: CGFloat
    let windowSize: CGSize

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(RexCoordinateSpace.window))

            RexWindowBackdrop()
                .frame(width: windowSize.width, height: windowSize.height)
                .offset(x: -frame.minX, y: -frame.minY)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .topLeading
                )
                .clipped()
                .mask {
                    WindowedCEFViewportCornerMask(cornerRadius: cornerRadius)
                        .fill(style: FillStyle(eoFill: true))
                }
        }
    }
}

struct RexWindowBackground: View {
    var body: some View {
        RexWindowBackdrop()
    }
}

private struct RexWindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(hex: "151726"), Color(hex: "0B1018"), Color(hex: "202036")]
                    : [Color(hex: "EAF2FF"), Color(hex: "F5F2FF"), Color(hex: "E7F5F3")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(hex: "8B7CF6").opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 540
            )
        }
    }
}
