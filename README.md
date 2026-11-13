# ChatGPT Work iPhone Mirroring Harness

**A native macOS gesture helper that lets ChatGPT Work in the Mac desktop app operate an iPhone through Apple's iPhone Mirroring.**

Built during a real Home Screen redesign: the agent could see and click the mirrored phone, but reliable long presses, continuous held drags, folder drops and page transfers needed more precise timing. This harness supplies those gestures through a small Swift app and a local JSON request/response bridge.

The working loop is: **observe the mirrored iPhone → choose a gesture → send it to the native helper → inspect the result**. The agent retains the visual reasoning; the helper executes bounded mouse gestures.

The original joke was “GPT's attempt at creating its own Force Touch and Magic Trackpad for iOS.” It synthesises mouse events, not pressure or multitouch. It is an independent experiment, not an official OpenAI or Apple integration, and does not modify ChatGPT's built-in tools.

## What works

- Click and long-press in iPhone Mirroring.
- Keep the mouse button held from pickup through movement and release.
- Move Home Screen icons, create folders, and add or extract apps.
- Swipe Home Screen and folder pages.
- Transfer an icon across a Home Screen page edge using a short edge dwell.
- Read the Mirroring window's current geometry and permission status.
- Cancel a running gesture, with mouse-up cleanup.

These operations were exercised on a real mirrored iPhone. Coordinates and timings are empirical, not a guarantee for every device, scale or OS version. Always verify the screenshot after a change.

## Requirements

- A Mac and iPhone on which [Apple's iPhone Mirroring](https://support.apple.com/en-au/120421) already works. The iPhone must remain locked during mirroring.
- ChatGPT Work on the Mac with an authorised computer-control/screenshot interface and local command execution, or another operator able to call the same local bridge.
- Apple's Swift compiler/Xcode command-line tools and Python 3.9 or later.
- Accessibility permission granted by the user to the built **Precision Mouse** app. The helper cannot grant this permission itself.

The agent's shell does not need to inject mouse events. The separately authorised native app does that. A sandboxed shell may report no displays or no event access even when the native app is permitted.

## Build and start

```sh
zsh build.sh
open PrecisionMouse.app
```

In the helper, click **Request Accessibility Access**, enable Precision Mouse in **System Settings → Privacy & Security → Accessibility**, then quit and reopen the helper if needed. Connect iPhone Mirroring and leave its window visible.

The build is local and ad-hoc signed, not notarised. The build script uses a stable bundle identifier and designated requirement; permission behaviour after rebuilding can still depend on macOS. Quit the old helper before opening a rebuilt copy. Keep the app beside `mouse_harness.py`, or pass the client's `--bridge-dir` option to the bridge directory beside the app.

```sh
python3 mouse_harness.py '{"action":"status"}'
```

Check `trusted`, `posting`, and `frame`. If the helper repeatedly reports that Mirroring did not become frontmost, refocus Mirroring and restart the helper; restarting resolved a stale focus problem during the original session.

## Agent integration

Use the existing authorised computer-control interface for screenshots and app/window inspection. This repository does not provide a screenshot backend, an MCP server, or an automatic ChatGPT plugin installation.

1. Inspect the iPhone's current screen. Do not infer app positions from an old screenshot.
2. Convert the chosen screenshot point to fractions of the **entire Mirroring window, including the title bar**: `x / screenshot_width`, `y / screenshot_height`.
3. Run one JSON request using the local shell.
4. Inspect a fresh screenshot. The response's `done` state means event delivery finished; it does not prove the intended app moved.
5. Allow visible folder/page animations to finish before the next dependent gesture.

Example shell call an agent can issue:

```sh
python3 mouse_harness.py '{"action":"click","from":[0.5,0.77],"hold":1400}'
```

This long-press example enters Home Screen editing only if that point is blank wallpaper in the observed layout. It is not a semantic “edit Home Screen” command.

## Gesture recipes

### Move an icon or drop it into a folder

Enter editing first, inspect the grid, then use icon centres:

```sh
python3 mouse_harness.py '{"action":"drag","from":[0.173,0.707],"to":[0.39,0.492],"hold":400,"move":100,"steps":1,"settle":500}'
```

One full-displacement drag event worked better than many tiny events in the tested Mirroring session. The mouse remains down during hold, movement and settle.

### Extract an app from a folder

Drag from its observed folder position to blank space outside the folder. A longer destination dwell lets the folder close:

```sh
python3 mouse_harness.py '{"action":"drag","from":[0.28,0.398],"to":[0.83,0.76],"hold":400,"move":100,"steps":1,"settle":850}'
```

Inspect again before moving the extracted app. iOS may put it in the first free slot, shift other icons, or push an icon onto the next page.

### Swipe a page

Use a visibly empty horizontal gap, not an app icon:

```sh
python3 mouse_harness.py '{"action":"drag","from":[0.8,0.58],"to":[0.3,0.58],"hold":20,"move":180,"steps":3,"settle":50}'
```

Reverse the endpoints for the previous page. The example gap was used inside a folder; choose another gap for the Home Screen.

### Move an icon to the previous Home Screen page

```sh
python3 mouse_harness.py '{"action":"drag","from":[0.173,0.6],"to":[0.03,0.6],"hold":400,"move":150,"steps":2,"settle":1200}'
```

Two movement steps and about 1.2 seconds at the edge successfully transferred an icon one page in the session. A 1.9-second dwell skipped two pages; 0.8 seconds did not cross. This is especially timing-sensitive. Inspect the destination and account for any displaced icons. Use the opposite edge for a next-page transfer and verify its timing separately.

### Cancel

```sh
python3 mouse_harness.py cancel
```

The helper checks the cancel file during waits and releases the mouse. The client permits one active request at a time and times out after 20 seconds. Quit Precision Mouse to stop its polling entirely.

## Protocol

| Field | Meaning |
| --- | --- |
| `action` | `status`, `click`, or `drag` |
| `from` | Two window-relative fractions, each between 0 and 1 |
| `to` | Drag destination, in the same coordinate system |
| `hold` | Mouse-down dwell in milliseconds, 0–5000 |
| `move` | Movement duration in milliseconds, 100–5000 |
| `steps` | Number of held drag events, 1–300; 0/omitted uses approximately 60 Hz |
| `settle` | Destination dwell before mouse-up, 0–3000 ms |

The Python client adds a unique `id` and `created` timestamp and writes `mouse-bridge/request.json` atomically. The app ignores expired requests and the request present at startup. Results appear in `response.json`, matched by ID, with `running`, `done`, `cancelled`, or `error` state. The bridge is local files only; there is no network listener or arbitrary shell-command operation.

The native app resolves Apple's `com.apple.ScreenContinuity` process and the `iphone-mirroring-main` accessibility window. It reads geometry for every request, checks existing event/Accessibility permission, and verifies foreground ownership before injecting input. It cancels if focus changes during a gesture. Do not use the physical mouse simultaneously.

## Limits and lessons

- iPhone Mirroring exposes the Mac window controls to Accessibility, but the Home Screen icons were not available as semantic accessibility elements in this session. Visual verification is essential.
- Picking up/unlocking the iPhone ends mirroring. Lock it and reconnect before continuing.
- Folder drop timing and edge timing differ. Overlong dwells may open a folder or cross an extra page.
- Page layout changes can invalidate the next coordinate even when the previous gesture succeeded.
- Keyboard injection, Shift-scroll and direct-to-process mouse posting were tried without a reliable visible result. They are intentionally absent from this published interface.
- Screenshots use the agent's existing authorised interface. An experimental ScreenCaptureKit route lacked separate screen-recording permission and is not included.
- The prototype sends real Mac mouse input. It is intended for a supervised, user-authorised session, not unattended background operation.
- No iPhone jailbreak, private iOS API, developer-mode change, automatic login, startup service or permission bypass is involved.

## Files

| File | Purpose |
| --- | --- |
| `PrecisionMouse.swift` | Native AppKit UI, bounded gesture bridge, and diagnostic CLI |
| `mouse_harness.py` | Atomic request client, response matching and cancellation |
| `build.sh` | Compile and locally sign the app |
| `Info.plist` | App bundle metadata |

The manual panel accepts global Mac screen **points**, unlike the bridge's fractions. Its Run Held Drag button queues through the same native bridge. The optional diagnostic CLI can validate a raw drag without sending input:

```sh
PrecisionMouse.app/Contents/MacOS/PrecisionMouse drag 100 100 200 200 400 100 500 --dry-run
```

Source is published without session screenshots, account data, bridge request logs or compiled binaries.

## Validation

```sh
python3 -m unittest discover -s tests -v
```

The protocol tests use temporary files and a simulated native peer; they send no mouse events. They check that stale/in-progress responses cannot complete a request, a concurrent client cannot overwrite an active request, and cancellation remains available while the client lock is held. The Swift app also compiles locally, and the diagnostic CLI supports dry runs. Live gesture observations above come from the original Mirroring session; the tests do not simulate iOS behaviour.
