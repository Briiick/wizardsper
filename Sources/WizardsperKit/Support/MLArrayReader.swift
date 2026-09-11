import Accelerate
import CoreML
import Foundation

/// The single door through which every model output is read.
///
/// `MLMultiArray` is a *view*, not a buffer. CoreML is free to return one whose
/// `strides` are not the dense row-major strides implied by `shape` — the ANE
/// routinely pads the innermost axis up to a 64-byte boundary, and fused graphs
/// can hand back transposed views. Reading `dataPointer` as if it were dense
/// then silently interleaves channels with padding, which does not crash and
/// does not throw: it just produces a subtly wrong tensor, and the only symptom
/// is a transcript that degrades into noise.
///
/// Every accessor here goes through `withUnsafeBufferPointer(ofType:)`, which
/// hands back the real strides, and takes a dense fast path only after
/// confirming the strides actually are dense. Outputs are also accepted as
/// Float16, because a model whose schema declares Float32 may still return
/// Float16 when CoreML picks a reduced compute precision.
public enum MLArrayReader {

    // MARK: - Shape

    public static func shape(of array: MLMultiArray) -> [Int] {
        array.shape.map(\.intValue)
    }

    public static func strides(of array: MLMultiArray) -> [Int] {
        array.strides.map(\.intValue)
    }

    /// Dense row-major strides for `shape`, innermost axis last.
    public static func denseStrides(for shape: [Int]) -> [Int] {
        var out = [Int](repeating: 1, count: shape.count)
        var acc = 1
        for axis in stride(from: shape.count - 1, through: 0, by: -1) {
            out[axis] = acc
            acc *= shape[axis]
        }
        return out
    }

    /// Throw unless `array` matches `expected`. `-1` matches any extent, so a
    /// flexible time axis can still be shape-checked on every other axis.
    public static func requireShape(
        _ array: MLMultiArray, _ expected: [Int], named name: String
    ) throws {
        let actual = shape(of: array)
        guard actual.count == expected.count else {
            throw WizardsperError.modelShapeMismatch(name: name, expected: expected, actual: actual)
        }
        for (a, e) in zip(actual, expected) where e != -1 && a != e {
            throw WizardsperError.modelShapeMismatch(name: name, expected: expected, actual: actual)
        }
    }

    /// Fetch a named output and shape-check it in one step.
    public static func output(
        _ provider: MLFeatureProvider, _ name: String, expecting: [Int]? = nil
    ) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: name)?.multiArrayValue else {
            throw WizardsperError.modelOutputMissing(name)
        }
        if let expecting {
            try requireShape(value, expecting, named: name)
        }
        return value
    }

    // MARK: - Reads

    /// Copy `array` into a dense row-major `[Float]`, honouring strides.
    public static func dense(_ array: MLMultiArray, named name: String) throws -> [Float] {
        let shp = shape(of: array)
        let count = shp.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        try out.withUnsafeMutableBufferPointer { dst in
            try copy(array, named: name, into: dst.baseAddress!)
        }
        return out
    }

    /// Copy `array` into `destination`, which must hold `shape.reduce(1,*)` floats.
    public static func copy(
        _ array: MLMultiArray, named name: String, into destination: UnsafeMutablePointer<Float>
    ) throws {
        let shp = shape(of: array)
        let count = shp.reduce(1, *)
        let dense = denseStrides(for: shp)
        // Only `withUnsafeMutableBufferPointer` hands back strides; the read-only
        // accessor does not, so they come from the array itself. Same values.
        let actual = strides(of: array)

        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { buf in
                guard let src = buf.baseAddress else { return }
                if actual == dense {
                    destination.update(from: src, count: count)
                } else {
                    gather(src: src, shape: shp, strides: actual, dst: destination)
                }
            }
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { buf in
                guard let src = buf.baseAddress else { return }
                if actual == dense {
                    var srcDesc = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: src), height: 1,
                        width: vImagePixelCount(count), rowBytes: count * 2)
                    var dstDesc = vImage_Buffer(
                        data: destination, height: 1, width: vImagePixelCount(count),
                        rowBytes: count * 4)
                    vImageConvert_Planar16FtoPlanarF(&srcDesc, &dstDesc, 0)
                } else {
                    gather(src: src, shape: shp, strides: actual, dst: destination) { Float($0) }
                }
            }
        case .double:
            array.withUnsafeBufferPointer(ofType: Double.self) { buf in
                guard let src = buf.baseAddress else { return }
                if actual == dense {
                    vDSP_vdpsp(src, 1, destination, 1, vDSP_Length(count))
                } else {
                    gather(src: src, shape: shp, strides: actual, dst: destination) { Float($0) }
                }
            }
        default:
            throw WizardsperError.modelShapeMismatch(
                name: "\(name) (dtype \(array.dataType.rawValue))", expected: [], actual: shp)
        }
    }

    /// Copy `[1, channels, time]` at a single `time` index into `destination`
    /// (`channels` floats). Used once per encoder frame in the RNN-T loop.
    public static func timeStep(
        _ array: MLMultiArray, named name: String, time: Int,
        into destination: UnsafeMutablePointer<Float>
    ) throws {
        let shp = shape(of: array)
        guard shp.count == 3, shp[0] == 1, time >= 0, time < shp[2] else {
            throw WizardsperError.modelShapeMismatch(
                name: name, expected: [1, -1, time + 1], actual: shp)
        }
        let channels = shp[1]
        guard array.dataType == .float32 else {
            // Rare path: go through the general reader, then pick the lane out.
            let all = try dense(array, named: name)
            for c in 0..<channels { destination[c] = all[c * shp[2] + time] }
            return
        }
        let actual = strides(of: array)
        array.withUnsafeBufferPointer(ofType: Float.self) { buf in
            guard let src = buf.baseAddress else { return }
            let lane = src + time * actual[2]
            // vDSP handles the channel stride without a Swift-level loop.
            vDSP_vsadd(
                lane, actual[1], [0] as [Float], destination, 1, vDSP_Length(channels))
        }
    }

    /// Index of the largest value, honouring strides. The RNN-T greedy step
    /// calls this once per symbol, so it stays on the vDSP path.
    public static func argmax(_ array: MLMultiArray, named name: String) throws -> (
        index: Int, value: Float
    ) {
        let count = shape(of: array).reduce(1, *)
        guard count > 0 else { throw WizardsperError.modelOutputMissing(name) }

        if array.dataType == .float32 {
            var result: (Int, Float)?
            // vDSP_maxvi returns the offset into the buffer (index * stride),
            // so the logical index is that divided back out.
            let innerStride = strides(of: array).last ?? 1
            array.withUnsafeBufferPointer(ofType: Float.self) { buf in
                guard let src = buf.baseAddress else { return }
                // logits is [1,1,1,V]; only the innermost axis has extent, so a
                // single strided scan is exact.
                var maxValue: Float = -.infinity
                var maxIndex: vDSP_Length = 0
                vDSP_maxvi(src, innerStride, &maxValue, &maxIndex, vDSP_Length(count))
                result = (Int(maxIndex) / max(innerStride, 1), maxValue)
            }
            if let result { return result }
        }

        let values = try dense(array, named: name)
        var maxValue: Float = -.infinity
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(values, 1, &maxValue, &maxIndex, vDSP_Length(values.count))
        return (Int(maxIndex), maxValue)
    }

    /// True when every element is exactly zero. A healthy encoder cannot do this
    /// for non-zero input (LayerNorm bias guarantees it), so an all-zero result
    /// means the ANE program never instantiated.
    public static func isAllZero(_ array: MLMultiArray, named name: String) throws -> Bool {
        let values = try dense(array, named: name)
        var maxMagnitude: Float = 0
        vDSP_maxmgv(values, 1, &maxMagnitude, vDSP_Length(values.count))
        return maxMagnitude == 0
    }

    // MARK: - Writes

    public static func float32(shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        zero(array)
        return array
    }

    public static func int32(shape: [Int], value: Int32 = 0) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .int32)
        array.withUnsafeMutableBufferPointer(ofType: Int32.self) { buf, _ in
            guard let p = buf.baseAddress else { return }
            for i in 0..<buf.count { p[i] = value }
        }
        return array
    }

    public static func zero(_ array: MLMultiArray) {
        switch array.dataType {
        case .float32:
            array.withUnsafeMutableBufferPointer(ofType: Float.self) { buf, _ in
                guard let p = buf.baseAddress else { return }
                vDSP_vclr(p, 1, vDSP_Length(buf.count))
            }
        case .int32:
            array.withUnsafeMutableBufferPointer(ofType: Int32.self) { buf, _ in
                guard let p = buf.baseAddress else { return }
                p.update(repeating: 0, count: buf.count)
            }
        default:
            break
        }
    }

    // MARK: - Strided gather

    private static func gather(
        src: UnsafePointer<Float>, shape: [Int], strides: [Int],
        dst: UnsafeMutablePointer<Float>
    ) {
        gather(src: src, shape: shape, strides: strides, dst: dst) { $0 }
    }

    /// Walk `shape` in row-major order, reading through `strides`. The odometer
    /// avoids recursion and allocates nothing.
    private static func gather<T>(
        src: UnsafePointer<T>, shape: [Int], strides: [Int],
        dst: UnsafeMutablePointer<Float>, transform: (T) -> Float
    ) {
        let rank = shape.count
        guard rank > 0 else { return }
        var counter = [Int](repeating: 0, count: rank)
        var offset = 0
        var written = 0
        let total = shape.reduce(1, *)
        while written < total {
            dst[written] = transform(src[offset])
            written += 1
            var axis = rank - 1
            while axis >= 0 {
                counter[axis] += 1
                offset += strides[axis]
                if counter[axis] < shape[axis] { break }
                offset -= strides[axis] * shape[axis]
                counter[axis] = 0
                axis -= 1
            }
        }
    }
}
