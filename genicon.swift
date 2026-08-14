// genicon.swift — 生成 DeepSeekSpend 的 App 图标（圆角渐变 + ¥ 符号）
// 用法: swift genicon.swift <输出.png>
import AppKit

let size = CGSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let insetRect = rect.insetBy(dx: 56, dy: 56)
let path = NSBezierPath(roundedRect: insetRect, xRadius: 216, yRadius: 216)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.24, green: 0.46, blue: 0.96, alpha: 1),
    NSColor(calibratedRed: 0.52, green: 0.32, blue: 0.95, alpha: 1),
])!
gradient.draw(in: path, angle: -65)

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 620, weight: .heavy),
    .foregroundColor: NSColor.white,
]
let str = NSAttributedString(string: "¥", attributes: attrs)
let strSize = str.size()
str.draw(at: NSPoint(x: (size.width - strSize.width) / 2, y: (size.height - strSize.height) / 2 - 70))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("无法生成图标")
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("图标已生成: \(CommandLine.arguments[1])")
