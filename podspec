{
  "name": "SwiftNIO",
  "version": "2.40.0",
  "license": {
    "type": "Apache 2.0",
    "file": "LICENSE.txt"
  },
  "summary": "Event-driven network application framework for high performance protocol servers & clients, non-blocking.",
  "homepage": "https://github.com/apple/swift-nio",
  "authors": "Apple Inc.",
  "source": {
    "git": "https://github.com/shapr3d/swift-nio.git",
    "commit": "b99a928"
  },
  "documentation_url": "https://apple.github.io/swift-nio/docs/current/NIOCore/index.html",
  "module_name": "NIO",
  "swift_versions": "5.4",
  "cocoapods_version": ">=1.6.0",
  "platforms": {
    "ios": "10.0",
    "osx": "10.10",
    "tvos": "10.0",
    "watchos": "6.0",
    "visionos": "1.0"
  },
  "source_files": "Sources/NIO/**/*.{swift,c,h}",
  "dependencies": {
    "CNIOWindows": [
      "2.40.0"
    ],
    "CNIOLinux": [
      "2.40.0"
    ],
    "SwiftNIOCore": [
      "2.40.0"
    ],
    "_NIODataStructures": [
      "2.40.0"
    ],
    "SwiftNIOPosix": [
      "2.40.0"
    ],
    "CNIOAtomics": [
      "2.40.0"
    ],
    "SwiftNIOEmbedded": [
      "2.40.0"
    ],
    "SwiftNIOConcurrencyHelpers": [
      "2.40.0"
    ],
    "CNIODarwin": [
      "2.40.0"
    ]
  },
  "swift_version": "5.4"
}
