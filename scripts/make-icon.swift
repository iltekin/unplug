// Uygulama ikonunu üretir: mavi zemin üzerinde beyaz iki monitör.
// SF Symbols lisansı sembollerin uygulama ikonunda kullanılmasına izin vermediği için
// monitörler burada elle çizilir.
// Kullanım: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")

/// Beyaz çerçeveli, yarı saydam ekranlı, ayaklı bir monitör çizer (1024'lük koordinatlarda).
func drawMonitor(screen: NSRect) {
    let line: CGFloat = 30
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: screen.insetBy(dx: line, dy: line), xRadius: 18, yRadius: 18).fill()

    NSColor.white.setStroke()
    let frame = NSBezierPath(roundedRect: screen.insetBy(dx: line / 2, dy: line / 2), xRadius: 40, yRadius: 40)
    frame.lineWidth = line
    frame.stroke()

    NSColor.white.setFill()
    let neckWidth: CGFloat = 56, neckHeight: CGFloat = 50
    NSRect(x: screen.midX - neckWidth / 2, y: screen.minY - neckHeight, width: neckWidth, height: neckHeight + 2).fill()
    let baseWidth = screen.width * 0.34, baseHeight: CGFloat = 30
    NSBezierPath(roundedRect: NSRect(x: screen.midX - baseWidth / 2, y: screen.minY - neckHeight - baseHeight + 4,
                                     width: baseWidth, height: baseHeight),
                 xRadius: baseHeight / 2, yRadius: baseHeight / 2).fill()
}

func render(size: CGFloat) -> Data {
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS ikon ızgarası: 1024'lük tuvalde 824'lük yuvarlatılmış kare.
    let body = canvas.insetBy(dx: 100 * s, dy: 100 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let dropShadow = NSShadow()
    dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    dropShadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    dropShadow.shadowBlurRadius = 20 * s
    dropShadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 0.31, green: 0.64, blue: 1.0, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.36, blue: 0.86, alpha: 1))!
        .draw(in: shape, angle: -90)

    // Çizim 1024'lük koordinatlarda yapılır ve boyuta göre ölçeklenir.
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.scaleBy(x: s, y: s)
    context.translateBy(x: -4, y: 0)   // iki monitörü görsel olarak ortala

    let symbolShadow = NSShadow()
    symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    symbolShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    symbolShadow.shadowBlurRadius = 12 * s
    symbolShadow.set()
    context.beginTransparencyLayer(auxiliaryInfo: nil)

    let back = NSRect(x: 232, y: 410, width: 420, height: 300)
    let front = NSRect(x: 520, y: 390, width: 280, height: 204)

    // Öndeki monitörün etrafında boşluk kalsın diye arkadakini oradan kırp.
    NSGraphicsContext.saveGraphicsState()
    let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    clip.append(NSBezierPath(roundedRect: front.insetBy(dx: -18, dy: -18), xRadius: 56, yRadius: 56))
    clip.windingRule = .evenOdd
    clip.addClip()
    drawMonitor(screen: back)
    NSGraphicsContext.restoreGraphicsState()
    drawMonitor(screen: front)

    context.endTransparencyLayer()
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(size: CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: output.deletingPathExtension().appendingPathExtension("png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote \(output.path)")
