import Foundation
import ImageIO
import CoreGraphics
let source = CGImageSourceCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,nil)!
let image = CGImageSourceCreateImageAtIndex(source,0,nil)!
let w=image.width,h=image.height
var bytes=[UInt8](repeating:0,count:w*h*4)
bytes.withUnsafeMutableBytes {raw in
 let ctx=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
}
var seen=[Bool](repeating:false,count:w*h)
var components:[[String:Any]]=[]
for start in 0..<w*h {
 if seen[start] || bytes[start*4+3]<20 {continue}
 seen[start]=true
 var queue=[start],head=0,minX=w,minY=h,maxX=0,maxY=0
 while head<queue.count {
  let p=queue[head];head+=1;let x=p%w,y=p/w
  minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y)
  for dy in -1...1 {for dx in -1...1 {
   let nx=x+dx,ny=y+dy
   if nx<0 || nx>=w || ny<0 || ny>=h {continue}
   let q=ny*w+nx
   if !seen[q] && bytes[q*4+3]>=20 {seen[q]=true;queue.append(q)}
  }}
 }
 if queue.count>2000 {components.append(["bounds":[minX,minY,maxX,maxY],"area":queue.count])}
}
print(String(data:try JSONSerialization.data(withJSONObject:components,options:[.sortedKeys]),encoding:.utf8)!)
