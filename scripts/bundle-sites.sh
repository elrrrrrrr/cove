#!/bin/sh
set -eu
source_dir="${SRCROOT}/../sites"
output_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Sites"
mkdir -p "$output_dir"
find "$output_dir" -maxdepth 1 -type f -name '*.site' -delete
if [ -d "$source_dir" ]; then
    find "$source_dir" -maxdepth 1 -type f -name '*.site' -exec cp '{}' "$output_dir/" ';'
fi
touch "$output_dir/.staged"
data_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BundledData"
mkdir -p "$data_dir"
rm -f "$data_dir/favorites.json"
if [ -f "${SRCROOT}/../data/favorites.json" ]; then
    cp "${SRCROOT}/../data/favorites.json" "$data_dir/favorites.json"
fi
