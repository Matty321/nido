#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Generates the SBOM into $TMPDIR and checks its shape against the pinned inputs.
set -euo pipefail
cd "$(dirname "$0")/../.."

out="$(mktemp -d "${TMPDIR:-/tmp}/nido-sbom.XXXXXX")/sbom.spdx.json"
swift scripts/gen-sbom.swift --version 1.2.3 --out "$out"

python3 -c '
import json, sys
sbom = json.load(open(sys.argv[1]))
gv = json.load(open("Resources/gvproxy/release.json"))
ol = json.load(open("guest/linux/ollama/release.json"))
assert sbom["spdxVersion"] == "SPDX-2.3", sbom["spdxVersion"]
names = sorted(p["name"] for p in sbom["packages"])
assert names == ["Nido", "Sparkle", "gvproxy", "ollama", "ollama", "swift-argument-parser"], names
by = {p["name"]: p for p in sbom["packages"]}
by_id = {p["SPDXID"]: p for p in sbom["packages"]}
def sha(p): return [c["checksumValue"] for c in p["checksums"] if c["algorithm"] == "SHA256"][0]
assert sha(by["gvproxy"]) == gv["sha256"]
for id, machine in (("SPDXRef-ollama-arm64", "aarch64"), ("SPDXRef-ollama-amd64", "x86_64")):
    assert sha(by_id[id]) == ol["architectures"][machine]["sha256"], id
    assert "not included in the DMG" in by_id[id]["comment"], id
    assert ("OTHER", id) in {(r["relationshipType"], r["relatedSpdxElement"]) for r in sbom["relationships"]}, id
assert by["Nido"]["versionInfo"] == "1.2.3"
assert by["Sparkle"]["versionInfo"] == "2.10.1"
rels = {(r["relationshipType"], r["relatedSpdxElement"]) for r in sbom["relationships"]}
for n in ("Sparkle", "gvproxy", "swift-argument-parser"):
    assert ("CONTAINS", by[n]["SPDXID"]) in rels, n
print("ok: sbom", len(names), "packages")
' "$out"
