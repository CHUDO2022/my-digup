#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// The EmbeddingGemma 2 files the app runs: ggml-org's Q8_0 GGUF conversion at one pinned revision of the repo (made
/// from google/embeddinggemma-2 at 914f7f8, the weights the mlx-vlm reference runs). Never the F16 files: the model's
/// activations overflow float16.
///
/// The app downloads them on first launch (`ModelDownload`) and the helper loads them (`LlamaModels`); this is what
/// both agree on.
public enum ModelFiles {
    public static let repository = "ggml-org/embeddinggemma-2-GGUF"
    public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    public struct File: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
        /// "repository@revision" when the file isn't EmbeddingGemma's (the namer's, `NamerFiles`).
        var source: String? = nil

        /// Hugging Face's address for this file at the pinned revision (it redirects to a CDN that takes HTTP ranges).
        public var url: URL {
            let (repository, revision) = source.map { source -> (String, String) in
                let parts = source.split(separator: "@", maxSplits: 1).map(String.init)
                return (parts[0], parts[1])
            } ?? (ModelFiles.repository, ModelFiles.revision)
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(name)")!
        }
    }

    /// The text model (310 MB): all that queries need.
    public static let text = File(name: "embeddinggemma-2-Q8_0.gguf", bytes: 309_855_456,
                                  sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
    /// The image and audio encoders (555 MB).
    public static let media = File(name: "mmproj-embeddinggemma-2-Q8_0.gguf", bytes: 554_821_024,
                                   sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
    /// In download order.
    public static let all = [text, media]
    public static let totalBytes = all.reduce(0) { $0 + $1.bytes }

    /// Where the app keeps them (`AppPaths`).
    public static let installed = AppPaths.applicationSupport.appendingPathComponent("Models")

    /// The pinned revision's folder in the Hugging Face cache (`hf download` puts the files there): `$HF_HUB_CACHE`,
    /// `$HF_HOME/hub`, or `~/.cache/huggingface/hub`.
    public static var huggingFaceSnapshot: URL {
        let environment = ProcessInfo.processInfo.environment
        let hub = environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? environment["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        return hub.appendingPathComponent("models--\(repository.replacingOccurrences(of: "/", with: "--"))/snapshots/\(revision)")
    }

    /// `file` in the Hugging Face cache, when it's there at the right size (its checksum is for the caller to check).
    public static func cachedCopy(of file: File) -> URL? {
        let url = huggingFaceSnapshot.appendingPathComponent(file.name).resolvingSymlinksInPath()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size == file.bytes ? url : nil
    }

    /// The files that aren't in `folder` yet. Only verified files get their final name, so being there is enough.
    public static func missing(in folder: URL) -> [File] {
        all.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
    }

    /// The SHA-256 of a file as lowercase hex, read in 8 MB pieces (a 555 MB file takes about half a second).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try autoreleasepool { () -> Bool in
                guard let data = try handle.read(upToCount: 8 << 20), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The model that names the analysis's groups of pictures (своя версия): Gemma 3 4B with its image encoder, ggml-org's
/// GGUF at a pinned revision. Q4_K_M keeps it at 2.5 GB, so it fits a 6 GB GPU beside nothing else (the analysis
/// doesn't load EmbeddingGemma). Downloaded by `digup analyze` the first time it names groups.
public enum NamerFiles {
    static let source = "ggml-org/gemma-3-4b-it-GGUF@d0976223747697cb51e056d85c532013931fe52e"
    public static let text = ModelFiles.File(name: "gemma-3-4b-it-Q4_K_M.gguf", bytes: 2_489_757_856,
                                             sha256: "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863",
                                             source: source)
    public static let media = ModelFiles.File(name: "mmproj-model-f16.gguf", bytes: 851_251_104,
                                              sha256: "8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb",
                                              source: source)
    public static let all = [text, media]
    public static let totalBytes = all.reduce(0) { $0 + $1.bytes }

    /// Beside EmbeddingGemma's files: `$DIGUP_MODELS/Namer` when the app chose the models' folder, else
    /// DigUp's own Models/Namer.
    public static var folder: URL {
        if let chosen = ProcessInfo.processInfo.environment["DIGUP_MODELS"], !chosen.isEmpty {
            return URL(fileURLWithPath: chosen).appendingPathComponent("Namer")
        }
        return ModelFiles.installed.appendingPathComponent("Namer")
    }

    public static func missing(in folder: URL) -> [ModelFiles.File] {
        all.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
    }
}
