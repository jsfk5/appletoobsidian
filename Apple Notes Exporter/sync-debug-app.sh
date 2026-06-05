#!/bin/zsh
set -euo pipefail

project_name="Apple_Notes_Exporter"
derived_data_root="${HOME}/Library/Developer/Xcode/DerivedData"

find_latest_app() {
    local app_paths=()
    while IFS= read -r path; do
        app_paths+=("${path}")
    done < <(/usr/bin/find "${derived_data_root}" \
        -type d \
        -path "*${project_name}-*/Build/Products/Debug/Apple Notes Exporter.app" \
        ! -path "*/Index.noindex/*" \
        -print 2>/dev/null)

    if [[ ${#app_paths[@]} -eq 0 ]]; then
        while IFS= read -r path; do
            app_paths+=("${path}")
        done < <(/usr/bin/find "${derived_data_root}" \
            -type d \
            -path "*${project_name}-*/Build/Products/Debug/Apple Notes Exporter.app" \
            -print 2>/dev/null)
    fi

    if [[ ${#app_paths[@]} -eq 0 ]]; then
        return 1
    fi

    local newest_app=""
    local newest_mtime=0
    local app_path
    local executable_path
    local mtime

    for app_path in "${app_paths[@]}"; do
        executable_path="${app_path}/Contents/MacOS/Apple Notes Exporter"
        if [[ -f "${executable_path}" ]]; then
            mtime=$(/usr/bin/stat -f '%m' "${executable_path}")
        else
            mtime=$(/usr/bin/stat -f '%m' "${app_path}")
        fi

        if (( mtime > newest_mtime )); then
            newest_mtime=${mtime}
            newest_app="${app_path}"
        fi
    done

    if [[ -n "${newest_app}" ]]; then
        printf '%s\n' "${newest_app}"
        return 0
    fi

    return 1
}

latest_app="$(find_latest_app || true)"

if [[ -z "${latest_app}" ]]; then
    echo "No built debug app found in DerivedData. Build the project in Xcode first."
    exit 1
fi

destination="${PWD}/Products/Apple Notes Exporter.app"
/bin/mkdir -p "${PWD}/Products"
destination_executable="${destination}/Contents/MacOS/Apple Notes Exporter"
source_executable="${latest_app}/Contents/MacOS/Apple Notes Exporter"

/bin/rm -rf "${destination}"
/usr/bin/ditto "${latest_app}" "${destination}"

# Make the copied app reflect the source executable timestamp exactly.
# Finder often shows the bundle directory timestamp instead of the inner binary timestamp.
/usr/bin/touch -r "${source_executable}" "${destination_executable}"
/usr/bin/touch -r "${source_executable}" "${destination}"

echo "Copied:"
echo "  ${latest_app}"
echo "to:"
echo "  ${destination}"
echo
echo "Source executable timestamp:"
/usr/bin/stat -f '  %Sm %N' "${source_executable}"
echo "Destination executable timestamp:"
/usr/bin/stat -f '  %Sm %N' "${destination_executable}"
echo "Destination app bundle timestamp:"
/usr/bin/stat -f '  %Sm %N' "${destination}"
