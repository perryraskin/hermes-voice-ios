import ActivityKit
import SwiftUI
import WidgetKit

private let sage=Color(red:0.77,green:0.89,blue:0.71)
private let surface=Color(red:0.055,green:0.075,blue:0.062)

@main struct HermesVoiceWidgets:WidgetBundle {
    var body:some Widget { HermesVoiceActivityWidget() }
}
struct HermesVoiceActivityWidget:Widget {
    var body:some WidgetConfiguration {
        ActivityConfiguration(for:VoiceActivityAttributes.self) { context in
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Label("Hermes",systemImage:"waveform").font(.subheadline.weight(.semibold)).foregroundStyle(sage)
                    Spacer()
                    Text(context.attributes.startedAt,style:.timer).font(.caption.monospacedDigit()).multilineTextAlignment(.trailing).foregroundStyle(.white.opacity(0.65))
                }
                HStack(spacing:16) {
                    Image(systemName:context.state.symbol).font(.title2).foregroundStyle(sage).frame(width:32)
                    VStack(alignment:.leading,spacing:3) {
                        Text(context.state.title).font(.headline).foregroundStyle(.white)
                        Text(context.state.muted ? "Microphone paused":context.attributes.isCall ? "Voice call":"Voice conversation").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength:0)
                    VoiceActivityControls(attributes:context.attributes,state:context.state)
                }
            }.padding(18)
                .activityBackgroundTint(surface)
                .activitySystemActionForegroundColor(sage)
                .widgetURL(URL(string:"hermesvoice://conversation"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Hermes",systemImage:"waveform").font(.subheadline.weight(.semibold)).foregroundStyle(sage)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt,style:.timer).font(.caption.monospacedDigit()).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Label(context.state.title,systemImage:context.state.symbol).font(.subheadline).foregroundStyle(sage)
                        Spacer()
                        VoiceActivityControls(attributes:context.attributes,state:context.state)
                    }.padding(.top,6)
                }
            } compactLeading: {
                Image(systemName:"waveform").foregroundStyle(sage)
            } compactTrailing: {
                Image(systemName:context.state.symbol).foregroundStyle(context.state.muted ? .orange:sage)
            } minimal: {
                Image(systemName:context.state.muted ? "mic.slash.fill":"waveform").foregroundStyle(sage)
            }
            .widgetURL(URL(string:"hermesvoice://conversation"))
            .keylineTint(sage)
        }
    }
}
private struct VoiceActivityControls:View {
    let attributes:VoiceActivityAttributes
    let state:VoiceActivityAttributes.ContentState
    var body:some View {
        HStack(spacing:10) {
            Button(intent:SetHermesMuteIntent(sessionID:attributes.sessionID,muted:!state.muted)) {
                Image(systemName:state.muted ? "mic.slash.fill":"mic.fill").frame(width:42,height:42)
                    .background(.white.opacity(0.1),in:Circle()).foregroundStyle(sage)
            }.disabled(state.phase=="Connecting").accessibilityLabel(state.muted ? "Unmute Hermes":"Mute Hermes")
            Button(intent:EndHermesSessionIntent(sessionID:attributes.sessionID)) {
                Image(systemName:"stop.fill").frame(width:42,height:42)
                    .background(sage,in:Circle()).foregroundStyle(surface)
            }.accessibilityLabel("End conversation")
        }.buttonStyle(.plain)
    }
}
