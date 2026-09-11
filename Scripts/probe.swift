import Foundation
import IOKit.hid
import QuartzCore
let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, ["VendorID":0x5ac,"ProductID":0x8104,"PrimaryUsagePage":32,"PrimaryUsage":138] as CFDictionary)
print("managerOpen=\(IOHIDManagerOpen(manager, 0)) uid=\(getuid())")
defer { IOHIDManagerClose(manager, 0) }
let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
print("devices=\(devices.count)")
for device in devices {
 let opened = IOHIDDeviceOpen(device, 0)
 print("deviceOpen=\(opened)")
 guard opened == 0 else { continue }
 defer { IOHIDDeviceClose(device, 0) }
 let start = CACurrentMediaTime()
 var count = 0, changes = 0, last = -1
 var lo = 999, hi = -1
 var durations: [Double] = []
 while CACurrentMediaTime()-start < 5 {
  var bytes = [UInt8](repeating:0,count:8), length = 8
  let t = CACurrentMediaTime()
  let result = IOHIDDeviceGetReport(device,kIOHIDReportTypeFeature,1,&bytes,&length)
  durations.append((CACurrentMediaTime()-t)*1000)
  if count == 0 { print("result=\(result) length=\(length) bytes=\(bytes)") }
  guard result == 0, length >= 3 else { break }
  let angle = Int(bytes[1]) | Int(bytes[2]) << 8
  if angle != last { changes += 1; last = angle }
  lo = min(lo,angle); hi = max(hi,angle); count += 1
  Thread.sleep(forTimeInterval:max(0, 1.0/120 - (CACurrentMediaTime()-t)))
 }
 print("reads=\(count) readHz=\(Double(count)/(CACurrentMediaTime()-start)) changes=\(max(0,changes-1)) range=\(lo)...\(hi) meanReadMs=\(durations.reduce(0,+)/Double(durations.count))")
}
