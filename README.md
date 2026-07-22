# Live Wallpapers for Mac

Menu bar macOS app for live video, image and GIF wallpapers.

Creator contact: https://x.com/Bubblegumbbbbb

## Release and Updates

Updates are distributed through GitHub Releases:

https://github.com/medusa4111/LiveWallpapersForMac

Build a signed release archive:

```bash
./script/package_release.sh 0.1.0 1
```

Upload these files from `dist/release/` to a GitHub Release:

- `Live Wallpapers for Mac-<version>.zip`
- `Live Wallpapers for Mac-<version>.zip.sha256`

Verify an update archive without installing it:

```bash
./script/install_update.sh --verify-only "dist/release/Live Wallpapers for Mac-0.1.0.zip"
```

Install an update archive:

```bash
./script/install_update.sh "dist/release/Live Wallpapers for Mac-0.1.0.zip"
```

## TCC Stability Rules

macOS privacy permissions are preserved only when the updated app has the same
designated requirement as the installed app.

Do not change between releases:

- `CFBundleIdentifier`: `com.medusa411.LiveWallpapersForMac`
- `CFBundleExecutable`: `Live Wallpapers for Mac`
- app path: `/Applications/Live Wallpapers for Mac.app`
- signing identity: `Live Wallpapers for Mac Release Signing`
- designated requirement baseline in `release/designated-requirement.txt`
- certificate SHA-1 baseline in `release/certificate-sha1.txt`

Allowed release changes:

- `CFBundleShortVersionString`
- `CFBundleVersion`
- source code and resources

The release packager refuses to fall back to ad-hoc signing.
