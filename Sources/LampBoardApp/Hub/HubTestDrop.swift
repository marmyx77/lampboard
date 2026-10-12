import AppKit

/// A drop on the Hub's terminal, as AppKit hands one to it, for the end-to-end
/// suite (fake home only): its own pasteboard, the files or the text on it.
@MainActor
enum HubTestDrop {

    static func drop(on view: NSView, files: [String], text: String?) -> Bool {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lampboard.test.drop"))
        pasteboard.clearContents()
        if !files.isEmpty {
            pasteboard.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
        } else if let text {
            pasteboard.setString(text, forType: .string)
        }
        let info = TestDraggingInfo(pasteboard: pasteboard, window: view.window)
        guard view.draggingEntered(info) != [] else { return false }
        return view.performDragOperation(info)
    }
}

/// What AppKit hands a view at a drop, made by hand.
private final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, window: NSWindow?) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
