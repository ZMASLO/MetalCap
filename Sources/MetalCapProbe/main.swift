// A minimal Metal app for end-to-end tests: clears a window at a fixed frame rate for a while.
// Usage: MetalCapProbe [seconds = 10] [frames per second = 60]
import AppKit
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue

    init(device: MTLDevice) {
        queue = device.makeCommandQueue()!
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

let arguments = CommandLine.arguments.dropFirst().compactMap(Double.init)
let seconds = arguments.first ?? 10
let framesPerSecond = arguments.dropFirst().first.map(Int.init) ?? 60

let app = NSApplication.shared
app.setActivationPolicy(.regular)
guard let device = MTLCreateSystemDefaultDevice() else { exit(1) }
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 300),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "MetalCap probe"
let view = MTKView(frame: window.contentView!.bounds, device: device)
view.clearColor = MTLClearColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1)
view.preferredFramesPerSecond = framesPerSecond
let renderer = Renderer(device: device)
view.delegate = renderer
window.contentView = view
window.makeKeyAndOrderFront(nil)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
