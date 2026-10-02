import ActivityKit
import SwiftUI
import WidgetKit
import GoToHPActivity

struct GSUploadWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GSUploadAttributes.self) { context in
            GSUploadCard(state: context.state, language: context.attributes.language, stale: context.isStale)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    GSUploadCard(state: context.state, language: context.attributes.language, stale: context.isStale, glass: false)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up").foregroundStyle(.mint)
                    Text("\(context.state.files.count)").monospacedDigit()
                }.font(.system(size: 12, weight: .semibold))
            } compactTrailing: {
                Text(GSUploadText.rate(context.isStale ? nil : context.state.speed)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            } minimal: {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.mint)
            }.keylineTint(.mint)
        }
    }
}

@main
struct GSUploadWidgetBundle: WidgetBundle {
    var body: some Widget { GSUploadWidget() }
}
