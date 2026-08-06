import SwiftUI
import UniformTypeIdentifiers

/// Wrapper that lets `DocumentGroup(viewing:)` treat 3D model files as
/// documents — Open, Open Recent, Finder double-click, Dock drop, native
/// window tabbing (one tab per file) all come from the system for free once
/// a type conforms to `FileDocument`.
///
/// Deliberately does no real work: `FileDocument`'s read path can't hand back
/// a real on-disk `URL` (only a `FileWrapper`), and this app's loaders
/// (`ModelLoader`) need the real URL — for external-texture resolution on FBX
/// files, and because `GLTFAsset`/`MDLAsset` both load from a URL, not raw
/// `Data`. So this struct only satisfies the protocol; the actual model load
/// happens in `ContentView`, fed by `FileDocumentConfiguration.fileURL`
/// (exposed to the `DocumentGroup(viewing:)` editor closure, not to this
/// type's own initializer).
struct Peek3DDocument: FileDocument {
    static var readableContentTypes: [UTType] { ModelLoader.supportedContentTypes }

    init(configuration: ReadConfiguration) throws {}

    /// Never called — `.viewing` documents have no Save/Save As commands.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteUnsupportedScheme)
    }
}
