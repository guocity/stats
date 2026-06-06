# Release Guide for Stats Fork

This guide explains how versioning works in this fork of **Stats** and how to compile, package, and release new versions to GitHub.

---

## 1. How Versioning Works

Stats uses two distinct version numbers:

1. **Marketing Version (`CFBundleShortVersionString`)**
   * **Format:** `Major.Minor.Patch` (e.g., `2.12.15`).
   * **Location:** Inside [project.pbxproj](file:///Users/leon/Documents/github/stats/Stats.xcodeproj/project.pbxproj) under `MARKETING_VERSION`.
   * **Purpose:** Public-facing version tag.
2. **Build Version (`CFBundleVersion`)**
   * **Format:** Integer (e.g., `801`).
   * **Location:** Inside [Info.plist](file:///Users/leon/Documents/github/stats/Stats/Supporting%20Files/Info.plist) under `CFBundleVersion`.
   * **Purpose:** Internal compilation build tracker.

---

## 2. Prerequisites for Publishing Releases

Before running the release command locally, make sure you have set up:

1. **Apple Developer Certificate**: Installed in your Mac's Keychain.
2. **Notarization Profile**: A Keychain profile named `AC_PASSWORD` containing your App Store Connect API Key or App-Specific Password:
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" --apple-id "your-email@apple.com" --team-id "YOURTEAMID"
   ```
3. **GitHub CLI (`gh`)**: Logged in with write access to the repository:
   ```bash
   gh auth login
   ```

---

## 3. How to Release (Automatic Version Increment & Upload)

### Running a Full Release (Update Patch and Publish to GitHub)
If you want to increment the patch version (e.g. from `2.12.16` to `2.12.17`) and automatically publish the built `.dmg` package to GitHub Releases, run this command:

```bash
make release
```

### Bumping the Version Separately
If you want to increment the marketing patch version inside `project.pbxproj` (e.g., from `2.12.15` to `2.12.16`) **without** running the full compile and publish process, run:
```bash
make next-patch-version
```

### Behind the Scenes
When running `make release`, the following pipeline is executed:

1. **Increment Version**: Runs the `next-patch-version` target to update the marketing patch version inside `project.pbxproj` (e.g., from `2.12.15` to `2.12.16`).
2. **Increment Build**: Increases the internal build version by `+1` (e.g., `801` to `802`).
3. **Build & Package**: Builds and compiles the app, signs it, submits it for Apple notarization, staples the notarization ticket, and packages it into `Stats.dmg`.
4. **Publish**: Uses the GitHub CLI (`gh`) to create a tag `v2.12.16` on `https://github.com/guocity/stats` and uploads the `Stats.dmg` asset to the release page.

---

## 4. Auto-Updater and Security Check

The app checks for updates directly from the `guocity/stats` repository. 

> [!IMPORTANT]
> The auto-updater performs a security check (`validateAppSignature` in `Updater.swift`) to verify that the downloaded app's Apple Developer **Team ID** matches the currently running app's Team ID. Both the installed app and the updates uploaded to GitHub **must be signed using the same developer certificate**. If they do not match, the update installation will be blocked.
