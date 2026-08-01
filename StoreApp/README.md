# Portly Companion for the Mac App Store

This target is intentionally separate from the full Portly distribution. It is an App Sandbox-compliant controller for a Portly service already running on the same Mac.

- It communicates only with `http://127.0.0.1:7737`.
- It does not embed Sparkle, install a CLI, launch shell commands, inspect ports, or read project files.
- The full Developer ID distribution remains the process supervisor and source of truth.

Generate and validate the project with:

```bash
cd StoreApp
xcodegen generate
xcodebuild -project PortlyCompanion.xcodeproj -scheme PortlyCompanion -destination 'platform=macOS' test
```
