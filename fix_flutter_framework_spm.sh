#!/bin/bash
# Patcht FlutterFramework/Package.swift zu einem Binary Target.
# Muss nach jedem "flutter build ipa" ausgefuehrt werden, bevor
# Xcode GUI ein Archive startet — Flutter ueberschreibt die Datei
# bei jedem Build zurueck auf ein leeres Source Target.

PACKAGE_SWIFT="/Users/atschi/Documents/PartyPin/ios/Flutter/ephemeral/Packages/.packages/FlutterFramework/Package.swift"
XCFRAMEWORK="/Users/atschi/flutter/bin/cache/artifacts/engine/ios-release/Flutter.xcframework"

if [ ! -d "$XCFRAMEWORK" ]; then
  echo "Fehler: Flutter.xcframework nicht gefunden unter $XCFRAMEWORK"
  exit 1
fi

cat > "$PACKAGE_SWIFT" << SWIFT
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
            path: "$XCFRAMEWORK"
        )
    ]
)
SWIFT

echo "FlutterFramework Package.swift gepatcht (Binary Target)."
echo "Xcode: File -> Packages -> Reset Package Caches, dann Archive."
