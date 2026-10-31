// chanlevel — per-channel level meter for a multichannel CoreAudio input.
//
//   swiftc -O tools/chanlevel.swift -o chanlevel
//   ./chanlevel [device-name-substring] [seconds]     (defaults: "LatSOF", 10)
//
// Prints RMS / peak (dBFS) for every channel once per second, then a summary
// with the correlation between all channel pairs. Silent channel = no signal
// reaching it; correlation ~1.0 between two channels = duplicated data.
import AVFoundation
import CoreAudio

let wanted = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "LatSOF"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 10 : 10

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
          let n = name else { return "" }
    return n.takeRetainedValue() as String
}

func inputChannels(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioDevicePropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func findDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids where inputChannels(id) > 0 {
        let n = deviceName(id)
        print("input device: \(n) (\(inputChannels(id)) ch)")
        if n.localizedCaseInsensitiveContains(wanted) { return id }
    }
    return nil
}

guard var dev = findDevice() else {
    print("no input device matching \"\(wanted)\""); exit(1)
}

let engine = AVAudioEngine()
let input = engine.inputNode
if let au = input.audioUnit {
    let st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0, &dev,
                                  UInt32(MemoryLayout<AudioDeviceID>.size))
    if st != noErr { print("cannot select device (\(st))"); exit(1) }
}

let fmt = input.outputFormat(forBus: 0)
let nch = Int(fmt.channelCount)
print("capturing \(nch) ch @ \(Int(fmt.sampleRate)) Hz for \(Int(seconds)) s ...")

var sumSq = [Double](repeating: 0, count: nch)
var peak = [Double](repeating: 0, count: nch)
var cross = [Double](repeating: 0, count: nch * nch)   // running sum x_i * x_j
var frames = 0
var totSq = [Double](repeating: 0, count: nch)
var totFrames = 0
let lock = NSLock()

func db(_ v: Double) -> String { v <= 1e-9 ? " -inf" : String(format: "%5.1f", 20 * log10(v)) }

input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
    guard let d = buf.floatChannelData else { return }
    let n = Int(buf.frameLength)
    lock.lock(); defer { lock.unlock() }
    for c in 0..<nch {
        for i in 0..<n {
            let x = Double(d[c][i])
            sumSq[c] += x * x
            totSq[c] += x * x
            peak[c] = max(peak[c], abs(x))
        }
    }
    for a in 0..<nch { for b in a..<nch {
        var s = 0.0
        for i in 0..<n { s += Double(d[a][i]) * Double(d[b][i]) }
        cross[a * nch + b] += s
    } }
    frames += n
    totFrames += n
}

try engine.start()
for _ in 0..<Int(seconds) {
    Thread.sleep(forTimeInterval: 1)
    lock.lock()
    let f = max(frames, 1)
    let line = (0..<nch).map { "ch\($0) rms \(db((sumSq[$0] / Double(f)).squareRoot())) pk \(db(peak[$0]))" }
    sumSq = [Double](repeating: 0, count: nch); peak = [Double](repeating: 0, count: nch); frames = 0
    lock.unlock()
    print(line.joined(separator: " | "))
}
engine.stop()

lock.lock()
print("\ncorrelation (1.0 = identical, 0 = unrelated):")
for a in 0..<nch { for b in (a + 1)..<max(nch, a + 1) {
    let d = (totSq[a] * totSq[b]).squareRoot()
    let r = d > 0 ? cross[a * nch + b] / d : 0
    print(String(format: "  ch%d-ch%d  %+.3f", a, b, r))
} }
for c in 0..<nch where (totSq[c] / Double(max(totFrames, 1))).squareRoot() < 1e-5 {
    print("ch\(c): SILENT")
}
lock.unlock()
