#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_path="${script_dir}/Apple Notes Exporter.xcodeproj"
scheme="Apple Notes Exporter"
configuration="${CONFIGURATION:-Debug}"
candidate_bundle_id="${CANDIDATE_BUNDLE_ID:-com.jsfk5.appletoobsidian.candidate}"
candidate_display_name="${CANDIDATE_DISPLAY_NAME:-Apple to Obsidian Candidate}"
derived_data="${DERIVED_DATA_PATH:-${TMPDIR%/}/apple-to-obsidian-candidate-deriveddata}"
output_root="${1:-${script_dir}/Products}"
production_bundle_id="com.zaremski.AppleNotesExporter"

fail() {
    print -u2 -- "Candidate build failed: $*"
    exit 1
}

if [[ $# -gt 1 ]]; then
    fail "usage: ${0:t} [output-directory]"
fi

if [[ ! -d "${project_path}" ]]; then
    fail "Xcode project not found at ${project_path}"
fi

if [[ -z "${candidate_display_name}" || "${candidate_display_name}" == */* ]]; then
    fail "CANDIDATE_DISPLAY_NAME must be a non-empty filename-safe name"
fi

if ! print -r -- "${candidate_bundle_id}" | /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]+$'; then
    fail "CANDIDATE_BUNDLE_ID is not a valid bundle identifier"
fi

if [[ "${candidate_bundle_id}" == "${production_bundle_id}" ]]; then
    fail "candidate bundle identifier must differ from production"
fi

derived_data="${derived_data:A}"
output_root="${output_root:A}"

case "${output_root}" in
    /|/Applications|/Applications/*|/System|/System/*)
        fail "refusing candidate output root ${output_root}"
        ;;
esac

print -- "Building isolated validation candidate"
print -- "  configuration: ${configuration}"
print -- "  bundle id:     ${candidate_bundle_id}"
print -- "  display name:  ${candidate_display_name}"
print -- "  derived data:  ${derived_data}"

/usr/bin/xcodebuild \
    -project "${project_path}" \
    -scheme "${scheme}" \
    -configuration "${configuration}" \
    -destination "platform=macOS" \
    -derivedDataPath "${derived_data}" \
    "PRODUCT_BUNDLE_IDENTIFIER=${candidate_bundle_id}" \
    "INFOPLIST_KEY_CFBundleDisplayName=${candidate_display_name}" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    build

source_app="${derived_data}/Build/Products/${configuration}/Apple Notes Exporter.app"
source_info="${source_app}/Contents/Info.plist"

if [[ ! -d "${source_app}" || ! -f "${source_info}" ]]; then
    fail "built app not found at ${source_app}"
fi

build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${source_info}")
destination="${output_root}/${candidate_display_name} build ${build_number}.app"

if [[ "${destination:h}" != "${output_root}" ]]; then
    fail "candidate destination escaped its output root"
fi

/bin/mkdir -p "${output_root}"
/bin/rm -rf -- "${destination}"
/usr/bin/ditto "${source_app}" "${destination}"

info_plist="${destination}/Contents/Info.plist"
actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}")
actual_display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${info_plist}")
actual_signing_id=$(/usr/bin/codesign -dvv "${destination}" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')

[[ "${actual_bundle_id}" == "${candidate_bundle_id}" ]] ||
    fail "bundle id mismatch: ${actual_bundle_id}"
[[ "${actual_display_name}" == "${candidate_display_name}" ]] ||
    fail "display name mismatch: ${actual_display_name}"
[[ "${actual_signing_id}" == "${candidate_bundle_id}" ]] ||
    fail "code-signing identifier mismatch: ${actual_signing_id}"

/usr/bin/codesign --verify --deep --strict --verbose=2 "${destination}"

print
print -- "Candidate ready:"
print -- "  ${destination}"
print
print -- "This app has a separate identity from the installed production app."
print -- "Grant Full Disk Access only to this candidate when testing it."
print -- "Keep all candidate exports in an isolated output directory."
print -- "Launch one-shot CLI checks with open -W -n ... --args; never use launchctl submit."
