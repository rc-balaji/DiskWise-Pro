# Fix for Flutter 3.47.7 Android build

Original error: Gradle 8.10.2 is lower than Flutter 3.47.7 minimum 8.14.

Changed:
- android/gradle/wrapper/gradle-wrapper.properties: Gradle 8.14
- android/settings.gradle.kts: AGP 8.11.1; Kotlin 2.2.20
- .github/workflows/build-android.yml: pin Flutter 3.47.7; add preflight assertions; artifact renamed.

AGP 9 warning in the build output was not the direct failure. Keeping AGP 8.x avoids the AGP 9 DSL migration.

To build: upload repo root including .github/; Actions > Build Android APK > Run workflow.

This environment does not include Flutter/Android SDK so a full APK compile is not verified.
