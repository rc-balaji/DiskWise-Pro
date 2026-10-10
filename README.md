# DiskWise Mobile v3 — Complete Flutter + Native Kotlin Android project

An offline, user-controlled storage analysis and duplicate cleanup app for **Android 11+ (API 30+)**. This ZIP includes an actual `android/` application project, Kotlin native scan engine, Flutter screens, asset resources, tests, and `.github/workflows/build-android.yml`.

## Get an APK through GitHub Actions

1. Extract the ZIP. Open the `DiskWise_Mobile_Pro_v3` folder.
2. Create a **new empty** GitHub repository. Upload **the contents of that folder** to the repository root (not just `lib/`). Keep the hidden `.github/workflows` directory.
3. Commit to `main` and open **Actions → Build Android APK**. Choose **Run workflow** (or let the push trigger run).
4. When the workflow completes, open its successful run → **Artifacts** → `DiskWise-Mobile-v3-APK`.
5. Download the artifact ZIP, extract `app-release.apk`, then install it on an Android 11+ device. Enable installation from your chosen file manager if Android prompts.

> If you upload the parent folder itself (leaving `DiskWise_Mobile_Pro_v3/` as a subdirectory in your repository), the workflow will not be detected. The `.github` folder must be at repository root.

The workflow installs Java 17, Flutter stable, generates the official **Gradle wrapper binary** in a temporary clean Flutter app, copies only its wrapper files, resolves packages, runs Dart analysis and tests, compiles Kotlin/Android and publishes a release-mode APK. The project **already contains** its Gradle build scripts, manifest, Kotlin code, UI, and resources. Generating the wrapper on CI avoids including an unverified Gradle JAR in the source ZIP; it does not replace or overwrite the native app code.

The CI release APK is signed with the **Android debug key** for convenient sideloading and evaluation. It is NOT a production Play Store signature. Set up a private upload keystore and Play signing before distributing an official release.

## What is implemented

- **Modern dark Material 3 UI**: overview, duplicates, insights, controls.
- **Explicit volume selection**: all available user storage, internal storage or removable SD volume discovered from Android `StorageManager`.
- **Custom age and size filters**: 1–3650 days and 1–100,000 MB, plus presets.
- **Folder-level, recursive rollup** of file count, unused candidate count and sizes.
- **Large files** and **empty/tiny files** (including 0-byte files) as reviewable insights.
- **Duplicate detection** with size grouping → SHA-256 of first+last 64 KiB → SHA-256 of all bytes. Files with **different names** but identical content are detected.
- **Background native scanner**, cancellation, progress events, file count limits, paged results.
- **Select duplicate copies** for permanent deletion. Keeps the first listed entry unselectable in the UI and, before every deletion, rechecks file metadata, full SHA-256 and at least one remaining byte-identical, unselected copy.
- **No deletion just from scanning** and no automated deletion of large, old or tiny files.
- **No account, cloud calls, analytics, ads, network permissions, accessibility privileges or root access.**

## Permission and security model

Android 11+ needs the special Android **All files access** permission to scan across shared-storage folders. DiskWise asks you to open Android's official application-specific permission settings; **you must enable it manually**. It does not silently grant itself permissions.

The permission does **NOT** enable access to private data of other applications (e.g. `/data/data`, protected `/Android/data` or `/Android/obb`) and it does not authorize erasing system apps' caches. The scanner intentionally skips the entire `/Android` directory, recovery/system directories, symlinks and paths outside recognized external storage roots.

> Google Play significantly restricts use of `MANAGE_EXTERNAL_STORAGE`. This source targets private/sideloaded builds; if publishing on Play, review current Google Play policy and use SAF/MediaStore APIs as appropriate.

**Deletion is permanent.** This version does **not** move files to the Android trash and has no undo. The app warns and requires a second confirmation before deleting manually selected duplicates. Back up important data before deleting anything. Deletion of arbitrary large/old files is intentionally NOT implemented.

## What “unused” actually means

Android does not provide a consistent or complete file last-opened date. This product uses **last-modified time**, not reliable usage tracking. A file not modified for a year might still be frequently viewed and important. Every unused finding is **recommendation only**.

## Performance boundaries

- Single native worker thread for filesystem I/O, Flutter UI remains responsive.
- At most **250,000 file metadata entries** per scan; if reached, the report explicitly says it is partial.
- Readable entries are limited to the **top 2,000** per insight category, **700** folder rows and **700** duplicate groups, returned in 40-item pages.
- Cryptographic hashes are calculated only for size-matched candidates; streaming I/O avoids loading file contents fully into RAM.
- Partial hashes are **not** evidence of duplicates; only full SHA-256 matches are shown as duplicates. File metadata is checked before/after hashing and before deletion.
- Exact speed is device-, storage-, file-count- and SD-card-dependent. No performance guarantee is made.
- Empty files are listed under Tiny Files but skipped for duplicate hashing because removing an empty file recovers 0 bytes.

## Source tree

```
DiskWise_Mobile_Pro_v3/
├── .github/workflows/build-android.yml
├── android/
│   ├── app/build.gradle.kts
│   ├── app/src/main/AndroidManifest.xml
│   ├── app/src/main/kotlin/com/diskwise/mobile/
│   │   ├── MainActivity.kt          (permission, volumes, platform APIs)
│   │   └── ScanCore.kt             (streaming SHA-256 scanning engine)
│   ├── app/src/main/res/...        (styles and custom launcher icon)
│   ├── gradle/wrapper/gradle-wrapper.properties
│   ├── settings.gradle.kts
│   └── build.gradle.kts
├── lib/main.dart                    (Flutter UI)
├── lib/format.dart                  (pure formatting functions)
├── test/format_test.dart            (Flutter unit tests)
├── analysis_options.yaml
├── pubspec.yaml
└── README.md
```

## Build locally (if Flutter + Android SDK installed)

`flutter create --platforms=android --project-name diskwise_mobile --org com.diskwise /tmp/diskwise_wrapper`

Copy the clean scaffold's `android/gradlew`, `android/gradlew.bat` and `android/gradle/wrapper/gradle-wrapper.jar` into this project's equivalent locations (they are bootstrap artifacts, not application source files).

Then run:

```bash
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

The APK appears at `build/app/outputs/flutter-apk/app-release.apk`.

## Validation performed here

The portable Kotlin core (`ScanCore.kt`) **compiled with `kotlinc`** and passed a JVM functional test identifying identical content under different filenames, excluding unique/empty files from duplicate groups and computing reclaimable bytes. The full Flutter/Android app **has not been compiled or run in this environment**, because Flutter/Android SDK and network downloads are unavailable. The GitHub workflow is designed to perform that required end-to-end build test. If it reports a compilation error, supply the Actions log to identify the exact failure.

## Limitations / deliberately not present

- No cleaning other apps' private caches (Android app sandbox)
- No app-uninstall automation / permission bypass
- No files moved to trash or rollback
- No byte-level visual near-duplicate detection (similar photos/videos with different encoding are **not** exact duplicates)
- No scan across cloud storage or app-private data
- No background service, scheduled job, or storage monitoring

**Before distribution, security-review and test on a spare device.** This software is provided as open-source project code, not a certified data recovery product.
