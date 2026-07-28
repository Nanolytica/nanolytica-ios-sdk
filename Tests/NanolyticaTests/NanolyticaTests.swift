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

final class MockTransport: URLProtocol {
    static let lock = NSLock()
    static var paths: [String] = []
    static let started = DispatchSemaphore(value: 0)
    static let release = DispatchSemaphore(value: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&bytes, maxLength: bytes.count)
                if n <= 0 { break }
                body.append(contentsOf: bytes.prefix(n))
            }
            stream.close()
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let path = payload?["path"] as? String ?? "missing"
        Self.lock.lock(); Self.paths.append(path); Self.lock.unlock()
        if path == "/first" { Self.started.signal(); Self.release.wait() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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
    try? Nanolytica.shared.start(siteID: "11111111-1111-4111-8111-111111111111")
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
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockTransport.self]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let client = Nanolytica(session: URLSession(configuration: config), storageURL: url)
    do {
        try client.start(siteID: "11111111-1111-4111-8111-111111111111", options: .init(bufferSize: 0))
        check(false, "zero buffer accepted")
    } catch {}
    try! client.start(siteID: "11111111-1111-4111-8111-111111111111", options: .init(bufferSize: 2))
    if case .failure(.invalidValue) = client.track("sale", value: .nan) {} else { check(false, "NaN accepted") }
    if case .failure(.invalidPropValue) = Nanolytica.validateProps(["v": String(repeating: "é", count: 129)]) {} else { check(false, "UTF-8 limit ignored") }
    client.pageview("/first")
    check(MockTransport.started.wait(timeout: .now() + 5) == .success, "first send not started")
    client.pageview("/second"); client.pageview("/third"); client.pageview("/fourth")
    let flushed = DispatchSemaphore(value: 0)
    client.flush { flushed.signal() }
    check(flushed.wait(timeout: .now() + 0.02) == .timedOut, "flush returned early")
    MockTransport.release.signal()
    check(flushed.wait(timeout: .now() + 5) == .success, "flush stuck")
    MockTransport.lock.lock()
    check(MockTransport.paths == ["/first", "/third", "/fourth"], "overflow lost wrong request: \(MockTransport.paths)")
    MockTransport.lock.unlock()
    try! Data("saved queue".utf8).write(to: url)
    client.optOut()
    check(!FileManager.default.fileExists(atPath: url.path), "opt-out left saved data")

}

run()
if failures == 0 {
    print("all tests passed")
} else {
    FileHandle.standardError.write(Data("\(failures) failures\n".utf8))
    exit(1)
}
