import SwiftUI

/// The skeleton's one window: the product's name and what the dictionary service answered at launch.
public struct LaunchView: View {
    private let status: LaunchStatus

    public init(status: LaunchStatus) {
        self.status = status
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "XDict").font(.largeTitle)
            Text(status.headline)
            if let detail = status.detail {
                Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 360, alignment: .leading)
    }
}
