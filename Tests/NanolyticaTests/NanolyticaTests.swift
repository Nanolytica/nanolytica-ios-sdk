import Foundation
@testable import Nanolytica

// Minimal test harness so this target works on a stock Swift toolchain (no Xcode).

var failures = 0

func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond {
        failures += 1
        FileHandle.standardError.write(Data("FAIL \(file):\(line): \(msg)\n".utf8))
    }
}

func run() {
    // Event-name validation
    check(Nanolytica.validateEventName("signup") == nil, "valid name rejected")
    check(Nanolytica.validateEventName("my_event-1") == nil, "valid name with _- rejected")
    check(Nanolytica.validateEventName("") == .invalidEventName, "empty name accepted")
    check(Nanolytica.validateEventName("has space") == .invalidEventName, "space accepted")
    check(Nanolytica.validateEventName("with!") == .invalidEventName, "special char accepted")
    check(Nanolytica.validateEventName("nanolytica_outbound") == .reservedPrefix, "reserved prefix accepted")
    let long = String(repeating: "a", count: 65)
    check(Nanolytica.validateEventName(long) == .invalidEventName, "over-long name accepted")

    // Props validation
    if case .success(let p) = Nanolytica.validateProps(["plan": "pro"]) {
        check(p?["plan"] == "pro", "plan prop round-trip")
    } else {
        check(false, "valid props rejected")
    }

    var tooMany: [String: String] = [:]
    for i in 0..<11 { tooMany["k\(i)"] = "v" }
    if case .failure(let err) = Nanolytica.validateProps(tooMany) {
        check(err == .tooManyProps, "tooManyProps error mismatch: \(err)")
    } else {
        check(false, "11 props accepted")
    }

    if case .failure(let err) = Nanolytica.validateProps(["bad key": "v"]) {
        check(err == .invalidPropKey, "invalidPropKey error mismatch: \(err)")
    } else {
        check(false, "bad prop key accepted")
    }

    let longV = String(repeating: "a", count: 257)
    if case .failure(let err) = Nanolytica.validateProps(["k": longV]) {
        check(err == .invalidPropValue, "invalidPropValue error mismatch: \(err)")
    } else {
        check(false, "long prop value accepted")
    }

    // start() rejects empty site ID
    do {
        try Nanolytica.shared.start(siteID: "")
        check(false, "empty siteID accepted")
    } catch let err as NanolyticaError {
        check(err == .invalidSiteID, "wrong error for empty siteID")
    } catch {
        check(false, "unexpected error type")
    }

    // Reserved prefix via track()
    try? Nanolytica.shared.start(siteID: "site-uuid")
    if case .failure(let err) = Nanolytica.shared.track("nanolytica_outbound", props: nil, value: nil) {
        check(err == .reservedPrefix, "track reserved err mismatch: \(err)")
    } else {
        check(false, "track accepted reserved prefix")
    }

    // optOut blocks track
    Nanolytica.shared.optOut()
    let r = Nanolytica.shared.track("signup", props: nil, value: nil)
    if case .success = r { check(false, "optOut did not block track") }
    Nanolytica.shared.optIn()
}

run()
if failures == 0 {
    print("all tests passed")
} else {
    FileHandle.standardError.write(Data("\(failures) failures\n".utf8))
    exit(1)
}
