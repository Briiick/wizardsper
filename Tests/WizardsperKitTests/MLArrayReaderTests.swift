import CoreML
import Foundation
import Testing

@testable import WizardsperKit

@Suite("MLArrayReader")
struct MLArrayReaderTests {

    /// Build an array whose innermost axis is padded, which is exactly what the
    /// Neural Engine hands back: `shape` says 4 but consecutive elements are 8
    /// apart. Reading `dataPointer` as dense would interleave the padding into
    /// the data.
    private func paddedArray() throws -> (array: MLMultiArray, expected: [Float]) {
        let shape = [1, 3, 4]
        let strides = [3 * 8, 8, 1]  // innermost axis padded from 4 to 8
        let backing = UnsafeMutablePointer<Float>.allocate(capacity: 3 * 8)
        backing.update(repeating: -999, count: 3 * 8)
        var expected: [Float] = []
        for channel in 0..<3 {
            for t in 0..<4 {
                let value = Float(channel * 10 + t)
                backing[channel * 8 + t] = value
                expected.append(value)
            }
        }
        let array = try MLMultiArray(
            dataPointer: backing,
            shape: shape.map(NSNumber.init),
            dataType: .float32,
            strides: strides.map(NSNumber.init),
            deallocator: { _ in backing.deallocate() })
        return (array, expected)
    }

    @Test("a padded array is gathered through its strides, not read as dense")
    func honoursStrides() throws {
        let (array, expected) = try paddedArray()
        #expect(MLArrayReader.strides(of: array) != MLArrayReader.denseStrides(for: [1, 3, 4]))
        #expect(try MLArrayReader.dense(array, named: "padded") == expected)
    }

    @Test("the dense fast path returns the same values as the gather")
    func denseMatchesGather() throws {
        let array = try MLArrayReader.float32(shape: [1, 3, 4])
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<buffer.count { buffer[i] = Float(i) }
        }
        #expect(try MLArrayReader.dense(array, named: "dense") == (0..<12).map(Float.init))
    }

    /// One encoder frame is pulled out per RNN-T step; getting the stride wrong
    /// here silently feeds the joint network a mixture of channels.
    @Test("timeStep pulls one lane out of a strided [1, C, T]")
    func extractsTimeStep() throws {
        let (array, _) = try paddedArray()
        var lane = [Float](repeating: 0, count: 3)
        try lane.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            try MLArrayReader.timeStep(array, named: "padded", time: 2, into: base)
        }
        #expect(lane == [2, 12, 22])
    }

    @Test("timeStep refuses an out-of-range index rather than reading past the end")
    func rejectsBadTimeIndex() throws {
        let (array, _) = try paddedArray()
        var lane = [Float](repeating: 0, count: 3)
        #expect(throws: WizardsperError.self) {
            try lane.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                try MLArrayReader.timeStep(array, named: "padded", time: 4, into: base)
            }
        }
    }

    @Test("argmax reports the logical index, not the byte offset")
    func argmaxIsLogical() throws {
        let logits = try MLArrayReader.float32(shape: [1, 1, 1, 8])
        logits.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<buffer.count { buffer[i] = Float(i) * -1 }
            buffer[5] = 42
        }
        let result = try MLArrayReader.argmax(logits, named: "logits")
        #expect(result.index == 5)
        #expect(result.value == 42)
    }

    @Test("argmax also works through padded strides")
    func argmaxHonoursStrides() throws {
        let (array, _) = try paddedArray()
        // Largest value is channel 2, t 3 -> logical index 11 of 12.
        #expect(try MLArrayReader.argmax(array, named: "padded").index == 11)
    }

    /// An all-zero encoder output is how a failed Neural Engine program shows
    /// up: no throw, no error, just silence. The probe has to catch it.
    @Test("isAllZero distinguishes a dead encoder from a live one")
    func detectsAllZero() throws {
        let zeros = try MLArrayReader.float32(shape: [1, 4])
        #expect(try MLArrayReader.isAllZero(zeros, named: "zeros"))
        zeros[2] = 0.0001
        #expect(!(try MLArrayReader.isAllZero(zeros, named: "zeros")))
    }

    @Test("shape checks treat -1 as a wildcard so a flexible axis still validates")
    func shapeWildcards() throws {
        let array = try MLArrayReader.float32(shape: [1, 1024, 7])
        #expect(throws: Never.self) {
            try MLArrayReader.requireShape(array, [1, 1024, -1], named: "encoded")
        }
        #expect(throws: WizardsperError.self) {
            try MLArrayReader.requireShape(array, [1, 512, -1], named: "encoded")
        }
        #expect(throws: WizardsperError.self) {
            try MLArrayReader.requireShape(array, [1, 1024], named: "encoded")
        }
    }

    @Test("float16 outputs are widened rather than rejected")
    func readsFloat16() throws {
        let array = try MLMultiArray(shape: [4], dataType: .float16)
        array.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
            for i in 0..<buffer.count { buffer[i] = Float16(i) * 0.5 }
        }
        #expect(try MLArrayReader.dense(array, named: "half") == [0, 0.5, 1.0, 1.5])
    }
}

@Suite("Ring buffer")
struct AudioRingBufferTests {

    private func write(_ ring: AudioRingBuffer, _ values: [Float]) -> Int {
        values.withUnsafeBufferPointer { ring.write($0) }
    }

    private func read(_ ring: AudioRingBuffer, _ count: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: count)
        let got = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        return Array(out[0..<got])
    }

    @Test("values come back in order")
    func roundTrips() {
        let ring = AudioRingBuffer(capacity: 64)
        #expect(write(ring, [1, 2, 3]) == 3)
        #expect(ring.availableToRead == 3)
        #expect(read(ring, 8) == [1, 2, 3])
        #expect(ring.availableToRead == 0)
    }

    /// The audio thread must never block. When the consumer stalls, the correct
    /// behaviour is to drop and count, not to wait.
    @Test("an overrun drops and counts instead of blocking or corrupting")
    func dropsOnOverrun() {
        let ring = AudioRingBuffer(capacity: 8)
        let written = write(ring, Array(repeating: 1, count: 64))
        #expect(written < 64)
        #expect(ring.droppedFrames == 64 - written)
        // Whatever it did accept must still read back cleanly.
        #expect(read(ring, 64).allSatisfy { $0 == 1 })
    }

    @Test("reads and writes stay correct across the wrap point")
    func wrapsAround() {
        let ring = AudioRingBuffer(capacity: 8)
        _ = write(ring, [1, 2, 3, 4, 5])
        #expect(read(ring, 4) == [1, 2, 3, 4])
        _ = write(ring, [6, 7, 8, 9])
        #expect(read(ring, 8) == [5, 6, 7, 8, 9])
    }

    @Test("reset drops everything so a new session starts clean")
    func resets() {
        let ring = AudioRingBuffer(capacity: 16)
        _ = write(ring, [1, 2, 3])
        ring.reset()
        #expect(ring.availableToRead == 0)
        #expect(read(ring, 4).isEmpty)
    }
}

@Suite("Input gain")
struct GainBoxTests {

    @Test("decibels round-trip to linear")
    func decibelRoundTrip() {
        for dB in [-12.0, -6.0, 0.0, 6.0, 12.0, 20.0, 30.0] {
            let linear = GainBox.linear(fromDecibels: dB)
            let back = GainBox.decibels(fromLinear: linear)
            #expect(abs(back - dB) < 0.01, "\(dB) dB round-tripped to \(back)")
        }
        #expect(abs(GainBox.linear(fromDecibels: 0) - 1) < 1e-6)
        #expect(abs(GainBox.linear(fromDecibels: 6) - 2) < 0.01)
    }

    /// The tap reads this value every buffer and multiplies by it. A NaN or an
    /// absurd value there would not throw — it would silently turn every sample
    /// into garbage the recogniser cannot decode.
    @Test("out-of-range and non-finite gains are clamped, never stored raw")
    func clampsHostileValues() {
        #expect(GainBox.clamp(.nan) == 1)
        #expect(GainBox.clamp(.infinity) == GainBox.maximum)
        #expect(GainBox.clamp(-5) == GainBox.minimum)
        #expect(GainBox.clamp(1_000_000) == GainBox.maximum)
        #expect(GainBox.clamp(4) == 4)

        let box = GainBox(.nan)
        #expect(box.current == 1)
        box.set(.infinity)
        #expect(box.current == GainBox.maximum)
    }

    @Test("a fresh box is unity gain, so nothing changes until asked")
    func defaultsToUnity() {
        #expect(GainBox().current == 1)
    }

    @Test("the slider range covers a very quiet microphone")
    func rangeIsUseful() {
        // 30 dB is what a built-in array delivering ~0.005 RMS needs to reach
        // the ~0.15 the recogniser expects.
        #expect(GainBox.maximumDecibels >= 29)
        #expect(GainBox.minimumDecibels <= -12)
    }
}
