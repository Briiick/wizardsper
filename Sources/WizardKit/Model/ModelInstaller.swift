import Foundation
import os

/// Gets a Nemotron tier onto the disk and proves it is actually there.
///
/// A tier is ~615 MB of loose files published on Hugging Face, 94% of it in a
/// single `encoder_int8.mlmodelc/weights/weight.bin`. Everything in here exists
/// because that shape is hostile: a download that dies two thirds of the way
/// through leaves a directory that *looks* installed, and CoreML's failure on a
/// truncated bundle is an opaque internal error with no hint that the fix is to
/// download it again. So the installer never trusts a path's existence, writes
/// every file through a `.partial` sibling, and re-verifies the whole tier
/// before it reports `.ready`.
public actor ModelInstaller {

    /// What the installer is doing, for a progress bar to render directly.
    ///
    /// A phase carries no tier: Wizard installs one tier at a time, and pairing
    /// each phase with the tier would push the UI into filtering a stream it
    /// already knows the subject of. Read `status(for:)` for a specific tier.
    public enum Phase: Sendable, Equatable {
        case idle
        /// Asking Hugging Face which files the tier is made of.
        case listing
        case downloading(completedBytes: Int64, totalBytes: Int64, file: String)
        /// Re-checking every required file now that the transfers are done.
        case verifying
        case ready
        /// Carries the message already shown to the user, so the UI does not have
        /// to re-derive it from an error it no longer holds.
        case failed(String)
    }

    public static let shared = ModelInstaller()

    /// Four is enough to saturate a home connection while leaving the huge
    /// encoder weights a slot of their own; more only splits the same bandwidth
    /// into more ways to time out.
    private static let maxConcurrentDownloads = 4
    private static let maxAttempts = 3
    private static let partialExtension = "partial"
    private static let host = "huggingface.co"
    /// The three files CoreML reads out of a compiled model directory. All three
    /// are present in every `.mlmodelc` this repository publishes.
    private static let compiledModelContents = ["coremldata.bin", "model.mil", "weights/weight.bin"]

    private let session: URLSession
    /// Last phase published per tier, which is also the dedupe key: the ticker
    /// fires five times a second and most ticks say nothing new.
    private var phases: [NemotronTier: Phase] = [:]
    private var inFlight: [NemotronTier: Task<URL, any Error>] = [:]
    private var subscribers: [UUID: AsyncStream<Phase>.Continuation] = [:]

    public init() {
        let configuration = URLSessionConfiguration.default
        // Caching 615 MB of model weights in the URL cache would double the disk
        // cost of an install for no benefit — these files are fetched once.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        // Failing fast beats waiting silently: the retry loop below handles a
        // flapping connection, and a user watching a stalled bar cannot.
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = Self.maxConcurrentDownloads
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Status

    /// The current phase for a tier, from memory and the filesystem only.
    ///
    /// Safe to call on every view update: it never touches the network.
    public func status(for tier: NemotronTier) -> Phase {
        if inFlight[tier] != nil, let phase = phases[tier] { return phase }
        if isInstalled(tier) { return .ready }
        // A failure survives until something changes it, so the dashboard can
        // still explain why the last attempt did not work.
        if let phase = phases[tier], case .failed = phase { return phase }
        return .idle
    }

    /// Whether `tier` is complete enough to load.
    public func isInstalled(_ tier: NemotronTier) -> Bool {
        Self.missingPiece(of: tier, in: WizardPaths.modelDirectory(for: tier)) == nil
    }

    /// A live feed of phase changes for whichever install is running.
    ///
    /// Each call gets its own stream; ending the `for await` drops it.
    public func events() -> AsyncStream<Phase> {
        let id = UUID()
        // Only the newest few phases matter to a progress bar, and an unbounded
        // buffer would grow without limit behind a consumer that stopped reading.
        let (stream, continuation) = AsyncStream<Phase>.makeStream(
            bufferingPolicy: .bufferingNewest(8))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        return stream
    }

    private func forget(_ id: UUID) async {
        subscribers[id] = nil
    }

    private func publish(_ phase: Phase, for tier: NemotronTier) {
        guard phases[tier] != phase else { return }
        phases[tier] = phase
        for continuation in subscribers.values {
            continuation.yield(phase)
        }
    }

    // MARK: - Install

    /// Downloads `tier` if it is not already complete, and returns its directory.
    ///
    /// Idempotent in both directions: an install that already passes verification
    /// returns immediately, and a second concurrent caller joins the running
    /// install rather than starting a rival one over the same `.partial` files.
    /// Cancelling the caller cancels the shared install for every waiter, which
    /// is what a "Cancel download" button means.
    @discardableResult
    public func install(_ tier: NemotronTier) async throws -> URL {
        let directory = WizardPaths.modelDirectory(for: tier)

        if isInstalled(tier) {
            publish(.ready, for: tier)
            return directory
        }

        // A predecessor that was cancelled — by `remove`, or by another waiter's
        // Cancel button — must not answer for this caller: adopting it rethrew
        // that `CancellationError` here, so the install the user had just asked
        // for failed instantly without ever running. It is still waited out
        // before a fresh run starts, because its cleanup deletes `.partial` files
        // the fresh run is about to write.
        while let running = inFlight[tier] {
            do {
                return try await withTaskCancellationHandler {
                    try await running.value
                } onCancel: {
                    running.cancel()
                }
            } catch is CancellationError {
                // This caller's own cancellation is an answer; only somebody
                // else's is worth starting over from.
                try Task.checkCancellation()
                retire(running, for: tier)
            }
        }

        let work = Task { try await self.performInstall(tier) }
        inFlight[tier] = work
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            retire(work, for: tier)
            return result
        } catch {
            retire(work, for: tier)
            throw error
        }
    }

    /// Forgets `work`, unless a fresh install has already taken its place.
    ///
    /// A cancelled install is replaced while it is still unwinding, so clearing
    /// the slot unconditionally would unregister that successor and leave the
    /// next caller free to start a second download over the same `.partial` files.
    private func retire(_ work: Task<URL, any Error>, for tier: NemotronTier) {
        if inFlight[tier] == work { inFlight[tier] = nil }
    }

    private func performInstall(_ tier: NemotronTier) async throws -> URL {
        let directory = WizardPaths.modelDirectory(for: tier)
        do {
            publish(.listing, for: tier)
            try WizardPaths.ensureApplicationSupport()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let files = try await Self.listTier(tier, session: session)
            try Task.checkCancellation()

            let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

            // Anything already on disk at exactly the published size is left
            // alone, so re-running after an interruption fetches only the gap.
            var pending: [RemoteFile] = []
            var settledBytes: Int64 = 0
            for file in files {
                let destination = directory.appendingPathComponent(file.relativePath)
                if file.size > 0, let onDisk = Self.fileSize(at: destination), onDisk == file.size {
                    settledBytes += onDisk
                } else {
                    pending.append(file)
                }
            }

            if pending.isEmpty == false {
                // Biggest first. The encoder weights are 94% of a tier, so if they
                // do not start in the first wave they alone decide how long the
                // install takes.
                pending.sort { $0.size > $1.size }
                try await runDownloads(
                    pending, tier: tier, into: directory,
                    settledBytes: settledBytes, totalBytes: totalBytes)
            }

            try Task.checkCancellation()
            publish(.verifying, for: tier)
            if let missing = Self.missingPiece(of: tier, in: directory) {
                throw WizardError.downloadFailed(
                    "\(tier.subdirectory) is still incomplete after downloading — \(missing)")
            }

            publish(.ready, for: tier)
            Log.model.info("installed \(tier.subdirectory, privacy: .public)")
            return directory
        } catch is CancellationError {
            Self.removePartials(in: directory)
            publish(.idle, for: tier)
            Log.model.notice("install of \(tier.subdirectory, privacy: .public) was cancelled")
            throw CancellationError()
        } catch {
            Self.removePartials(in: directory)
            let message = Self.describe(error)
            Log.model.error(
                "install of \(tier.subdirectory, privacy: .public) failed: \(message, privacy: .public)"
            )
            publish(.failed(message), for: tier)
            throw error
        }
    }

    /// Runs `pending` through a bounded task group, publishing byte progress.
    private func runDownloads(
        _ pending: [RemoteFile],
        tier: NemotronTier,
        into directory: URL,
        settledBytes: Int64,
        totalBytes: Int64
    ) async throws {
        let tally = ProgressTally(settledBytes: settledBytes, currentFile: pending[0].relativePath)
        publishProgress(tally, totalBytes: totalBytes, for: tier)

        // The encoder weights are one file worth ten minutes, so per-file
        // completion is far too coarse to drive a bar. The ticker samples the
        // live `URLSessionTask` byte counters instead.
        let ticker = Task {
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                await self.tick(tally, totalBytes: totalBytes, for: tier)
            }
        }
        defer { ticker.cancel() }

        let session = self.session
        try await withThrowingTaskGroup(of: String.self) { group in
            var next = 0
            while next < min(Self.maxConcurrentDownloads, pending.count) {
                let file = pending[next]
                group.addTask {
                    try await Self.fetch(
                        file, tier: tier, into: directory, session: session, tally: tally)
                }
                next += 1
            }
            // One finished file frees exactly one slot, which keeps the number of
            // live transfers at the cap instead of in waves.
            while let landed = try await group.next() {
                Log.model.debug("model file ready: \(landed, privacy: .public)")
                try Task.checkCancellation()
                if next < pending.count {
                    let file = pending[next]
                    next += 1
                    group.addTask {
                        try await Self.fetch(
                            file, tier: tier, into: directory, session: session, tally: tally)
                    }
                }
            }
        }

        publishProgress(tally, totalBytes: totalBytes, for: tier)
    }

    /// Async so the ticker's `await` is correct whether or not `Task {}` inherited
    /// this actor's isolation.
    private func tick(_ tally: ProgressTally, totalBytes: Int64, for tier: NemotronTier) async {
        publishProgress(tally, totalBytes: totalBytes, for: tier)
    }

    private func publishProgress(
        _ tally: ProgressTally, totalBytes: Int64, for tier: NemotronTier
    ) {
        let reading = tally.read()
        // Published sizes and delivered bytes disagree by a few bytes often
        // enough that an unclamped bar visibly overshoots 100%.
        let completed = min(max(0, reading.completed), max(0, totalBytes))
        publish(
            .downloading(completedBytes: completed, totalBytes: totalBytes, file: reading.file),
            for: tier)
    }

    // MARK: - Offline import

    /// Installs a tier from a user-supplied `.zip` instead of the network.
    ///
    /// The published bundle is loose files, so no such zip exists upstream — this
    /// is for a machine that cannot reach Hugging Face and gets the bundle by
    /// hand. Archives made in the Finder wrap everything in a folder, and one
    /// zipped from the repository root holds all four tiers, so the bundle is
    /// located by looking rather than assumed to be at the top.
    @discardableResult
    public func importZip(at zipURL: URL, as tier: NemotronTier) async throws -> URL {
        let destination = WizardPaths.modelDirectory(for: tier)
        let manager = FileManager.default
        do {
            // Unpacking has no byte count to report, so it borrows `.listing`.
            publish(.listing, for: tier)
            try WizardPaths.ensureApplicationSupport()
            try manager.createDirectory(at: WizardPaths.models, withIntermediateDirectories: true)

            // Staged on the same volume as the models directory so the final swap
            // is a rename and not a 615 MB copy.
            let staging = try manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: WizardPaths.models, create: true)
            defer {
                do {
                    try manager.removeItem(at: staging)
                } catch {
                    let reason = error.localizedDescription
                    Log.model.error(
                        "could not clear the import staging directory: \(reason, privacy: .public)")
                }
            }

            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)

            // Detached so the blocking `unzip` never runs on this actor's
            // executor: `status(for:)` has to stay answerable while it works. A
            // detached task inherits no cancellation, so the box is what carries a
            // cancel across to the child — without it, cancelling an import buys
            // nothing until `unzip` decides to finish on its own.
            let control = ProcessBox()
            let unpacking = Task.detached(priority: .userInitiated) {
                try Self.unpack(zipURL, into: unpacked, control: control)
            }
            try await withTaskCancellationHandler {
                try await unpacking.value
            } onCancel: {
                control.cancel()
            }
            try Task.checkCancellation()

            guard let root = Self.locateBundle(of: tier, under: unpacked) else {
                throw WizardError.downloadFailed(
                    "\(zipURL.lastPathComponent) does not contain a model bundle — expected a "
                        + "folder holding metadata.json beside the compiled .mlmodelc directories.")
            }

            publish(.verifying, for: tier)
            // Verified where it landed, before the existing install is touched: a
            // truncated archive must not be able to destroy a working tier.
            if let missing = Self.missingPiece(of: tier, in: root) {
                throw WizardError.downloadFailed(
                    "\(zipURL.lastPathComponent) is not a complete \(tier.chunkMilliseconds) ms "
                        + "bundle — \(missing)")
            }

            let replaced = staging.appendingPathComponent("replaced", isDirectory: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: destination, to: replaced)
            }
            do {
                try manager.moveItem(at: root, to: destination)
            } catch {
                // Put the previous install back rather than leaving the user with
                // neither the old tier nor the new one.
                if manager.fileExists(atPath: replaced.path) {
                    try? manager.moveItem(at: replaced, to: destination)
                }
                throw WizardError.downloadFailed(
                    "could not move the imported bundle into place: \(error.localizedDescription)")
            }

            if let missing = Self.missingPiece(of: tier, in: destination) {
                throw WizardError.downloadFailed(
                    "the imported bundle is incomplete after the move — \(missing)")
            }

            publish(.ready, for: tier)
            Log.model.info(
                "imported \(tier.subdirectory, privacy: .public) from \(zipURL.lastPathComponent, privacy: .public)"
            )
            return destination
        } catch is CancellationError {
            publish(.idle, for: tier)
            Log.model.notice("zip import of \(tier.subdirectory, privacy: .public) was cancelled")
            throw CancellationError()
        } catch {
            let message = Self.describe(error)
            Log.model.error(
                "zip import of \(tier.subdirectory, privacy: .public) failed: \(message, privacy: .public)"
            )
            publish(.failed(message), for: tier)
            throw error
        }
    }

    // MARK: - Removal

    /// Deletes a tier from disk, cancelling an install of it first.
    public func remove(_ tier: NemotronTier) throws {
        // Without this, an install racing the delete would put the files straight
        // back and leave the dashboard claiming the tier was removed.
        inFlight[tier]?.cancel()

        let directory = WizardPaths.modelDirectory(for: tier)
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            do {
                try manager.removeItem(at: directory)
            } catch {
                let reason = error.localizedDescription
                Log.model.error(
                    "could not delete \(tier.subdirectory, privacy: .public): \(reason, privacy: .public)"
                )
                throw WizardError.downloadFailed(
                    "the \(tier.chunkMilliseconds) ms files could not be deleted — "
                        + error.localizedDescription)
            }
        }
        publish(.idle, for: tier)
        Log.model.info("removed \(tier.subdirectory, privacy: .public)")
    }

    // MARK: - Verification

    /// Why `tier` is not usable out of `directory`, or `nil` when it is.
    ///
    /// This stats real files rather than checking that the directory exists,
    /// because a half-finished download leaves the directory and most of its
    /// contents behind. A bare existence check reads that as a warm cache; CoreML
    /// then fails to compile the bundle with an opaque internal error, and
    /// because the app believes the tier is installed it never downloads again.
    /// The install is bricked until the user finds the folder and deletes it by
    /// hand. So every required entry is stat-ed, and every `.mlmodelc` has to
    /// carry the three files CoreML actually reads, all at non-zero size.
    private static func missingPiece(of tier: NemotronTier, in directory: URL) -> String? {
        for entry in tier.requiredEntries {
            let url = directory.appendingPathComponent(entry)
            if entry.hasSuffix(".mlmodelc") {
                guard isDirectory(at: url) else { return "\(entry) is missing" }
                for piece in compiledModelContents {
                    guard let size = fileSize(at: url.appendingPathComponent(piece)), size > 0
                    else {
                        return "\(entry)/\(piece) is missing or empty"
                    }
                }
            } else {
                guard let size = fileSize(at: url), size > 0 else {
                    return "\(entry) is missing or empty"
                }
            }
        }
        return nil
    }

    /// Size of a regular file, or `nil` for anything that is not one. A stat that
    /// fails and a file that is absent mean the same thing here — not usable — so
    /// there is no error to report.
    private static func fileSize(at url: URL) -> Int64? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
            directory.boolValue == false
        else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    private static func isDirectory(at url: URL) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return exists && directory.boolValue
    }

    /// Deletes leftover `.partial` files after a failed or cancelled install.
    ///
    /// Best-effort by design: it runs on a path that is already throwing the real
    /// error, so a failure here is logged rather than allowed to replace it.
    private static func removePartials(in directory: URL) {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for case let url as URL in walker where url.pathExtension == partialExtension {
            do {
                try manager.removeItem(at: url)
            } catch {
                let reason = error.localizedDescription
                let name = url.lastPathComponent
                Log.model.error(
                    "could not delete \(name, privacy: .public): \(reason, privacy: .public)")
            }
        }
    }

    // MARK: - Listing

    /// One file of a published tier, as the Hugging Face tree API describes it.
    private struct RemoteFile: Sendable {
        /// Path inside the repository, which is what the download URL needs.
        let remotePath: String
        /// `remotePath` with the tier's own directory prefix stripped, which is
        /// where the file goes locally.
        let relativePath: String
        let size: Int64
    }

    private static func listTier(_ tier: NemotronTier, session: URLSession) async throws
        -> [RemoteFile]
    {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/models/\(NemotronTier.repository)/tree/\(tier.revision)"
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let url = components.url else {
            throw WizardError.downloadFailed(
                "could not build a listing URL for \(NemotronTier.repository)@\(tier.revision)")
        }

        let data = try await retrying("the file listing") { () async throws -> Data in
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PermanentFailure(reason: "the file listing came back without an HTTP status")
            }
            guard http.statusCode == 200 else {
                throw classify(status: http.statusCode, path: "the file listing", tier: tier)
            }
            return data
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WizardError.downloadFailed(
                "the file listing for \(tier.subdirectory) is not JSON: \(error.localizedDescription)"
            )
        }
        guard let entries = parsed as? [[String: Any]] else {
            throw WizardError.downloadFailed(
                "the file listing for \(tier.subdirectory) is not a JSON array of entries")
        }

        let prefix = tier.subdirectory + "/"
        var files: [RemoteFile] = []
        for entry in entries {
            guard entry["type"] as? String == "file",
                let path = entry["path"] as? String,
                path.hasPrefix(prefix)
            else { continue }

            let relative = String(path.dropFirst(prefix.count))
            guard isSafeRelativePath(relative) else {
                throw WizardError.downloadFailed("the listing contains an unsafe path: \(path)")
            }
            // `size` is the *pointer file* size for anything stored in LFS, so the
            // 589 MB encoder weights would read as a couple of hundred bytes and
            // the progress bar would finish before the download started. `lfs.size`
            // is the real one whenever the field is there.
            let lfsSize = (entry["lfs"] as? [String: Any])?["size"] as? Int
            let size = Int64(lfsSize ?? (entry["size"] as? Int ?? 0))
            files.append(RemoteFile(remotePath: path, relativePath: relative, size: size))
        }

        guard files.isEmpty == false else {
            throw WizardError.downloadFailed(
                "\(NemotronTier.repository)@\(tier.revision) has no \(tier.subdirectory) directory "
                    + "— that revision no longer publishes the \(tier.chunkMilliseconds) ms tier.")
        }
        return files
    }

    // MARK: - Transfer

    /// Fetches one file and renames it into place. Returns its relative path.
    private static func fetch(
        _ file: RemoteFile,
        tier: NemotronTier,
        into directory: URL,
        session: URLSession,
        tally: ProgressTally
    ) async throws -> String {
        try Task.checkCancellation()
        tally.beginFile(file.relativePath)

        let manager = FileManager.default
        let destination = directory.appendingPathComponent(file.relativePath)
        let partial = destination.appendingPathExtension(partialExtension)
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(NemotronTier.repository)/resolve/\(tier.revision)/\(file.remotePath)"
        guard let url = components.url else {
            throw WizardError.downloadFailed("could not build a download URL for \(file.remotePath)")
        }

        try await retrying(file.relativePath) { () async throws -> Void in
            // A partial from an earlier attempt is never resumed — the bytes on
            // the far side may have changed and a silent splice is unfixable.
            try? manager.removeItem(at: partial)
            try await transfer(
                from: url, to: partial, session: session, tally: tally,
                path: file.relativePath, tier: tier)
        }

        guard let landed = fileSize(at: partial), landed > 0 else {
            throw WizardError.downloadFailed("\(file.relativePath) arrived empty")
        }
        if file.size > 0, landed != file.size {
            try? manager.removeItem(at: partial)
            throw WizardError.downloadFailed(
                "\(file.relativePath) is \(landed) bytes, expected \(file.size)")
        }

        // Renamed only once the whole file is on disk, so an interrupted run can
        // never leave behind a truncated file that the next run reads as cached.
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: partial, to: destination)

        tally.settle(landed)
        return file.relativePath
    }

    /// One attempt at one file: downloads to `partial`, or throws.
    private static func transfer(
        from url: URL,
        to partial: URL,
        session: URLSession,
        tally: ProgressTally,
        path: String,
        tier: NemotronTier
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        let registration = UUID()
        // The tally reads this task's `countOfBytesReceived` while it runs, so it
        // has to be unregistered on every exit including a thrown one.
        defer { tally.unregister(registration) }

        let box = CancellableTaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(
                            throwing: PermanentFailure(
                                reason: "\(path) came back without an HTTP status"))
                        return
                    }
                    guard http.statusCode == 200 || http.statusCode == 206 else {
                        continuation.resume(
                            throwing: classify(status: http.statusCode, path: path, tier: tier))
                        return
                    }
                    guard let location else {
                        continuation.resume(
                            throwing: TransientFailure(reason: "\(path) produced no file"))
                        return
                    }
                    // URLSession deletes `location` the moment this handler
                    // returns, so the move happens here rather than back in the
                    // async caller.
                    do {
                        try FileManager.default.moveItem(at: location, to: partial)
                        continuation.resume()
                    } catch {
                        continuation.resume(
                            throwing: TransientFailure(
                                reason: "\(path) could not be written: \(error.localizedDescription)"
                            ))
                    }
                }
                tally.register(task, as: registration)
                box.adopt(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Retries transient failures with exponential backoff.
    ///
    /// The split matters: a 5xx or a dropped connection is worth waiting out, but
    /// a 404 means the pinned revision no longer publishes this tier and every
    /// retry is another ten seconds of the user watching a bar that cannot move.
    private static func retrying<T>(
        _ label: String,
        _ body: () async throws -> T
    ) async throws -> T {
        var lastReason = "no attempt was made"
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                return try await body()
            } catch let failure as PermanentFailure {
                Log.model.error(
                    "\(label, privacy: .public): \(failure.reason, privacy: .public)")
                throw WizardError.downloadFailed(failure.reason)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A cancelled URLSessionTask surfaces as URLError.cancelled; it is
                // our own cancellation coming back, not a network fault.
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw CancellationError()
                }
                lastReason = describe(error)
                guard isTransient(error), attempt < maxAttempts else {
                    Log.model.error(
                        "\(label, privacy: .public) failed: \(lastReason, privacy: .public)")
                    throw WizardError.downloadFailed("\(label) — \(lastReason)")
                }
                Log.model.notice(
                    "\(label, privacy: .public) attempt \(attempt) failed (\(lastReason, privacy: .public)); retrying")
                try await Task.sleep(for: .seconds(0.8 * pow(2.0, Double(attempt - 1))))
            }
        }
        throw WizardError.downloadFailed("\(label) — \(lastReason)")
    }

    private static func classify(status: Int, path: String, tier: NemotronTier) -> any Error {
        switch status {
        case 404, 410:
            return PermanentFailure(
                reason: "\(path) is not in \(NemotronTier.repository) at revision "
                    + "\(tier.revision) (HTTP \(status)) — that revision no longer publishes the "
                    + "\(tier.chunkMilliseconds) ms tier.")
        case 401, 403:
            return PermanentFailure(reason: "access to \(path) was refused (HTTP \(status))")
        case 408, 429, 500...599:
            return TransientFailure(reason: "HTTP \(status) for \(path)")
        default:
            return PermanentFailure(reason: "unexpected HTTP \(status) for \(path)")
        }
    }

    private static func isTransient(_ error: any Error) -> Bool {
        if error is TransientFailure { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
            .badServerResponse, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let transient = error as? TransientFailure { return transient.reason }
        if let permanent = error as? PermanentFailure { return permanent.reason }
        if let wizard = error as? WizardError { return wizard.errorDescription ?? "\(wizard)" }
        return error.localizedDescription
    }

    // MARK: - Archives

    /// Extracts a zip into `directory` after vetting every entry name.
    ///
    /// Synchronous and blocking; callers run it off this actor.
    private static func unpack(_ zipURL: URL, into directory: URL, control: ProcessBox) throws {
        let unzip = "/usr/bin/unzip"
        guard FileManager.default.isExecutableFile(atPath: unzip) else {
            throw WizardError.downloadFailed("\(unzip) is missing, so the archive cannot be opened")
        }
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw WizardError.downloadFailed("\(zipURL.lastPathComponent) does not exist")
        }

        // Every name is vetted before a single byte is written. An entry holding a
        // ".." component or an absolute path would otherwise be extracted outside
        // the staging directory — a zip slip — and could overwrite anything the
        // user can write to.
        let listing = try run(unzip, ["-Z1", "--", zipURL.path], control: control)
        let names = listing.split(separator: "\n").map(String.init)
        guard names.isEmpty == false else {
            throw WizardError.downloadFailed("\(zipURL.lastPathComponent) is empty")
        }
        for name in names {
            let entry = name.hasSuffix("/") ? String(name.dropLast()) : name
            guard isSafeRelativePath(entry) else {
                throw WizardError.downloadFailed(
                    "\(zipURL.lastPathComponent) contains an unsafe entry: \(name)")
            }
        }

        _ = try run(
            unzip, ["-qq", "-o", "--", zipURL.path, "-d", directory.path], control: control)
    }

    /// Runs a tool and returns its standard output, throwing on a bad exit status.
    ///
    /// Both pipes are drained at once because `unzip` writes to both. Reading
    /// stdout to the end first lets a child with more than a pipe buffer (64 KB)
    /// of warnings block writing stderr while this thread blocks reading a stdout
    /// that will never close: the import then hangs there permanently, with no
    /// timeout and nothing left to notice it. `control` terminates the child when
    /// the enclosing task is cancelled, so a cancelled import stops the extraction
    /// instead of waiting it out.
    private static func run(_ executable: String, _ arguments: [String], control: ProcessBox)
        throws -> String
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw WizardError.downloadFailed(
                "could not start \(executable): \(error.localizedDescription)")
        }

        control.adopt(process)
        // Released once the child has been reaped: its identifier goes back to the
        // system then, and a later signal could land on whatever inherited it.
        defer { control.release() }

        let collected = DataBox()
        let errorHandle = errors.fileHandleForReading
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            collected.store(errorHandle.readDataToEndOfFile())
            drained.signal()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        // Checked before the exit status, which after a terminate is only the
        // signal that did it and says nothing about the archive.
        if control.isCancelled { throw CancellationError() }

        let tool = URL(fileURLWithPath: executable).lastPathComponent
        let detail = String(decoding: collected.take(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let status = process.terminationStatus
        // unzip exits 1 for warnings it recovered from. The structural check that
        // follows is the real gate, so a warning is worth logging, not failing on.
        if status == 1 {
            Log.model.notice("\(tool, privacy: .public) reported: \(detail, privacy: .public)")
        } else if status != 0 {
            throw WizardError.downloadFailed(
                "\(tool) exited with status \(status)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    /// Finds the tier's bundle somewhere inside an unpacked archive.
    ///
    /// A zip of the whole repository holds all four tiers, so a directory named
    /// after this tier wins outright; otherwise the shallowest directory that
    /// looks like a bundle is taken, which covers the Finder's habit of wrapping
    /// everything in one extra folder.
    private static func locateBundle(of tier: NemotronTier, under root: URL) -> URL? {
        var level = [root]
        var fallback: URL?
        var depth = 0

        while level.isEmpty == false && depth <= 4 {
            var next: [URL] = []
            for directory in level {
                if looksLikeBundle(directory) {
                    if directory.lastPathComponent == tier.subdirectory { return directory }
                    if fallback == nil { fallback = directory }
                }
                // A directory we cannot read simply contributes no children.
                let children =
                    (try? FileManager.default.contentsOfDirectory(
                        at: directory, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles])) ?? []
                for child in children where isDirectory(at: child) {
                    next.append(child)
                }
            }
            level = next
            depth += 1
        }
        return fallback
    }

    private static func looksLikeBundle(_ directory: URL) -> Bool {
        guard let size = fileSize(at: directory.appendingPathComponent("metadata.json")), size > 0
        else { return false }
        if isDirectory(at: directory.appendingPathComponent("encoder")) { return true }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return children.contains { $0.hasSuffix(".mlmodelc") }
    }

    /// Rejects any relative path that could escape the directory it is joined to.
    ///
    /// Applied to zip entry names and to the Hugging Face listing alike: both are
    /// strings from elsewhere that this code turns into local file paths.
    private static func isSafeRelativePath(_ path: String) -> Bool {
        if path.isEmpty { return false }
        if path.hasPrefix("/") || path.hasPrefix("~") { return false }
        if path.contains("\\") { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." || component == ".." { return false }
        }
        return true
    }
}

// MARK: - Phase conveniences

extension ModelInstaller.Phase {
    /// 0…1 while downloading and 1 once ready, so a progress view can bind to it
    /// without taking the enum apart. `nil` when there is nothing to show.
    public var fraction: Double? {
        switch self {
        case .downloading(let completed, let total, _):
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(completed) / Double(total)))
        case .ready:
            return 1
        case .idle, .listing, .verifying, .failed:
            return nil
        }
    }

    /// True while the installer is busy, for disabling the install button.
    public var isWorking: Bool {
        switch self {
        case .listing, .downloading, .verifying: return true
        case .idle, .ready, .failed: return false
        }
    }
}

// MARK: - Supporting types

/// A failure worth another attempt: a timeout, a 5xx, a body that did not land.
private struct TransientFailure: Error {
    let reason: String
}

/// A failure no retry can fix: a 404 from a revision that dropped the tier, a
/// reply that is not what the API documents.
private struct PermanentFailure: Error {
    let reason: String
}

/// The byte tally shared by the concurrent downloads.
///
/// Progress is read straight off the live `URLSessionDownloadTask` counters
/// rather than from a delegate, so it is exact and needs no callback plumbing:
/// bytes of files that have fully landed, plus what the in-flight tasks have
/// received so far. Without this the bar would sit still for the ten minutes the
/// 589 MB encoder weights take, since that one file is 94% of a tier.
///
/// Invariant behind `@unchecked Sendable`: every stored property is read and
/// written only while `lock` is held, and none of them is handed out by
/// reference. `URLSessionDownloadTask` is itself `Sendable`, and
/// `countOfBytesReceived` is a plain counter read.
private final class ProgressTally: @unchecked Sendable {
    private let lock = NSLock()
    private var settledBytes: Int64
    private var currentFile: String
    private var active: [UUID: URLSessionDownloadTask] = [:]

    init(settledBytes: Int64, currentFile: String) {
        self.settledBytes = settledBytes
        self.currentFile = currentFile
    }

    /// The file named in the published phase. With four transfers at once this is
    /// whichever started most recently, which is what a one-line label can say.
    func beginFile(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        currentFile = name
    }

    func register(_ task: URLSessionDownloadTask, as id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        active[id] = task
    }

    func unregister(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        active[id] = nil
    }

    /// A file finished and was renamed into place; its bytes are now permanent.
    /// The task is unregistered separately, so a retry that starts over from zero
    /// never double-counts.
    func settle(_ bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        settledBytes += bytes
    }

    func read() -> (completed: Int64, file: String) {
        lock.lock()
        defer { lock.unlock() }
        let live = active.values.reduce(Int64(0)) { $0 + $1.countOfBytesReceived }
        return (settledBytes + live, currentFile)
    }
}

/// Collects a child process's standard error on a second thread.
///
/// It exists to be `Sendable` so the drain can hand the bytes back: the semaphore
/// in `run` orders the write before the read, and the lock keeps that ordering
/// true rather than merely likely.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        data = bytes
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Holds the `unzip` child so a cancellation can reach it across the detached
/// task that is blocked waiting on it.
///
/// Same early-cancel problem as `CancellableTaskBox`: the cancel can arrive
/// before the process is launched, so the box remembers it and terminates on
/// adoption. It reports the cancel afterwards too, so `run` can tell a child it
/// killed itself from one that failed on its own.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func adopt(_ process: Process) {
        lock.lock()
        let alreadyCancelled = cancelled
        self.process = process
        lock.unlock()
        if alreadyCancelled { Self.terminate(process) }
    }

    /// Forgets the child once it has been reaped, so a late cancel cannot signal a
    /// process identifier the system has since handed to somebody else.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        process = nil
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process { Self.terminate(process) }
    }

    private static func terminate(_ process: Process) {
        // `terminate()` raises an Objective-C exception for a process that was
        // never launched, and no `catch` in Swift could contain it.
        if process.isRunning { process.terminate() }
    }
}

/// Holds a `URLSessionDownloadTask` so a structured cancellation handler can
/// reach it.
///
/// `onCancel` can fire before the task has even been created, so the box also
/// remembers a cancel that arrived early and applies it on adoption — otherwise
/// a cancel in that window would be dropped and the transfer would run to
/// completion after the user gave up on it.
///
/// Invariant behind `@unchecked Sendable`: both stored properties are touched
/// only while `lock` is held, and `cancel()` is called outside it so a slow
/// `URLSession` teardown cannot block a reader.
private final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func adopt(_ task: URLSessionDownloadTask) {
        lock.lock()
        let alreadyCancelled = cancelled
        self.task = task
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
