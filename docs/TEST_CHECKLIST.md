# Android real-device acceptance test checklist

## Installation and access
- [ ] CI build succeeds and APK installs on Android 11/12/13/14/15
- [ ] On first launch, storage is displayed without runtime crash
- [ ] Permission off: Open Settings correctly routes to all-files access
- [ ] Permission denied: no filesystem scan/deletion happens
- [ ] Permission granted: available storage roots appear
- [ ] Internal and optional removable SD selection work independently
- [ ] "All available storage" scans each discovered volume

## Scan correctness
- [ ] Two files with identical content but different names are grouped
- [ ] Same size but different content is NOT grouped
- [ ] 0-byte files appear in Tiny Files
- [ ] A file modified years ago appears with applicable age threshold
- [ ] Recursively nested folders report accumulated old file bytes
- [ ] Custom 1–3650 day threshold is accepted
- [ ] Custom 1–100000 MB threshold is accepted
- [ ] Cancel does not retain old scan result for deletion
- [ ] Files inaccessible due to Android permissions are skipped
- [ ] Scanner does not traverse symlinks or `/Android/data`
- [ ] Partial scan clearly indicates 250K file safety cap

## Safety
- [ ] First duplicate in each group cannot be selected in UI
- [ ] No files deleted automatically by scan
- [ ] Delete requires explicit modal confirmation
- [ ] Modified/removed keeper makes subsequent duplicate deletion skip
- [ ] No files outside selected scan result can be deleted
- [ ] After successful deletion, scan session is invalidated
- [ ] No app-private or system folders are scanned
- [ ] App reports deletion as permanent, without false undo promise

## Performance
- [ ] Interface stays responsive during 50K-file scan
- [ ] Device not excessively heated during long hash phase
- [ ] An optional external SD scan handles unavailable/ejected drive
- [ ] Back/home/resume do not crash scanner
- [ ] File counts and space labels are visually readable on small phones
