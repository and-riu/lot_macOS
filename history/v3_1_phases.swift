// tapclick v3: en la partida de LoL, detecta el tap de 2 dedos leyendo el trackpad
// directamente y manda el clic derecho al instante (sin esperar al reconocedor de macOS).
// Los clics derechos tardíos que macOS genera por tap se descartan. El clic físico pasa igual.
// Fuera de la partida no toca nada.
import Cocoa
setvbuf(stdout, nil, _IOLBF, 0)

let gameBundle = "com.riotgames.LeagueofLegends.GameClient"
let maxContact: UInt64 = 250_000_000   // tap: contacto < 250 ms
let maxMove: Float = 0.04              // tap: el centro de los dedos se mueve < 4 % del trackpad
let maxLead: UInt64 = 150_000_000    // el 1er dedo no debe llevar > 150 ms solo (evita clics al mover el cursor)
let hold: Double = 0.025               // el clic dura 25 ms
let magic: Int64 = 0x7A9C11C4
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

var inGame = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == gameBundle
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
  inGame = app?.bundleIdentifier == gameBundle
  print(inGame ? "→ partida al frente: activo" : "→ fuera de la partida: inactivo")
}

let lock = NSLock()
var fingersDown = 0            // dedos en el trackpad ahora
var phaseStart: UInt64 = 0, oneStart: UInt64 = 0, lead: UInt64 = 0, phaseValid = false
var startCX: Float = 0, startCY: Float = 0, maxDisp: Float = 0, haveStart = false
var physicalClickInTouch = false
var swallowUp = false
var pendingDown: CGEvent? = nil

func sendRightClick() {
  let pos = CGEvent(source: nil)?.location ?? .zero
  guard let d = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: pos, mouseButton: .right),
        let u = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: pos, mouseButton: .right) else { return }
  for e in [d, u] { e.setIntegerValueField(.eventSourceUserData, value: magic); e.setIntegerValueField(.mouseEventClickState, value: 1) }
  d.post(tap: .cgSessionEventTap)
  DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + hold) { u.post(tap: .cgSessionEventTap) }
}

// ---- toques crudos del trackpad ----
typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
let mtCB: MTCallback = { _, touches, n, _, _ in
  let t = now(); let f = Int(n)
  var cx: Float = 0, cy: Float = 0, valid = false
  if f > 0, let p = touches {
    for i in 0..<f { cx += p.load(fromByteOffset: i*96 + 32, as: Float.self); cy += p.load(fromByteOffset: i*96 + 36, as: Float.self) }
    cx /= Float(f); cy /= Float(f); valid = cx >= 0 && cx <= 1 && cy >= 0 && cy <= 1
  }
  var fire = false
  lock.lock()
  let prev = fingersDown
  if f == 1 && prev != 1 { oneStart = t }                          // empieza fase de 1 dedo
  if f == 2 && prev != 2 {                                        // empieza fase de 2 dedos = posible tap
    phaseStart = t; haveStart = false; maxDisp = 0; physicalClickInTouch = false
    lead = prev == 1 ? t - oneStart : 0                           // cuánto llevaba el 1er dedo solo
    phaseValid = prev < 2
  }
  if f == 2 && valid {
    if !haveStart { startCX = cx; startCY = cy; haveStart = true }
    else { maxDisp = max(maxDisp, hypot(cx - startCX, cy - startCY)) }
  }
  if prev == 2 && f != 2 && phaseValid && inGame {                 // termina la fase de 2 dedos
    let dur = t - phaseStart
    if f > 2 { print("  ignorado: 3er dedo") }
    else if physicalClickInTouch { }                              // fue clic físico
    else if dur < maxContact && maxDisp < maxMove && lead < maxLead { fire = true
      print(String(format: "tap 2 dedos (%.0f ms, mov %.3f, previo %.0f ms) → clic", Double(dur)/1e6, maxDisp, Double(lead)/1e6)) }
    else { print(String(format: "  ignorado: %.0f ms, mov %.3f, previo %.0f ms", Double(dur)/1e6, maxDisp, Double(lead)/1e6)) }
    phaseValid = false
  }
  fingersDown = f
  lock.unlock()
  if fire { sendRightClick() }
  return 0
}
guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
      let pList = dlsym(h, "MTDeviceCreateList"), let pReg = dlsym(h, "MTRegisterContactFrameCallback"), let pStart = dlsym(h, "MTDeviceStart") else {
  print("NO_SE_PUDO_LEER_EL_TRACKPAD"); exit(1)
}
typealias ListFn = @convention(c) () -> Unmanaged<CFArray>
typealias RegFn = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
let devs = unsafeBitCast(pList, to: ListFn.self)().takeUnretainedValue() as [AnyObject]
for d in devs { let p = Unmanaged.passUnretained(d).toOpaque()
  unsafeBitCast(pReg, to: RegFn.self)(p, mtCB); unsafeBitCast(pStart, to: StartFn.self)(p, 0) }

// ---- filtro de los clics derechos de macOS ----
var tapRef: CFMachPort? = nil
let cb: CGEventTapCallBack = { _, type, ev, _ in
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let t = tapRef { CGEvent.tapEnable(tap: t, enable: true) }; print("!! tap reactivado")
    return Unmanaged.passUnretained(ev)
  }
  if ev.getIntegerValueField(.eventSourceUserData) == magic { return Unmanaged.passUnretained(ev) }
  guard inGame else { return Unmanaged.passUnretained(ev) }
  lock.lock(); defer { lock.unlock() }
  if type == .rightMouseDown {
    if fingersDown == 0 { swallowUp = true; print("  descartado clic tardío de macOS"); return nil }  // tap tardío: ya lo mandamos nosotros
    // con dedos en el trackpad: ¿clic físico o tap tardío de macOS? Si la soltada llega en < 5 ms, era tap.
    guard let d = ev.copy() else { return Unmanaged.passUnretained(ev) }
    d.setIntegerValueField(.eventSourceUserData, value: magic)
    pendingDown = d
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
      lock.lock(); let p = pendingDown; pendingDown = nil; if p != nil { physicalClickInTouch = true }; lock.unlock()
      p?.post(tap: .cgSessionEventTap)                                                      // clic físico: pasa
    }
    return nil
  }
  if type == .rightMouseUp {
    if pendingDown != nil { pendingDown = nil; print("  descartado clic tardío de macOS (con dedos)"); return nil }
    if swallowUp { swallowUp = false; return nil }
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
print("tapclick v3.1 listo, trackpads: \(devs.count) (\(inGame ? "partida al frente" : "esperando la partida"))")
RunLoop.main.run()
