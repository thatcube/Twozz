import SwiftUI

struct StreamChannelCard: View {
  enum Layout {
    case rail(
      mediaWidth: CGFloat,
      mediaHeight: CGFloat,
      focusHorizontalInset: CGFloat,
      focusVerticalInset: CGFloat,
      cardCornerRadius: CGFloat,
      mediaCornerRadius: CGFloat
    )
    case grid(
      cardCornerRadius: CGFloat = 16,
      mediaCornerRadius: CGFloat = 12,
      contentInset: CGFloat = 14
    )

    var cardCornerRadius: CGFloat {
      switch self {
      case .rail(_, _, _, _, let cardCornerRadius, _):
        cardCornerRadius
      case .grid(let cardCornerRadius, _, _):
        cardCornerRadius
      }
    }

    var mediaCornerRadius: CGFloat {
      switch self {
      case .rail(_, _, _, _, _, let mediaCornerRadius):
        mediaCornerRadius
      case .grid(_, let mediaCornerRadius, _):
        mediaCornerRadius
      }
    }

    var focusHorizontalInset: CGFloat {
      switch self {
      case .rail(_, _, let focusHorizontalInset, _, _, _):
        focusHorizontalInset
      case .grid(_, _, let contentInset):
        contentInset
      }
    }

    var focusVerticalInset: CGFloat {
      switch self {
      case .rail(_, _, _, let focusVerticalInset, _, _):
        focusVerticalInset
      case .grid(_, _, let contentInset):
        contentInset
      }
    }

    var mediaWidth: CGFloat? {
      switch self {
      case .rail(let mediaWidth, _, _, _, _, _):
        mediaWidth
      case .grid:
        nil
      }
    }

    var mediaHeight: CGFloat? {
      switch self {
      case .rail(_, let mediaHeight, _, _, _, _):
        mediaHeight
      case .grid:
        nil
      }
    }

    var avatarSize: CGFloat {
      switch self {
      case .rail:
        62
      case .grid:
        68
      }
    }

    var usesFocusedShadow: Bool {
      switch self {
      case .rail:
        true
      case .grid:
        false
      }
    }
  }

  let channel: FollowedChannel
  let isFocused: Bool
  var layout: Layout = .grid()
  var showsGameName: Bool = false

  @Environment(\.themePalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      media

      HStack(alignment: .top, spacing: 10) {
        AsyncImage(url: channel.profileImageURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          Circle()
            .fill(Color.primary.opacity(0.14))
        }
        .frame(width: layout.avatarSize, height: layout.avatarSize)
        .clipShape(Circle())

        VStack(alignment: .leading, spacing: 4) {
          Text(channel.displayName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isFocused ? palette.liftPrimaryText : Color.primary)
            .lineLimit(1)

          Text(channel.title.isEmpty ? "No title" : channel.title)
            .font(.footnote)
            .foregroundStyle(isFocused ? palette.liftSecondaryText : Color.secondary)
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)

          if showsGameName {
            Text(channel.gameName)
              .font(.caption2)
              .foregroundStyle(isFocused ? palette.liftSecondaryText : Color.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, layout.focusHorizontalInset)
    .padding(.vertical, layout.focusVerticalInset)
    .frame(width: railCardWidth, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: layout.cardCornerRadius)
        .fill(isFocused ? palette.liftSurface : Color.primary.opacity(0.07))
    }
    .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius))
    .shadow(
      color: Color.black.opacity(layout.usesFocusedShadow && isFocused ? 0.36 : 0),
      radius: layout.usesFocusedShadow ? 20 : 0,
      y: layout.usesFocusedShadow ? 10 : 0
    )
  }

  @ViewBuilder
  private var media: some View {
    ZStack(alignment: .bottomLeading) {
      Color.primary.opacity(0.08)

      AsyncImage(url: channel.thumbnailURL) { image in
        image.resizable().scaledToFill()
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
          .fill(channel.isLive ? Color.red : Color.gray)
          .frame(width: 8, height: 8)
        if let viewerCount = channel.viewerCount {
          Text("\(viewerCount) watching")
            .font(.caption2)
            .foregroundStyle(Color.white.opacity(0.78))
        }
      }
      .padding(12)
    }
    .frame(width: layout.mediaWidth, height: layout.mediaHeight)
    .frame(maxWidth: layout.mediaWidth == nil ? .infinity : nil, alignment: .leading)
    .aspectRatio(layout.mediaWidth == nil ? 16 / 9 : nil, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: layout.mediaCornerRadius))
  }

  private var railCardWidth: CGFloat? {
    guard let mediaWidth = layout.mediaWidth else { return nil }
    return mediaWidth + (layout.focusHorizontalInset * 2)
  }
}
