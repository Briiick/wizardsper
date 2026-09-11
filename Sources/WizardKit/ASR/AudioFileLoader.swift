import AVFoundation
import Foundation

/// Reads any audio file the system can decode into the 16 kHz mono Float32 the
/// recogniser expects. Used by the CLI harness and by "re-transcribe this file"
/// paths; live capture has its own converter on the render thread.
public enum AudioFileLoader {

    public static func samples(at url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw WizardError.audioEngineFailed(
                "cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }

        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(NemotronConfig.sampleRate),
                channels: 1, interleaved: false)
        else {
            throw WizardError.audioEngineFailed("could not build the 16 kHz mono target format")
        }

        let source = file.processingFormat
        if source == target {
            return try readDirect(file: file, format: target)
        }

        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw WizardError.audioEngineFailed(
                "no conversion from \(source.sampleRate) Hz / \(source.channelCount) ch to 16 kHz mono")
        }
        // Default to the highest-quality resampler: this path is offline, so the
        // extra cost is irrelevant next to being a faithful reference for the
        // live path.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let readChunk: AVAudioFrameCount = 16384
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: readChunk) else {
            throw WizardError.audioEngineFailed("could not allocate the read buffer")
        }
        let ratio = target.sampleRate / source.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(readChunk) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity)
        else {
            throw WizardError.audioEngineFailed("could not allocate the conversion buffer")
        }

        let pull = FilePull(file: file, buffer: input, frames: readChunk)
        // Hoisted out of the loop: a fresh closure per `convert` call would be an
        // allocation per 16 k frames, and the block must be the same object for
        // the converter's internal bookkeeping to stay meaningful.
        let inputBlock: AVAudioConverterInputBlock = { _, status in pull.next(status) }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1024)

        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: inputBlock)

            if let failure = pull.failure {
                throw WizardError.audioEngineFailed("decode failed: \(failure.localizedDescription)")
            }
            if let conversionError {
                throw WizardError.audioEngineFailed(
                    "conversion failed: \(conversionError.localizedDescription)")
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            switch status {
            case .haveData:
                continue
            case .endOfStream:
                return samples
            case .inputRanDry:
                // Only reachable if the pull block reported `.noDataNow`, which
                // it never does; treat it as the end rather than spinning.
                return samples
            case .error:
                throw WizardError.audioEngineFailed("conversion reported an error")
            @unknown default:
                return samples
            }
        }
    }

    /// Feeds the converter one read of the file at a time.
    ///
    /// `AVAudioConverterInputBlock` is declared `@Sendable`, but the converter
    /// invokes it synchronously on the thread that called `convert` — the state
    /// below never actually crosses a thread. Holding it in an
    /// `@unchecked Sendable` box states that invariant once, instead of leaving
    /// five concurrency warnings scattered over a strictly sequential loop.
    private final class FilePull: @unchecked Sendable {
        private let file: AVAudioFile
        private let buffer: AVAudioPCMBuffer
        private let frames: AVAudioFrameCount
        private var reachedEnd = false
        private(set) var failure: NSError?

        init(file: AVAudioFile, buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) {
            self.file = file
            self.buffer = buffer
            self.frames = frames
        }

        func next(
            _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
        ) -> AVAudioPCMBuffer? {
            if reachedEnd || failure != nil {
                status.pointee = .endOfStream
                return nil
            }
            do {
                buffer.frameLength = 0
                try file.read(into: buffer, frameCount: frames)
            } catch {
                failure = error as NSError
                status.pointee = .endOfStream
                return nil
            }
            if buffer.frameLength == 0 {
                reachedEnd = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }

    private static func readDirect(file: AVAudioFile, format: AVAudioFormat) throws -> [Float] {
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw WizardError.audioEngineFailed("could not allocate a \(frames)-frame buffer")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
