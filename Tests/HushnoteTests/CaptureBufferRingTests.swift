@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import Hushnote

/// `AudioHardware.h` states IOBlocks are dispatched synchronously, so the HAL's
/// real-time thread blocks until the block returns. Every allocation inside it
/// is a chance to miss the deadline and lose audio, which is why the copy
/// target is allocated once at start rather than per callback.
@Suite("Capture buffer ring")
struct CaptureBufferRingTests {
    @Test("A copy reproduces the delivered samples exactly")
    func copiesSamples() throws {
        let format = Self.format(channels: 1, interleaved: false)
        let ring = try #require(CaptureBufferRing(format: format, capacityFrames: 4_096, slotCount: 4))
        let source = Self.source(format: format, frames: 512) { Float($0) / 512 }

        let copy = try #require(ring.copy(from: source.audioBufferList, frames: 512))

        #expect(copy.frameLength == 512)
        for frame in 0..<512 {
            #expect(copy.floatChannelData![0][frame] == Float(frame) / 512)
        }
    }

    /// The whole point: no allocation per callback.
    @Test("Copies cycle through the pre-allocated slots")
    func reusesSlots() throws {
        let format = Self.format(channels: 1, interleaved: false)
        let ring = try #require(CaptureBufferRing(format: format, capacityFrames: 1_024, slotCount: 4))
        let source = Self.source(format: format, frames: 256) { _ in 0.5 }

        // The copies are held for the length of the test on purpose: a released
        // buffer's address is handed straight back out by the allocator, which
        // makes freshly allocated buffers look identical to reused ones.
        var copies: [AVAudioPCMBuffer] = []
        for _ in 0..<8 {
            copies.append(try #require(ring.copy(from: source.audioBufferList, frames: 256)))
        }
        let identities = copies.map(ObjectIdentifier.init)

        #expect(Set(identities).count == 4, "a ring of four slots must not allocate a fifth buffer")
        #expect(identities[0] == identities[4], "slots repeat in order")
    }

    /// `frameLength`'s setter rewrites `mDataByteSize`. Writing the byte size
    /// first and the frame length second is the only order that leaves the two
    /// agreeing when the slot is larger than the buffer delivered into it.
    @Test("Frame length and byte size agree after a partial-slot copy")
    func lengthAndByteSizeAgree() throws {
        let format = Self.format(channels: 1, interleaved: false)
        let ring = try #require(CaptureBufferRing(format: format, capacityFrames: 4_096, slotCount: 2))
        let source = Self.source(format: format, frames: 300) { _ in 0.25 }

        let copy = try #require(ring.copy(from: source.audioBufferList, frames: 300))

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let list = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        #expect(copy.frameLength == 300)
        #expect(Int(list[0].mDataByteSize) == 300 * bytesPerFrame)
    }

    @Test("A buffer list that no longer matches the format is refused")
    func refusesMismatchedLayout() throws {
        let stereo = Self.format(channels: 2, interleaved: false)
        let ring = try #require(CaptureBufferRing(format: stereo, capacityFrames: 1_024, slotCount: 2))
        // The device switched to mono: one buffer where two are expected.
        let mono = Self.source(format: Self.format(channels: 1, interleaved: false), frames: 256) { _ in 0.1 }

        #expect(ring.copy(from: mono.audioBufferList, frames: 256) == nil)
    }

    /// A device whose buffer size grows past the slot size must still be
    /// recorded in full. One allocation in a rare case beats losing audio.
    @Test("A buffer larger than a slot is still copied whole")
    func oversizedBufferStillCopies() throws {
        let format = Self.format(channels: 1, interleaved: false)
        let ring = try #require(CaptureBufferRing(format: format, capacityFrames: 256, slotCount: 2))
        let source = Self.source(format: format, frames: 1_000) { Float($0 % 7) / 7 }

        let copy = try #require(ring.copy(from: source.audioBufferList, frames: 1_000))

        #expect(copy.frameLength == 1_000)
        #expect(copy.floatChannelData![0][999] == Float(999 % 7) / 7)
    }

    @Test("Interleaved stereo is copied without reshaping it")
    func copiesInterleavedStereo() throws {
        let format = Self.format(channels: 2, interleaved: true)
        let ring = try #require(CaptureBufferRing(format: format, capacityFrames: 1_024, slotCount: 2))
        let source = Self.source(format: format, frames: 128) { Float($0 % 2 == 0 ? 0.5 : -0.5) }

        let copy = try #require(ring.copy(from: source.audioBufferList, frames: 128))

        #expect(copy.frameLength == 128)
        #expect(copy.floatChannelData![0][0] == 0.5)
        #expect(copy.floatChannelData![0][1] == -0.5)
    }

    private static func format(channels: AVAudioChannelCount, interleaved: Bool) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: channels,
            interleaved: interleaved
        )!
    }

    /// Stands in for the HAL's buffer list, which is the same shape.
    private static func source(
        format: AVAudioFormat,
        frames: Int,
        value: (Int) -> Float
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        if format.isInterleaved {
            let values = buffer.floatChannelData![0]
            for index in 0..<(frames * channels) {
                values[index] = value(index)
            }
        } else {
            for channel in 0..<channels {
                let values = buffer.floatChannelData![channel]
                for frame in 0..<frames {
                    values[frame] = value(frame)
                }
            }
        }
        return buffer
    }
}

@Suite("Frame counting")
struct CaptureFrameCountTests {
    /// Reading `frameLength` off a throwaway `AVAudioPCMBuffer` costs an
    /// allocation on the real-time thread for a number that is one division.
    @Test("Frames are derived from the byte size, not from a temporary buffer")
    func countsFramesArithmetically() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
        buffer.frameLength = 700

        #expect(SystemAudioTapCapture.frameCount(of: buffer.audioBufferList, format: format) == 700)
    }

    @Test("Deinterleaved layouts count frames per channel, not in total")
    func countsDeinterleavedFrames() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
        buffer.frameLength = 512

        #expect(SystemAudioTapCapture.frameCount(of: buffer.audioBufferList, format: format) == 512)
    }
}
