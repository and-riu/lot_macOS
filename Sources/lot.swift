// lot — League of Trackpad
// Two-finger tap = right click, only while the League of Legends match window is in front.
//
// Why: macOS turns a two-finger tap into a right click that lasts ~0.2 ms, arrives ~370 ms
// after you lift your fingers, and gets dropped ~36 % of the time when you tap fast.
// The game never sees most of them. lot reads the raw trackpad touches itself, detects the
// two-finger tap, and posts a normal 25 ms right click the moment the first finger lifts.
// The late right clicks macOS generates for those taps are discarded so nothing doubles.
// Physical two-finger clicks pass through untouched. Outside the match, lot does nothing.
import Cocoa
setvbuf(stdout, nil, _IOLBF, 0)

// ---- tuning ----
let gameBundle = "com.riotgames.LeagueofLegends.GameClient"   // the in-match app, not the lobby client
let maxContact: UInt64 = 250_000_000   // a tap finger touches for < 250 ms
let maxMove: Float = 0.04              // ...and moves < 4 % of the trackpad (normalized units)
let maxSkew: UInt64 = 150_000_000      // both fingers land within 150 ms of each other
let hold: Double = 0.025               // the posted click is held for 25 ms (long enough for any frame rate ≥ 40 fps)
let magic: Int64 = 0x7A9C11C4          // tags our own events so the filter lets them through
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

// ---- is the match window in front? ----
var inGame = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == gameBundle
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
  inGame = app?.bundleIdentifier == gameBundle
  print(inGame ? "→ match in front: active" : "→ match not in front: idle")
}

let lock = NSLock()
var fingersDown = 0                    // fingers in real contact right now
struct Touch { var start: UInt64; var sx: Float; var sy: Float; var disp: Float; var used: Bool; var haveStart: Bool }
var active: [Int32: Touch] = [:]       // per-finger tracking, keyed by the trackpad's finger id
var pendingDown: CGEvent? = nil
var owed = 0                           // late duplicates macOS may still send for taps lot already handled
var lastFire: UInt64 = 0
let owedWindow: UInt64 = 1_500_000_000 // macOS's late tap-clicks arrive within ~1.1 s

func sendRightClick() {
  let pos = CGEvent(source: nil)?.location ?? .zero
  guard let d = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: pos, mouseButton: .right),
        let u = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: pos, mouseButton: .right) else { return }
  for e in [d, u] { e.setIntegerValueField(.eventSourceUserData, value: magic); e.setIntegerValueField(.mouseEventClickState, value: 1) }
  d.post(tap: .cgSessionEventTap)
  DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + hold) { u.post(tap: .cgSessionEventTap) }
}

// ---- raw trackpad touches (MultitouchSupport, private framework, read-only) ----
// Each touch record is 96 bytes: id @16 (Int32), state @20 (Int32), normalized x,y @32/@36 (Float).
// States: 1-2 in range / hovering, 3 make-touch, 4 touching, 5 break-touch, 6-7 lingering / out of range.
// Only 3 and 4 are real contact; positions are only trustworthy in state 4.
typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
let mtCB: MTCallback = { _, touches, n, _, _ in
  let t = now()
  var fire = false
  lock.lock()
  var seen = Set<Int32>()
  if n > 0, let p = touches {
    for i in 0..<Int(n) {
      let base = i * 96
      let id = p.load(fromByteOffset: base + 16, as: Int32.self)
      let st = p.load(fromByteOffset: base + 20, as: Int32.self)
      let x = p.load(fromByteOffset: base + 32, as: Float.self), y = p.load(fromByteOffset: base + 36, as: Float.self)
      guard st == 3 || st == 4 else { continue }
      seen.insert(id)
      if active[id] == nil { active[id] = Touch(start: t, sx: x, sy: y, disp: 0, used: false, haveStart: st == 4) }
      if st == 4 {
        if !active[id]!.haveStart { active[id]!.sx = x; active[id]!.sy = y; active[id]!.haveStart = true }
        else { active[id]!.disp = max(active[id]!.disp, hypot(x - active[id]!.sx, y - active[id]!.sy)) }
      }
    }
  }
  // fingers that lifted in this frame
  for (id, x0) in active where !seen.contains(id) {
    let x = active[id] ?? x0             // current value (its partner may have marked it used this frame)
    active[id] = nil
    guard inGame, !x.used else { continue }
    let dur = t - x.start
    guard dur < maxContact, x.disp < maxMove else { continue }
    // partner: another finger still down that landed at almost the same time, short and still
    if let (pid, pt) = active.filter({ !$0.value.used && $0.value.disp < maxMove && t - $0.value.start < maxContact }).min(by: {
         abs(Double(Int64(bitPattern: $0.value.start &- x.start))) < abs(Double(Int64(bitPattern: $1.value.start &- x.start))) }),
       abs(Double(Int64(bitPattern: pt.start &- x.start))) < Double(maxSkew) {
      active[pid]!.used = true; fire = true; owed += 1; lastFire = t
      print(String(format: "two-finger tap (%.0f ms, move %.3f/%.3f, skew %.0f ms) → right click", Double(dur)/1e6, x.disp, pt.disp,
                   abs(Double(Int64(bitPattern: pt.start &- x.start)))/1e6))
    }
  }
  fingersDown = active.count
  lock.unlock()
  if fire { sendRightClick() }
  return 0
}
guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
      let pList = dlsym(h, "MTDeviceCreateList"), let pReg = dlsym(h, "MTRegisterContactFrameCallback"), let pStart = dlsym(h, "MTDeviceStart") else {
  print("CANNOT_READ_TRACKPAD: MultitouchSupport not available"); exit(1)
}
typealias ListFn = @convention(c) () -> Unmanaged<CFArray>
typealias RegFn = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
typealias StartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
let devs = unsafeBitCast(pList, to: ListFn.self)().takeUnretainedValue() as [AnyObject]
for d in devs { let p = Unmanaged.passUnretained(d).toOpaque()
  unsafeBitCast(pReg, to: RegFn.self)(p, mtCB); unsafeBitCast(pStart, to: StartFn.self)(p, 0) }

// ---- filter for macOS's own (late) right clicks ----
var tapRef: CFMachPort? = nil
let cb: CGEventTapCallBack = { _, type, ev, _ in
  if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let t = tapRef { CGEvent.tapEnable(tap: t, enable: true) }; print("!! event tap re-enabled")
    return Unmanaged.passUnretained(ev)
  }
  if ev.getIntegerValueField(.eventSourceUserData) == magic { return Unmanaged.passUnretained(ev) }
  guard inGame else { return Unmanaged.passUnretained(ev) }
  lock.lock(); defer { lock.unlock() }
  if type == .rightMouseDown {
    // Only a click that could be the late duplicate of a tap lot already sent is ever held back.
    // Anything else (an external mouse, a physical trackpad click) passes straight through.
    if owed > 0 && now() - lastFire > owedWindow { owed = 0 }
    if owed == 0 {
      for k in active.keys { active[k]!.used = true }   // physical trackpad click: don't also count it as a tap
      return Unmanaged.passUnretained(ev)
    }
    // A duplicate's mouse-up follows within ~0.2 ms; a real click's takes 50+ ms. Hold the down 5 ms to tell.
    guard let d = ev.copy() else { return Unmanaged.passUnretained(ev) }
    d.setIntegerValueField(.eventSourceUserData, value: magic)
    pendingDown = d
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
      lock.lock(); let p = pendingDown; pendingDown = nil; if p != nil { for k in active.keys { active[k]!.used = true } }; lock.unlock()
      p?.post(tap: .cgSessionEventTap)   // real click: let it through
    }
    return nil
  }
  if type == .rightMouseUp, pendingDown != nil {
    pendingDown = nil; owed -= 1          // the up came instantly: it's the duplicate → drop both
    print("  dropped late macOS tap-click")
    return nil
  }
  return Unmanaged.passUnretained(ev)
}
let mask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                  eventsOfInterest: mask, callback: cb, userInfo: nil) else {
  print("NO_EVENT_TAP: grant Accessibility permission to lot (System Settings → Privacy & Security → Accessibility)")
  let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
  _ = AXIsProcessTrustedWithOptions(opts)
  sleep(30); exit(1)
}
tapRef = tap
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("lot ready, trackpads: \(devs.count) (\(inGame ? "match in front" : "waiting for the match"))")
RunLoop.main.run()
