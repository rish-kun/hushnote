@preconcurrency import AVFoundation
import Foundation
import os

/// Pre-allocated copy targets for the HAL's IOProc.
///
/// `AudioHardware.h` states IOBlocks are dispatched synchronously, so the HAL's
/// real-time thread is blocked until the block returns. The copy target used to
/// be allocated inside it, once per callback — an Objective-C object plus a
/// malloc of the sample memory, on the deadline. These are allocated once at
/// `start()` instead and handed out in turn.
///
/// Reuse is safe because the capture's semaphore admits at most `slotCount`
/// buffers at a time and the processing queue is serial: acquiring slot
/// *n + slotCount* cannot happen until slot *n* has been released.
final class CaptureBufferRing: @unchecked Sendable {
    let format: AVAudioFormat
    let capacityFrames: AVAudioFrameCount
    let slotCount: Int

    private let slots: [AVAudioPCMBuffer]
    private let nextSlot = OSAllocatedUnfairLock(initialState: 0)

    init?(format: AVAudioFormat, capacityFrames: AVAudioFrameCount, slotCount: Int) {
        guard capacityFrames > 0, slotCount > 0 else { return nil }
        var allocated: [AVAudioPCMBuffer] = []
        allocated.reserveCapacity(slotCount)
        for _ in 0..<slotCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacityFrames) else {
                return nil
            }
            allocated.append(buffer)
        }
        self.format = format
        self.capacityFrames = capacityFrames
        self.slotCount = slotCount
        slots = allocated
    }

    /// Copies one delivered buffer list into the next slot.
    ///
    /// Returns nil when the list no longer matches the format capture started
    /// with, which is a permanent condition the caller has to treat as a
    /// failure rather than a dropped buffer.
    func copy(
        from inputData: UnsafePointer<AudioBufferList>,
        frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard frames > 0 else { return nil }
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

        let owned: AVAudioPCMBuffer
        if frames <= capacityFrames {
            owned = slots[nextSlot.withLock { index -> Int in
                let current = index
                index = (index + 1) % slotCount
                return current
            }]
        } else {
            // A device whose buffer size grew past the slots. One allocation in
            // a rare case beats losing the audio.
            guard let oversized = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                return nil
            }
            owned = oversized
        }

        let destination = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let writableBytes = min(Int(frames), Int(owned.frameCapacity)) * bytesPerFrame
        for index in 0..<source.count {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData
            else { return nil }
            let byteCount = min(Int(source[index].mDataByteSize), writableBytes)
            guard byteCount > 0 else { return nil }
            memcpy(destinationData, sourceData, byteCount)
        }

        // Set last. `frameLength`'s setter rewrites every `mDataByteSize` in the
        // list, so assigning it first and the byte sizes second is the one order
        // that can leave the two disagreeing.
        owned.frameLength = frames
        return owned
    }
}
