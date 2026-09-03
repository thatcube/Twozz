import SwiftUI

/// Global settings use a persistent category rail so the viewer sees one
/// coherent group at a time instead of a single wall of unrelated controls.
struct SettingsView: View {
  var onRequestSignIn: () -> Void = {}
  var onRequestYouTubeSignIn: () -> Void = {}
  var onClearWatchHistory: () -> Void = {}
  var onResetNotInterested: () -> Void = {}
  var onAccountChanged: () -> Void = {}
  var onRepublishTopShelf: () -> Void = {}

  @Environment(\.themePalette) private var palette
  @State private var selectedCategory = SettingsCategory.appearance
  @FocusState private var focusedCategory: SettingsCategory?
  @Namespace private var categoryFocusScope

  private enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case appearance
    case homeAndDiscovery
    case watching
    case alerts
    case accounts
    case about

    var id: Self { self }

    var title: String {
      switch self {
      case .appearance: "Appearance"
      case .homeAndDiscovery: "Home & Discovery"
      case .watching: "Watching"
      case .alerts: "Alerts"
      case .accounts: "Accounts"
      case .about: "About"
      }
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        LinearGradient(
          colors: palette.backgroundColors,
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()

        GeometryReader { proxy in
          HStack(alignment: .top, spacing: 0) {
            categoryRail
              .frame(width: min(400, max(320, proxy.size.width * 0.25)))

            Divider()
              .overlay(Color.primary.opacity(0.12))
              .padding(.horizontal, 40)
              .padding(.vertical, 8)

            categoryDetail
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
          .padding(.horizontal, AppLayout.horizontalPadding)
          .padding(.vertical, 32)
        }
      }
    }
  }

  private var categoryRail: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text("Settings")
        .font(.system(size: 44, weight: .bold))
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 18)

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 8) {
          ForEach(SettingsCategory.allCases) { category in
            categoryButton(category)
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }
      .scrollClipDisabled()
      .focusScope(categoryFocusScope)
    }
    .onChange(of: focusedCategory) { _, category in
      guard let category else { return }
      selectedCategory = category
    }
  }

  private func categoryButton(_ category: SettingsCategory) -> some View {
    let isFocused = focusedCategory == category
    let isSelected = selectedCategory == category

    return Button {
      selectedCategory = category
    } label: {
      Text(category.title)
        .font(.system(size: 28, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isFocused ? palette.liftPrimaryText : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .frame(height: 64)
        .background {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
              isFocused
                ? palette.liftSurface
                : Color.primary.opacity(isSelected ? 0.10 : 0)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(isSelected && !isFocused ? 0.14 : 0))
            }
        }
        .scaleEffect(isFocused ? 1.025 : 1)
        .shadow(
          color: .black.opacity(isFocused ? 0.22 : 0),
          radius: isFocused ? 12 : 0,
          y: isFocused ? 6 : 0
        )
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .animation(.easeOut(duration: 0.16), value: isSelected)
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .focused($focusedCategory, equals: category)
    .prefersDefaultFocus(category == .appearance, in: categoryFocusScope)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var categoryDetail: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 28) {
        Text(selectedCategory.title)
          .font(.system(size: 38, weight: .bold))
          .accessibilityAddTraits(.isHeader)

        categoryContent
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, 8)
      .padding(.bottom, 32)
    }
    .id(selectedCategory)
    .scrollClipDisabled()
  }

  @ViewBuilder
  private var categoryContent: some View {
    switch selectedCategory {
    case .appearance:
      SettingsPreferencesSection(
        group: .appearance,
        onClearWatchHistory: onClearWatchHistory,
        onResetNotInterested: onResetNotInterested
      )
      SettingsNightShiftSection()
    case .homeAndDiscovery:
      SettingsPreferencesSection(
        group: .homeAndDiscovery,
        onClearWatchHistory: onClearWatchHistory,
        onResetNotInterested: onResetNotInterested
      )
    case .watching:
      SettingsPreferencesSection(
        group: .watching,
        onClearWatchHistory: onClearWatchHistory,
        onResetNotInterested: onResetNotInterested
      )
    case .alerts:
      SettingsPreferencesSection(
        group: .alerts,
        onClearWatchHistory: onClearWatchHistory,
        onResetNotInterested: onResetNotInterested
      )
    case .accounts:
      SettingsAccountSection(
        onRequestSignIn: onRequestSignIn,
        onAccountChanged: onAccountChanged
      )
      SettingsYouTubeAccountSection(
        onRequestYouTubeSignIn: onRequestYouTubeSignIn,
        onAccountChanged: onAccountChanged
      )
    case .about:
      SettingsAboutSection(showsTitle: false)
    }
  }
}
