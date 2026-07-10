import SwiftUI
import Foundation
import SceneKit
import Metal
import AppKit

@main
struct GLBViewerApp: App {

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// Headless verification hook. Set `GLBVIEWER_SELFTEST=/path/to/model` to load a
/// file through the real `ModelLoader`, print the computed stats, and exit —
/// no window required. Used to verify the load path from the command line.
enum SelfTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["GLBVIEWER_SELFTEST"] else { return }
        let url = URL(fileURLWithPath: path)
        do {
            let (scene, stats) = try ModelLoader.loadSync(url: url)
            _ = scene
            print("SELFTEST_OK")
            print("file: \(stats.fileName)")
            print("triangles: \(stats.triangleCount)")
            print("vertices: \(stats.vertexCount)")
            print("meshes: \(stats.meshCount)")
            print("materials: \(stats.materialCount)")
            print(String(format: "dimensions: %.4f x %.4f x %.4f",
                         stats.dimensions.x, stats.dimensions.y, stats.dimensions.z))
            print("fileSize: \(stats.fileSizeBytes) bytes (\(stats.fileSizeFormatted))")

            if let out = ProcessInfo.processInfo.environment["GLBVIEWER_SELFTEST_RENDER"] {
                let ok = renderOffscreen(scene: scene, to: URL(fileURLWithPath: out))
                print(ok ? "render: OK -> \(out)" : "render: FAILED")
            }
            fflush(stdout)
            exit(0)
        } catch {
            print("SELFTEST_FAIL: \(error.localizedDescription)")
            fflush(stdout)
            exit(1)
        }
    }

    /// Renders the loaded scene offscreen (Metal, no window) and writes a PNG.
    /// Verifies the render pipeline + camera fit produce a visible image.
    private static func renderOffscreen(scene: SCNScene, to url: URL) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true

        let camera = CameraFit.makeFittedCamera(for: scene)
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera

        let size = CGSize(width: 900, height: 600)
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
