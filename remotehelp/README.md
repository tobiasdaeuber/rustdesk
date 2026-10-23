# RemoteHelp client

This branch (`remotehelp`) of the RustDesk fork builds the Windows x64 and macOS (Apple Silicon and Intel)
clients for the RemoteHelp server (`rd.dbnetsoft.com`). `master` follows upstream `rustdesk/rustdesk` unchanged.

## What differs from upstream

| Change | Where |
|--------|-------|
| App name *RemoteHelp*; ID/relay server, key and API server fixed; Settings → Network hidden | `remotehelp/client.json`, compiled in by `load_custom_client()` in `src/common.rs` |
| [db] icon for exe, tray, shortcuts and UI | `remotehelp/branding/icon.svg` → `make_icons.py` → `res/*.ico/png`, `flutter/assets/icon.*`, `flutter/windows/runner/resources/app_icon.ico`, `flutter/macos/Runner/AppIcon.icns`, `res/mac-*.png` |
| macOS: `RemoteHelp.app`, bundle ID `com.dbnetsoft.remotehelp`, `remotehelp://` links, bundle version = client version | `flutter/macos/Runner/Configs/AppInfo.xcconfig`, `Runner.xcodeproj/project.pbxproj`, `Runner/Info.plist`, `build_flutter_dmg()` in `build.py` |
| macOS: menu bar icon is the [db] template, not the coloured `assets/icon.png` | `src/tray.rs` |
| RemoteHelp logo at the top of the home page (light and dark theme) | `remotehelp/branding/logo-light.png`, `logo-dark.png` → `make_icons.py` → `flutter/assets/logo_light.png`, `logo_dark.png` |
| Version info (product name, company) | `flutter/windows/runner/Runner.rc`, `[package.metadata.winres]` in `Cargo.toml` and `libs/portable/Cargo.toml` |
| Slim CI builds, unsigned (macOS: ad hoc) | `.github/workflows/remotehelp-windows.yml`, `remotehelp-macos.yml` |
| Local signing, packing and publishing | `remotehelp/build-client.ps1` (Windows), `remotehelp/build-client-macos.sh` (macOS) |
| Auto-update from this fork's releases, announced by the RemoteHelp server, signed with the RemoteHelp update key; revisions like `1.5.1-2` | `src/common.rs` (`do_check_software_update`, `UPDATE_RELEASE_*`, `display_version_from_release_id`), `src/updater/artifact.rs`, `src/update_metadata.rs` (`TRUSTED_UPDATE_KEYS`), `res/update/generate_update_metadata.py` (`KEY_ID`); on macOS also `check_update_as_root` in `src/updater.rs` (upstream skips custom clients there) |
| Version | `remotehelp/set-version.ps1` (Cargo.toml, Cargo.lock) |

`client.json` uses the format of a RustDesk custom client (`custom.txt`): `app-name`, `override-settings`
(user cannot change), `default-settings` (initial values). Being compiled in, it needs no signature.
Because the app name is not "RustDesk", the client behaves as a custom client: it installs to
`C:\Program Files\RemoteHelp`, keeps its settings in `%APPDATA%\RemoteHelp` and never offers stock RustDesk updates.
On macOS it installs to `/Applications/RemoteHelp.app` with the launchd jobs `com.carriez.RemoteHelp_service` and
`_server`, beside a stock RustDesk if there is one.

## Building (Windows)

Plug in the code-signing token, then in this repository:

```powershell
.\remotehelp\build-client.ps1
```

It starts the GitHub Actions build, waits for it (45–75 min), downloads the result, signs every
`.exe`/`.dll` here, packs them into `remotehelp\out\RemoteHelp-<version>-x86_64.exe` and signs that.
`-RunId <id>` re-uses a finished run; `-NoSign` skips signing; `-CertThumbprint` picks a certificate.

## Building (macOS)

On a Mac, in this repository:

```bash
remotehelp/build-client-macos.sh
```

It starts the "RemoteHelp macOS" workflow, waits for it (40–70 min), downloads `RemoteHelp.app` for Apple Silicon
and Intel, signs both and packs them into `remotehelp/out/RemoteHelp-<version>-aarch64.dmg` and `-x86_64.dmg`.
`--run-id <id>` re-uses a finished run; `--help` lists the options.

Signing: without options the apps are signed ad hoc. Gatekeeper does not accept that (nor an *Apple Development*
certificate): users open the app once via System Settings → Privacy & Security → **Open Anyway**, and because an
ad-hoc signature changes with every build, macOS asks again for screen recording and accessibility after each update.
For distribution, use a *Developer ID Application* certificate (Apple Developer Program) and notarize:

```bash
xcrun notarytool store-credentials remotehelp     # once: Apple ID, team ID, app-specific password
remotehelp/build-client-macos.sh --identity "Developer ID Application: <name> (<team id>)" --notary-profile remotehelp
```

## Releasing an update

Installed clients check the RemoteHelp server once a day (`POST <api-server>/api/version/latest`). When the
server announces a version higher than their own, they download it from this fork's GitHub release, check the
signed `rustdesk-update.json` against the RemoteHelp update key, and install it while no session is active.
Auto-update is on by default (`allow-auto-update` in `client.json`) and only runs on installed clients
(on macOS: from the service in `/Applications/RemoteHelp.app`).

1. Raise the version: `.\remotehelp\set-version.ps1 1.5.1-2` (revision 1–9 on top of the RustDesk
   version; a merged RustDesk release resets it, e.g. `1.5.2`). Commit and push.
2. Plug in the token and run `.\remotehelp\build-client.ps1 -Publish`. It builds, signs, packs, signs the
   update metadata and creates the release `<version>` here.
3. On the Mac, run `remotehelp/build-client-macos.sh --publish` (with the signing options above). It adds the DMGs
   to that release and signs the update metadata again, now covering the Windows installer and both DMGs. Run it
   after the Windows publish: `build-client.ps1` refuses a release that already exists. The Mac needs a copy of the
   update key at `~/Library/Application Support/RemoteHelp/update-signing/ed25519-seed.txt` (or `--update-key`).
4. Roll it out in the RemoteHelp portal: **Settings → Client updates**, enter the version, save.
   Clearing the field stops announcing; clients never downgrade.

The update key's seed lives in `%APPDATA%\RemoteHelp\update-signing\ed25519-seed.txt` (not in this repository).
Back it up: without it no further updates can be published, and clients would have to be reinstalled by hand
with a build that trusts a new key.

## Changing server or branding

* Server, key or hidden settings: edit `remotehelp/client.json`.
* Icon and logo: they come from the RemoteHelp server repository (`wwwroot/img/remotehelp-icon.svg`,
  `branding/remotehelp-logo.png` and `-dark.png`, rendered there by `tools/Render-Branding.ps1`). Copy them to
  `remotehelp/branding/` as `icon.svg`, `logo-light.png` and `logo-dark.png`, run
  `python remotehelp/branding/make_icons.py` (needs Pillow and Microsoft Edge or Google Chrome; runs on Windows
  and macOS), commit the outputs.

Commit, push to `remotehelp`, run the build script.

## Updating to a new RustDesk version

```powershell
git fetch upstream            # upstream = https://github.com/rustdesk/rustdesk.git
git checkout master; git merge --ff-only upstream/master; git push
git checkout remotehelp; git merge master
git submodule update --init --recursive
```

Conflicts are limited to the files in the table above. Check `remotehelp-windows.yml` against the
x86_64 leg of `build-for-windows-flutter` in `flutter-build.yml`, and `remotehelp-macos.yml` against
`build-for-macOS` (tool versions, vcpkg commit, steps).

## Licence

RustDesk is AGPL-3.0. This fork is public, which provides the source of every client built from it.
