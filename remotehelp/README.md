# RemoteHelp client

This branch (`remotehelp`) of the RustDesk fork builds the Windows x64 client for the RemoteHelp server
(`rd.dbnetsoft.com`). `master` follows upstream `rustdesk/rustdesk` unchanged.

## What differs from upstream

| Change | Where |
|--------|-------|
| App name *RemoteHelp*; ID/relay server, key and API server fixed; Settings → Network hidden | `remotehelp/client.json`, compiled in by `load_custom_client()` in `src/common.rs` |
| [db] icon for exe, tray, shortcuts and UI | `remotehelp/branding/icon.svg` → `make_icons.py` → `res/*.ico/png`, `flutter/assets/icon.*`, `flutter/windows/runner/resources/app_icon.ico` |
| Version info (product name, company) | `flutter/windows/runner/Runner.rc`, `[package.metadata.winres]` in `Cargo.toml` and `libs/portable/Cargo.toml` |
| Slim Windows x64 CI build, unsigned | `.github/workflows/remotehelp-windows.yml` |
| Local signing and packing | `remotehelp/build-client.ps1` |

`client.json` uses the format of a RustDesk custom client (`custom.txt`): `app-name`, `override-settings`
(user cannot change), `default-settings` (initial values). Being compiled in, it needs no signature.
Because the app name is not "RustDesk", the client behaves as a custom client: it installs to
`C:\Program Files\RemoteHelp`, keeps its settings in `%APPDATA%\RemoteHelp` and never offers stock RustDesk updates.

## Building

Plug in the code-signing token, then in this repository:

```powershell
.\remotehelp\build-client.ps1
```

It starts the GitHub Actions build, waits for it (45–75 min), downloads the result, signs every
`.exe`/`.dll` here, packs them into `remotehelp\out\RemoteHelp-<version>-x86_64.exe` and signs that.
`-RunId <id>` re-uses a finished run; `-NoSign` skips signing; `-CertThumbprint` picks a certificate.

## Changing server or branding

* Server, key or hidden settings: edit `remotehelp/client.json`.
* Icon: replace `remotehelp/branding/icon.svg`, run `python remotehelp/branding/make_icons.py`, commit the outputs.

Commit, push to `remotehelp`, run the build script.

## Updating to a new RustDesk version

```powershell
git fetch upstream            # upstream = https://github.com/rustdesk/rustdesk.git
git checkout master; git merge --ff-only upstream/master; git push
git checkout remotehelp; git merge master
git submodule update --init --recursive
```

Conflicts are limited to the files in the table above. Check `remotehelp-windows.yml` against the
x86_64 leg of `build-for-windows-flutter` in `flutter-build.yml` (tool versions, vcpkg commit, steps).

## Licence

RustDesk is AGPL-3.0. This fork is public, which provides the source of every client built from it.
