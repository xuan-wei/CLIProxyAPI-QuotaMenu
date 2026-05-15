import SwiftUI

struct QuotaListView: View {
    @EnvironmentObject var viewModel: QuotaViewModel

    var body: some View {
        ScrollView {
            if viewModel.quotas.isEmpty && !viewModel.isLoading {
                Text("No quota data").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.groupedQuotas, id: \.provider) { group in
                        providerSection(group)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
        }
    }

    private func providerSection(_ group: (provider: String, label: String, items: [QuotaItem])) -> some View {
        let hiddenCount = group.items.filter { viewModel.isHidden($0.id) }.count
        let visibleItems = viewModel.showHidden
            ? group.items
            : group.items.filter { !viewModel.isHidden($0.id) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(group.label)
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(providerBadgeColor(group.provider))
                    .foregroundStyle(providerBadgeText(group.provider))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("\(group.items.count) accounts")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                if hiddenCount > 0 {
                    Button {
                        viewModel.showHidden.toggle()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: viewModel.showHidden ? "eye" : "eye.slash")
                            Text("\(hiddenCount)")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Button { viewModel.toggleProviderHidden(group.provider) } label: {
                        let allHidden = group.items.allSatisfy { viewModel.isHidden($0.id) }
                        Text(allHidden ? "Show All" : "Hide All")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
            }
            .padding(.horizontal, 4)

            ForEach(visibleItems) { item in
                let hidden = viewModel.isHidden(item.id)
                QuotaRowView(item: item, isHidden: hidden, onToggleHidden: {
                    viewModel.toggleHidden(item.id)
                }) {
                    Task { await viewModel.refreshAccount(item.name) }
                }
                .opacity(hidden ? 0.4 : 1.0)
            }
        }
    }

    private func providerBadgeColor(_ provider: String) -> Color {
        switch provider {
        case "claude": Color(red: 0.37, green: 0.17, blue: 0.08)
        case "codex": Color(red: 0.15, green: 0.14, blue: 0.58)
        case "antigravity": Color(red: 0, green: 0.30, blue: 0.25)
        case "gemini-cli": Color(red: 0.11, green: 0.25, blue: 0.45)
        case "kimi": Color(red: 0, green: 0.22, blue: 0.50)
        default: Color.gray
        }
    }

    private func providerBadgeText(_ provider: String) -> Color {
        switch provider {
        case "claude": Color(red: 0.91, green: 0.66, blue: 0.51)
        case "codex": Color(red: 0.71, green: 0.69, blue: 1.0)
        case "antigravity": Color(red: 0.50, green: 0.87, blue: 0.92)
        case "gemini-cli": Color(red: 0.66, green: 0.78, blue: 1.0)
        case "kimi": Color(red: 0.44, green: 0.71, blue: 1.0)
        default: Color.white
        }
    }
}
