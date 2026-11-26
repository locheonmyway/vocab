import Cocoa
import ApplicationServices
import ScreenCaptureKit
import Vision

struct SourceSnapshot {
    let pid: pid_t
    let appID: String
    let name: String
    let title: String
    let pointer: CGPoint  // Quartz global, top-left
    var isBooks: Bool { appID.lowercased().contains("ibooks") || appID == "com.apple.Books" }
    static func manual() -> SourceSnapshot {
        SourceSnapshot(pid:0,appID:"",name:"手动查询",title:"",pointer:CGEvent(source:nil)?.location ?? .zero)
    }
    static func front() -> SourceSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0
        var title = ""
        if AXIsProcessTrusted(), pid != 0 {
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let w = window, CFGetTypeID(w) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &value)
                title = value as? String ?? ""
            }
        }
        return SourceSnapshot(pid: pid, appID: app?.bundleIdentifier ?? "", name: app?.localizedName ?? "手动查询",
                              title: title, pointer: CGEvent(source:nil)?.location ?? .zero)
    }
}

struct Captured {
    var text: String?
    var method: String
    var status: String
    var needsEdit = false
}

enum SelectionCapture {
    private static func selectedAX(_ source: SourceSnapshot) -> String? {
        guard AXIsProcessTrusted(), source.pid != 0 else { return nil }
        let app = AXUIElementCreateApplication(source.pid)
        AXUIElementSetMessagingTimeout(app,0.40)
        var focus: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focus) == .success,
              let f = focus, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let element = f as! AXUIElement
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String, !cleanText(text).isEmpty { return text }
        // Some editors expose the range without a selectedText attribute.
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let range, CFGetTypeID(range) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &r), r.length > 0, r.length < 10000 {
                var text: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                              range, &text) == .success,
                   let s = text as? String, !cleanText(s).isEmpty { return s }
            }
        }
        return nil
    }

    private static func waitModifiers() -> Bool {
        let until = Date().addingTimeInterval(0.8)
        while Date() < until {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection([.maskControl,.maskAlternate,.maskCommand,.maskShift]).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private static func copied(_ source: SourceSnapshot) -> String? {
        guard AXIsProcessTrusted(), waitModifiers(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { return nil }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        var snapshot: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pb.pasteboardItems ?? [] {
            var entry: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type), data.count < 64 * 1024 * 1024 else { return nil }
                entry.append((type, data))
            }
            snapshot.append(entry)
        }
        guard pb.changeCount == before,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return nil }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        for _ in 0..<26 {
            Thread.sleep(forTimeInterval: 0.025)
            let changed = pb.changeCount
            guard changed != before else { continue }
            let text = pb.string(forType: .string)
            // If user copied while we waited, prefer not to restore over their clipboard.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { return nil }
            let items = snapshot.map { entry -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in entry { item.setData(data, forType: type) }
                    return item
            }
            // Check immediately before restoration, after constructing items.
            if pb.changeCount == changed,NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid {
                pb.clearContents()
                if !items.isEmpty { _ = pb.writeObjects(items) }
            }
            return text
        }
        return nil
    }

    static func selected(_ source: SourceSnapshot) -> Captured {
        if let text = selectedAX(source) { return Captured(text:text,method:"AX",status:"") }
        if let text = copied(source), !cleanText(text).isEmpty { return Captured(text:text,method:"复制",status:"") }
        return Captured(text:nil,method:"",status:AXIsProcessTrusted() ? "当前应用未提供选区" : "辅助功能尚未授权")
    }
}

enum LocalOCR {
    struct Candidate {
        var text: String
        var line: String
        var confidence: Float
        var exact: Bool
        var highlighted = false
    }
    private struct Word {
        var text: String; var line: String; var box: CGRect
        var confidence: Float; var lineNo: Int; var position: Int
        var selected: Bool = false
    }
    private struct ColorSample {
        let r:Int,g:Int,b:Int
        let share:Double
        var light:Double{Double(r+g+b)/3}
        var saturation:Int{max(r,g,b)-min(r,g,b)}
        func difference(_ other:Self)->Double {
            sqrt(Double((r-other.r)*(r-other.r)+(g-other.g)*(g-other.g)+(b-other.b)*(b-other.b)))
        }
    }
    /// Sample the dominant background (not the glyph) in a small pixel crop.
    /// Using CGImage's pixel rect directly also avoids mixing Retina points
    /// with the Vision normalized coordinate system.
    private static func dominant(_ image:CGImage,rect:CGRect)->ColorSample? {
        let pixels=rect.integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        guard pixels.width>=2,pixels.height>=2,let part=image.cropping(to:pixels) else{return nil}
        let w=min(36,part.width),h=min(22,part.height)
        var bytes=[UInt8](repeating:0,count:w*h*4)
        let hist:[Int:Int]?=bytes.withUnsafeMutableBytes { buffer in
            guard let context=CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
            context.interpolationQuality = .none
            context.draw(part,in:CGRect(x:0,y:0,width:w,height:h))
            var result:[Int:Int]=[:]
            let p=buffer.bindMemory(to:UInt8.self)
            for i in stride(from:0,to:w*h*4,by:4) {
                let r=Int(p[i])/16,g=Int(p[i+1])/16,b=Int(p[i+2])/16
                result[(r<<8)|(g<<4)|b,default:0]+=1
            }
            return result
        }
        guard let hit=hist?.max(by:{$0.value<$1.value}) else{return nil}
        return ColorSample(r:((hit.key>>8)&15)*16+8,g:((hit.key>>4)&15)*16+8,b:(hit.key&15)*16+8,
                           share:Double(hit.value)/Double(w*h))
    }
    private static func pixels(_ box:CGRect,image:CGImage)->CGRect {
        CGRect(x:box.minX*CGFloat(image.width),y:(1-box.maxY)*CGFloat(image.height),
               width:box.width*CGFloat(image.width),height:box.height*CGFloat(image.height))
    }
    private static func highlight(_ word:Word,image:CGImage,base:ColorSample)->Bool {
        let r=pixels(word.box,image:image)
        // The selection background extends a little beyond the OCR glyphs.
        let inside=r.insetBy(dx:-min(3,r.height*0.05),dy:-min(3,r.height*0.08))
        guard let fill=dominant(image,rect:inside),fill.share>=0.40,fill.difference(base)>=37 else{return false}
        // Reject high-contrast glyph colours when they dominate a very short word.
        if base.light < 65 && fill.light > 221 && fill.saturation < 22 { return false }
        if base.light > 190 && fill.light < 32 && fill.saturation < 22 { return false }
        // Confirm the background is visible next to the glyphs, at the top or bottom
        // of the word. This disambiguates a gray/blue selection rectangle from type.
        let stripH=max(2,r.height*0.24)
        let top=CGRect(x:r.minX,y:max(0,r.minY-r.height*0.09),width:r.width,height:stripH)
        let bottom=CGRect(x:r.minX,y:r.maxY-stripH+r.height*0.09,width:r.width,height:stripH)
        let samples=[dominant(image,rect:top),dominant(image,rect:bottom)].compactMap{$0}
        return samples.contains{$0.difference(fill)<35 && $0.share>=0.40 && $0.difference(base)>=32}
    }
    /// Vision normalized coordinates originate bottom-left, whereas the sampled
    /// pointer is top-left. On a Books page the actual visually highlighted
    /// selection takes precedence over the approximate mouse position.
    static func recognize(_ image: CGImage, pointer: CGPoint, preferSelection:Bool = false) throws -> Candidate? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "en-GB"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let p = CGPoint(x:pointer.x,y:1-pointer.y)
        var candidates:[Word]=[]
        let pattern = try NSRegularExpression(pattern:"[\\p{L}][\\p{L}\\p{M}'’–-]*")
        let observations=(request.results ?? []).sorted {
            if abs($0.boundingBox.midY-$1.boundingBox.midY)<0.012 {return $0.boundingBox.minX<$1.boundingBox.minX}
            return $0.boundingBox.midY>$1.boundingBox.midY
        }
        for (lineNumber,line) in observations.enumerated() {
            guard let candidate = line.topCandidates(1).first else { continue }
            let s = candidate.string
            for (position,match) in pattern.matches(in:s,range:NSRange(s.startIndex...,in:s)).enumerated() {
                guard let range = Range(match.range,in:s),
                      let box = try? candidate.boundingBox(for:range)?.boundingBox else { continue }
                candidates.append(Word(text:String(s[range]),line:s,box:box,confidence:candidate.confidence,
                                       lineNo:lineNumber,position:position))
            }
        }
        func distance(_ box:CGRect)->CGFloat{
            hypot(max(box.minX-p.x,0,p.x-box.maxX),max(box.minY-p.y,0,p.y-box.maxY))
        }
        if preferSelection,let base=dominant(image,rect:CGRect(x:0,y:0,width:image.width,height:image.height)),
           base.share>0.30 {
            for i in candidates.indices {candidates[i].selected=highlight(candidates[i],image:image,base:base)}
            let selected=candidates.filter{$0.selected}
            if !selected.isEmpty {
                var groups:[[Word]]=[]
                for word in selected {
                    if let last=groups.last?.last,
                       (word.lineNo==last.lineNo && word.position==last.position+1) ||
                       (word.lineNo==last.lineNo+1 && word.position==0 && last.position==candidates.filter({$0.lineNo==last.lineNo}).map(\.position).max()) {
                        groups[groups.count-1].append(word)
                    } else {groups.append([word])}
                }
                let ranked=groups.sorted {
                    let a=$0.map{distance($0.box)}.min() ?? 1
                    let b=$1.map{distance($0.box)}.min() ?? 1
                    return a<b
                }
                if let group=ranked.first {
                    let dist=group.map{distance($0.box)}.min() ?? 1
                    // A uniquely highlighted selection is strong even if the
                    // pointer has moved a short distance from the highlight.
                    if dist<0.40 || groups.count==1 {
                        let words=group.map(\.text).joined(separator:" ")
                        let context=Array(Set(group.map(\.lineNo))).sorted().compactMap{n in group.first(where:{$0.lineNo==n})?.line}.joined(separator:" ")
                        let confidence=group.map(\.confidence).min() ?? 0
                        let clear=groups.count==1 || (ranked.count>1 &&
                            (ranked[1].map{distance($0.box)}.min() ?? 1)-dist>0.10)
                        return Candidate(text:words,line:context,confidence:confidence,exact:clear,highlighted:true)
                    }
                }
            }
        }
        var best:(Candidate,CGFloat)?
        for word in candidates {
            let dist=distance(word.box)
            let hit=word.box.insetBy(dx:-0.004,dy:-0.008).contains(p)
            let c=Candidate(text:word.text,line:word.line,confidence:word.confidence,exact:hit)
            if best == nil || dist<best!.1 {best=(c,dist)}
        }
        guard let best, best.1 < 0.12 else { return nil }
        return best.0
    }

    @available(macOS 14.0, *)
    static func capture(_ point: CGPoint,preferSelection:Bool = false) async throws -> Candidate? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: {
            CGDisplayBounds($0.displayID).contains(point)
        }) else { return nil }
        let bounds = CGDisplayBounds(display.displayID)
        let local = CGPoint(x:point.x-bounds.minX,y:point.y-bounds.minY)
        let config = SCStreamConfiguration()
        // SCScreenshotManager sourceRect/output sizing varies by macOS/display.
        // Capture the display at its native resolution, then crop the exact
        // pixel rect ourselves (only the local crop is OCR'd).
        config.width = CGDisplayPixelsWide(display.displayID)
        config.height = CGDisplayPixelsHigh(display.displayID)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display:display,excludingWindows:[]),configuration:config)
        let xScale=CGFloat(image.width)/bounds.width,yScale=CGFloat(image.height)/bounds.height
        let center=CGPoint(x:local.x*xScale,y:local.y*yScale)
        let radiusX:CGFloat=preferSelection ? 420 : 240
        let radiusY:CGFloat=preferSelection ? 210 : 105
        let crop=CGRect(x:center.x-radiusX*xScale,y:center.y-radiusY*yScale,
                        width:2*radiusX*xScale,height:2*radiusY*yScale).integral
            .intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        guard crop.width>10,crop.height>10,let cropped=image.cropping(to:crop) else{return nil}
        return try recognize(cropped,pointer:CGPoint(x:(center.x-crop.minX)/crop.width,y:(center.y-crop.minY)/crop.height),
                             preferSelection:preferSelection)
    }
}

enum BooksAdapter {
    static func lookup(term: String, source: SourceSnapshot,visibleContext:String? = nil) -> (context:BookContext?,issue:String?) {
        guard source.isBooks else { return (nil,nil) }
        let input: [String:String] = ["term":term,"windowTitle":source.title,"visibleContext":visibleContext ?? ""]
        guard let data = try? JSONEncoder().encode(input) else { return (nil,"无法准备阅读语境查询") }
        switch LocalProcess.run(URL(fileURLWithPath:"/usr/bin/python3"),arguments:[Paths.resource("books_context").path],input:data,timeout:5){
        case .timeout:return (nil,"阅读语境查询超时")
        case .failed:return (nil,"暂时无法读取阅读语境")
        case .data(let response):
            if let context=try? JSONDecoder().decode(BookContext?.self,from:response){return (context,nil)}
            if String(data:response,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines)=="null"{return (nil,nil)}
            return (nil,"暂时无法读取阅读语境")
        }
    }
}
