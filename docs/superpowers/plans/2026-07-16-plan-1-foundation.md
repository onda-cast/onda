# Onda Plan 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Xcode project, SwiftData model layer, the neo-brutalist theme/design system, and the app shell (3-tab bar) so later subsystems have models, styling, and navigation to build into.

**Architecture:** SwiftUI "MV" pattern — views read SwiftData `@Query` and `@Observable` services from the environment; no ViewModel layer. SwiftData `ModelContainer` is created at app launch and injected. The theme is a resolved-sRGB palette (converted from the prototype's oklch values) exposed as `Color` extensions plus reusable view modifiers for the sharp-corner / thick-border / hard-shadow look.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Xcode 16+, iOS 17 deployment target, XCTest.

## Global Constraints

- Deployment target: **iOS 17.0** minimum (SwiftData requires 17+).
- UI framework: **SwiftUI** only. No UIKit view controllers except where an API requires a bridge (none in this plan).
- Persistence: **SwiftData** only. No Core Data, no UserDefaults for domain data (UserDefaults is allowed only for the app-appearance toggle).
- Pattern: **MV** — no ViewModel classes. Services are `@Observable` classes injected via `.environment(...)`.
- Visual source of truth: the imported prototype `Podcast App.dc.html`. Style = thick borders (2–3px), hard offset drop shadows (no blur), sharp corners (`cornerRadius: 0`), uppercase Arial-Black-style headers.
- All new Swift files begin with no license header; match Apple's default file template comment (`//  FileName.swift`).
- Prerequisite (Step 0, one-time): full **Xcode** installed and selected (`sudo xcode-select -s /Applications/Xcode.app`), an iOS 17+ simulator available.

---

## File Structure

```
Onda.xcodeproj
Onda/
  OndaApp.swift            — @main App; builds ModelContainer, injects services, sets color scheme
  Models/
    Podcast.swift          — @Model Podcast
    Episode.swift          — @Model Episode
    Chapter.swift          — @Model Chapter
    ShowSettings.swift     — @Model ShowSettings (+ default factory)
    QueueItem.swift        — @Model QueueItem
    DownloadedFile.swift   — @Model DownloadedFile
    ModelSchema.swift      — array of all model types for the container
  Theme/
    Palette.swift          — resolved sRGB Color tokens for light/dark
    Theme.swift            — @Observable AppTheme (appearance state, persisted)
    BrutalStyle.swift      — view modifiers: .brutalBorder(), .hardShadow(), BrutalHeader text style
  Shell/
    RootView.swift         — TabView with Library / Discover / Profile
    LibraryView.swift      — placeholder grid (filled in Plan 2)
    DiscoverView.swift     — placeholder (filled in Plan 2)
    ProfileView.swift      — appearance toggle + settings rows (Downloads screen filled in Plan 5)
OndaTests/
  ModelTests.swift         — SwiftData in-memory model tests
  ThemeTests.swift         — palette / appearance tests
```

---

### Task 1: Create the Xcode project

**Files:**
- Create: `Onda.xcodeproj` (via `xcodegen` or Xcode), `Onda/OndaApp.swift`, `OndaTests/`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable iOS app target `Onda` + unit test target `OndaTests`, iOS 17 deployment target, that launches to an empty screen.

- [ ] **Step 0: Verify Xcode is installed and selected**

Run: `xcodebuild -version`
Expected: prints `Xcode 16.x` (NOT the command-line-tools error). If it errors, run `sudo xcode-select -s /Applications/Xcode.app` first.

- [ ] **Step 1: Create the project via XcodeGen for reproducibility**

Create `project.yml`:

```yaml
name: Onda
options:
  bundleIdPrefix: com.onda
  deploymentTarget:
    iOS: "17.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    GENERATE_INFOPLIST_FILE: YES
    INFOPLIST_KEY_UILaunchScreen_Generation: YES
    INFOPLIST_KEY_UIBackgroundModes: audio
    CURRENT_PROJECT_VERSION: "1"
    MARKETING_VERSION: "0.1.0"
targets:
  Onda:
    type: application
    platform: iOS
    sources: [Onda]
    settings:
      base:
        INFOPLIST_KEY_CFBundleDisplayName: Onda
  OndaTests:
    type: bundle.unit-test
    platform: iOS
    sources: [OndaTests]
    dependencies:
      - target: Onda
```

Run: `brew install xcodegen` (if not installed), then `xcodegen generate`
Expected: `Created project at Onda.xcodeproj`.

> Note: `INFOPLIST_KEY_UIBackgroundModes: audio` is set now so background playback (Plan 3) works without revisiting project config.

- [ ] **Step 2: Create a minimal app entry point**

Create `Onda/OndaApp.swift`:

```swift
//  OndaApp.swift
import SwiftUI

@main
struct OndaApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Onda")
        }
    }
}
```

- [ ] **Step 3: Build to verify the project compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add project.yml Onda.xcodeproj Onda OndaTests
git commit -m "chore: scaffold Onda Xcode project (iOS 17, SwiftUI)"
```

---

### Task 2: Define the SwiftData models

**Files:**
- Create: `Onda/Models/Podcast.swift`, `Episode.swift`, `Chapter.swift`, `ShowSettings.swift`, `QueueItem.swift`, `DownloadedFile.swift`, `ModelSchema.swift`
- Test: `OndaTests/ModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (relied on by every later plan — exact shapes):
  - `Podcast(feedURL: URL, title: String, author: String, artworkURL: URL?, category: String, itunesId: Int?)`; properties `isSubscribed: Bool`, relationship `episodes: [Episode]`, `settings: ShowSettings?`
  - `Episode(guid: String, title: String, publishDate: Date, duration: TimeInterval, audioURL: URL, notes: String)`; properties `playbackPosition: TimeInterval`, `played: Bool`, relationships `podcast: Podcast?`, `chapters: [Chapter]`, `downloadedFile: DownloadedFile?`
  - `Chapter(title: String, startTime: TimeInterval, isAd: Bool)`; relationship `episode: Episode?`
  - `ShowSettings.makeDefault() -> ShowSettings` with `speed=1.0, voiceBoost=0, skipSilence=false, adSkipMode="off", autoDownload=false, introTrimSec=0, outroTrimSec=0, notifMode="all"`
  - `QueueItem(episode: Episode, position: Int)`
  - `DownloadedFile(localFileName: String, fileSizeBytes: Int64, downloadedAt: Date)`; relationship `episode: Episode?`
  - `ondaSchema: [any PersistentModel.Type]`

- [ ] **Step 1: Write the failing model test**

Create `OndaTests/ModelTests.swift`:

```swift
//  ModelTests.swift
import XCTest
import SwiftData
@testable import Onda

final class ModelTests: XCTestCase {
    private func inMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(ondaSchema), configurations: config)
        return ModelContext(container)
    }

    func test_insertPodcastWithEpisode_persistsRelationship() throws {
        let ctx = try inMemoryContext()
        let pod = Podcast(feedURL: URL(string: "https://ex.com/f.xml")!,
                          title: "The Signal", author: "Ex", artworkURL: nil,
                          category: "Technology", itunesId: 42)
        let ep = Episode(guid: "g1", title: "Ep 1", publishDate: .now,
                         duration: 100, audioURL: URL(string: "https://ex.com/1.mp3")!,
                         notes: "notes")
        ep.podcast = pod
        ctx.insert(pod); ctx.insert(ep)
        try ctx.save()

        let pods = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(pods.count, 1)
        XCTAssertEqual(pods.first?.episodes.count, 1)
        XCTAssertEqual(pods.first?.episodes.first?.title, "Ep 1")
    }

    func test_showSettingsDefault_hasExpectedValues() {
        let s = ShowSettings.makeDefault()
        XCTAssertEqual(s.speed, 1.0)
        XCTAssertEqual(s.voiceBoost, 0)
        XCTAssertFalse(s.skipSilence)
        XCTAssertEqual(s.adSkipMode, "off")
        XCTAssertFalse(s.autoDownload)
        XCTAssertEqual(s.introTrimSec, 0)
        XCTAssertEqual(s.outroTrimSec, 0)
        XCTAssertEqual(s.notifMode, "all")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ModelTests`
Expected: FAIL — `cannot find 'Podcast' in scope`.

- [ ] **Step 3: Write the model files**

Create `Onda/Models/Podcast.swift`:

```swift
//  Podcast.swift
import Foundation
import SwiftData

@Model
final class Podcast {
    @Attribute(.unique) var feedURL: URL
    var title: String
    var author: String
    var artworkURL: URL?
    var category: String
    var itunesId: Int?
    var isSubscribed: Bool

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    @Relationship(deleteRule: .cascade, inverse: \ShowSettings.podcast)
    var settings: ShowSettings?

    init(feedURL: URL, title: String, author: String, artworkURL: URL?,
         category: String, itunesId: Int?, isSubscribed: Bool = false) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.category = category
        self.itunesId = itunesId
        self.isSubscribed = isSubscribed
    }
}
```

Create `Onda/Models/Episode.swift`:

```swift
//  Episode.swift
import Foundation
import SwiftData

@Model
final class Episode {
    @Attribute(.unique) var guid: String
    var title: String
    var publishDate: Date
    var duration: TimeInterval
    var audioURL: URL
    var notes: String
    var playbackPosition: TimeInterval
    var played: Bool

    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \Chapter.episode)
    var chapters: [Chapter] = []

    @Relationship(deleteRule: .cascade, inverse: \DownloadedFile.episode)
    var downloadedFile: DownloadedFile?

    init(guid: String, title: String, publishDate: Date, duration: TimeInterval,
         audioURL: URL, notes: String, playbackPosition: TimeInterval = 0, played: Bool = false) {
        self.guid = guid
        self.title = title
        self.publishDate = publishDate
        self.duration = duration
        self.audioURL = audioURL
        self.notes = notes
        self.playbackPosition = playbackPosition
        self.played = played
    }
}
```

Create `Onda/Models/Chapter.swift`:

```swift
//  Chapter.swift
import Foundation
import SwiftData

@Model
final class Chapter {
    var title: String
    var startTime: TimeInterval
    var isAd: Bool
    var episode: Episode?

    init(title: String, startTime: TimeInterval, isAd: Bool = false) {
        self.title = title
        self.startTime = startTime
        self.isAd = isAd
    }
}
```

Create `Onda/Models/ShowSettings.swift`:

```swift
//  ShowSettings.swift
import Foundation
import SwiftData

@Model
final class ShowSettings {
    var speed: Double
    var voiceBoost: Int         // 0 = Off, 1 = Med, 2 = High
    var skipSilence: Bool
    var adSkipMode: String      // "off" | "manual" | "auto"
    var autoDownload: Bool
    var introTrimSec: Int
    var outroTrimSec: Int
    var notifMode: String       // "all" | "important" | "none"
    var podcast: Podcast?

    init(speed: Double, voiceBoost: Int, skipSilence: Bool, adSkipMode: String,
         autoDownload: Bool, introTrimSec: Int, outroTrimSec: Int, notifMode: String) {
        self.speed = speed
        self.voiceBoost = voiceBoost
        self.skipSilence = skipSilence
        self.adSkipMode = adSkipMode
        self.autoDownload = autoDownload
        self.introTrimSec = introTrimSec
        self.outroTrimSec = outroTrimSec
        self.notifMode = notifMode
    }

    static func makeDefault() -> ShowSettings {
        ShowSettings(speed: 1.0, voiceBoost: 0, skipSilence: false, adSkipMode: "off",
                     autoDownload: false, introTrimSec: 0, outroTrimSec: 0, notifMode: "all")
    }
}
```

Create `Onda/Models/QueueItem.swift`:

```swift
//  QueueItem.swift
import Foundation
import SwiftData

@Model
final class QueueItem {
    var position: Int
    var episode: Episode?

    init(episode: Episode, position: Int) {
        self.episode = episode
        self.position = position
    }
}
```

Create `Onda/Models/DownloadedFile.swift`:

```swift
//  DownloadedFile.swift
import Foundation
import SwiftData

@Model
final class DownloadedFile {
    var localFileName: String     // filename only; resolved against Application Support at read time
    var fileSizeBytes: Int64
    var downloadedAt: Date
    var episode: Episode?

    init(localFileName: String, fileSizeBytes: Int64, downloadedAt: Date) {
        self.localFileName = localFileName
        self.fileSizeBytes = fileSizeBytes
        self.downloadedAt = downloadedAt
    }
}
```

Create `Onda/Models/ModelSchema.swift`:

```swift
//  ModelSchema.swift
import SwiftData

let ondaSchema: [any PersistentModel.Type] = [
    Podcast.self, Episode.self, Chapter.self,
    ShowSettings.self, QueueItem.self, DownloadedFile.self
]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ModelTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Models OndaTests/ModelTests.swift
git commit -m "feat: SwiftData model layer (Podcast, Episode, Chapter, ShowSettings, QueueItem, DownloadedFile)"
```

---

### Task 3: Theme palette and appearance state

**Files:**
- Create: `Onda/Theme/Palette.swift`, `Onda/Theme/Theme.swift`
- Test: `OndaTests/ThemeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum Appearance: String { case light, dark }`
  - `@Observable final class AppTheme` with `var appearance: Appearance` (persisted to UserDefaults key `"appearance"`), `func toggle()`, and `var colorScheme: ColorScheme`
  - `extension Color` static tokens resolved per-appearance via `OndaColors.token(_:for:)`: `bg, bgElevated, text, textSecondary, textTertiary, accent, accentWash, separator, border, cardShadow, sheetBg, tabBarBg`

> The prototype defines colors in oklch. iOS 17 `Color` has no oklch initializer, so these are pre-converted to sRGB hex at plan-authoring time. Light `--bg` `oklch(95% 0.03 95)` ≈ `#F2EFE4`; `--accent` `oklch(45% 0.1 150)` ≈ `#1F6E4E`; dark `--bg` `#111111`; dark `--accent` `oklch(55% 0.1 150)` ≈ `#3E8E68`. Remaining tokens converted the same way below.

- [ ] **Step 1: Write the failing theme test**

Create `OndaTests/ThemeTests.swift`:

```swift
//  ThemeTests.swift
import XCTest
import SwiftUI
@testable import Onda

final class ThemeTests: XCTestCase {
    func test_toggle_flipsAppearance() {
        let theme = AppTheme(appearance: .light, persist: false)
        XCTAssertEqual(theme.appearance, .light)
        theme.toggle()
        XCTAssertEqual(theme.appearance, .dark)
        theme.toggle()
        XCTAssertEqual(theme.appearance, .light)
    }

    func test_colorScheme_matchesAppearance() {
        XCTAssertEqual(AppTheme(appearance: .dark, persist: false).colorScheme, .dark)
        XCTAssertEqual(AppTheme(appearance: .light, persist: false).colorScheme, .light)
    }

    func test_tokens_differBetweenAppearances() {
        let lightBg = OndaColors.token(.bg, for: .light)
        let darkBg = OndaColors.token(.bg, for: .dark)
        XCTAssertNotEqual(lightBg.description, darkBg.description)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ThemeTests`
Expected: FAIL — `cannot find 'AppTheme' in scope`.

- [ ] **Step 3: Write the palette**

Create `Onda/Theme/Palette.swift`:

```swift
//  Palette.swift
import SwiftUI

enum Appearance: String { case light, dark }

enum ColorToken {
    case bg, bgElevated, text, textSecondary, textTertiary
    case accent, accentWash, separator, border, cardShadow, sheetBg, tabBarBg
}

enum OndaColors {
    // Hex values pre-converted from the prototype's oklch palette.
    private static let light: [ColorToken: String] = [
        .bg: "F2EFE4", .bgElevated: "FFFFFF", .text: "111111",
        .textSecondary: "4A4A44", .textTertiary: "6B6A60",
        .accent: "1F6E4E", .accentWash: "1F6E4E22", .separator: "111111",
        .border: "111111", .cardShadow: "111111", .sheetBg: "FFFFFF", .tabBarBg: "F2EFE4"
    ]
    private static let dark: [ColorToken: String] = [
        .bg: "111111", .bgElevated: "1E2A24", .text: "FFFFFF",
        .textSecondary: "C3C8C4", .textTertiary: "8A8F8B",
        .accent: "3E8E68", .accentWash: "3E8E6830", .separator: "3A3A3A",
        .border: "FFFFFF", .cardShadow: "FFFFFF", .sheetBg: "161616", .tabBarBg: "111111"
    ]

    static func token(_ t: ColorToken, for a: Appearance) -> Color {
        let hex = (a == .light ? light : dark)[t] ?? "FF00FF"
        return Color(hex: hex)
    }
}

extension Color {
    init(hex: String) {
        var h = hex; var alpha = 1.0
        if h.count == 8 { // RRGGBBAA
            let aa = h.suffix(2)
            alpha = Double(Int(aa, radix: 16) ?? 255) / 255.0
            h = String(h.prefix(6))
        }
        let v = Int(h, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: alpha)
    }
}
```

Create `Onda/Theme/Theme.swift`:

```swift
//  Theme.swift
import SwiftUI

@Observable
final class AppTheme {
    var appearance: Appearance {
        didSet { if persist { UserDefaults.standard.set(appearance.rawValue, forKey: Self.key) } }
    }
    private let persist: Bool
    private static let key = "appearance"

    init(appearance: Appearance? = nil, persist: Bool = true) {
        self.persist = persist
        if let appearance {
            self.appearance = appearance
        } else {
            let stored = UserDefaults.standard.string(forKey: Self.key).flatMap(Appearance.init)
            self.appearance = stored ?? .light
        }
    }

    var colorScheme: ColorScheme { appearance == .dark ? .dark : .light }
    func toggle() { appearance = (appearance == .light) ? .dark : .light }
    func color(_ t: ColorToken) -> Color { OndaColors.token(t, for: appearance) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:OndaTests/ThemeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Onda/Theme/Palette.swift Onda/Theme/Theme.swift OndaTests/ThemeTests.swift
git commit -m "feat: theme palette + AppTheme appearance state"
```

---

### Task 4: Brutal style view modifiers

**Files:**
- Create: `Onda/Theme/BrutalStyle.swift`

**Interfaces:**
- Consumes: `AppTheme` from the environment.
- Produces:
  - `View.brutalBorder(width: CGFloat = 2.5)` — sharp-corner border in `.border` token
  - `View.hardShadow(offset: CGFloat = 4)` — offset, blur-free drop shadow in `.cardShadow` token
  - `Text.brutalHeader(size: CGFloat)` — uppercase, heavy weight, tight tracking
  - `BrutalCard<Content>` container applying elevated bg + border + hard shadow

- [ ] **Step 1: Write the style modifiers**

Create `Onda/Theme/BrutalStyle.swift`:

```swift
//  BrutalStyle.swift
import SwiftUI

private struct BrutalBorder: ViewModifier {
    @Environment(AppTheme.self) private var theme
    var width: CGFloat
    func body(content: Content) -> some View {
        content.overlay(Rectangle().stroke(theme.color(.border), lineWidth: width))
    }
}

private struct HardShadow: ViewModifier {
    @Environment(AppTheme.self) private var theme
    var offset: CGFloat
    func body(content: Content) -> some View {
        content.background(
            Rectangle().fill(theme.color(.cardShadow))
                .offset(x: offset, y: offset)
        )
    }
}

extension View {
    func brutalBorder(width: CGFloat = 2.5) -> some View { modifier(BrutalBorder(width: width)) }
    func hardShadow(offset: CGFloat = 4) -> some View { modifier(HardShadow(offset: offset)) }
}

extension Text {
    func brutalHeader(size: CGFloat) -> some View {
        self.font(.system(size: size, weight: .black, design: .default))
            .textCase(.uppercase)
            .tracking(-0.5)
    }
}

struct BrutalCard<Content: View>: View {
    @Environment(AppTheme.self) private var theme
    var offset: CGFloat = 4
    var borderWidth: CGFloat = 2.5
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(theme.color(.bgElevated))
            .brutalBorder(width: borderWidth)
            .hardShadow(offset: offset)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

(No unit test — these are pure view modifiers; they are exercised visually in Task 6 and via the shell in Task 5.)

- [ ] **Step 3: Commit**

```bash
git add Onda/Theme/BrutalStyle.swift
git commit -m "feat: brutal style view modifiers (border, hard shadow, header, card)"
```

---

### Task 5: App shell — container, model container, tab bar

**Files:**
- Modify: `Onda/OndaApp.swift`
- Create: `Onda/Shell/RootView.swift`, `Onda/Shell/LibraryView.swift`, `Onda/Shell/DiscoverView.swift`, `Onda/Shell/ProfileView.swift`

**Interfaces:**
- Consumes: `ondaSchema`, `AppTheme`, brutal style modifiers.
- Produces:
  - `RootView` — `TabView` with three custom brutal tabs (Library, Discover, Profile) matching the prototype's bottom bar (thick top border, accent-colored active item).
  - `LibraryView`, `DiscoverView`, `ProfileView` — real headers + placeholders that Plans 2/5 fill in. `ProfileView` already has a working Appearance toggle.

- [ ] **Step 1: Wire the app entry point to the container + theme**

Replace `Onda/OndaApp.swift`:

```swift
//  OndaApp.swift
import SwiftUI
import SwiftData

@main
struct OndaApp: App {
    let container: ModelContainer
    @State private var theme = AppTheme()

    init() {
        do {
            container = try ModelContainer(for: Schema(ondaSchema))
        } catch {
            fatalError("Failed to build ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(theme)
                .preferredColorScheme(theme.colorScheme)
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 2: Create the tab shell**

Create `Onda/Shell/RootView.swift`:

```swift
//  RootView.swift
import SwiftUI

enum Tab: Hashable { case library, discover, profile }

struct RootView: View {
    @Environment(AppTheme.self) private var theme
    @State private var tab: Tab = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            theme.color(.bg).ignoresSafeArea()
            Group {
                switch tab {
                case .library:  LibraryView()
                case .discover: DiscoverView()
                case .profile:  ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            tabBar
        }
    }

    private var tabBar: some View {
        HStack {
            tabButton(.library, "Library", "rectangle.grid.1x2")
            tabButton(.discover, "Discover", "magnifyingglass")
            tabButton(.profile, "Profile", "person")
        }
        .padding(.top, 8)
        .frame(height: 78)
        .background(theme.color(.tabBarBg))
        .overlay(Rectangle().frame(height: 2.5).foregroundStyle(theme.color(.border)), alignment: .top)
    }

    private func tabButton(_ t: Tab, _ label: String, _ icon: String) -> some View {
        let active = tab == t
        return Button { tab = t } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(label).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(active ? theme.color(.accent) : theme.color(.textTertiary))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: Create the three tab screens (headers + placeholders)**

Create `Onda/Shell/LibraryView.swift`:

```swift
//  LibraryView.swift
import SwiftUI

struct LibraryView: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                .padding(.horizontal, 20).padding(.top, 56)
            Spacer()
            Text("No shows yet").foregroundStyle(theme.color(.textTertiary))
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }
}
```

Create `Onda/Shell/DiscoverView.swift`:

```swift
//  DiscoverView.swift
import SwiftUI

struct DiscoverView: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Discover").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                .padding(.horizontal, 20).padding(.top, 56)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

Create `Onda/Shell/ProfileView.swift`:

```swift
//  ProfileView.swift
import SwiftUI

struct ProfileView: View {
    @Environment(AppTheme.self) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Profile").brutalHeader(size: 32).foregroundStyle(theme.color(.text))
                .padding(.top, 56)

            Text("Appearance").brutalHeader(size: 13).foregroundStyle(theme.color(.textTertiary))
            BrutalCard {
                HStack {
                    Text("Light / Dark").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.color(.text))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { theme.appearance == .dark },
                        set: { _ in theme.toggle() }
                    )).labelsHidden().tint(theme.color(.accent))
                }
                .padding(16)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 4: Build and launch in the simulator to verify tabs + appearance toggle**

Run: `xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' build`
Expected: `** BUILD SUCCEEDED **`.

Then boot and run the app:
```bash
xcrun simctl boot "iPhone 16" 2>/dev/null || true
open -a Simulator
xcodebuild -project Onda.xcodeproj -scheme Onda -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath build install
xcrun simctl launch booted com.onda.Onda
```
Expected: app launches, three tabs switch, Profile → toggle flips the whole app between light and dark.

- [ ] **Step 5: Commit**

```bash
git add Onda/OndaApp.swift Onda/Shell
git commit -m "feat: app shell — model container, brutal tab bar, three tab screens, working appearance toggle"
```

---

## Self-Review

- **Spec coverage:** Data model (all 6 `@Model`s) ✓; MV architecture + environment injection ✓; theme/light-dark from prototype oklch palette ✓; tab bar (Library/Discover/Profile) ✓; brutal visual language primitives ✓. Discovery/playback/downloads are explicitly deferred to Plans 2–5.
- **Placeholder scan:** `LibraryView`/`DiscoverView` bodies are intentional UI placeholders that Plan 2 replaces; no plan-level TODOs remain. Every code step shows full code.
- **Type consistency:** Model initializers here match the "Produces" interface used by Plans 2–5 (`Podcast(feedURL:title:author:artworkURL:category:itunesId:)`, `ShowSettings.makeDefault()`, `DownloadedFile(localFileName:fileSizeBytes:downloadedAt:)`). `ColorToken`/`AppTheme.color(_:)` are the styling entry points Plans 2–5 reuse.
