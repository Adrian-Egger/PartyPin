#!/bin/bash
# Patcht FlutterFramework/Package.swift zu einem Binary Target mit relativem Pfad.
# Xcode 26+ erfordert relative Pfade in SPM binary targets (keine absoluten Pfade).
# Muss nach jedem "flutter pub get" oder "flutter build ios" ausgefuehrt werden.

PACKAGE_DIR="/Users/atschi/Documents/PartyPin/ios/Flutter/ephemeral/Packages/.packages/FlutterFramework"
PACKAGE_SWIFT="$PACKAGE_DIR/Package.swift"
XCFRAMEWORK="/Users/atschi/flutter/bin/cache/artifacts/engine/ios-release/Flutter.xcframework"
SYMLINK="$PACKAGE_DIR/Flutter.xcframework"

if [ ! -d "$XCFRAMEWORK" ]; then
  echo "Fehler: Flutter.xcframework nicht gefunden unter $XCFRAMEWORK"
  exit 1
fi

# Symlink erstellen (Xcode 26 erlaubt keine absoluten Pfade in binary targets)
ln -sf "$XCFRAMEWORK" "$SYMLINK"
echo "Symlink erstellt: $SYMLINK -> $XCFRAMEWORK"

cat > "$PACKAGE_SWIFT" << 'SWIFT'
// swift-tools-version: 5.9
// Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "FlutterFramework",
    products: [
        .library(name: "FlutterFramework", targets: ["Flutter"])
    ],
    targets: [
        .binaryTarget(
            name: "Flutter",
            path: "Flutter.xcframework"
        )
    ]
)
SWIFT

echo "FlutterFramework Package.swift gepatcht (Binary Target, relativer Pfad fuer Xcode 26+)."
echo "Naechste Schritte: xcodebuild archive ODER Xcode: File -> Packages -> Reset Package Caches, dann Archive."
