import XCTest
import UIKit

@MainActor final class ImageLayoutUITests: XCTestCase {
    func testCoverRemainsVisibleInAllThreeLayouts() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400), format: format).image { context in
            UIColor(red: 0.9, green: 0.1, blue: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        }
        let server = try LocalPageServer(image: XCTUnwrap(picture.pngData())); defer { server.listener.cancel() }
        let imageURI = server.url + "cover.png"
        let app = XCUIApplication(), title = "封面回归-" + String(UUID().uuidString.prefix(6))
        app.launch(); app.tabBars.buttons["设置"].tap()
        let management = app.buttons["管理网站"]; reveal(management, in: app); management.tap()
        app.buttons["添加或导入站点"].tap(); app.buttons["创建站点规则"].tap()
        let name = app.textFields["站点名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(title)
        let address = app.textFields["入口 URL"]
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)); address.typeText(server.url)
        app.buttons["创建配置并打开页面"].tap(); app.segmentedControls.buttons["高级"].tap()
        let editor = app.textViews["完整站点 YAML"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.press(forDuration: 1)
        let all = app.menuItems["Select All"].exists ? app.menuItems["Select All"] : app.menuItems["全选"]
        XCTAssertTrue(all.waitForExistence(timeout: 3)); all.tap()
        editor.typeText("""
        schemaVersion: 1
        id: ui.cover.\(UUID().uuidString)
        name: \(title)
        match:
          hosts: [127.0.0.1]
        entries:
          - id: main
            name: \(title)
            path: \(server.url)
            category: video
        rules:
          - id: catalog
            role: catalog
            contentType: video
            extract:
              script: |
                return [{title:'封面内容',url:'/video',thumbnail:'\(imageURI)'}];
        """)
        app.buttons["保存"].tap()
        let cell = app.cells.containing(.staticText, identifier: title).firstMatch
        reveal(cell, in: app); cell.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "封面内容").firstMatch.waitForExistence(timeout: 10))
        for layout in ["列表", "竖版", "Bento"] {
            app.buttons["browser-layout-menu"].tap(); app.buttons[layout].tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "封面内容").firstMatch.waitForExistence(timeout: 3))
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                ((try? self.magentaPixels(in: app.screenshot().image)) ?? 0) > 10_000
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed, "实际图片必须显示，不能只显示占位图")
            let snapshot = XCTAttachment(screenshot: app.screenshot()); snapshot.name = "cover-" + layout
            snapshot.lifetime = .keepAlways; add(snapshot)
        }
    }
    private func magentaPixels(in image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = buffer.bindMemory(to: UInt8.self)
            var count = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[offset] > 180, pixels[offset + 1] < 80, pixels[offset + 2] > 180 { count += 1 }
            }
            return count
        }
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 { if element.isHittable { return }; app.swipeUp() }
    }
}
