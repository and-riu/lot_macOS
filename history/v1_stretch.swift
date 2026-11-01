// tapclick: en la partida de LoL, alarga los clics derechos hechos con tap (≈0.2 ms)
// para que el juego los registre. Fuera de la partida no toca nada.
import Cocoa
setvbuf(stdout, nil, _IOLBF, 0)

let gameBundle = "com.riotgames.LeagueofLegends.GameClient"
let tapThreshold: UInt64 = 15_000_000   // < 15 ms = tap
let holdTarget:   UInt64 = 40_000_000   // soltar a los 40 ms
let magic: Int64 = 0x7A9C11C4           // marca de los eventos que reenviamos

var inGame = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == gameBundle
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
  inGame = app?.bundleIdentifier == gameBundle
  print(inGame ? "→ partida al frente: activo" : "→ fuera de la partida: inactivo")
}

var downTS: UInt64 = 0
var pendingUp: CGEvent? = nil
var tapRef: CFMachPort? = nil

func flushPending() {
  if let up = pendingUp { pendingUp = nil; up.post(tap: .cgSessionEventTap) }
}

let cb: CGEventTapCallBack = { _, type, ev, _ in
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let t = tapRef { CGEvent.tapEnable(tap: t, enable: true) }
    return Unmanaged.passUnretained(ev)
  }
  if ev.getIntegerValueField(.eventSourceUserData) == magic { return Unmanaged.passUnretained(ev) }
  guard inGame else { return Unmanaged.passUnretained(ev) }

  if type == .rightMouseDown {
    flushPending()                       // si quedó una soltada pendiente, mándala antes
    downTS = ev.timestamp
    return Unmanaged.passUnretained(ev)
  }
  if type == .rightMouseUp {
    let held = ev.timestamp &- downTS
    if downTS != 0 && held < tapThreshold, let copy = ev.copy() {
      copy.setIntegerValueField(.eventSourceUserData, value: magic)
      pendingUp = copy
      let wait = Double(holdTarget - held) / 1e9
      DispatchQueue.main.asyncAfter(deadline: .now() + wait) { flushPending() }
      print(String(format: "tap derecho %.2f ms → alargado a 40 ms", Double(held)/1e6))
      return nil                         // se traga la soltada original
    }
  }
  return Unmanaged.passUnretained(ev)
}

let mask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: mask, callback: cb, userInfo: nil) else {
  print("NO_SE_PUDO_CREAR_TAP: falta permiso de Accesibilidad")
  let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
  _ = AXIsProcessTrustedWithOptions(opts)
  exit(1)
}
tapRef = tap
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("tapclick listo (\(inGame ? "partida al frente" : "esperando la partida"))")
RunLoop.main.run()
