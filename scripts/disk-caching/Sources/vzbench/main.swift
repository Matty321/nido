// SPDX-License-Identifier: Apache-2.0
// Measurement harness for docs/DISK-CACHING.md (not shipped). Boots an existing Nido bundle with
// the configuration Nido builds (LinuxConfigurationBuilder), optionally replacing the boot disk
// attachment with `.cached` caching and `.fsync` or `.full` synchronization.
//   vzbench <bundle.nidovm> default|cached-fsync|cached-full
// SIGUSR1: hard stop (VZVirtualMachine.stop, no guest shutdown). SIGTERM/SIGINT: guest shutdown.
import Foundation
import NidoCore
import Virtualization

let args = CommandLine.arguments
guard args.count == 3, ["default", "cached-fsync", "cached-full"].contains(args[2]) else {
    FileHandle.standardError.write(Data("usage: vzbench <bundle> default|cached-fsync|cached-full\n".utf8))
    exit(2)
}
let bundle = VMBundle(url: URL(fileURLWithPath: args[1], isDirectory: true))
let lock = try BundleLock.acquire(bundle, owner: .cli)
let config = try bundle.readConfig()
if !FileManager.default.fileExists(atPath: bundle.consoleLogURL.path) {
    FileManager.default.createFile(atPath: bundle.consoleLogURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
}
let console = try FileHandle(forWritingTo: bundle.consoleLogURL)
try console.seekToEnd()
let built = try LinuxConfigurationBuilder.make(bundle: bundle, config: config, console: console)
let configuration = built.configuration
if args[2] != "default" {
    let disk = try VZDiskImageStorageDeviceAttachment(
        url: bundle.diskURL, readOnly: false, cachingMode: .cached,
        synchronizationMode: args[2] == "cached-fsync" ? .fsync : .full)
    var devices = configuration.storageDevices
    devices[0] = VZVirtioBlockDeviceConfiguration(attachment: disk)
    configuration.storageDevices = devices
}
let boot = (configuration.storageDevices[0] as! VZVirtioBlockDeviceConfiguration).attachment as! VZDiskImageStorageDeviceAttachment
print("vzbench: disk cachingMode=\(boot.cachingMode.rawValue) synchronizationMode=\(boot.synchronizationMode.rawValue)")
try configuration.validate()

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { print("vzbench: guest stopped"); exit(0) }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("vzbench: error \(error)"); exit(1)
    }
}
let delegate = Delegate()
let vm = VZVirtualMachine(configuration: configuration)
vm.delegate = delegate
var sources: [DispatchSourceSignal] = []
for (sig, hard) in [(SIGUSR1, true), (SIGTERM, false), (SIGINT, false)] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        if hard {
            vm.stop { error in print("vzbench: hard stop \(error.map { "\($0)" } ?? "ok")"); lock.release(); exit(0) }
        } else {
            try? vm.requestStop()
        }
    }
    source.resume()
    sources.append(source)
}
vm.start { result in
    switch result {
    case .success: print("vzbench: started pid \(getpid())")
    case .failure(let error): print("vzbench: start failed \(error)"); exit(1)
    }
}
dispatchMain()
