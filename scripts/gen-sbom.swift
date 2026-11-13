// SPDX-License-Identifier: Apache-2.0
//
// Generates the SPDX 2.3 JSON SBOM of a Nido release.
//
// Usage (from the repository root; inputs are resolved against the current directory):
//   swift scripts/gen-sbom.swift --version <x.y.z> --out <file>
//
// Inputs: Package.resolved, the app's Package.resolved (Sparkle),
// Resources/gvproxy/release.json and guest/linux/ollama/release.json (the file the Guest Tools
// ship; OllamaArchive.swift reads it from the generated payload). Exits 1 on any missing input.

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gen-sbom: \(message)\n".utf8))
    exit(1)
}

var version: String?
var outPath: String?
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--version": version = args.popFirst()
    case "--out": outPath = args.popFirst()
    default: fail("unknown argument \(arg)")
    }
}
guard let version, !version.isEmpty, let outPath, !outPath.isEmpty else {
    fail("usage: swift scripts/gen-sbom.swift --version <x.y.z> --out <file>")
}
guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else {
    fail("invalid version \(version)")
}

func loadJSON(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("missing input \(path) (run from the repository root)")
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("invalid JSON in \(path)")
    }
    return object
}

struct Pin { let version: String; let revision: String; let location: String }

func pin(_ identity: String, in path: String) -> Pin {
    let root = loadJSON(path)
    guard let pins = root["pins"] as? [[String: Any]] else { fail("\(path): no pins") }
    guard let entry = pins.first(where: { ($0["identity"] as? String) == identity }),
        let state = entry["state"] as? [String: Any],
        let v = state["version"] as? String, let r = state["revision"] as? String,
        let l = entry["location"] as? String
    else { fail("\(path): no pin for \(identity)") }
    return Pin(version: v, revision: r, location: l)
}

func string(_ object: [String: Any], _ key: String, _ path: String) -> String {
    guard let value = object[key] as? String, !value.isEmpty else { fail("\(path): missing \(key)") }
    return value
}

let parser = pin("swift-argument-parser", in: "Package.resolved")
let sparkle = pin("sparkle", in: "App/Nido.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")

let gvPath = "Resources/gvproxy/release.json"
let gv = loadJSON(gvPath)
let ollamaPath = "guest/linux/ollama/release.json"
let ollama = loadJSON(ollamaPath)

func package(
    id: String, name: String, version: String, download: String, license: String,
    sha256: String? = nil, comment: String? = nil
) -> [String: Any] {
    var p: [String: Any] = [
        "SPDXID": id, "name": name, "versionInfo": version,
        "downloadLocation": download, "filesAnalyzed": false,
        "licenseConcluded": license, "licenseDeclared": license,
        "copyrightText": "NOASSERTION",
    ]
    if let sha256 { p["checksums"] = [["algorithm": "SHA256", "checksumValue": sha256]] }
    if let comment { p["comment"] = comment }
    return p
}

let gvSha = string(gv, "sha256", gvPath)
let ollamaSha = string(ollama, "sha256", ollamaPath)
let ollamaVersion = string(ollama, "version", ollamaPath)

var nido = package(
    id: "SPDXRef-Nido", name: "Nido", version: version,
    download: "NOASSERTION", license: "Apache-2.0")
nido["supplier"] = "Person: Mattia Pichierri"

let packages: [[String: Any]] = [
    nido,
    package(
        id: "SPDXRef-swift-argument-parser", name: "swift-argument-parser", version: parser.version,
        download: "git+\(parser.location)@\(parser.version)", license: "Apache-2.0",
        comment: "Revision \(parser.revision)"),
    package(
        id: "SPDXRef-Sparkle", name: "Sparkle", version: sparkle.version,
        download: "git+\(sparkle.location)@\(sparkle.version)", license: "MIT",
        comment: "Revision \(sparkle.revision)"),
    package(
        id: "SPDXRef-gvproxy", name: "gvproxy", version: string(gv, "version", gvPath),
        download: string(gv, "url", gvPath), license: "Apache-2.0", sha256: gvSha,
        comment: "Universal binary (arm64 + x86_64) from \(string(gv, "project", gvPath))"),
    package(
        id: "SPDXRef-ollama", name: "ollama", version: ollamaVersion,
        download: string(ollama, "url", ollamaPath), license: "MIT", sha256: ollamaSha,
        comment: "Downloaded into the VM at runtime, not included in the DMG. Archive \(string(ollama, "file", ollamaPath))"),
]

let relationships: [[String: Any]] = [
    ["spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Nido"],
    ["spdxElementId": "SPDXRef-Nido", "relationshipType": "CONTAINS", "relatedSpdxElement": "SPDXRef-swift-argument-parser"],
    ["spdxElementId": "SPDXRef-Nido", "relationshipType": "CONTAINS", "relatedSpdxElement": "SPDXRef-Sparkle"],
    ["spdxElementId": "SPDXRef-Nido", "relationshipType": "CONTAINS", "relatedSpdxElement": "SPDXRef-gvproxy"],
    ["spdxElementId": "SPDXRef-Nido", "relationshipType": "OTHER", "relatedSpdxElement": "SPDXRef-ollama",
        "comment": "Downloaded into the VM, not included in the DMG"],
]

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime]
formatter.timeZone = TimeZone(identifier: "UTC")

let document: [String: Any] = [
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": "Nido \(version)",
    "documentNamespace": "https://spdx.org/spdxdocs/nido-\(version)",
    "creationInfo": ["created": formatter.string(from: Date()), "creators": ["Tool: gen-sbom.swift"]],
    "packages": packages,
    "relationships": relationships,
]

do {
    let data = try JSONSerialization.data(
        withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
} catch {
    fail("cannot write \(outPath): \(error.localizedDescription)")
}
