import DuckyCore
import SwiftUI

/// The keyboard drawn to scale. With `onStroke`, clicking or dragging reports each key once per stroke.
struct KeyboardCanvas: View {
    private let colors: [RGB]
    private let onStroke: ((Int) -> Void)?
    @State private var stroked = Set<Int>()

    init(colors: [RGB], onStroke: ((Int) -> Void)? = nil) {
        self.colors = colors
        self.onStroke = onStroke
    }

    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width / KeyboardLayout.width, geometry.size.height / KeyboardLayout.height)
            ZStack(alignment: .topLeading) {
                ForEach(KeyboardLayout.keys) { key in
                    let color = colors.indices.contains(key.id) ? colors[key.id] : .black
                    let frame = rect(for: key, unit: unit)
                    RoundedRectangle(cornerRadius: unit * 0.12)
                        .fill(Color(color))
                        .overlay(RoundedRectangle(cornerRadius: unit * 0.12).stroke(.black.opacity(0.35), lineWidth: 1))
                        .overlay(Text(key.legend).font(.system(size: max(7, unit * 0.28), weight: .medium)).foregroundStyle(color.legendColor))
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(width: unit * KeyboardLayout.width, height: unit * KeyboardLayout.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in hit(value.location, unit: unit) }
                    .onEnded { _ in stroked.removeAll() },
                including: onStroke == nil ? .none : .all
            )
        }
        .aspectRatio(KeyboardLayout.width / KeyboardLayout.height, contentMode: .fit)
    }

    private func rect(for key: KeyInfo, unit: CGFloat) -> CGRect {
        CGRect(x: key.x * unit + 2, y: key.y * unit + 2, width: key.width * unit - 4, height: key.height * unit - 4)
    }

    private func hit(_ point: CGPoint, unit: CGFloat) {
        guard unit > 0, let key = KeyboardLayout.key(atX: point.x / unit, y: point.y / unit), !stroked.contains(key.id) else { return }
        stroked.insert(key.id)
        onStroke?(key.id)
    }
}
