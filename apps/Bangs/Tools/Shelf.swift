import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files parked on the notch: drag them in, drag them out wherever they go next.
@MainActor
final class Shelf: ObservableObject {
    @Published private(set) var files: [URL] = []
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
        files = (Storage.load([String].self, from: "shelf.json") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
        save()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        save()
    }

    func clear() {
        files.removeAll()
        save()
    }

    /// Files moved or deleted since they were parked (a drag to Finder moves a file on the same disk) leave the shelf.
    func prune() {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard existing.count != files.count else { return }
        files = existing
        save()
    }

    /// A file was dropped somewhere else.
    func draggedOut(_ url: URL) {
        if preferences.shelfRemovesOnDragOut { remove(url) } else { prune() }
    }

    /// Reads dropped file URLs.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.add([url]) } }
            }
        }
        return true
    }

    private func save() {
        Storage.save(files.map(\.path), to: "shelf.json")
    }
}

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    var targeted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shelf.files.isEmpty || targeted {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 13))
                    Text(targeted ? "松开放进中转站" : "把文件拖到刘海上就放进来；拖到任何地方就取走")
                }
                .font(.system(size: 12))
                .foregroundStyle(targeted ? Palette.ink : Palette.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? Palette.accent : Palette.wash(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(targeted ? Palette.accent.opacity(0.12) : .clear)))
            }
            if !shelf.files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(shelf.files, id: \.self) { url in
                            ShelfItem(url: url, shelf: shelf)
                        }
                    }
                }
                .scrollIndicators(.never)
                HStack {
                    Text("\(shelf.files.count) 项 · 拖出去即可取走，单击打开").font(.system(size: 10.5)).foregroundStyle(Palette.dim)
                    Spacer()
                    Button("清空") { shelf.clear() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
        .onAppear { shelf.prune() }
    }
}

struct ShelfItem: View {
    let url: URL
    @ObservedObject var shelf: Shelf
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: Thumbnails.preview(for: url, points: 56))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .frame(width: 80, height: 64)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.wash(hovering ? 0.12 : 0.06)))
                    .overlay(DragSource(url: url, onDraggedOut: { shelf.draggedOut(url) }))
                if hovering {
                    Button { shelf.remove(url) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }
            .overlay(alignment: .topLeading) {
                if hovering { SendToAgentIcon { .files([url]) }.offset(x: -4, y: -4) }
            }
            Text(url.lastPathComponent).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle).frame(width: 80)
        }
        .onHover { hovering = $0 }
        .help(url.path)
    }

}

/// Lets a file be dragged out of the island to Finder or any app, and tells when it landed somewhere. A click opens it.
struct DragSource: NSViewRepresentable {
    let url: URL
    var onDraggedOut: () -> Void = {}
    /// Instead of opening the file.
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.url = url
        view.onDraggedOut = onDraggedOut
        view.onClick = onClick
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var onDraggedOut: () -> Void = {}
    var onClick: (() -> Void)?
    private var dragged = false

    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let url else { return }
        dragged = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: MainActor.assumeIsolated { Thumbnails.preview(for: url, points: 64) })
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged, let url else { return }
        if let onClick { onClick() } else { NSWorkspace.shared.open(url) }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDraggedOut() }
    }
}
