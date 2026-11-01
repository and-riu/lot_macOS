// tapclick v2: en la partida de LoL, alarga los clics derechos hechos con tap
// para que el juego los registre. Fuera de la partida no toca nada.
// Diagnóstico: registra los toques crudos del trackpad para medir la latencia de macOS.
import Cocoa
setvbuf(stdout, nil, _IOLBF, 0)

let gameBundle = "com.riotgames.LeagueofLegends.GameClient"
let tapThreshold: UInt64 = 15_000_000   // < 15 ms = tap
let holdTarget:   UInt64 = 25_000_000   // soltar a los 25 ms
let magic: Int64 = 0x7A9C11C4
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> String { String(format: "%.0f ms", Double(Int64(bitPattern: a &- b))/1e6) }

var inGame = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == gameBundle
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
  inGame = app?.bundleIdentifier == gameBundle
  print(inGame ? "→ partida al frente: activo" : "→ fuera de la partida: inactivo")
}

// ---- toques crudos (solo lectura) ----
let lock = NSLock()
var lastTwoFingerLift: UInt64 = 0, twoFingerStart: UInt64 = 0, maxFingers = 0, prevFingers = 0
var liftsSinceClick = 0
typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
let mtCB: MTCallback = { _, _, n, _, _ in
  let t = now(); let f = Int(n)
  lock.lock()
  if prevFingers == 0 && f > 0 { twoFingerStart = t; maxFingers = 0 }
  maxFingers = max(maxFingers, f)
  if prevFingers > 0 && f == 0 && maxFingers == 2 {
    let dur = Double(t - twoFingerStart)/1e6
    if dur < 300 { lastTwoFingerLift = t; liftsSinceClick += 1
      if inGame { print(String(format: "  dedos: tap de 2 dedos (%.0f ms en contacto)", dur)) } }
  }
  prevFingers = f
  lock.unlock()
  return 0
}
if let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
   let pList = dlsym(h, "MTDeviceCreateList"), let pReg = dlsym(h, "MTRegisterContactFrameCallback"), let pStart = dlsym(h, "MTDeviceStart") {
  typealias ListFn = @convention(c) () -> Unmanaged<CFArray>
  typealias RegFn = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
  typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
  let devs = unsafeBitCast(pList, to: ListFn.self)().takeUnretainedValue() as [AnyObject]
  for d in devs { let p = Unmanaged.passUnretained(d).toOpaque()
    unsafeBitCast(pReg, to: RegFn.self)(p, mtCB); unsafeBitCast(pStart, to: StartFn.self)(p, 0) }
  print("trackpads leídos: \(devs.count)")
}

// ---- event tap ----
var downTS: UInt64 = 0
var pendingUp: CGEvent? = nil
var tapRef: CFMachPort? = nil
func flushPending() { if let up = pendingUp { pendingUp = nil; up.post(tap: .cgSessionEventTap) } }

let cb: CGEventTapCallBack = { _, type, ev, _ in
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let t = tapRef { CGEvent.tapEnable(tap: t, enable: true) }; print("!! tap reactivado")
    return Unmanaged.passUnretained(ev)
  }
  if ev.getIntegerValueField(.eventSourceUserData) == magic { return Unmanaged.passUnretained(ev) }
  guard inGame else { return Unmanaged.passUnretained(ev) }

  if type == .rightMouseDown {
    let t = now()
    lock.lock(); let lift = lastTwoFingerLift; let lifts = liftsSinceClick; liftsSinceClick = 0; lock.unlock()
    let extra = lifts > 1 ? "  ⚠️ \(lifts - 1) tap(s) sin clic" : ""
    print("clic der: \(ms(t, lift)) después de levantar los dedos\(extra)")
    downTS = ev.timestamp
    if pendingUp != nil, let d = ev.copy() {          // soltada pendiente: manda soltada y luego este clic, en orden
      d.setIntegerValueField(.eventSourceUserData, value: magic)
      flushPending(); d.post(tap: .cgSessionEventTap)
      return nil
    }
    return Unmanaged.passUnretained(ev)
  }
  if type == .rightMouseUp {
    let held = ev.timestamp &- downTS
    if downTS != 0 && held < tapThreshold, let copy = ev.copy() {
      copy.setIntegerValueField(.eventSourceUserData, value: magic)
      pendingUp = copy
      let p = copy
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(holdTarget - held)/1e9) { if pendingUp === p { flushPending() } }
      return nil
    }
  }
  return Unmanaged.passUnretained(ev)
}

let mask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: mask, callback: cb, userInfo: nil) else {
  print("NO_SE_PUDO_CREAR_TAP: falta permiso de Accesibilidad"); exit(1)
}
tapRef = tap
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("tapclick v2 listo (\(inGame ? "partida al frente" : "esperando la partida"))")
RunLoop.main.run()
