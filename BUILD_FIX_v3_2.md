# Build fix: release resource shrinking

Previous error:
```
Removing unused resources requires unused code shrinking to be turned on.
```

Cause: Android Gradle Plugin 8.11.1 was trying to shrink release resources while R8 code minification was disabled.

Fix in `android/app/build.gradle.kts` within `buildTypes { getByName("release") { ... } }`:

```kotlin
isMinifyEnabled = false
isShrinkResources = false
```

No other app functionality, permissions, native Kotlin scanning or Flutter UI was changed. Flutter 3.47.7, Gradle 8.14, AGP 8.11.1 and Kotlin 2.2.20 remain pinned.

## Retry
1. Replace the two modified Gradle / workflow files (or all ZIP files) in the repository root.
2. Commit and run `Build Android APK` in Actions.
3. Successful builds publish `DiskWise-Mobile-v3.2-APK`.

**Unverified:** Full Flutter/Android compilation unavailable in the packaging environment. If CI encounters another error, attach its first `FAILURE:` block and task name.
