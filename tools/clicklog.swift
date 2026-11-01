import Cocoa
setvbuf(stdout, nil, _IOLBF, 0)
if !CGPreflightListenEventAccess() { print("SIN_PERMISO: pidiendo acceso"); CGRequestListenEventAccess() }
let types: [CGEventType] = [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp]
var mask: CGEventMask = 0
for t in types { mask |= (1 << t.rawValue) }
var downTS: [UInt32: UInt64] = [:]
let cb: CGEventTapCallBack = { _, type, ev, _ in
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(ev) }
  let ts = ev.timestamp
  var extra = ""
  if [.leftMouseUp,.rightMouseUp,.otherMouseUp].contains(type), let d = downTS[type.rawValue - 1] {
    extra = String(format: " dur=%.2fms", Double(ts - d)/1e6)
  } else { downTS[type.rawValue] = ts }
  var fields: [String] = []
  for i in 0..<200 { if let f = CGEventField(rawValue: UInt32(i)) { let v = ev.getIntegerValueField(f); if v != 0 { fields.append("\(i)=\(v)") } } }
  let name: [UInt32:String] = [1:"LDOWN",2:"LUP",3:"RDOWN",4:"RUP",25:"ODOWN",26:"OUP"]
  print("\(name[type.rawValue] ?? "\(type.rawValue)") t=\(ts/1_000_000)ms flags=\(ev.flags.rawValue)\(extra) | \(fields.joined(separator: " "))")
  return Unmanaged.passUnretained(ev)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: cb, userInfo: nil) else { print("NO_SE_PUDO_CREAR_TAP (falta permiso)"); exit(1) }
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("ESCUCHANDO")
CFRunLoopRun()
