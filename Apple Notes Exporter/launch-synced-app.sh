#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
app_path="${script_dir}/Products/Apple Notes Exporter.app"
app_executable="${app_path}/Contents/MacOS/Apple Notes Exporter"

"${script_dir}/sync-debug-app.sh"

if [[ ! -x "${app_executable}" ]]; then
    echo "Copied app executable not found:"
    echo "  ${app_executable}"
    exit 1
fi

echo
echo "Launching exact executable:"
echo "  ${app_executable}"

exec "${app_executable}"
