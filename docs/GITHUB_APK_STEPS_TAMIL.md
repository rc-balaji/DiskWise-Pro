# GitHub Actions la APK build pannurathu

**Important:** ZIP extract pannunga. Extract panna `DiskWise_Mobile_Pro_v3` folder-kulla irukkira ella files-um GitHub repository root-la upload pannanum. `.github` hidden directory-um include aaganum.

1. GitHub → New repository → name `DiskWise-Mobile` → Create.
2. Add file → Upload files → `DiskWise_Mobile_Pro_v3`-kulla irukkira **contents**-ai upload pannunga. Folder-a mattum nested-a upload panna workflow theriyathu.
3. Commit changes.
4. GitHub repository → **Actions** → **Build Android APK** → **Run workflow**.
5. Build successful aana piragu workflow open panni **Artifacts** → **DiskWise-Mobile-v3-APK** download pannunga.
6. Artifact ZIP extract → `app-release.apk` phone-la install pannunga. Android 11 or newer required.
7. Phone-la DiskWise open pannina storage permission settings varum. **Allow access to manage all files** toggle manually ON pannunga.
8. Overview → `All available storage` / `Internal storage` / `External storage` select panni → `Start smart analysis` click pannunga.
9. Duplicates tab-la exact same content irukkira files review panni, extra copies mattum select pannunga. Delete permanent, so important files backup pannikonga.

## If workflow not visible

Make sure `.github/workflows/build-android.yml` repository root-la correct path-la irukku. ZIP full-folder nested structure upload pannirundha root-ku move pannunga.

## If APK compilation fails

Actions run open panni red step click panni build log copy pannunga. Intha project Flutter SDK illatha environment-la create pannapattathu; full Android APK compile and real-phone smoke test GitHub Actions la first verify aagum.

**Android limitations:** Android 11+ special permission irunthalum other apps private cache/system folders scan/delete panna mudiyathu. "Unused" file score = last modified date, real last-used time illa. Self-delete and blind cleanup intentionally disabled.
