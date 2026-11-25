import BangsCore
import Darwin
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import notify

// Runs as root under launchd (see ChargeLimit): holds the battery at the limit Bangs set. Charging stops at the limit
// and starts again `resumeBelow` points under it; meanwhile the adapter powers the Mac. Told to quit (Bangs turned the
// limit off and removed it, or launchd stops it), it lets the battery charge again first.

if CommandLine.arguments.contains("--version") {
    print(ChargeLimit.helperVersion)
    exit(0)
}

/// Everything here runs on the main thread: the run loop's sources, the notification and the signals all deliver there.
enum Helper {
    nonisolated(unsafe) static var smc: SMC!
    nonisolated(unsafe) static var control: ChargeLimit.Switch!
    nonisolated(unsafe) static var holding = false
    /// Kept while charging toward the limit on the adapter, so the Mac does not idle to sleep and charge on past it.
    nonisolated(unsafe) static var awake: IOPMAssertionID = 0
    nonisolated(unsafe) static var powerPort: io_connect_t = 0
    nonisolated(unsafe) static var keep: [AnyObject] = []

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(Timestamps.string()) \(message)\n".utf8))
    }

    static var limit: Int? {
        ChargeLimit.limit(from: try? String(contentsOfFile: ChargeLimit.settingPath, encoding: .utf8))
    }

    static func hold(_ on: Bool) {
        guard on != holding else { return }
        if control.hold(on, smc) {
            holding = on
            log(on ? "charging held" : "charging resumed")
        } else {
            log("could not \(on ? "hold" : "resume") charging")
        }
    }

    static func apply() {
        let limit = limit
        // The firmware keeps the limit itself, through sleep too: only tell it.
        if control.keepsLimit {
            let range = limit.map { (lower: $0 - ChargeLimit.resumeBelow, upper: $0) }
            let before = control.firmwareLimit(smc)
            guard control.keep(range, smc) else { log("could not set the firmware limit"); return }
            let after = control.firmwareLimit(smc)
            if before?.on != after?.on || before?.lower != after?.lower || before?.upper != after?.upper {
                log(range.map { "firmware limit \($0.lower)–\($0.upper)%" } ?? "firmware limit off")
            }
            return
        }
        guard let battery = Battery.current() else { return }
        hold(ChargeLimit.holds(level: battery.level, limit: limit, holding: holding))
        let charging = limit.map { battery.onPower && !holding && battery.level < $0 } ?? false
        if charging && awake == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Bangs is charging to the limit" as CFString, &awake)
        } else if !charging && awake != 0 {
            IOPMAssertionRelease(awake)
            awake = 0
        }
    }

    /// Going to sleep within reach of the limit: hold charging, so it does not creep past it while nothing runs.
    /// Further below, it charges on so a closed MacBook is not left low.
    static func willSleep() {
        guard !control.keepsLimit else { return }
        if let limit, let battery = Battery.current(), battery.level >= limit - ChargeLimit.resumeBelow { hold(true) }
    }

    static func stop() {
        if control.keepsLimit { control.keep(nil, smc) } else if control.holding(smc) { control.hold(false, smc) }
        log("stopped; charging resumed")
        exit(0)
    }
}

guard let smc = SMC(), let control = ChargeLimit.Switch(smc) else {
    Helper.log("no battery charging control on this Mac")
    exit(0)
}
Helper.smc = smc
Helper.control = control
Helper.holding = control.holding(smc)

// Quit: charge again, so the battery is never left held without anything watching it.
for signal in [SIGTERM, SIGINT, SIGHUP] {
    Darwin.signal(signal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
    source.setEventHandler { Helper.stop() }
    source.resume()
    Helper.keep.append(source)
}

// The adapter plugged in or out, or the level changed.
if let source = IOPSNotificationCreateRunLoopSource({ _ in Helper.apply() }, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
}

// Bangs changed the limit.
var token: Int32 = 0
notify_register_dispatch(ChargeLimit.changedNotification, &token, .main) { _ in Helper.apply() }

// Sleep and wake. IOMessage.h's values, whose macros Swift does not import.
var notifyPort: IONotificationPortRef?
var notifier: io_object_t = 0
Helper.powerPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, message, argument in
    switch message {
    case 0xe000_0270: // kIOMessageCanSystemSleep
        IOAllowPowerChange(Helper.powerPort, Int(bitPattern: argument))
    case 0xe000_0280: // kIOMessageSystemWillSleep
        Helper.willSleep()
        IOAllowPowerChange(Helper.powerPort, Int(bitPattern: argument))
    case 0xe000_0300: // kIOMessageSystemHasPoweredOn
        Helper.apply()
    default:
        break
    }
}, &notifier)
if let notifyPort { CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode) }

// And once a minute, in case a change went unnoticed.
let timer = Timer(timeInterval: 60, repeats: true) { _ in Helper.apply() }
RunLoop.main.add(timer, forMode: .default)

Helper.log("started (\(control), limit \(Helper.limit.map { "\($0)%" } ?? "none"))")
Helper.apply()
RunLoop.main.run()
