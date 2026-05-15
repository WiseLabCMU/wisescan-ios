# Release Process

This document describes the end-to-end release process for Scan4D (wisescan-ios). The process uses **release-please** for versioning/changelog and **Fastlane** for TestFlight distribution.

## Overview

```
Finalize Code → Merge release-please PR → Pull Tag Locally → Fastlane Build & Upload
```

## Prerequisites

### One-Time Setup

1. **Install Fastlane** (via Bundler):
   ```bash
   cd wisescan-ios
   bundle install
   ```

2. **App Store Connect API Key** — required for Fastlane to upload to TestFlight without interactive login:
   - Go to [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
   - Create a new key with **App Manager** role
   - Download the `.p8` file (you only get one chance)
   - Set these environment variables (e.g. in `~/.zshrc` or a `.env` file):
     ```bash
     export APP_STORE_CONNECT_API_KEY_KEY_ID="XXXXXXXXXX"
     export APP_STORE_CONNECT_API_KEY_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
     export APP_STORE_CONNECT_API_KEY_KEY="$(base64 < /path/to/AuthKey_XXXXXXXXXX.p8)"
     ```

3. **Xcode Signing** — ensure automatic signing is configured with the correct team (`24D5JLAEA3`) and that you have a valid App Store distribution certificate.

## Release Steps

### 1. Finalize Code on `main`

Ensure all features and fixes for this release are merged into `main` using [Conventional Commits](https://www.conventionalcommits.org/) format:

```
feat: add new scan export option
fix: correct mesh rotation on older devices
chore: update dependencies
```

> **Note:** Only `feat:` and `fix:` commits generate changelog entries. `chore:`, `docs:`, `ci:` etc. are excluded from the changelog.

### 2. Merge the release-please PR

After pushing to `main`, the **release-please** GitHub Action automatically creates (or updates) a release PR titled something like:

```
chore(main): release 0.2.0
```

This PR contains:
- Updated `CHANGELOG.md` with all new entries
- Updated `.release-please-manifest.json` with the new version

**Review the changelog**, then **merge the PR**. This triggers release-please to:
- Create a **git tag** (e.g. `v0.2.0`)
- Create a **GitHub Release** with the changelog

### 3. Pull the Tag Locally

```bash
git pull origin main --tags
```

Verify the tag exists:
```bash
git describe --tags
# Should output: v0.2.0 (or similar)
```

> **Why this matters:** The Xcode build phase "Pull Release Tag From Github" runs `git describe --tags` during Archive and writes the version into `CFBundleShortVersionString`. If the tag isn't pulled locally, the version won't be correct.

### 4. Build & Upload to TestFlight via Fastlane

```bash
bundle exec fastlane beta
```

This single command:
1. Authenticates with App Store Connect (via API key)
2. Auto-increments the build number (fetches latest from TestFlight + 1)
3. Archives the app (which triggers the git tag → version injection)
4. Uploads the `.ipa` to TestFlight
5. Sets the **beta feedback email** to `arenaxr@andrew.cmu.edu`

### 5. Distribute to Testers

After the build finishes processing on App Store Connect (~10-20 min):
1. Go to [App Store Connect → TestFlight](https://appstoreconnect.apple.com)
2. Add release notes for testers
3. Enable the build for your test groups

## Quick Reference

| Step | Command / Action | What Happens |
|------|-----------------|--------------|
| Finalize | Merge feature/fix PRs to `main` | Code is ready |
| Version | Merge the release-please PR | Tag + GitHub Release created |
| Sync | `git pull origin main --tags` | Local repo has the new tag |
| Ship | `bundle exec fastlane beta` | Archive → TestFlight upload |
| Distribute | App Store Connect UI | Enable build for testers |

## Troubleshooting

### "No tags found" during Archive
```bash
git fetch --tags
git describe --tags  # Verify tag exists
```

### Build number conflict
Fastlane auto-increments from the latest TestFlight build number. If you get a conflict, check App Store Connect for the current highest build number.

### Authentication errors
Ensure the API key environment variables are set:
```bash
echo $APP_STORE_CONNECT_API_KEY_KEY_ID  # Should not be empty
```

### Custom Feedback Email
The `beta_feedback_email` in `fastlane/Fastfile` controls where TestFlight "Send Beta Feedback" reports go. Update this email as needed — this is the primary reason Fastlane is used in this project.
