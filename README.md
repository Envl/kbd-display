# kbd-display

A macOS menu bar app that lights up the VIPI Action75’s 1920 × 720 display as you type. Runs on Apple silicon and Intel Macs with macOS 13 or later.

## Install and update

[Build from source](#build-from-source) or, when a packaged version is available, download the app ZIP from [GitHub Releases](https://github.com/Envl/kbd-display/releases). Extract **kbd-display.app** and move it to **Applications** before opening it. Release builds automatically check for signed updates. When an update has downloaded and is ready to install, an orange dot appears on the keyboard menu bar icon. Choose **Restart to Update** there or in **Effects…**. Quitting normally also lets Sparkle finish a staged installation.

## Using the keyboard display

Choose the Action75 from the menu bar while it is in extended mode. Selection is saved by display UUID and restored on reconnect. Choose **Output Off** to release it. The app starts listening for key presses on launch. Grant macOS Input Monitoring access so it can respond while other apps are active.

Open **Effects…** to change colors, keyboard lighting, key animations, typing sounds, music visuals, or the dictation glow. Click a key in the settings preview to try an effect. Changes apply immediately. **Pause Effects** suspends playback and **Resume Effects** restores your setup. Opening Effects shows the app in the Dock until the settings window closes. **More** in the sidebar contains restore defaults and quit.

Under **Dictation**, click the current **Hold shortcut**, press your chosen keys together, then release. Single keys, left and right modifiers, and multi-key combinations are supported. Right Option is the default. The glow appears around the last recorded key present on the Action75 layout. If none are present, it appears around Right Option. Hold the shortcut while using your dictation app for voice-reactive animation.

Run `scripts/run.sh` for the Debug build. Its menu adds **Calibrate…**, **Exclusive Display Capture**, and **Debug Window…**, which opens an interactive floating preview with sample app icons and a live plugin view.

With legends off, the idle frame is black. A round foil glow travels from the previous key’s center to the new key’s center, spilling light and sparks across the keys between them. Each hit scatters larger sparks with individually sampled sizes and lanes. The destination key’s outline glows on contact and catches a softer glint as the glow arrives. The first hit uses a short local sweep. Repeating a key starts a small flicker. Rapid taps build its size, brightness, and ember count. After about a second of rest, or a change of key, it starts cool again. The traveling glow adapts Glimm 0.3.0 and the gradient settings from Shell Click’s homepage intro. Both outputs share the baked Metal frames for the glow and flame. The renderer reads virtual key codes for these effects and discards them after the animation. The ANSI key grid starts at 16 × 6 units and can be calibrated to the physical panel.

## Display plugin protocol v2

Any macOS app in the same login session can publish keyboard hints through Foundation’s `DistributedNotificationCenter.default()`. Use the notification names below and pass a UTF-8 JSON string as the notification’s `object`. Send with `deliverImmediately: true`. The full name of each topic starts with `kbd-display.v2.`.

1. Choose a stable provider ID, typically your bundle identifier. Pair it with your current process ID. The pair identifies one running provider.
2. Subscribe to `discover` before posting `register`. Post a registration on startup and again whenever you receive `discover` (which has a nil object). Include your full current snapshot, even while idle. This supports either app launching first and rediscovery after wake.
3. Post `state` with a full replacement snapshot whenever your visible hints change. Optional `press` flashes a macOS virtual key code once. The display accepts state only from registered providers. Use localized labels and SF Symbol names. Each snapshot supports up to 128 hints and 64 KiB of JSON.
4. To clear your hints while staying registered, send `state` with an empty `hints` array and omit `title`. To disable your integration while your app is running, post `unregister` with just the provider object, e.g. `{"id":"org.example.editor","pid":1234}`. Process exit automatically removes the registration.

The most recent active provider to publish takes the display. If it clears, unregisters, or exits, the previous active provider’s hints return. Discovery and restoration never replay a press.

A minimal Swift provider can run this on its main thread. Keep the discovery observer alive while the plugin is enabled.

```swift
import Foundation

let center = DistributedNotificationCenter.default()
let provider: [String: Any] = ["id": "org.example.editor", "pid": ProcessInfo.processInfo.processIdentifier]
var hints: [[String: Any]] = [["keyCode": 1, "label": "Save", "symbol": "square.and.arrow.down"]]

func publish(_ topic: String, press: Int? = nil) {
    var snapshot: [String: Any] = ["provider": provider, "hints": hints]
    if let press { snapshot["press"] = press }
    guard let data = try? JSONSerialization.data(withJSONObject: snapshot),
          let json = String(data: data, encoding: .utf8) else { return }
    center.postNotificationName(.init("kbd-display.v2.\(topic)"), object: json,
                                userInfo: nil, deliverImmediately: true)
}

let observer = center.addObserver(forName: .init("kbd-display.v2.discover"), object: nil,
                                  queue: .main) { _ in publish("register") }
publish("register")
// In your action handler: publish("state", press: 1)
// When the mode closes: hints = []; publish("state")
```

For custom artwork, include an opaque `iconID` on the hint. Observe `requestIcon` for `{"provider":{"id":"org.example.editor","pid":1234},"iconID":"save"}`. Reply only when the provider pair matches yours. Post `icon` with those same fields plus `png`, a base64-encoded 64 × 64 PNG. Each reply carries one image and supports up to 48 KiB of JSON. Icon IDs are local to each provider. The v2 receiver requires v2 providers.

## Build from source

Install Xcode with the macOS 15 SDK or newer and select its command-line tools. Swift Package Manager downloads the checksum-pinned Sparkle framework on the first build. The app and its settings can be tested without an external display.

- `swift test` runs the protocol and layout checks.
- `scripts/build.sh` builds and locally signs `dist/kbd-display.app`.
- `scripts/run.sh` builds and opens the separate Debug bundle.

The build script uses a local Developer ID or Apple Development identity when available and falls back to ad-hoc signing. Set `KBD_DISPLAY_SIGN_IDENTITY=-` for ad-hoc signing, or specify a stable identity to retain Input Monitoring permission across rebuilds. Local builds omit the production update feed by default.

## Release automation

GitHub Actions tests branches and pull requests. A stable version tag such as `v1.2.3` triggers a universal Release build, Apple notarization, and publication of the signed update ZIP and appcast as a single GitHub Release. The feed URL comes from the repository running the workflow. A public repository is required for clients to fetch the feed without authentication. See [release setup](RELEASING.md).

## License

Original project code is available under the [MIT License](LICENSE). The [Glimm notice](Licenses/Glimm.txt) covers adapted shader code. The [Sparkle notices](Licenses/Sparkle.txt) cover the updater and its bundled components. These notices ship with the macOS app. The code license does not grant rights to third-party brands, artwork, or recordings.

## Keyboard Ninja in the browser

Run `cd web && pnpm dev` and open [Keyboard Ninja](http://127.0.0.1:4399/). The server binds to this Mac on port 4399. Use `pnpm check` in `web` for the JavaScript checks and game-rule tests.

Hold a marked key and tap another to slice. Desktop players can also drag across the arena with a mouse. Space starts or resumes a round. Esc pauses, and the number row or the bracket keys select a blade. The theme menu switches fruit, vegetables, and gadgets during play. High scores and preferences are saved in the browser.

After changing blade artwork or timing, run `scripts/bake-web-blades.sh` to regenerate the web sprite sheets. To embed the game elsewhere, export its self-contained assets with `node web/export.mjs /path/to/destination`. On touchscreens, swipe to start and slice. Each finger draws its own short blade trail along the path you trace. Arcade is the initial touch mode. Desktop play uses Tab, Caps Lock, Shift, Enter, backslash, the marked letter and punctuation keys, and Space. In the focused arena Tab slices. Press Esc to pause and use Tab to reach the toolbar.
