#!/bin/bash
# Builds the RemoteHelp macOS client on GitHub Actions and signs and packs it here.
#
#  1. Starts the "RemoteHelp macOS" workflow in the fork and waits for it (roughly 40-70 minutes).
#  2. Downloads RemoteHelp.app for Apple Silicon (aarch64) and Intel (x86_64).
#  3. Signs each app with --identity (default "-", ad hoc).
#  4. Packs each into remotehelp/out/RemoteHelp-<version>-<arch>.dmg, signs it and, with
#     --notary-profile, notarizes and staples it.
#  5. With --publish: adds the DMGs to the GitHub release <version> in the fork (created if the
#     Windows build has not published it yet) and signs update metadata for all of the release's
#     installers with the update key. Installed clients take it once the RemoteHelp server announces
#     it (portal: Settings -> Client updates).
#
# The version comes from Cargo.toml of the built commit; set it with set-version.ps1.
#
# Options:
#   --run-id ID             Use the artifacts of an existing workflow run instead of starting a build.
#   --ref BRANCH            Branch of the fork to build. Default: remotehelp.
#   --identity NAME         Code-signing identity, e.g. "Developer ID Application: ... (TEAMID)".
#                           Default "-": ad hoc. Ad-hoc and Apple Development signed apps are not
#                           accepted by Gatekeeper (users open them via System Settings -> Privacy &
#                           Security -> Open Anyway), and macOS asks again for screen recording and
#                           accessibility after every update of an ad-hoc signed app.
#   --notary-profile NAME   Notarize with this notarytool keychain profile (needs a Developer ID identity;
#                           create it with: xcrun notarytool store-credentials NAME).
#   --publish               Publish the DMGs and signed update metadata to the GitHub release.
#   --update-key FILE       Base64 ed25519 seed of the update signing key (same file as on Windows).
#                           Default: ~/Library/Application Support/RemoteHelp/update-signing/ed25519-seed.txt
#
# Examples:
#   remotehelp/build-client-macos.sh
#   remotehelp/build-client-macos.sh --run-id 12345678901 --publish
#   remotehelp/build-client-macos.sh --identity "Developer ID Application: dbnetsoft (ABCDE12345)" \
#       --notary-profile remotehelp --publish

set -euo pipefail

run_id=''
ref='remotehelp'
repo='tobiasdaeuber/rustdesk'
identity='-'
notary_profile=''
publish=0
update_key="$HOME/Library/Application Support/RemoteHelp/update-signing/ed25519-seed.txt"

while [ $# -gt 0 ]; do
    case "$1" in
        --run-id) run_id=$2; shift 2 ;;
        --ref) ref=$2; shift 2 ;;
        --repo) repo=$2; shift 2 ;;
        --identity) identity=$2; shift 2 ;;
        --notary-profile) notary_profile=$2; shift 2 ;;
        --publish) publish=1; shift ;;
        --update-key) update_key=$2; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

workflow='remotehelp-macos.yml'
app_name='RemoteHelp'
archs='aarch64 x86_64'
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/remotehelp/out"
work="$out/work-macos"

step() { printf '\033[36m==> %s\033[0m\n' "$1"; }
fail() { echo "Error: $1" >&2; exit 1; }

if [ $publish -eq 1 ] && [ ! -f "$update_key" ]; then fail "Update signing key not found: $update_key"; fi
if [ -n "$notary_profile" ] && [ "$identity" = '-' ]; then fail '--notary-profile needs a Developer ID --identity.'; fi

# --- Prerequisites -----------------------------------------------------------------------------
step 'Checking prerequisites'
command -v gh >/dev/null || fail 'GitHub CLI (gh) not found.'
gh auth status
if [ "$identity" != '-' ]; then
    security find-identity -v -p codesigning | grep -F "\"$identity\"" >/dev/null ||
        fail "Signing identity not found in the keychain: $identity"
fi
mkdir -p "$out"
if [ $publish -eq 1 ]; then
    python="$out/venv/bin/python3"
    if ! [ -x "$python" ] || ! "$python" -c 'import cryptography' 2>/dev/null; then
        echo 'Installing the Python cryptography package (needed to sign update metadata)...'
        python3 -m venv "$out/venv"
        "$python" -m pip install --quiet cryptography
    fi
fi

# --- Build on GitHub Actions -------------------------------------------------------------------
if [ -z "$run_id" ]; then
    step "Starting $workflow on $repo@$ref"
    started="$(date -u -v-5S +%Y-%m-%dT%H:%M:%SZ)"
    gh workflow run "$workflow" -R "$repo" --ref "$ref"
    for _ in $(seq 30); do
        sleep 4
        run_id="$(gh run list -R "$repo" -w "$workflow" -b "$ref" -e workflow_dispatch -L 5 \
            --json databaseId,createdAt --jq "[.[] | select(.createdAt >= \"$started\")][0].databaseId // empty")"
        [ -n "$run_id" ] && break
    done
    [ -n "$run_id" ] || fail "The workflow run did not show up; check https://github.com/$repo/actions"
    echo "Run: https://github.com/$repo/actions/runs/$run_id"
    step 'Waiting for the build (usually 40-70 minutes)'
    gh run watch "$run_id" -R "$repo" --exit-status --interval 60
fi

step "Downloading the artifacts of run $run_id"
rm -rf "$work"
mkdir -p "$work"
version=''
for arch in $archs; do
    gh run download "$run_id" -R "$repo" -n "remotehelp-macos-$arch" -D "$work/$arch"
    tar -C "$work/$arch" -xzf "$work/$arch/RemoteHelp-macos-$arch.tar.gz"
    app="$work/$arch/$app_name.app"
    [ -x "$app/Contents/MacOS/$app_name" ] || fail "The $arch artifact does not contain $app_name.app."
    # The client's own version (Cargo.toml); build.py writes it into the bundle, where the updater reads it.
    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    [[ "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[1-9])?$ ]] || fail "Unexpected client version '$app_version' ($arch)"
    [ -z "$version" ] || [ "$version" = "$app_version" ] || fail "The builds differ in version: $version, $app_version"
    version=$app_version
done
echo "Client version: $version"

# --- Sign and pack -----------------------------------------------------------------------------
entitlements="$root/flutter/macos/Runner/Release.entitlements"
if [ "$identity" = '-' ]; then
    # Ad-hoc signatures have no team ID, so the hardened runtime's library validation would refuse
    # the Flutter frameworks ("different Team IDs") on current macOS.
    entitlements="$work/adhoc.entitlements"
    cp "$root/flutter/macos/Runner/Release.entitlements" "$entitlements"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"
fi
dmgs=()
for arch in $archs; do
    app="$work/$arch/$app_name.app"
    step "Signing $arch ($([ "$identity" = '-' ] && echo 'ad hoc' || echo "$identity"))"
    bash "$root/.github/scripts/sign-macos-app.sh" "$app" "$identity" "$entitlements"
    "$app/Contents/MacOS/$app_name" --version >/dev/null 2>&1 || [ "$arch" != "$(uname -m | sed 's/arm64/aarch64/')" ] ||
        fail "The signed $arch app does not start."

    step "Packing $app_name-$version-$arch.dmg"
    stage="$work/$arch/dmg"
    mkdir -p "$stage"
    ditto "$app" "$stage/$app_name.app"
    ln -s /Applications "$stage/Applications"
    dmg="$out/$app_name-$version-$arch.dmg"
    rm -f "$dmg"
    hdiutil create -quiet -volname "$app_name" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
    if [ "$identity" != '-' ]; then
        codesign --force --timestamp --sign "$identity" "$dmg"
    fi
    if [ -n "$notary_profile" ]; then
        step "Notarizing $app_name-$version-$arch.dmg"
        xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
        xcrun stapler staple "$dmg"
    fi
    dmgs+=("$dmg")
done

# --- Publish -----------------------------------------------------------------------------------
if [ $publish -eq 1 ]; then
    step "Publishing to release $version"
    release_dir="$work/release"
    mkdir -p "$release_dir"
    metadata="$out/rustdesk-update.json"
    signature="$out/rustdesk-update.json.sig"
    artifact_args=()
    release_exists=0
    if gh release view "$version" -R "$repo" --json tagName >/dev/null 2>&1; then
        release_exists=1
        # The metadata covers every installer of the release, so it is signed again with the Windows
        # (and any other) installers already there; their hashes come from the downloaded files.
        if gh release download "$version" -R "$repo" -p rustdesk-update.json -D "$release_dir" 2>/dev/null; then
            while IFS=$'\t' read -r platform arch format file_name; do
                gh release download "$version" -R "$repo" -p "$file_name" -D "$release_dir" --clobber
                artifact_args+=(--artifact "$platform" "$arch" "$format" "$release_dir/$file_name")
            done < <("$python" -c '
import json, sys
for a in json.load(open(sys.argv[1]))["artifacts"]:
    if a["platform"] != "macos":
        print("\t".join([a["platform"], a["arch"], a["format"], a["file_name"]]))
' "$release_dir/rustdesk-update.json")
        fi
    fi
    for arch in $archs; do
        artifact_args+=(--artifact macos "$arch" dmg "$out/$app_name-$version-$arch.dmg")
    done
    # File names and schema are what the client's updater expects (src/updater/artifact.rs).
    RUSTDESK_UPDATE_ED25519_SEED="$(tr -d '[:space:]' < "$update_key")" \
        "$python" "$root/res/update/generate_update_metadata.py" sign \
        "${artifact_args[@]}" \
        --version "$version" --release-id "$version" --package-id rustdesk \
        --release-base-url "https://github.com/$repo/releases/download" \
        --published-at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --metadata-out "$metadata" --signature-out "$signature"
    if [ $release_exists -eq 1 ]; then
        gh release upload "$version" "${dmgs[@]}" "$metadata" "$signature" -R "$repo" --clobber
    else
        commit="$(gh run view "$run_id" -R "$repo" --json headSha --jq .headSha)"
        notes="RemoteHelp client $version, built by run https://github.com/$repo/actions/runs/$run_id."
        if [ "$identity" = '-' ]; then
            gh release create "$version" "${dmgs[@]}" "$metadata" "$signature" -R "$repo" --target "$commit" \
                --prerelease --title "$app_name $version (unsigned test)" \
                --notes "$notes"$'\n\n'"Ad-hoc signed macOS test build for trying the auto-update."
        else
            gh release create "$version" "${dmgs[@]}" "$metadata" "$signature" -R "$repo" --target "$commit" \
                --title "$app_name $version" --notes "$notes"
        fi
    fi
    echo "Release: https://github.com/$repo/releases/tag/$version"
    printf '\033[33m%s\033[0m\n' "Roll it out in the RemoteHelp portal: Settings -> Client updates -> $version"
fi

echo
printf '\033[32mDone:\033[0m\n'
printf '  %s\n' "${dmgs[@]}"
