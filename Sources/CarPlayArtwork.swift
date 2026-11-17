import UIKit

/// Cached state animations. CarPlay plays these locally; microphone meters never
/// trigger image transfers or template replacement over the vehicle connection.
@MainActor enum CarPlayArtwork {
    static let sage=UIColor(red:0.77,green:0.89,blue:0.71,alpha:1)
    private static var cache:[String:UIImage]=[:]
    static let background:UIImage=UIGraphicsImageRenderer(size:CGSize(width:800,height:480)).image { context in
        UIColor(red:0.055,green:0.075,blue:0.062,alpha:1).setFill()
        context.fill(CGRect(x:0,y:0,width:800,height:480))
    }
    static func image(state:VoiceState,muted:Bool)->UIImage {
        let key=muted ? "muted":state.rawValue
        if let image=cache[key] { return image }
        let animated = !muted && [.connecting,.listening,.thinking,.speaking].contains(state)
        let count=animated ? 24:1
        let format=UIGraphicsImageRendererFormat();format.scale=2
        let renderer=UIGraphicsImageRenderer(size:CGSize(width:150,height:150),format:format)
        let frames=(0..<count).map { frame in renderer.image { _ in
            let phase=Double(frame)/Double(count)*2*Double.pi
            if muted || state == .failed || state == .paused {
                let symbol=muted ? "mic.slash.fill":state == .failed ? "wifi.exclamationmark":"pause.fill"
                UIImage(systemName:symbol)?.withTintColor(sage,renderingMode:.alwaysOriginal).draw(in:CGRect(x:53,y:53,width:44,height:44))
            } else {
                for bar in 0..<9 {
                    let distance=abs(Double(bar)-4)/4
                    let envelope=1-distance*0.7
                    let pulse=(sin(phase+Double(bar)*0.75)+1)/2
                    let amplitude:Double
                    switch state {
                    case .speaking: amplitude=16+64*pulse
                    case .thinking,.connecting: amplitude=12+22*pulse
                    case .listening: amplitude=10+30*pulse
                    default: amplitude=10
                    }
                    let height=CGFloat(amplitude*envelope)
                    sage.withAlphaComponent(0.6+0.4*envelope).setFill()
                    UIBezierPath(roundedRect:CGRect(x:CGFloat(17+bar*14),y:75-height/2,width:7,height:height),cornerRadius:3.5).fill()
                }
            }
        } }
        let image=animated ? UIImage.animatedImage(with:frames,duration:state == .speaking ? 1.2:2.4)!:frames[0]
        cache[key]=image;return image
    }
}
