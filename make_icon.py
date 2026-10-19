#!/usr/bin/env python3
"""
Generate MeetingRecorder.icns from a programmatically drawn microphone icon.
Draws a clean vector mic using AppKit, renders at all required icon sizes.
"""
import subprocess, os, shutil, tempfile

SCRIPT = """
import AppKit
import Foundation

func drawMicIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    
    let s = size
    let pad = s * 0.12
    
    // --- Background: rounded rectangle with dark fill ---
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: s * 0.22, yRadius: s * 0.22)
    NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1).setFill()
    bg.fill()
    
    NSColor.white.setFill()
    NSColor.white.setStroke()
    
    // --- Mic capsule body ---
    let capW = s * 0.28
    let capH = s * 0.38
    let capX = (s - capW) / 2
    let capY = s * 0.42
    let cap = NSBezierPath(roundedRect: NSRect(x: capX, y: capY, width: capW, height: capH),
                           xRadius: capW / 2, yRadius: capW / 2)
    cap.fill()
    
    // --- Arc stand ---
    let arcPath = NSBezierPath()
    arcPath.lineWidth = s * 0.065
    arcPath.lineCapStyle = .round
    let arcRad = s * 0.25
    let cx = s / 2
    let cy = s * 0.44
    arcPath.appendArc(withCenter: NSPoint(x: cx, y: cy),
                      radius: arcRad,
                      startAngle: 0, endAngle: 180, clockwise: false)
    arcPath.stroke()
    
    // --- Vertical base line ---
    let linePath = NSBezierPath()
    linePath.lineWidth = s * 0.065
    linePath.lineCapStyle = .round
    linePath.move(to: NSPoint(x: cx, y: cy - arcRad))
    linePath.line(to: NSPoint(x: cx, y: cy - arcRad - s * 0.10))
    linePath.stroke()
    
    // --- Horizontal foot ---
    let footW = s * 0.28
    let footPath = NSBezierPath()
    footPath.lineWidth = s * 0.065
    footPath.lineCapStyle = .round
    footPath.move(to: NSPoint(x: cx - footW/2, y: cy - arcRad - s * 0.10))
    footPath.line(to: NSPoint(x: cx + footW/2, y: cy - arcRad - s * 0.10))
    footPath.stroke()
    
    img.unlockFocus()
    return img
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = "/tmp/iconset_tmp.iconset"

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for sz in sizes {
    let img = drawMicIcon(size: CGFloat(sz))
    let name = sz <= 16 ? "icon_16x16.png" :
               sz <= 32 ? "icon_16x16@2x.png" :
               sz <= 64 ? "icon_32x32@2x.png" :
               sz <= 128 ? "icon_128x128.png" :
               sz <= 256 ? "icon_128x128@2x.png" :
               sz <= 512 ? "icon_256x256@2x.png" : "icon_512x512@2x.png"
    let url = URL(fileURLWithPath: outDir + "/" + name)
    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: url)
        print("Wrote \\(name)")
    }
}
print("DONE")
"""

# Write and run the Swift script
tmp = tempfile.mktemp(suffix='.swift')
with open(tmp, 'w') as f:
    f.write(SCRIPT)

result = subprocess.run(['swift', tmp], capture_output=True, text=True, timeout=60)
print(result.stdout)
if result.returncode != 0:
    print("STDERR:", result.stderr[-500:])
    raise SystemExit(1)

# Convert iconset → .icns
iconset_path = '/tmp/iconset_tmp.iconset'
icns_out = '/Users/virgoh/MeetingRecorder/AppIcon.icns'

r = subprocess.run(['iconutil', '-c', 'icns', iconset_path, '-o', icns_out],
                   capture_output=True, text=True)
print("iconutil:", r.returncode, r.stderr or "OK")

# Copy to app bundle Resources
bundle_res = '/Users/virgoh/MeetingRecorder/MeetingRecorder.app/Contents/Resources/'
os.makedirs(bundle_res, exist_ok=True)
shutil.copy(icns_out, bundle_res + 'AppIcon.icns')
print(f"Icon installed → {bundle_res}AppIcon.icns")

os.unlink(tmp)
shutil.rmtree(iconset_path, ignore_errors=True)
