import SwiftUI

struct QuotaRowView: View {
    let item: QuotaItem
    var isHidden: Bool = false
    var onToggleHidden: (() -> Void)?
    var onRefresh: (() -> Void)?
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(item.displayAccount)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if let plan = item.plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(item.providerColor.opacity(0.15))
                        .foregroundStyle(item.providerColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Spacer(minLength: 4)

                Button {
                    isRefreshing = true
                    onRefresh?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isRefreshing = false }
                } label: {
                    Image(systemName: isRefreshing ? "arrow.trianglehead.2.counterclockwise" : "arrow.trianglehead.2.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(isRefreshing ? Color.green : Color.secondary)
                        .rotationEffect(isRefreshing ? .degrees(360) : .zero)
                        .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)

                Button {
                    onToggleHidden?()
                } label: {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text(timeAgo(item.fetchedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.bottom, 8)

            if !isHidden {
                if item.isError {
                    Text(item.error ?? "Failed to fetch")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Divider().padding(.bottom, 8)

                    ForEach(item.windows) { window in
                        windowRow(window)
                            .padding(.bottom, 10)
                    }

                    if let extra = item.extra {
                        HStack {
                            Text(extra.label).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(extra.used) / \(extra.limit)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [item.providerColor.opacity(0.08), .clear],
                startPoint: .top, endPoint: .bottom
            )
        )
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
    }

    private func windowRow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(String(format: "%.0f%%", window.remaining))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.statusColor)

                if let reset = window.resetTimeFormatted {
                    Text(reset)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(window.statusColor)
                        .frame(width: max(0, geo.size.width * min(max(window.remaining / 100, 0), 1)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 10 { return "Just now" }
        if diff < 60 { return "\(diff)s ago" }
        let m = diff / 60
        if m < 60 { return "\(m) min ago" }
        return "\(m / 60)h ago"
    }
}
