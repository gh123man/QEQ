import AppKit
import QuartzCore
import SwiftUI

/// Documentation-only desktop context around the actual QEQ view.
/// All wallpaper/menu-bar elements are synthetic; no screen or audio capture.
@MainActor
struct DesktopScreenshot: View {
    @ObservedObject var model: MixerModel
    let panelHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            menuBar
            VStack(spacing: 0) {
                Triangle().fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 20, height: 10)
                    .frame(width: 500, alignment: .leading).padding(.leading, 268)
                    .frame(width: 500, alignment: .leading).clipped()
                MixerView(model: model)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            }
            .frame(width: 500, height: panelHeight + 10)
            .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 16)
            .offset(x: 478, y: 33)
        }
        .frame(width: 1000, height: 720)
        .clipped()
        .environment(\.controlActiveState, .active)
    }

    private var wallpaper: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.10, blue: 0.26), Color(red: 0.18, green: 0.24, blue: 0.47),
                    Color(red: 0.42, green: 0.29, blue: 0.48),
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            Ellipse().fill(
                LinearGradient(
                    colors: [Color(red: 0.57, green: 0.46, blue: 0.70), Color(red: 0.18, green: 0.23, blue: 0.48)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 1430, height: 700).rotationEffect(.degrees(-27)).offset(x: -310, y: 190)
            .shadow(color: .black.opacity(0.3), radius: 70, x: 30, y: 10)
            Ellipse().fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.30, green: 0.57, blue: 0.75), Color(red: 0.10, green: 0.26, blue: 0.45),
                        Color(red: 0.04, green: 0.12, blue: 0.28),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 1340, height: 520).rotationEffect(.degrees(-32)).offset(x: -360, y: 340)
            .shadow(color: Color(red: 0.07, green: 0.12, blue: 0.28).opacity(0.55), radius: 45, x: 0, y: -20)
            Ellipse().fill(
                LinearGradient(
                    colors: [Color(red: 0.26, green: 0.47, blue: 0.62), Color(red: 0.04, green: 0.10, blue: 0.23)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 1400, height: 450).rotationEffect(.degrees(-30)).offset(x: -180, y: 580)
        }.frame(width: 1000, height: 720).clipped()
    }

    private var menuBar: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.white.opacity(0.09)).frame(height: 30)
            HStack(spacing: 22) {
                Image(systemName: "apple.logo").font(.system(size: 16))
                Text("Finder").fontWeight(.semibold)
                Text("File")
                Text("Edit")
                Text("View")
                Text("Go")
                Text("Window")
                Text("Help")
            }.font(.system(size: 13)).frame(height: 30).padding(.leading, 20)
            RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.22))
                .frame(width: 34, height: 26).position(x: 756, y: 15)
            Image(nsImage: MenuBarIcon.makeImage()).renderingMode(.template)
                .frame(width: 18, height: 18).position(x: 756, y: 15)
            Image(systemName: "wifi").position(x: 796, y: 15)
            Image(systemName: "switch.2").position(x: 832, y: 15)
            Image(systemName: "battery.100percent").position(x: 870, y: 15)
            Text("Mon 9:41").font(.system(size: 12, weight: .medium)).position(x: 930, y: 15)
        }.font(.system(size: 14)).foregroundStyle(.white.opacity(0.95)).frame(width: 1000, height: 30)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }

    static func render(model: MixerModel, panelHeight: CGFloat, appearance: NSAppearance?, to path: URL) throws {
        let host = NSHostingController(rootView: DesktopScreenshot(model: model, panelHeight: panelHeight))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: 0, width: 1000, height: 720), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.appearance = appearance
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<16 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.035))
            host.view.layoutSubtreeIfNeeded()
            host.view.displayIfNeeded()
            CATransaction.flush()
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1440, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 1000, height: 720)
        ScreenshotControls.prepare(in: host.view)
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        print("Desktop preview: \(path.lastPathComponent)")
    }
}
