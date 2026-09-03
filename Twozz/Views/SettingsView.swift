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
            SettingsCategoryRail(selection: $selectedCategory)
              .frame(width: min(360, max(300, proxy.size.width * 0.22)))

            Divider()
              .overlay(Color.primary.opacity(0.12))
              .padding(.horizontal, 28)
              .padding(.vertical, 8)

            SettingsCategoryDetail(
              category: selectedCategory,
              onRequestSignIn: onRequestSignIn,
              onRequestYouTubeSignIn: onRequestYouTubeSignIn,
              onClearWatchHistory: onClearWatchHistory,
              onResetNotInterested: onResetNotInterested,
              onAccountChanged: onAccountChanged
            )
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          }
          .padding(.horizontal, AppLayout.horizontalPadding)
          .padding(.vertical, 32)
        }
      }
    }
  }
}

private enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
  case appearance
  case homeAndDiscovery
  case watching
  case alerts
  case accounts
  case about

  var id: Self { self }

  var title: LocalizedStringResource {
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

private struct SettingsCategoryRail: View {
  @Binding var selection: SettingsCategory
  @FocusState private var focusedCategory: SettingsCategory?
  @Namespace private var focusScope

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text("Settings")
        .font(.system(size: 44, weight: .bold))
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 18)

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 8) {
          ForEach(SettingsCategory.allCases) { category in
            Button {
              selection = category
            } label: {
              Text(category.title)
                .font(.title3.weight(selection == category ? .semibold : .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsCategoryButtonStyle(isSelected: selection == category))
            .focused($focusedCategory, equals: category)
            .prefersDefaultFocus(category == selection, in: focusScope)
            .accessibilityAddTraits(selection == category ? .isSelected : [])
          }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
      }
      .scrollClipDisabled()
      .focusScope(focusScope)
    }
    .onChange(of: focusedCategory) { _, category in
      guard let category else { return }
      selection = category
    }
  }
}

private struct SettingsCategoryButtonStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    SettingsCategoryButtonBody(configuration: configuration, isSelected: isSelected)
  }
}

private struct SettingsCategoryButtonBody: View {
  let configuration: ButtonStyle.Configuration
  let isSelected: Bool

  @Environment(\.isFocused) private var isFocused
  @Environment(\.colorScheme) private var colorScheme

  private var focusFill: Color {
    colorScheme == .dark ? .white : .black
  }

  private var focusForeground: Color {
    colorScheme == .dark ? .black : .white
  }

  var body: some View {
    configuration.label
      .foregroundStyle(isFocused ? focusForeground : Color.primary)
      .background {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(
            isFocused
              ? focusFill
              : Color.accentColor.opacity(isSelected ? 0.16 : 0)
          )
          .padding(.horizontal, isFocused ? -10 : 0)
          .padding(.vertical, isFocused ? -3 : 0)
          .shadow(
            color: .black.opacity(isFocused ? 0.28 : 0),
            radius: isFocused ? 14 : 0,
            y: isFocused ? 6 : 0
          )
      }
      .overlay(alignment: .leading) {
        if isSelected && !isFocused {
          Capsule(style: .continuous)
            .fill(Color.accentColor)
            .frame(width: 4, height: 26)
        }
      }
      .opacity(configuration.isPressed ? 0.86 : 1)
  }
}

private struct SettingsCategoryDetail: View {
  let category: SettingsCategory
  let onRequestSignIn: () -> Void
  let onRequestYouTubeSignIn: () -> Void
  let onClearWatchHistory: () -> Void
  let onResetNotInterested: () -> Void
  let onAccountChanged: () -> Void

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 28) {
        Text(category.title)
          .font(.system(size: 38, weight: .bold))
          .accessibilityAddTraits(.isHeader)

        switch category {
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
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, 12)
      .padding(.bottom, 40)
    }
    .id(category)
    .scrollClipDisabled()
  }
}
