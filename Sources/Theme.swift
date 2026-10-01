import SwiftUI

enum Theme {
    static let background = Color(red:0.965, green:0.977, blue:0.980)
    static let ink = Color(red:0.125, green:0.141, blue:0.149)
    static let secondary = Color(red:0.400, green:0.439, blue:0.471)
    static let accent = Color(red:0.239, green:0.392, blue:0.478)
    static let border = Color(red:0.890, green:0.898, blue:0.902)
    static let selected = Color(red:0.918, green:0.941, blue:0.957)
    static let track = Color(red:0.914, green:0.929, blue:0.937)
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment:.leading,spacing:16) { content }
            .padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(.white,in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(Theme.border,lineWidth:1))
    }
}

struct ActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(.system(size:13,weight:.medium))
            .frame(maxWidth:.infinity).frame(height:38)
            .foregroundStyle(primary ? .white : Theme.ink)
            .background(primary ? Theme.accent : Theme.track,in:RoundedRectangle(cornerRadius:7))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

struct StepHeading: View {
    let number: String
    let title: String
    var body: some View {
        HStack(spacing:8) {
            Text(number).font(.system(size:11,weight:.semibold)).foregroundStyle(Theme.accent)
                .frame(width:22,height:22).background(Theme.selected,in:Circle())
            Text(title).font(.system(size:15,weight:.semibold))
        }
    }
}

struct Bar: View {
    let fraction: Double
    var muted = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment:.leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(muted ? Theme.secondary.opacity(0.45) : Theme.accent.opacity(0.85))
                    .frame(width:max(0,geo.size.width * min(1,max(0,fraction))))
            }
        }.frame(height:7)
    }
}
