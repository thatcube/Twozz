import SDWebImage
import SDWebImageWebPCoder
import SwiftUI

@main
struct TwizzApp: App {
  @State private var deepLinkRouter = DeepLinkRouter()

  init() {
    SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
  }

  var body: some Scene {
    WindowGroup {
      HomeView(deepLinkRouter: deepLinkRouter)
        .onOpenURL { url in
          deepLinkRouter.handle(url)
        }
    }
  }
}
