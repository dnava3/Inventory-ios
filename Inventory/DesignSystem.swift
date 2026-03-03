import SwiftUI

public struct SurfaceCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

public struct TileButton: View {
    public enum Size { case small, large }
    let title: String; let systemImage: String; let size: Size; let action: () -> Void
    public init(_ title: String, systemImage: String, size: Size = .large, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.size = size; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(size == .large ? .system(size: 24, weight: .semibold) : .title3)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.bordered)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

public struct StatTile: View {
    let title: String; let value: String; let subtitle: String?
    public init(title: String, value: String, subtitle: String? = nil) {
        self.title = title; self.value = value; self.subtitle = subtitle
    }
    public var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                if let s = subtitle { Text(s).font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

public struct StatusDot: View {
    public enum Kind { case good, warn, bad, neutral }
    let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
    }
    private var color: Color {
        switch kind { case .good: .green; case .warn: .orange; case .bad: .red; case .neutral: .gray }
    }
}
