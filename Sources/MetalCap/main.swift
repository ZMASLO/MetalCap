import Foundation
import MetalCapCore

// `MetalCap --run <app or executable> [--seconds N]` benchmarks headlessly:
// launches the target with the HUD on, records for N seconds and prints the metrics.
let arguments = CommandLine.arguments
if let runIndex = arguments.firstIndex(of: "--run"), runIndex + 1 < arguments.count {
    let seconds = arguments.firstIndex(of: "--seconds")
        .flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 10
    let source = LaunchedProcessSource(url: URL(fileURLWithPath: arguments[runIndex + 1]))
    let recorder = CaptureRecorder()
    source.onEvent = { event in DispatchQueue.main.async { recorder.ingest(event) } }
    do { try source.start() } catch {
        FileHandle.standardError.write(Data("MetalCap: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    recorder.start(at: Date(), preferredPID: source.pid)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        recorder.stop(at: Date())
        // Give the HUD time to log the line covering the last frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            source.terminate()
            guard let capture = recorder.finish(), let metrics = capture.metrics else {
                print("No frames captured.")
                exit(2)
            }
            print(String(format: "%@: %d frames in %.2f s (coverage %.1f%%, missing frames: %d)",
                         capture.processName, metrics.frameCount, metrics.duration,
                         (capture.coverage ?? .nan) * 100, capture.missingFrames ?? 0))
            print(String(format: "AVG %.1f | P1 %.1f | 1%% Low avg %.1f | 1%% Low integral %.1f | 0.1%% Low avg %.1f | min %.1f | max %.1f",
                         metrics.average, metrics.p1, metrics.onePercentLowAverage,
                         metrics.onePercentLowIntegral, metrics.pointOnePercentLowAverage,
                         metrics.min, metrics.max))
            exit(0)
        }
    }
    dispatchMain()
} else {
    MetalCapApp.main()
}
