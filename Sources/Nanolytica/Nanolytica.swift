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
    case invalidOptions
    case invalidValue
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
        #if os(iOS)
        let os = "iOS"
        #elseif os(tvOS)
        let os = "tvOS"
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

    private let queueLock = NSRecursiveLock()
    private let worker = DispatchQueue(label: "org.nanolytica.delivery")
    private var generation = 0
    private var scheduled = false
    private var task: URLSessionDataTask?
    private let storageOverride: URL?
    private var queue: [Data] = []
    private var siteID: String?
    private var options: NanolyticaOptions = .init()
    private var optedOut = false

    private let session: URLSession

    init(session: URLSession? = nil, storageURL: URL? = nil) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 10
        self.session = session ?? URLSession(configuration: cfg)
        self.storageOverride = storageURL
    }

    // MARK: - Public API

    public func start(siteID: String, options: NanolyticaOptions = .init()) throws {
        guard UUID(uuidString: siteID) != nil else { throw NanolyticaError.invalidSiteID }
        guard options.bufferSize > 0, options.userAgent.utf8.count <= 512,
              ["http", "https"].contains(options.endpoint.scheme ?? ""),
              options.endpoint.host != nil, options.endpoint.user == nil,
              options.endpoint.query == nil, options.endpoint.fragment == nil else { throw NanolyticaError.invalidOptions }
        queueLock.lock()
        generation += 1
        task?.cancel()
        queue.removeAll()
        self.siteID = siteID
        self.options = options
        restorePersisted()
        queueLock.unlock()
        flush()
    }

    public func setUserAgent(_ ua: String) {
        guard ua.utf8.count <= 512 else { return }
        queueLock.lock()
        options.userAgent = ua
        queueLock.unlock()
    }

    public func optOut() {
        queueLock.lock()
        optedOut = true
        generation += 1
        task?.cancel()
        queue.removeAll()
        persist()
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
        queueLock.lock()
        defer { queueLock.unlock() }
        guard ready() else { return }
        guard path.utf8.count <= 2048, !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              (referrer?.utf8.count ?? 0) <= 2048 else { return }
        if let size = screenSize, !size.isEmpty, size.range(of: "^[0-9]{1,5}x[0-9]{1,5}$", options: .regularExpression) == nil { return }
        for value in [utmSource, utmMedium, utmCampaign, utmContent, utmTerm] {
            if (value?.utf8.count ?? 0) > 256 { return }
        }
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
        queueLock.lock()
        defer { queueLock.unlock() }
        guard ready() else { return .failure(.notStarted) }
        if let value = value, !value.isFinite { return .failure(.invalidValue) }
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
        worker.async { [weak self] in
            guard let self = self else { return }
            self.drain()
            completion?()
        }
    }

    /// Persist queued events to disk. Call from `UIApplication.didEnterBackgroundNotification`.
    public func persist() {
        queueLock.lock()
        defer { queueLock.unlock() }
        guard let url = storageOverride ?? Self.storageURL() else { return }
        if queue.isEmpty || optedOut {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let envelope: [String: Any] = ["site_id": siteID ?? "", "endpoint": options.endpoint.absoluteString,
            "events": queue.map { $0.base64EncodedString() }]
        if let data = try? JSONSerialization.data(withJSONObject: envelope) { try? data.write(to: url, options: .atomic) }
    }

    private func ready() -> Bool { !optedOut && siteID != nil }

    private func enqueue(_ payload: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        if queue.count >= options.bufferSize { queue.removeFirst() }
        queue.append(body)
        if !scheduled {
            scheduled = true
            worker.async { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        queueLock.lock(); scheduled = true; queueLock.unlock()
        while true {
            queueLock.lock()
            guard !optedOut, !queue.isEmpty else { scheduled = false; queueLock.unlock(); return }
            let next = queue.removeFirst(), scope = generation, config = options
            queueLock.unlock()
            let ok = send(next, generation: scope, options: config)
            queueLock.lock()
            if scope == generation && !optedOut {
                if !ok {
                    queue.insert(next, at: 0)
                    if queue.count > options.bufferSize { queue.removeLast() }
                }
                if let url = storageOverride ?? Self.storageURL(), FileManager.default.fileExists(atPath: url.path) { persist() }
            }
            if !ok { scheduled = false }
            queueLock.unlock()
            if !ok { return }
        }
    }

    private func send(_ body: Data, generation scope: Int, options: NanolyticaOptions) -> Bool {
        let url = options.endpoint.appendingPathComponent("api/collect")
        for waitSec: UInt32 in [0, 1, 2, 4] {
            if waitSec > 0 { sleep(waitSec) }
            queueLock.lock()
            guard !optedOut && generation == scope else { queueLock.unlock(); return true }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
            let sem = DispatchSemaphore(value: 0)
            let result = DeliveryResult()
            let active = session.dataTask(with: req) { _, response, error in
                result.error = error
                result.status = (response as? HTTPURLResponse)?.statusCode ?? 0
                sem.signal()
            }
            task = active
            active.resume()
            queueLock.unlock()
            sem.wait()
            queueLock.lock()
            if task === active { task = nil }
            queueLock.unlock()
            if result.error == nil && result.status >= 200 && result.status < 500 && result.status != 408 && result.status != 429 { return true }
        }
        return false
    }

    private final class DeliveryResult: @unchecked Sendable {
        var error: Error?
        var status = 0
    }

    private func restorePersisted() {
        guard let url = storageOverride ?? Self.storageURL() else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        guard !optedOut, let data = try? Data(contentsOf: url),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              saved["site_id"] as? String == siteID,
              saved["endpoint"] as? String == options.endpoint.absoluteString,
              let events = saved["events"] as? [String] else { return }
        queue = events.compactMap { encoded in
            guard let body = Data(base64Encoded: encoded),
                  let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  payload["site_id"] as? String == siteID else { return nil }
            return body
        }.suffix(options.bufferSize).map { $0 }
    }

    private static func storageURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
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
            if v.utf8.count > 256 { return .failure(.invalidPropValue) }
            out[k] = v
        }
        return .success(out)
    }
}
