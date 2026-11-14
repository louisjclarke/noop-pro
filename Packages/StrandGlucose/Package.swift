// swift-tools-version:5.9
import PackageDescription

// NOOP Pro — continuous-glucose layer. Pure value types and math: no CoreBluetooth, no UIKit, no
// database. The iOS app target owns the radio, the network and the storage; everything that can be
// unit-tested without a sensor lives here.
let package = Package(
    name: "StrandGlucose",
    platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v10)],
    products: [.library(name: "StrandGlucose", targets: ["StrandGlucose"])],
    targets: [
        .target(name: "StrandGlucose"),
        .testTarget(name: "StrandGlucoseTests", dependencies: ["StrandGlucose"]),
    ]
)
