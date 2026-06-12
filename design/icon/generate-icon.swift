import AppKit

// Final Murmur icon: G3 "wave-M" with tails up, nudged down for vertical balance.
// Renders every size the .iconset needs, plus a preview.

func C(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat=1) -> CGColor { CGColor(srgbRed: r/255,green: g/255,blue: b/255,alpha: a) }
let TEAL = C(52,231,200), INDIGO = C(99,102,241)
let DTOP = C(22,26,36), DBOT = C(10,12,18)

func smooth(_ pts: [(CGFloat,CGFloat)], samples: Int = 40) -> [(CGFloat,CGFloat)] {
    func cr(_ p0:(CGFloat,CGFloat),_ p1:(CGFloat,CGFloat),_ p2:(CGFloat,CGFloat),_ p3:(CGFloat,CGFloat),_ t:CGFloat)->(CGFloat,CGFloat){
        let t2=t*t, t3=t2*t
        func f(_ a:CGFloat,_ b:CGFloat,_ c:CGFloat,_ d:CGFloat)->CGFloat{ 0.5*((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t2+(-a+3*b-3*c+d)*t3) }
        return (f(p0.0,p1.0,p2.0,p3.0), f(p0.1,p1.1,p2.1,p3.1))
    }
    var out:[(CGFloat,CGFloat)]=[]; let e=[pts.first!]+pts+[pts.last!]
    for i in 1..<(e.count-2){ for s in 0..<samples{ out.append(cr(e[i-1],e[i],e[i+1],e[i+2],CGFloat(s)/CGFloat(samples))) } }
    out.append(pts.last!); return out
}

func render(_ S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // background squircle + gradient
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x:0,y:0,width:S,height:S), cornerWidth: S*0.2237, cornerHeight: S*0.2237, transform: nil))
    ctx.clip()
    let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors:[DTOP,DBOT] as CFArray, locations:[0,1])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x:0,y:S), end: CGPoint(x:0,y:0), options: [])
    // glow (centered on the wave)
    let gc = C(99,102,241,0.20)
    let gGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors:[gc,gc.copy(alpha:0)!] as CFArray, locations:[0,1])!
    ctx.drawRadialGradient(gGrad, startCenter: CGPoint(x:S/2,y:S*0.47), startRadius:0, endCenter: CGPoint(x:S/2,y:S*0.47), endRadius:S*0.55, options:[])

    // wave-M, lowered for balance
    let pts:[(CGFloat,CGFloat)] = [ (0.06,0.54),(0.19,0.34),(0.33,0.70),(0.50,0.485),(0.67,0.70),(0.81,0.34),(0.94,0.54) ]
    let sm = smooth(pts)
    let path = CGMutablePath()
    for (i,p) in sm.enumerated(){ let pt=CGPoint(x:p.0*S,y:p.1*S); if i==0 { path.move(to:pt) } else { path.addLine(to:pt) } }
    ctx.addPath(path); ctx.setLineWidth(S*0.10); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    let wGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors:[TEAL,INDIGO] as CFArray, locations:[0,1])!
    ctx.drawLinearGradient(wGrad, start: CGPoint(x:S*0.08,y:0), end: CGPoint(x:S*0.92,y:0), options:[])
    ctx.restoreGState()
    return rep
}

func write(_ rep: NSBitmapImageRep,_ path: String){ try! rep.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath:path)) }

let outDir = "/tmp/murmuricon/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// (filename, pixel size)
let specs: [(String, CGFloat)] = [
    ("icon_16x16.png",16),("icon_16x16@2x.png",32),
    ("icon_32x32.png",32),("icon_32x32@2x.png",64),
    ("icon_128x128.png",128),("icon_128x128@2x.png",256),
    ("icon_256x256.png",256),("icon_256x256@2x.png",512),
    ("icon_512x512.png",512),("icon_512x512@2x.png",1024),
]
for (name,size) in specs { write(render(size), "\(outDir)/\(name)") }
write(render(1024), "/tmp/murmuricon/G3_final_preview.png")
print("rendered iconset + preview")
