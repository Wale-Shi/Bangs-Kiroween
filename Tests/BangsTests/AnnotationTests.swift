import AppKit
import XCTest
@testable import Bangs

@MainActor
final class AnnotationTests: XCTestCase {
    private func mark(_ kind: Annotation.Kind) -> Annotation { Annotation(kind: kind, color: .red, size: .medium) }

    func testUndoRedoAndOneStepPerDrag() {
        let model = AnnotationModel()
        model.add(mark(.rectangle(CGRect(x: 0, y: 0, width: 10, height: 10))))
        model.add(mark(.counter(1, at: .zero)))
        XCTAssertEqual(model.annotations.count, 2)
        model.undo()
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertTrue(model.canRedo)
        model.redo()
        XCTAssertEqual(model.annotations.count, 2)
        // A drag is live while it moves, and one step to undo.
        model.begin()
        model.live([mark(.counter(1, at: CGPoint(x: 5, y: 5)))])
        model.live([mark(.counter(1, at: CGPoint(x: 9, y: 9)))])
        model.end()
        model.undo()
        XCTAssertEqual(model.annotations.count, 2)
    }

    func testCountersNumberOnAndPickingAColourRestylesTheSelection() {
        let model = AnnotationModel()
        model.color = .red
        model.add(mark(.counter(1, at: .zero)))
        model.add(mark(.counter(2, at: .zero)))
        XCTAssertEqual(model.nextCounter, 3)
        model.selected = 0
        model.color = .blue
        XCTAssertEqual(model.annotations[0].color, .blue)
        XCTAssertEqual(model.annotations[1].color, .red)
        model.removeSelected()
        XCTAssertEqual(model.annotations.count, 1)
    }

    func testRendersAtTheScreenshotsResolutionWithMosaicsUnderneath() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try XCTUnwrap(context.makeImage())
        let marks = [mark(.arrow(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 90, y: 45))), mark(.mosaic(CGRect(x: 0, y: 0, width: 50, height: 50)))]
        let out = try XCTUnwrap(AnnotationRenderer.render(image, annotations: marks, scale: 2, mosaic: AnnotationRenderer.pixelated(image, scale: 2)))
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 100)
        XCTAssertEqual(AnnotationRenderer.layered(marks).first?.isMosaic, true)
    }

    func testPicksAShapeOnItsLineNotInsideIt() {
        let rectangle = mark(.rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(AnnotationRenderer.hits(rectangle, CGPoint(x: 1, y: 50)))
        XCTAssertFalse(AnnotationRenderer.hits(rectangle, CGPoint(x: 50, y: 50)))
        XCTAssertTrue(AnnotationRenderer.hits(mark(.counter(1, at: CGPoint(x: 10, y: 10))), CGPoint(x: 12, y: 8)))
        let moved = rectangle.moved(by: CGVector(dx: 10, dy: 5))
        XCTAssertEqual(moved.kind, .rectangle(CGRect(x: 10, y: 5, width: 100, height: 100)))
    }
}
