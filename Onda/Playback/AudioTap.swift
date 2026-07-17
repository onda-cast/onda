//  AudioTap.swift
import AVFoundation
import Accelerate
import os

let tapLog = Logger(subsystem: "com.chasegilliam.Onda", category: "audiotap")

final class AudioTap {
    // Boxed state the C callbacks read/write via the tap's clientInfo.
    // @unchecked Sendable: gain is a plain Float written from main, read from the
    // real-time audio thread — tearing a Float write is acceptable for a gain knob.
    final class Storage: @unchecked Sendable {
        var gain: Float = 1.0
        var onRMS: (@Sendable (Float, Double) -> Void)?
        var sampleRate: Double = 44_100
        var isFloat: Bool = true
        var lastRMSLog: Double = 0     // throttled diagnostics
    }
    let storage = Storage()
    private(set) var audioMix: AVAudioMix?

    var gain: Float {
        get { storage.gain }
        set { storage.gain = newValue }
    }
    var onRMS: (@Sendable (Float, Double) -> Void)? {
        get { storage.onRMS }
        set { storage.onRMS = newValue }
    }

    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(storage).toOpaque()),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare,
            unprepare: nil, process: tapProcess)

        var tap: MTAudioProcessingTap?
        MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                   kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        audioMix = mix
        return mix
    }
}

private func tapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                     _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    let raw = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioTap.Storage>.fromOpaque(raw).release()
}

private func tapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                        _ format: UnsafePointer<AudioStreamBasicDescription>) {
    let raw = MTAudioProcessingTapGetStorage(tap)
    let storage = Unmanaged<AudioTap.Storage>.fromOpaque(raw).takeUnretainedValue()
    let f = format.pointee
    storage.sampleRate = f.mSampleRate
    storage.isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    tapLog.notice("tap prepared: sampleRate=\(f.mSampleRate) float=\(storage.isFloat) bits=\(f.mBitsPerChannel) channels=\(f.mChannelsPerFrame) flags=\(f.mFormatFlags)")
}

private func tapProcess(_ tap: MTAudioProcessingTap, _ numberFrames: CMItemCount,
                        _ flags: MTAudioProcessingTapFlags,
                        _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                    flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let raw = MTAudioProcessingTapGetStorage(tap)
    let storage = Unmanaged<AudioTap.Storage>.fromOpaque(raw).takeUnretainedValue()
    let gain = storage.gain

    guard storage.isFloat else {
        // Non-float pipeline: our vDSP math would read garbage. Log once per second so
        // device diagnostics reveal it, and pass audio through untouched.
        let now = CFAbsoluteTimeGetCurrent()
        if now - storage.lastRMSLog > 1 { storage.lastRMSLog = now; tapLog.fault("tap: non-float format, DSP bypassed") }
        return
    }

    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    var sumRMS: Float = 0; var bufCount = 0
    for buffer in abl {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let ptr = data.assumingMemoryBound(to: Float.self)
        if gain != 1.0 { vDSP_vsmul(ptr, 1, [gain], ptr, 1, vDSP_Length(count)) }
        var rms: Float = 0; vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(count))
        sumRMS += rms; bufCount += 1
    }
    let avgRMS = bufCount > 0 ? sumRMS / Float(bufCount) : 0
    let seconds = Double(numberFrames) / storage.sampleRate
    let now = CFAbsoluteTimeGetCurrent()
    if now - storage.lastRMSLog > 1 {
        storage.lastRMSLog = now
        tapLog.notice("tap rms=\(avgRMS, format: .fixed(precision: 5)) gain=\(gain)")
    }
    if let cb = storage.onRMS {
        DispatchQueue.main.async { cb(avgRMS, seconds) }
    }
}
