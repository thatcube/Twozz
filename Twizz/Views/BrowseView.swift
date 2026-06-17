import SwiftUI

// MARK: - BrowseView

struct BrowseView: View {
    let auth: TwitchAuthSession
    let pagePadding: CGFloat
    @Binding var selectedChannel: FollowedChannel?

    @State private var service = BrowseService()
    @State private var selectedCategory: TwitchCategory?

    var body: some View {
        if let category = selectedCategory {
            BrowseStreamsView(
                category: category,
                service: service,
                selectedChannel: $selectedChannel,
                onBack: {
                    selectedCategory = nil
                }
            )
        } else {
            BrowseCategoriesView(
                service: service,
                onSelectCategory: { category in
                    selectedCategory = category
                    Task { await service.loadStreams(for: category) }
                }
            )
            .task {
                if service.categories.isEmpty {
                    await service.loadCategories()
                }
            }
        }
    }
}

// MARK: - Categories Grid

private struct BrowseCategoriesView: View {
    let service: BrowseService
    let onSelectCategory: (TwitchCategory) -> Void

    @FocusState private var focusedID: String?

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 24)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Browse")
                    .font(.title.weight(.bold))

                if service.isLoadingCategories {
                    ProgressView().scaleEffect(0.85)
                }

                Spacer()

                Button("Refresh") {
                    Task { await service.loadCategories() }
                }
            }

            if let err = service.categoryErrorMessage {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(service.categories) { category in
                        let isFocused = focusedID == category.id
                        CategoryCard(
                            category: category,
                            isFocused: isFocused
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                        .focusable(true)
                        .focused($focusedID, equals: category.id)
                        .focusEffectDisabled()
                        .onTapGesture {
                            onSelectCategory(category)
                        }
                        .scaleEffect(isFocused ? 1.07 : 1)
                        .animation(.easeOut(duration: 0.14), value: isFocused)
                        .zIndex(isFocused ? 2 : 0)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
            .focusSection()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: service.categories) { _, categories in
            if focusedID == nil, let first = categories.first {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    await MainActor.run { focusedID = first.id }
                }
            }
        }
    }
}

// MARK: - Streams for a Category

private struct BrowseStreamsView: View {
    let category: TwitchCategory
    let service: BrowseService
    @Binding var selectedChannel: FollowedChannel?
    let onBack: () -> Void

    @FocusState private var focusedStreamID: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 4)
    private let gridSpacing: CGFloat = 20

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 20) {
                    Button(action: onBack) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left")
                            Text("Categories")
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)

                    if let url = category.boxArtURL {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Color.white.opacity(0.08)
                        }
                        .frame(width: 40, height: 53)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.title.weight(.bold))
                        if let viewers = category.viewerCount {
                            Text("\(viewers) watching")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if service.isLoadingStreams && service.categoryStreams.isEmpty {
                        ProgressView().scaleEffect(0.85)
                    }

                    Spacer()
                }
                .focusSection()

                if let err = service.streamsErrorMessage {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if !service.isLoadingStreams && service.categoryStreams.isEmpty && service.streamsErrorMessage == nil {
                    Text("No live streams found for \(category.name) right now.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        ForEach(service.categoryStreams) { channel in
                            let isFocused = focusedStreamID == channel.id
                            BrowseChannelCard(
                                channel: channel,
                                isFocused: isFocused
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                            .focusable(true)
                            .focused($focusedStreamID, equals: channel.id)
                            .focusEffectDisabled()
                            .onTapGesture {
                                selectedChannel = channel
                            }
                            .scaleEffect(isFocused ? 1.06 : 1)
                            .animation(.easeOut(duration: 0.14), value: isFocused)
                            .zIndex(isFocused ? 2 : 0)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onExitCommand { onBack() }
        .onChange(of: service.categoryStreams) { _, streams in
            if focusedStreamID == nil, let first = streams.first {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    await MainActor.run { focusedStreamID = first.id }
                }
            }
        }
    }
}

// MARK: - Category Card

private struct CategoryCard: View {
    let category: TwitchCategory
    let isFocused: Bool

    private let cornerRadius: CGFloat = 14
    private let artRatio: CGFloat = 285.0 / 380.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: category.boxArtURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.08)
            }
            .aspectRatio(artRatio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius - 2))

            VStack(alignment: .leading, spacing: 4) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isFocused ? Color.black.opacity(0.92) : Color.primary)
                    .lineLimit(2, reservesSpace: true)

                if let viewers = category.viewerCount {
                    Text("\(viewers) watching")
                        .font(.caption2)
                        .foregroundStyle(isFocused ? Color.black.opacity(0.6) : Color.secondary)
                } else {
                    Text(" ")
                        .font(.caption2)
                        .hidden()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isFocused ? Color.white : Color.white.opacity(0.07))
        }
    }
}

// MARK: - Browse Channel Card

private struct BrowseChannelCard: View {
    let channel: FollowedChannel
    let isFocused: Bool

    private let cardCornerRadius: CGFloat = 16
    private let mediaCornerRadius: CGFloat = 12
    private let focusInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.white.opacity(0.08)

                AsyncImage(url: channel.thumbnailURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    if let viewerCount = channel.viewerCount {
                        Text("\(viewerCount) watching")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.78))
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: mediaCornerRadius))

            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: channel.profileImageURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                }
                .frame(width: 34, height: 34)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isFocused ? Color.black.opacity(0.92) : Color.primary)
                        .lineLimit(1)

                    Text(channel.title.isEmpty ? "No title" : channel.title)
                        .font(.footnote)
                        .foregroundStyle(isFocused ? Color.black.opacity(0.62) : Color.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(focusInset)
        .background {
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .fill(isFocused ? Color.white : Color.white.opacity(0.07))
        }
    }
}
