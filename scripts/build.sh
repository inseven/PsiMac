#!/bin/bash

# PsiMac -- Psion connectivity for macOS
#
# Copyright (C) 2024 Jason Morley
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

set -e
set -o pipefail
set -x
set -u

SCRIPTS_DIRECTORY="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

ROOT_DIRECTORY="${SCRIPTS_DIRECTORY}/.."
BUILD_DIRECTORY="${ROOT_DIRECTORY}/build"
TEMPORARY_DIRECTORY="${ROOT_DIRECTORY}/temp"

KEYCHAIN_PATH="${TEMPORARY_DIRECTORY}/temporary.keychain"
ARCHIVE_PATH="${BUILD_DIRECTORY}/PsiMac.xcarchive"
ENV_PATH="${ROOT_DIRECTORY}/.env"

RELEASE_SCRIPT_PATH="${SCRIPTS_DIRECTORY}/release.sh"

IOS_XCODE_PATH=${IOS_XCODE_PATH:-/Applications/Xcode.app}
MACOS_XCODE_PATH=${MACOS_XCODE_PATH:-/Applications/Xcode.app}

source "${SCRIPTS_DIRECTORY}/environment.sh"

# Check that the GitHub command is available on the path.
which gh || (echo "GitHub cli (gh) not available on the path." && exit 1)

# Process the command line arguments.
POSITIONAL=()
RELEASE=${RELEASE:-false}
while [[ $# -gt 0 ]]
do
    key="$1"
    case $key in
        -r|--release)
        RELEASE=true
        shift
        ;;
        *)
        POSITIONAL+=("$1")
        shift
        ;;
    esac
done

# Generate a random string to secure the local keychain.
export TEMPORARY_KEYCHAIN_PASSWORD=`openssl rand -base64 14`

# Source the .env file if it exists to make local development easier.
if [ -f "$ENV_PATH" ] ; then
    echo "Sourcing .env..."
    source "$ENV_PATH"
fi

# TODO: Remove this
function xcode_project {
    xcodebuild \
        -project PsiMac.xcodeproj "$@"
}

function build_scheme {
    # Disable code signing for the build server.
    xcode_project \
        -scheme "$1" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO "${@:2}"
}

cd "$ROOT_DIRECTORY"

# Select the correct Xcode.
sudo xcode-select --switch "$MACOS_XCODE_PATH"

# List the available schemes.
xcode_project -list

# Clean up the build directory.
if [ -d "$BUILD_DIRECTORY" ] ; then
    rm -r "$BUILD_DIRECTORY"
fi
mkdir -p "$BUILD_DIRECTORY"

# Create the a new keychain.
if [ -d "$TEMPORARY_DIRECTORY" ] ; then
    rm -rf "$TEMPORARY_DIRECTORY"
fi
mkdir -p "$TEMPORARY_DIRECTORY"
echo "$TEMPORARY_KEYCHAIN_PASSWORD" | build-tools create-keychain "$KEYCHAIN_PATH" --password

function cleanup {

    # Cleanup the temporary files, keychain and keys.
    cd "$ROOT_DIRECTORY"
    build-tools delete-keychain "$KEYCHAIN_PATH"
    rm -rf "$TEMPORARY_DIRECTORY"
    rm -rf ~/.appstoreconnect/private_keys
}

trap cleanup EXIT

# Determine the version and build number.
VERSION_NUMBER=`changes version`
BUILD_NUMBER=`build-number.swift`

# Import the certificates into our dedicated keychain.
echo "$APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD" | build-tools import-base64-certificate --password "$KEYCHAIN_PATH" "$APPLE_DISTRIBUTION_CERTIFICATE_BASE64"
echo "$MACOS_DEVELOPER_INSTALLER_CERTIFICATE_PASSWORD" | build-tools import-base64-certificate --password "$KEYCHAIN_PATH" "$MACOS_DEVELOPER_INSTALLER_CERTIFICATE_BASE64"

# Install the provisioning profiles.
build-tools install-provisioning-profile "PsiMac_Mac_App_Store_Profile.provisionprofile"

# Build and archive the macOS project.
sudo xcode-select --switch "$MACOS_XCODE_PATH"
xcode_project \
    -scheme "PsiMac" \
    -config Release \
    -archivePath "$ARCHIVE_PATH" \
    OTHER_CODE_SIGN_FLAGS="--keychain=\"${KEYCHAIN_PATH}\"" \
    CURRENT_PROJECT_VERSION=$BUILD_NUMBER \
    MARKETING_VERSION=$VERSION_NUMBER \
    clean archive
xcodebuild \
    -archivePath "$ARCHIVE_PATH" \
    -exportArchive \
    -exportPath "$BUILD_DIRECTORY" \
    -exportOptionsPlist "ExportOptions.plist"

APP_BASENAME="PsiMac.app"
APP_PATH="$BUILD_DIRECTORY/$APP_BASENAME"
PKG_PATH="$BUILD_DIRECTORY/PsiMac.pkg"

# Install the private key.
mkdir -p ~/.appstoreconnect/private_keys/
echo -n "$APPLE_API_KEY_BASE64" | base64 --decode -o ~/".appstoreconnect/private_keys/AuthKey_${APPLE_API_KEY_ID}.p8"

# Archive the build directory.
ZIP_BASENAME="build-${VERSION_NUMBER}-${BUILD_NUMBER}.zip"
ZIP_PATH="${BUILD_DIRECTORY}/${ZIP_BASENAME}"
pushd "${BUILD_DIRECTORY}"
zip -r "${ZIP_BASENAME}" .
popd

if $RELEASE ; then

    changes \
        release \
        --skip-if-empty \
        --pre-release \
        --push \
        --exec "${RELEASE_SCRIPT_PATH}" \
        "${PKG_PATH}" "${ZIP_PATH}"

fi