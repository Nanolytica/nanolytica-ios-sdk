# Nanolytica iOS SDK

Swift client for [Nanolytica Cloud](https://cloud.nanolytica.org) analytics. Supports iOS 14+, macOS 11+, and tvOS 14+. No third-party dependencies — uses `Foundation`'s `URLSession` and `DispatchQueue`.

## Requirements

- Swift 5.9 or later
- Xcode 15+ for building iOS/tvOS apps
- Stock Swift toolchain works for server-side macOS or for running tests

## Dashboard setup

1. Sign in at [cloud.nanolytica.org](https://cloud.nanolytica.org) and click **Add site**.
2. Choose **Native App** → **Mobile App** (or TV App) as the site type.
3. Copy the site UUID from the Setup tab — it looks like `3f4a1b2c-...`.

## Install

### Swift Package Manager (recommended)

Add to `Package.swift`:

```swift
.package(url: "https://github.com/eringen/nanolytica-cloud.git", from: "0.1.0")
```

Add `Nanolytica` to your target's dependencies:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "Nanolytica", package: "nanolytica-cloud"),
])
```

### Xcode

`File → Add Package Dependencies…` → paste `https://github.com/eringen/nanolytica-cloud` → select `Nanolytica`.

## Initialization

### UIKit AppDelegate

```swift
import UIKit
import Nanolytica

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let os      = UIDevice.current.systemVersion
        let model   = UIDevice.current.model // "iPhone", "iPad", "iPod touch"

        try? Nanolytica.shared.start(
            siteID: "3f4a1b2c-...",
            options: .init(
                endpoint:   URL(string: "https://cloud.nanolytica.org")!,
                userAgent:  "MyApp/\(version) (iOS \(os); \(model))",
                bufferSize: 100
            )
        )

        // Persist queue when app backgrounds
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in Nanolytica.shared.persist() }

        return true
    }
}
```

### SwiftUI App

```swift
import SwiftUI
import Nanolytica

@main
struct MyApp: App {
    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        try? Nanolytica.shared.start(
            siteID: "3f4a1b2c-...",
            options: .init(userAgent: "MyApp/\(version) (iOS \(UIDevice.current.systemVersion); iPhone)")
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didEnterBackgroundNotification
                )) { _ in
                    Nanolytica.shared.persist()
                }
        }
    }
}
```

### NanolyticaOptions reference

| Field | Type | Default | Description |
|---|---|---|---|
| `endpoint` | `URL` | `https://cloud.nanolytica.org` | Base URL of your Nanolytica instance |
| `userAgent` | `String` | `NanolyticaSwiftSDK/0.1.0 (iOS)` | Sent with every request; used for App Versions |
| `bufferSize` | `Int` | `100` | Max in-memory queue depth; oldest dropped when full |

## Recording pageviews

### Manual

```swift
Nanolytica.shared.pageview("/home")

Nanolytica.shared.pageview(
    "/product/42",
    referrer:    "https://example.com",
    screenSize:  screenSizeString(),
    utmSource:   "email",
    utmCampaign: "summer-sale"
)
```

### Getting screen size

```swift
func screenSizeString() -> String {
    let bounds = UIScreen.main.bounds
    return "\(Int(bounds.width))x\(Int(bounds.height))"
}
```

### Automatic pageview tracking (UIKit)

Override `viewDidAppear` in a base `UIViewController`:

```swift
class TrackedViewController: UIViewController {
    var analyticsPath: String { "/" + String(describing: type(of: self)) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Nanolytica.shared.pageview(analyticsPath)
    }
}
```

Then subclass `TrackedViewController` instead of `UIViewController`.

### Automatic pageview tracking (SwiftUI)

Use an `onAppear` modifier:

```swift
struct HomeView: View {
    var body: some View {
        Text("Welcome")
            .onAppear { Nanolytica.shared.pageview("/home") }
    }
}

// Or create a reusable modifier
extension View {
    func trackPageview(_ path: String) -> some View {
        self.onAppear { Nanolytica.shared.pageview(path) }
    }
}

// Usage
Text("Welcome").trackPageview("/home")
```

## Custom events

```swift
// Simple event
Nanolytica.shared.track("app_open")

// Event with props
Nanolytica.shared.track("signup", props: ["plan": "pro", "source": "pricing"])

// Event with revenue (summed in the Goals view)
Nanolytica.shared.track("purchase", props: ["plan": "pro"], value: 49.99)
```

`track` returns `Result<Void, NanolyticaError>` — you can ignore it (`@discardableResult`) or handle errors:

```swift
switch Nanolytica.shared.track("checkout", props: ["item": "widget"], value: 9.99) {
case .success:
    break
case .failure(let err):
    print("analytics error:", err)
}
```

## UTM campaign tracking

Capture UTM parameters from a deep link and pass them on the first pageview:

```swift
import UIKit
import Nanolytica

func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let q = comps?.queryItems ?? []
    func param(_ name: String) -> String? { q.first { $0.name == name }?.value }

    Nanolytica.shared.pageview("/deeplink",
        utmSource:   param("utm_source"),
        utmMedium:   param("utm_medium"),
        utmCampaign: param("utm_campaign"),
        utmContent:  param("utm_content"),
        utmTerm:     param("utm_term")
    )
    return true
}
```

UTM data appears in the **Sources** tab of your dashboard.

## Offline persistence

`persist()` serializes the queue to `Application Support/nanolytica/queue.ndjson`. Next `start()` restores and flushes it automatically — events survive force-quits.

```swift
// Call from didEnterBackgroundNotification (shown in the setup examples above)
Nanolytica.shared.persist()
```

The file is written atomically. If the app is killed before `persist()` returns, any in-memory events since the last persist are lost. For critical events, call `flush(completion:)` first:

```swift
NotificationCenter.default.addObserver(
    forName: UIApplication.didEnterBackgroundNotification,
    object: nil, queue: nil
) { _ in
    Nanolytica.shared.flush {
        Nanolytica.shared.persist()
    }
}
```

## Privacy and opt-out

```swift
// User declines analytics
Nanolytica.shared.optOut()    // clears queue, stops all sends

// User grants consent later
Nanolytica.shared.optIn()
Nanolytica.shared.pageview("/home")  // resumes normally
```

Typical GDPR pattern in Settings:

```swift
func setAnalyticsConsent(_ granted: Bool) {
    if granted {
        Nanolytica.shared.optIn()
    } else {
        Nanolytica.shared.optOut()
        // Also remove any persisted queue
        try? FileManager.default.removeItem(at: queueFileURL)
    }
}
```

## Self-hosted instance

```swift
Nanolytica.shared.start(
    siteID: "site-uuid",
    options: .init(endpoint: URL(string: "https://analytics.your-domain.com")!)
)
```

## User-Agent format

The server parses `User-Agent` to populate the **App Versions** column. Use the canonical form:

```
AppName/X.Y.Z (Platform N; Device)
```

Examples:
- `MyApp/2.1.0 (iOS 17.4; iPhone15,2)` → "MyApp 2.1.0" in the dashboard
- `MyTVApp/1.0.0 (tvOS 17.4; AppleTV6,2)` → "MyTVApp 1.0.0"

To get the hardware identifier on iOS (optional, requires `uname`):

```swift
import Darwin

func machineModel() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafeBytes(of: &systemInfo.machine) { ptr in
        String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
    }
}
// "iPhone15,2" (iPhone 14 Pro)
```

## tvOS

The SDK targets tvOS 14+ with the same API. `UIDevice` is not available on tvOS — use `Bundle.main` for version info:

```swift
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
try? Nanolytica.shared.start(
    siteID: "site-uuid",
    options: .init(userAgent: "MyTVApp/\(version) (tvOS; AppleTV)")
)
```

## Full API reference

### `Nanolytica.shared.start(siteID:options:) throws`

Starts the client. Throws `NanolyticaError.invalidSiteID` if `siteID` is empty. Safe to call multiple times — subsequent calls update the siteID and options.

### `Nanolytica.shared.pageview(_:referrer:screenSize:utmSource:utmMedium:utmCampaign:utmContent:utmTerm:)`

Records a pageview. All parameters except `path` are optional. No-op if `optOut()` was called or `start()` has not been called.

| Parameter | Type | Description |
|---|---|---|
| `path` | `String` | Screen path, e.g. `/home` (≤ 2048 chars) |
| `referrer` | `String?` | Previous URL |
| `screenSize` | `String?` | `WIDTHxHEIGHT`, e.g. `"390x844"` |
| `utmSource` | `String?` | UTM source |
| `utmMedium` | `String?` | UTM medium |
| `utmCampaign` | `String?` | UTM campaign |
| `utmContent` | `String?` | UTM content |
| `utmTerm` | `String?` | UTM term |

### `Nanolytica.shared.track(_:props:value:) -> Result<Void, NanolyticaError>`

Records a custom event. Returns `.failure` on validation error; never throws.

### `Nanolytica.shared.flush(completion:)`

Runs the drain loop on a background queue, calls `completion?()` when done.

### `Nanolytica.shared.persist()`

Writes the queue to disk. Call from background notification.

### `Nanolytica.shared.setUserAgent(_:)`

Replaces the User-Agent for subsequent requests.

### `Nanolytica.shared.optOut()` / `optIn()`

Toggles analytics globally.

## NanolyticaError cases

| Case | When |
|---|---|
| `.notStarted` | `track` called before `start` |
| `.invalidSiteID` | `siteID` is empty |
| `.invalidEventName` | Name empty, >64 chars, or bad chars |
| `.reservedPrefix` | Name starts with `nanolytica_` |
| `.tooManyProps` | More than 10 props |
| `.invalidPropKey` | Key empty, >64 chars, or bad chars |
| `.invalidPropValue` | Value >256 chars |
| `.invalidPath` | Path >2048 chars |

## Validation rules

| Field | Rule |
|---|---|
| `site_id` | Non-empty string |
| `path` | ≤ 2048 chars |
| `referrer` | ≤ 2048 chars |
| `event_name` | 1–64 chars, `^[a-zA-Z0-9_-]+$`, not starting with `nanolytica_` |
| `props` keys | 1–64 chars, `^[a-zA-Z0-9_-]+$` |
| `props` values | ≤ 256 chars |
| `props` count | ≤ 10 pairs |

## Transport behavior

- Events queue in memory; a single background `DispatchQueue` drains them one at a time.
- 5xx and network errors retry with 1 s / 2 s / 4 s backoff (blocking the drain goroutine). 4xx errors drop the event.
- Full queue drops oldest.
- All public methods are thread-safe via `NSLock`.

## Troubleshooting

**Events not appearing in the dashboard**
- Verify the site UUID and that the site type is **Native App**.
- Ensure `persist()` is called from `didEnterBackgroundNotification` and `start()` is called at launch.
- Check for a 400 response in the server logs — the body contains the validation error.

**App Versions shows the wrong string**
- UA must be `AppName/X.Y.Z (...)`. Anything before the first space (with `/` → space) is the version shown.
- Confirm the site is **Native App** type.

**`start` throws `invalidSiteID`**
- `siteID` is empty. Check that your UUID environment variable or plist entry is set.

**Offline events not appearing after re-launch**
- `persist()` must be called before the app is suspended. Register for `didEnterBackgroundNotification` at launch.

**Rate limit (429)**
- Default server limit is 1000 events/min per site. Reduce call frequency.

## Testing

```bash
swift run NanolyticaTests
```

The test target is a plain executable (not XCTest), so it runs on a stock Swift toolchain without Xcode.

## License

MIT
