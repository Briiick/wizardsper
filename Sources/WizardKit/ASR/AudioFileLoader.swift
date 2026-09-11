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

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio) + 1024)
        var reachedEnd = false

        while true {
            output.frameLength = 0
            // AVAudioConverter takes an NSErrorPointer, not a generic Error box.
            var thrown: NSError?
            let status = converter.convert(to: output, error: &thrown) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    input.frameLength = 0
                    try file.read(into: input, frameCount: readChunk)
                } catch {
                    thrown = error as NSError
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }

            if let thrown {
                throw WizardError.audioEngineFailed(
                    "decode failed: \(thrown.localizedDescription)")
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || (status == .inputRanDry && reachedEnd) { break }
            if status == .error { throw WizardError.audioEngineFailed("conversion reported an error") }
            if output.frameLength == 0 && reachedEnd { break }
        }
        return samples
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
