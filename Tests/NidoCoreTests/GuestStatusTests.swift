// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import NidoCore

/// What the user's own `monitor.py` prints (json.dumps with indent=2), as sent by their API.
let userAPIFixture = """
{
  "agent": "Nido AI Monitor",
  "version": "2.0",
  "timestamp": "2026-10-24T16:00:00.123456+00:00",
  "system": {
    "hostname": "debian-ai",
    "architecture": "aarch64",
    "kernel": "6.12.38+deb13-arm64",
    "uptime_seconds": 4321
  },
  "cpu": {"vcpus": 4, "usage_percent": 91.5, "load_1min": 3.2, "status": "WARNING"},
  "memory": {
    "total_gib": 3.86, "used_gib": 0.52, "available_gib": 3.34, "usage_percent": 13.5,
    "swap_total_gib": 0.0, "swap_used_gib": 0.0, "status": "OK"
  },
  "disk": {
    "total_gib": 9.54, "used_gib": 1.53, "available_gib": 7.63, "usage_percent": 16.7, "status": "OK"
  },
  "alerts": ["Utilizzo CPU elevato"],
  "status": "WARNING"
}
"""

/// `status_document` of Guest Tools 1.0.0 (guest/linux/nido_guest_tools/metrics.py), with
/// provisioning and a null swap percentage.
let guestTools100Fixture = """
{"agent":"Nido AI Monitor","version":"2.0","timestamp":"2026-10-24T16:00:00+00:00","hostname":"vm1","system":{"hostname":"vm1","architecture":"aarch64","kernel":"6.12.38+deb13-arm64","uptime_seconds":321},"cpu":{"vcpus":4,"usage_percent":12.3,"load_1min":0.31,"load_5min":0.2,"load_15min":0.1,"status":"OK"},"memory":{"total_gib":3.86,"used_gib":0.52,"available_gib":3.34,"usage_percent":13.5,"swap_total_gib":0.0,"swap_used_gib":0.0,"swap_usage_percent":null,"status":"OK"},"disk":{"total_gib":9.54,"used_gib":1.53,"available_gib":7.63,"usage_percent":16.7,"status":"OK"},"alerts":[],"status":"OK","provisioning":{"step":"packages","state":"running","message":"Installazione pacchetti"}}
"""

@Suite struct GuestStatusTests {
    private func decode(_ json: String) throws -> GuestStatus {
        try GuestStatus.decode(Data(json.utf8))
    }

    @Test func decodesUserAPIFixture() throws {
        let s = try decode(userAPIFixture)
        #expect(s.agent == "Nido AI Monitor")
        #expect(s.version == "2.0")
        #expect(s.isSupportedVersion)
        #expect(s.timestamp != nil)
        #expect(s.hostname == "debian-ai")
        #expect(s.system?.architecture == "aarch64")
        #expect(s.system?.kernel == "6.12.38+deb13-arm64")
        #expect(s.system?.uptimeSeconds == 4321)
        #expect(s.cpu?.vcpus == 4)
        #expect(s.cpu?.usagePercent == 91.5)
        #expect(s.cpu?.load1Min == 3.2)
        #expect(s.cpu?.load5Min == nil)
        #expect(s.memory?.totalGiB == 3.86)
        #expect(s.memory?.swapUsagePercent == nil)
        #expect(s.disk?.availableGiB == 7.63)
        #expect(s.alerts == ["Utilizzo CPU elevato"])
        #expect(s.status == .warning)
        #expect(s.provisioning == nil)
    }

    @Test func decodesGuestTools100Fixture() throws {
        let s = try decode(guestTools100Fixture)
        #expect(s.isSupportedVersion)
        #expect(s.hostname == "vm1")
        #expect(s.cpu?.load5Min == 0.2)
        #expect(s.cpu?.load15Min == 0.1)
        #expect(s.memory?.swapUsagePercent == nil)
        #expect(s.memory?.usagePercent == 13.5)
        #expect(s.alerts.isEmpty)
        #expect(s.status == .ok)
        #expect(s.provisioning?.step == "packages")
        #expect(s.provisioning?.state == "running")
        #expect(s.provisioning?.message == "Installazione pacchetti")
        #expect(s.provisioning?.error == nil)
        #expect(s.timestamp == Date(timeIntervalSince1970: 1_792_857_600))
    }

    @Test func missingFieldsDecodePartially() throws {
        let s = try decode(#"{"agent":"Nido AI Monitor","version":"2.0","cpu":{"usage_percent":5},"memory":"broken","disk":{"status":7}}"#)
        #expect(s.cpu?.usagePercent == 5)
        #expect(s.cpu?.vcpus == nil)
        #expect(s.memory == nil)
        #expect(s.disk != nil)
        #expect(s.disk?.usagePercent == nil)
        #expect(s.hostname == nil)
        #expect(s.alerts.isEmpty)
        #expect(s.status == .unknown(""))
    }

    @Test func numericStringsAccepted() throws {
        let s = try decode(#"{"version":"2.0","system":{"uptime_seconds":"90"},"cpu":{"vcpus":"2","usage_percent":"12.5"},"memory":{"total_gib":"4.0","swap_usage_percent":"3"}}"#)
        #expect(s.system?.uptimeSeconds == 90)
        #expect(s.cpu?.vcpus == 2)
        #expect(s.cpu?.usagePercent == 12.5)
        #expect(s.memory?.totalGiB == 4.0)
        #expect(s.memory?.swapUsagePercent == 3)
    }

    @Test func futureMajorVersionFlagged() throws {
        for version in ["3.0", "1.9", "10", "", "x"] {
            let s = try decode(#"{"agent":"Nido AI Monitor","version":"\#(version)","cpu":{"usage_percent":1}}"#)
            #expect(!s.isSupportedVersion, "version \(version)")
            #expect(s.cpu?.usagePercent == 1)
        }
        for version in ["2", "2.0", "2.7.1"] {
            let s = try decode(#"{"version":"\#(version)","cpu":{}}"#)
            #expect(s.isSupportedVersion, "version \(version)")
        }
        #expect(try !decode(#"{"agent":"x"}"#).isSupportedVersion)
    }

    /// The Guest Tools embed `state.json` of `nido-provision` as it is: `{"version": 1, "steps":
    /// {name: {state, message, updated, model?, progress?}}}`. The steps are read like
    /// `AIRuntime.status()` reads them, so the app can follow phase 2 over vsock.
    @Test func provisioningStepsOfGuestTools() throws {
        let s = try decode(#"""
            {"version":"2.0","provisioning":{"version":1,"steps":{
            "ollama-install":{"state":"done","message":"Ollama 0.12.6 installato","updated":"2026-10-24T16:00:00+00:00"},
            "model-pull":{"state":"failed","message":"interrotto: usa Riprova","model":"qwen3:0.6b",
              "progress":{"completed":"100","total":522653277},"updated":"2026-10-24T16:05:00+00:00"},
            "odd":{"state":"exploded"},"broken":7}}}
            """#)
        let steps = try #require(s.provisioning?.steps)
        #expect(steps.count == 3)
        #expect(steps["ollama-install"]?.state == .done)
        let pull = try #require(steps["model-pull"])
        #expect(pull.state == .failed)
        #expect(pull.model == "qwen3:0.6b")
        #expect(pull.completedBytes == 100)
        #expect(pull.totalBytes == 522_653_277)
        #expect(pull.updated == "2026-10-24T16:05:00+00:00")
        #expect(steps["odd"]?.state == .unknown)
        // The flat fields of the original API still decode (no steps there).
        #expect(try decode(guestTools100Fixture).provisioning?.steps.isEmpty == true)
    }

    @Test func unknownStatusKept() throws {
        #expect(try decode(#"{"version":"2.0","status":"CRITICAL"}"#).status == .unknown("CRITICAL"))
    }

    @Test func notAnObjectIsInvalid() {
        for json in ["[]", "42", "null", "{", "", #"{"unrelated":1}"#] {
            #expect(throws: MonitorError.invalidResponse, "\(json)") { _ = try GuestStatus.decode(Data(json.utf8)) }
        }
    }
}
