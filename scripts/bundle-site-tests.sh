#!/bin/sh
set -eu
# Private snapshots belong only to the XCTest bundle, never to the application.
source_dir="${SRCROOT}/../config/site-tests"
output_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/LocalSiteTests"
rm -rf "$output_dir"
mkdir -p "$output_dir"
if [ -d "$source_dir" ]; then
    cp -R "$source_dir/." "$output_dir/"
fi
