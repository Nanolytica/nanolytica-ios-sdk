//
//  Nanolytica.swift
//  Swift SDK for Nanolytica Cloud analytics. v0.1.0
//
//  Usage:
//
//      Nanolytica.shared.start(siteID: "your-site-uuid", options: .init(
//          userAgent: "MyApp/1.2.3 (iOS 17; iPhone15,2)"
//      ))
//      Nanolytica.shared.pageview("/home")
//      Nanolytica.shared.track("signup", props: ["plan": "pro"], value: 49.99)
//

import Foundation

public enum NanolyticaError: Error, Equatable {
    case notStarted
    case invalidSiteID
    case invalidEventName
    case reservedPrefix
    case tooManyProps
    case invalidPropKey
    case invalidPropValue
    case invalidPath
}

public struct NanolyticaOptions {
    public var endpoint: URL
    public var userAgent: String
    public var bufferSize: Int

    public init(
        endpoint: URL = URL(string: "https://cloud.nanolytica.org")!,
        userAgent: String? = nil,
        bufferSize: Int = 100
    ) {
        self.endpoint = endpoint
        self.userAgent = userAgent ?? Self.defaultUserAgent()
        self.bufferSize = bufferSize
    }

    static func defaultUserAgent() -> String {
        let v = "NanolyticaSwiftSDK/\(Nanolytica.version)"
        #if os(iOS) || os(tvOS)
        let os = "iOS"
        #elseif os(macOS)
        let os = "macOS"
        #elseif os(watchOS)
        let os = "watchOS"
        #else
        let os = "unknown"
        #endif
        return "\(v) (\(os))"
    }
}

public final class Nanolytica {
    public static let version = "0.1.0"
    public static let shared = Nanolytica()

    private let queueLock = NSLock()
    private var queue: [Data] = []
    private var inflight = false
    private var siteID: String?
    private var options: NanolyticaOptions = .init()
    private var optedOut = false

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.httpAdditionalHeaders = ["Content-Type": "application/json"]
        return URLSession(configuration: cfg)
    }()

    // MARK: - Public API

    public func start(siteID: String, options: NanolyticaOptions = .init()) throws {
        guard !siteID.isEmpty else { throw NanolyticaError.invalidSiteID }
        queueLock.lock()
        self.siteID = siteID
        self.options = options
        queueLock.unlock()
        restorePersisted()
    }

    public func setUserAgent(_ ua: String) {
        queueLock.lock()
        options.userAgent = ua
        queueLock.unlock()
    }

    public func optOut() {
        queueLock.lock()
        optedOut = true
        queue.removeAll()
        queueLock.unlock()
    }

    public func optIn() {
        queueLock.lock()
        optedOut = false
        queueLock.unlock()
    }

    public func pageview(
        _ path: String,
        referrer: String? = nil,
        screenSize: String? = nil,
        utmSource: String? = nil,
        utmMedium: String? = nil,
        utmCampaign: String? = nil,
        utmContent: String? = nil,
        utmTerm: String? = nil
    ) {
        guard ready() else { return }
        guard path.count <= 2048 else { return }
        var payload: [String: Any] = [
            "site_id": siteID!,
            "path": path,
            "user_agent": options.userAgent,
        ]
        if let v = referrer   { payload["referrer"]     = v }
        if let v = screenSize { payload["screen_size"]  = v }
        if let v = utmSource  { payload["utm_source"]   = v }
        if let v = utmMedium  { payload["utm_medium"]   = v }
        if let v = utmCampaign { payload["utm_campaign"] = v }
        if let v = utmContent { payload["utm_content"]  = v }
        if let v = utmTerm    { payload["utm_term"]     = v }
        enqueue(payload)
    }

    @discardableResult
    public func track(_ name: String, props: [String: String]? = nil, value: Double? = nil) -> Result<Void, NanolyticaError> {
        guard ready() else { return .failure(.notStarted) }
        if let err = Self.validateEventName(name) { return .failure(err) }
        let sortedProps: [String: String]?
        switch Self.validateProps(props) {
        case .failure(let err): return .failure(err)
        case .success(let v):   sortedProps = v
        }
        var payload: [String: Any] = [
            "site_id": siteID!,
            "event_name": name,
            "user_agent": options.userAgent,
        ]
        if let p = sortedProps { payload["props"] = p }
        if let v = value        { payload["value"] = v }
        enqueue(payload)
        return .success(())
    }

    public func flush(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.drain()
            completion?()
        }
    }

    /// Persist queued events to disk. Call from `UIApplication.didEnterBackgroundNotification`.
    public func persist() {
        queueLock.lock()
        let snapshot = queue
        queueLock.unlock()
        guard !snapshot.isEmpty, let url = Self.storageURL() else { return }
        let lines = snapshot.map { String(data: $0, encoding: .utf8) ?? "" }
        let joined = lines.joined(separator: "\n")
        try? joined.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - Internal

    private func ready() -> Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        return !optedOut && siteID != nil
    }

    private func enqueue(_ payload: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        queueLock.lock()
        if queue.count >= options.bufferSize { queue.removeFirst() }
        queue.append(body)
        queueLock.unlock()
        flush()
    }

    private func drain() {
        queueLock.lock()
        if inflight { queueLock.unlock(); return }
        inflight = true
        queueLock.unlock()

        defer {
            queueLock.lock(); inflight = false; queueLock.unlock()
        }

        while true {
            queueLock.lock()
            guard let next = queue.first else { queueLock.unlock(); break }
            queueLock.unlock()

            let ok = send(next)
            if ok {
                queueLock.lock()
                if !queue.isEmpty { queue.removeFirst() }
                queueLock.unlock()
            } else {
                break // pause until next flush; keeps queue intact
            }
        }
    }

    private func send(_ body: Data) -> Bool {
        let url = options.endpoint.appendingPathComponent("api/collect")
        let backoffs: [UInt32] = [0, 1, 2, 4]
        for waitSec in backoffs {
            if waitSec > 0 { sleep(waitSec) }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")

            let sem = DispatchSemaphore(value: 0)
            var status: Int = 0
            var networkErr: Error?
            let task = session.dataTask(with: req) { _, response, error in
                networkErr = error
                if let http = response as? HTTPURLResponse { status = http.statusCode }
                sem.signal()
            }
            task.resume()
            sem.wait()
            if networkErr != nil { continue }
            if status < 500 { return true } // 2xx or 4xx: done, don't retry
        }
        return false
    }

    private func restorePersisted() {
        guard let url = Self.storageURL(), let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        queueLock.lock()
        for line in lines {
            if let d = line.data(using: .utf8) { queue.append(d) }
        }
        if queue.count > options.bufferSize {
            queue.removeFirst(queue.count - options.bufferSize)
        }
        queueLock.unlock()
        try? FileManager.default.removeItem(at: url)
        flush()
    }

    private static func storageURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("nanolytica", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.ndjson")
    }

    // MARK: - Validation (matches server)

    static func validateEventName(_ name: String) -> NanolyticaError? {
        if name.isEmpty || name.count > 64 { return .invalidEventName }
        if name.hasPrefix("nanolytica_") { return .reservedPrefix }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) { return .invalidEventName }
        return nil
    }

    static func validateProps(_ props: [String: String]?) -> Result<[String: String]?, NanolyticaError> {
        guard let props = props, !props.isEmpty else { return .success(nil) }
        if props.count > 10 { return .failure(.tooManyProps) }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        var out: [String: String] = [:]
        for (k, v) in props {
            if k.isEmpty || k.count > 64 { return .failure(.invalidPropKey) }
            if k.unicodeScalars.contains(where: { !allowed.contains($0) }) { return .failure(.invalidPropKey) }
            if v.count > 256 { return .failure(.invalidPropValue) }
            out[k] = v
        }
        return .success(out)
    }
}
