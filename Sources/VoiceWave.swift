import SwiftUI

/// Motion follows actual audio energy; idle and mute never pretend to hear speech.
struct VoiceWave: View {
    let state: VoiceState
    let muted: Bool
    let input: CGFloat
    let output: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tint = Color(red:0.79,green:0.91,blue:0.74)
    private var moving: Bool { !muted && [.listening,.speaking,.thinking,.connecting].contains(state) && !reduceMotion }
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:!moving)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context,size in
                let color = muted ? Color.gray : tint
                let energy = muted ? 0 : (state == .speaking ? output : input)
                if state == .ready || state == .paused || state == .failed || muted || reduceMotion {
                    let heights:[CGFloat] = [12,24,40,57,76,57,40,24,12]
                    for i in 0..<heights.count {
                        let h = muted ? CGFloat(5) : heights[i] * (reduceMotion && state == .speaking ? 0.6 : 1)
                        let rect=CGRect(x:size.width/2+CGFloat(i-4)*13-3,y:(size.height-h)/2,width:6,height:h)
                        context.fill(Path(roundedRect:rect,cornerRadius:3),with:.color(color.opacity(muted ? 0.5:0.85)))
                    }
                } else if state == .thinking || state == .connecting {
                    for i in 0..<5 {
                        let pulse=(sin(time*3-Double(i)*0.65)+1)/2
                        let h=CGFloat(9+pulse*24)
                        context.fill(Path(roundedRect:CGRect(x:size.width/2+CGFloat(i-2)*16-3,y:(size.height-h)/2,width:6,height:h),cornerRadius:3),with:.color(color.opacity(0.3+pulse*0.65)))
                    }
                } else {
                    // Three fine ribbons share a measured amplitude with tapered edges.
                    for layer in 0..<3 {
                        var path=Path()
                        for step in 0...180 {
                            let x=CGFloat(step)/180*size.width
                            let normalized=Double(step)/180
                            let envelope=pow(sin(normalized * .pi),1.7)
                            let phase=time*(state == .speaking ? 4.5:3.2)
                            let carrier=sin(normalized * .pi*4-phase+Double(layer)*0.6)
                            let harmonic=sin(normalized * .pi*7+phase*0.7)*0.24
                            let amplitude=(2+Double(energy)*55)*envelope*(1-Double(layer)*0.19)
                            let point=CGPoint(x:x,y:size.height/2+CGFloat((carrier+harmonic)*amplitude))
                            if step==0 { path.move(to:point) } else { path.addLine(to:point) }
                        }
                        context.stroke(path,with:.color(color.opacity([0.95,0.4,0.18][layer])),style:StrokeStyle(lineWidth:layer==0 ? 3:1.5,lineCap:.round,lineJoin:.round))
                    }
                }
            }
        }.frame(maxWidth:290).frame(height:160).accessibilityHidden(true)
    }
}

struct VoiceButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration)->some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.92:1)
            .opacity(configuration.isPressed ? 0.8:1)
            .animation(reduceMotion ? nil:.spring(response:0.25,dampingFraction:0.65),value:configuration.isPressed)
    }
}
