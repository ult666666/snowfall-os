// Run with 'swift tests/check-wallpaper-art.swift', optionally followed by a built .app path.
import AppKit
import WebKit

let size = CGSize(width: 1024, height: 680)
let names = ["Observatory", "Map Room", "Music Box", "Ice Library", "Orchard", "Blue Studio"]
func fail(_ message: String) -> Never { fputs("FAIL: \(message)\n", stderr); exit(1) }

@MainActor final class WallpaperShot: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let root: URL, hideArt: Bool
    let window: NSWindow
    let web: WKWebView

    init(root: URL, hideArt: Bool) {
        self.root = root
        self.hideArt = hideArt
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: "window.snowfallNative=true; window.snowfallSurface='wallpaper';",
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let frame = CGRect(origin: .zero, size: size)
        web = WKWebView(frame: frame, configuration: config)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        controller.add(self, name: "snowfallWindow")
        web.navigationDelegate = self
        window.contentView = web
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 8)
    }

    func run() {
        window.orderBack(nil)
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
    var completed: (([UInt8], [[Double]]) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        var plots: [[String: Any]] = []
        for (i, name) in names.enumerated() {
            let x = 0.42 + Double(i % 3) * 0.19, y = 0.47 + Double(i / 3) * 0.26
            plots.append(["id": "fixture-\(i)", "name": name, "variant": i+1, "x": x, "y": y, "size": 86, "drawHouse": true])
        }
        let script = """
        document.documentElement.dataset.surface = 'wallpaper';
        window.dispatchEvent(new CustomEvent('snowfall-surface', {detail:'wallpaper'}));
        const style = document.createElement('style');
        style.textContent = '#snow,#village-life{visibility:hidden!important}' +
          (hiddenArt ? '.wallpaper-cottage img,.address-lettering{visibility:hidden!important}' : '');
        document.head.append(style);
        await document.querySelector('#wallpaper').decode();
        window.dispatchEvent(new CustomEvent('snowfall-house-plots', {detail:plots}));
        const cards = Array.from(document.querySelectorAll('#wallpaper-cottages .wallpaper-cottage'));
        await Promise.all(cards.map(card => card.querySelector('img').decode()));
        return cards.map(card => {
          const text = card.querySelector('.address-lettering'), sprite = card.querySelector('img');
          if (!hiddenArt && [sprite,text].some(el=>getComputedStyle(el).visibility!=='visible' || Number(getComputedStyle(el).opacity)===0)) {
            throw Error('A cottage sprite or address is hidden');
          }
          const b = card.getBoundingClientRect(), t = text.getBoundingClientRect();
          return [b.x,b.y,b.width,b.height,t.x,t.y,t.width,t.height];
        });
        """
        web.callAsyncJavaScript(script, arguments: ["plots": plots, "hiddenArt": hideArt], in: nil, in: .page) { result in
            guard case .success(let value) = result, let boxes = value as? [[Double]], boxes.count == names.count else {
                fail("The native wallpaper did not load six cottage sprites and addresses. \(result)")
            }
            let snapshot = WKSnapshotConfiguration()
            snapshot.afterScreenUpdates = true
            // Decode completes ahead of WebKit's first compositor transaction.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.web.takeSnapshot(with: snapshot) { image, error in
                    guard let image, let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        fail(error?.localizedDescription ?? "Wallpaper snapshot unavailable.")
                    }
                    let w = Int(size.width), h = Int(size.height)
                    var pixels = [UInt8](repeating: 0, count: w*h*4)
                    pixels.withUnsafeMutableBytes { bytes in
                        let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                        guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                                  bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format) else { fail("Bitmap allocation failed.") }
                        ctx.draw(raster, in: CGRect(origin: .zero, size: size))
                    }
                    self.window.orderOut(nil)
                    self.completed?(pixels, boxes)
                }
            }
        }
    }
}

func changedPixels(_ a: [UInt8], _ b: [UInt8], in box: CGRect) -> Int {
    let rect = box.integral.intersection(CGRect(origin: .zero, size: size))
    guard !rect.isEmpty else { return 0 }
    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let p = (y * Int(size.width) + x) * 4
            if (0..<3).contains(where: { abs(Int(a[p+$0]) - Int(b[p+$0])) > 24 }) { count += 1 }
        }
    }
    return count
}

let args = Array(CommandLine.arguments.dropFirst())
let root = args.isEmpty ? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                        : URL(fileURLWithPath: args[0]).appendingPathComponent("Contents/Resources/Desktop")
guard FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else { fail("Missing Snowfall web resources.") }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let drawn = WallpaperShot(root: root, hideArt: false)
    drawn.completed = { pixels, boxes in
        let baseline = WallpaperShot(root: root, hideArt: true)
        baseline.completed = { reference, _ in
            // Both snapshots must be of the same painted landscape. A blank, occluded
            // first frame would otherwise differ from every roof and falsely pass.
            let referenceStrip = CGRect(x: 8, y: 24, width: 100, height: size.height - 48)
            guard changedPixels(pixels, reference, in: referenceStrip) < 150 else { fail("Wallpaper snapshots have different landscapes.") }
            for (i, p) in boxes.enumerated() {
                guard p.count == 8 else { fail("Invalid cottage bounds.") }
                let house = CGRect(x:p[0], y:p[1], width:p[2], height:p[3]*0.82)
                let label = CGRect(x:p[4], y:p[5], width:p[6], height:p[7])
                let facade = changedPixels(pixels, reference, in: house), lettering = changedPixels(pixels, reference, in: label)
                guard facade > 800, lettering > 18 else { fail("\(names[i]) painted \(facade) facade and \(lettering) lettering pixels.") }
            }
            print("PASS: six cottage facades and six readable nameplates in the file-backed native wallpaper.")
            exit(0)
        }
        baseline.run()
    }
    Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in fail("Timed out waiting for the wallpaper renderer.") }
    drawn.run()
}
app.run()
