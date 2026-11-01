import SwiftUI
import UIKit

/// Image loader that sends the account's token for server-hosted images (avatars, uploads, logos).
actor ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private var running: [String: Task<UIImage?, Never>] = [:]

    func image(_ url: String, account: Account?) async -> UIImage? {
        let key = "\(account?.id.uuidString ?? "-")|\(url)" as NSString
        if let img = cache.object(forKey: key) { return img }
        if let t = running[key as String] { return await t.value }
        let task = Task<UIImage?, Never> {
            let data: Data?
            if let account { data = try? await HackbanAPI(account).data(url) }
            else if let u = URL(string: url) { data = try? await URLSession.shared.data(from: u).0 }
            else { data = nil }
            return data.flatMap(UIImage.init(data:))
        }
        running[key as String] = task
        let img = await task.value
        running[key as String] = nil
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

public struct AuthImage<Placeholder: View>: View {
    var url: String?
    var account: Account?
    var contentMode: ContentMode
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    public init(_ url: String?, account: Account?, contentMode: ContentMode = .fill, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url; self.account = account; self.contentMode = contentMode; self.placeholder = placeholder
    }

    public var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode) }
            else { placeholder() }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ImageLoader.shared.image(url, account: account)
        }
    }
}

public struct AvatarView: View {
    var user: UserRef?
    var name: String?
    var image: String?
    var account: Account?
    var size: CGFloat

    public init(_ user: UserRef?, account: Account?, size: CGFloat = 28) {
        self.user = user; self.name = user?.displayName; self.image = user?.image; self.account = account; self.size = size
    }

    public init(name: String?, image: String?, account: Account?, size: CGFloat = 28) {
        self.name = name; self.image = image; self.account = account; self.size = size
    }

    static func initials(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "?" }
        return name.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    public var body: some View {
        AuthImage(image, account: account) {
            ZStack {
                Circle().fill(Color(.systemGray4))
                Text(Self.initials(name)).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .opacity(user?.ghost == true ? 0.6 : 1)
        .accessibilityLabel(name ?? "Member")
    }
}
