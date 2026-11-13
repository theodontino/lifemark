import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func draw(_ size:Int, to url:URL) throws {
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 let context=NSGraphicsContext(bitmapImageRep:rep)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
 let transform=NSAffineTransform();transform.scale(by:CGFloat(size)/1024);transform.concat()
 NSColor(calibratedRed:0.94,green:0.95,blue:0.92,alpha:1).setFill();NSRect(x:0,y:0,width:1024,height:1024).fill()
 NSColor(calibratedRed:0.12,green:0.40,blue:0.36,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:46,y:46,width:932,height:932),xRadius:190,yRadius:190).fill()
 NSColor(calibratedRed:0.99,green:0.98,blue:0.94,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:222,y:178,width:580,height:668),xRadius:65,yRadius:65).fill()
 NSColor(calibratedRed:0.12,green:0.40,blue:0.36,alpha:1).setFill()
 for (y,w) in [(650,330),(510,250),(370,310)] {NSBezierPath(roundedRect:NSRect(x:330,y:y,width:w,height:38),xRadius:19,yRadius:19).fill()}
 NSColor(calibratedRed:0.93,green:0.66,blue:0.25,alpha:1).setFill();NSBezierPath(ovalIn:NSRect(x:690,y:125,width:195,height:195)).fill()
 NSColor.white.setStroke();let tick=NSBezierPath();tick.lineWidth=22;tick.lineCapStyle = .round;tick.lineJoinStyle = .round;tick.move(to:NSPoint(x:738,y:219));tick.line(to:NSPoint(x:773,y:185));tick.line(to:NSPoint(x:835,y:255));tick.stroke()
 NSGraphicsContext.restoreGraphicsState()
 try rep.representation(using:.png,properties:[:])!.write(to:url)
}
var mac:[[String:String]]=[]
let folder=root.appendingPathComponent("LifeMacIcon.appiconset");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for point in [16,32,128,256,512] {for scale in [1,2] {let name="icon_\(point)_\(scale).png";try draw(point*scale,to:folder.appendingPathComponent(name));mac.append(["idiom":"mac","size":"\(point)x\(point)","scale":"\(scale)x","filename":name])}}
let info:[String:Any]=["images":mac,"info":["author":"xcode","version":1]];try JSONSerialization.data(withJSONObject:info,options:.prettyPrinted).write(to:folder.appendingPathComponent("Contents.json"))
let ios=root.appendingPathComponent("LifeiOSIcon.appiconset");try FileManager.default.createDirectory(at:ios,withIntermediateDirectories:true);try draw(1024,to:ios.appendingPathComponent("icon.png"));try JSONSerialization.data(withJSONObject:["images":[["idiom":"universal","platform":"ios","size":"1024x1024","filename":"icon.png"]],"info":["author":"xcode","version":1]],options:.prettyPrinted).write(to:ios.appendingPathComponent("Contents.json"))
