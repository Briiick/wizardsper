import Foundation

/// The bundle's `tokenizer.json`: a flat object mapping a decimal token id to
/// its SentencePiece piece, e.g. `{"0": "<unk>", "5": "▁the"}`.
///
/// Decoding is SentencePiece's: concatenate the pieces, turn the word-boundary
/// marker `▁` (U+2581) into a space, and trim. There is no merge table and no
/// byte fallback — the vocabulary is 1024 pieces plus a blank at index 1024 that
/// is never emitted into the token stream.
public struct NemotronTokenizer: Sendable {
    /// Indexed by token id; pieces are stored exactly as they appear in the file.
    private let pieces: [String]
    public let count: Int

    public static let wordBoundary: Character = "\u{2581}"

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw WizardsperError.tokenizerInvalid("expected a flat object of id → piece")
        }
        guard !raw.isEmpty else {
            throw WizardsperError.tokenizerInvalid("vocabulary is empty")
        }

        var highest = -1
        var parsed: [(Int, String)] = []
        parsed.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard let id = Int(key), id >= 0 else {
                throw WizardsperError.tokenizerInvalid("token id “\(key)” is not a non-negative integer")
            }
            highest = max(highest, id)
            parsed.append((id, value))
        }

        var table = [String](repeating: "", count: highest + 1)
        for (id, value) in parsed { table[id] = value }
        self.pieces = table
        self.count = table.count
    }

    /// The raw piece, boundary marker intact. Used for per-token timings.
    public func piece(_ id: Int) -> String {
        guard id >= 0, id < pieces.count else { return "" }
        return pieces[id]
    }

    /// Concatenate, replace the boundary marker with a space, trim the edges.
    public func decode<S: Sequence<Int>>(_ ids: S) -> String {
        var out = ""
        for id in ids {
            guard id >= 0, id < pieces.count else { continue }
            out += pieces[id]
        }
        guard !out.isEmpty else { return "" }
        return out
            .replacingOccurrences(of: String(Self.wordBoundary), with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
