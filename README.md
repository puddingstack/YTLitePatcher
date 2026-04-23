# YTLitePatcher

Runtime hooks for YTLite v5.2's closed-source `YTLite.dylib`.  
Compiles to a standalone `.dylib` and gets injected into the YouTube IPA alongside YTLite.

**End product: a single `.ipa` file** — YouTube + YTLite + YTLitePatcher, ready to sideload.

## How to Use

1. Push this repo to your GitHub account
2. Go to **Actions** → **Build Patched YouTube Plus**
3. Click **Run workflow** and fill in:
   - `ipa_url`: URL to a decrypted YouTube `.ipa`
   - `tweak_version`: YTLite version (default: `5.2`)
   - `display_name`: App name (default: `YouTube`)
   - `bundle_id`: Bundle ID (default: `com.google.ios.youtube`)
4. Wait for the build to finish
5. Download the `.ipa` from **Releases** (created as draft)
6. Sideload with your preferred method

## What It Does

Hooks YTLite's closed-source paywall classes at runtime:

| Target | What It Does |
|--------|--------------|
| `DVNCell.setLocked:` | Forces `locked = NO` on all settings cells |
| `DVNCell.isLocked` / `.locked` | Always returns NO |
| `DVNPatreonContext` auth checks | Always returns YES (tries isAuthorized, isAuthenticated, isLoggedIn, isActive, isPatron, hasActiveSubscription) |
| `WelcomeVC.viewDidLoad` | Dismisses the login screen immediately |
| `YTPSettingsBuilder.patreonSection` | Returns nil — removes Patreon section from settings |
| `YTPSettingsBuilder.patreonButtonCellWithType:model:` | Returns nil |
| `DVNTableViewController.setLocked:` | Forces `locked = NO` |

## Build Pipeline

```
GitHub Actions (macos-latest)
    │
    ├─ Downloads YTLite v5.2 .deb from upstream releases
    ├─ Downloads your decrypted YouTube .ipa
    ├─ Compiles Tweak_Standalone.m → YTLitePatcher.dylib (arm64+arm64e)
    ├─ Injects both into the IPA using cyan (pyzule-rw)
    │
    └─ Outputs: single YouTubePlus_Patched_5.2.ipa
```

## Caveats

- Auth-check selectors on `DVNPatreonContext` are inferred from common patterns.
  The code tries multiple names and hooks whichever actually exists at runtime.
- If the developer strips symbols or adds server-side validation in future versions,
  additional RE work would be needed.
- From binary analysis, the paywall check is purely local (no server calls found).

## Files

```
YTLitePatcher/
├── Tweak_Standalone.m          # The patcher source (pure ObjC runtime)
├── .github/workflows/build.yml # GitHub Actions workflow
└── README.md
```
