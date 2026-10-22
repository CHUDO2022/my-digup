import DigUpKit
import Foundation
import LlamaRuntime

/// `digup analyze [<folder>...] [--out FILE] [--no-names]` (своя версия): what's in the pictures and videos the index
/// has read, as groups of alike files that a model names. Nothing is read again: the groups come from the vectors
/// indexing made (a picture's own, a video's frames averaged), and only a few pictures of each group are shown to the
/// namer (Gemma 3, `LlamaNamer`), which is downloaded the first time.
///
/// The result goes to FILE (default: analysis.json in the index folder) and stays there: a later run keeps the names of
/// groups that are still there (most of their samples the same), so only new groups are named again.
///
/// JSON lines on stdout:
///   {"event":"stage","stage":"reading|grouping|downloading|loading|naming"}
///   {"event":"progress","name":…,"bytes":n,"total":n,"all_bytes":n,"all_total":n}   the namer's download
///   {"event":"named","group":i,"name":…,"done":n,"total":n}
///   {"event":"done","file":…,"groups":n} | {"event":"error","message":…}
func analyze(_ args: Arguments) throws -> Int32 {
    let out = args.values["--out"].map(Arguments.folderURL)
        ?? args.indexFolder.appendingPathComponent("analysis.json")
    do {
        let result = try Analysis.run(args, out: out)
        emit(["event": "done", "file": out.path, "groups": result])
        return 0
    } catch {
        emit(["event": "error", "message": String("\(error)".prefix(500))])
        return 1
    }
}

private enum Analysis {
    struct Member {
        let path: String
        let kind: String
        let size: Int64
        let year: Int?
        var vector: [Float]
    }

    static let kinds = ["image", "screenshot", "video"]
    static let question = """
        Это фотографии из одной группы в личном фотоархиве. Придумай короткое название для этой группы на русском \
        языке: 2–5 слов о том, что у них общего (например: «Скриншоты переписок», «Дети на площадке», «Фото \
        документов», «Закаты на море»). Ответь только названием, без кавычек и пояснений.
        """

    static func run(_ args: Arguments, out: URL) throws -> Int {
        emit(["event": "stage", "stage": "reading"])
        let store = try args.store()
        let folders = args.positional.map { normalized(Arguments.folderURL($0).path) }
        var members = try readMembers(store, folders: folders)
        emit(["event": "stage", "stage": "grouping"])
        let (groups, misc) = cluster(&members)
        var previous = loadPrevious(out)
        var result: [[String: Any]] = groups.enumerated().map { index, group in
            describe(group, members: members, id: index)
        }
        if misc, !result.isEmpty {
            result[result.count - 1]["name"] = "Разное"
            result[result.count - 1]["misc"] = true
        }
        // The names a group had last time, when it's still there.
        for index in result.indices where result[index]["name"] == nil {
            let samples = Set(result[index]["samples"] as? [String] ?? [])
            if let match = previous.indices.max(by: { overlap(previous[$0], samples) < overlap(previous[$1], samples) }),
               overlap(previous[match], samples) >= 3, let name = previous[match]["name"] as? String {
                result[index]["name"] = name
                previous.remove(at: match)
            }
        }
        try write(result, members: members, folders: folders, to: out)
        let unnamed = result.indices.filter { result[$0]["name"] == nil }
        if !unnamed.isEmpty && !args.flags.contains("--no-names") {
            let folder = NamerFiles.folder
            if !NamerFiles.missing(in: folder).isEmpty {
                emit(["event": "stage", "stage": "downloading"])
                try download(into: folder)
            }
            emit(["event": "stage", "stage": "loading"])
            let namer = try LlamaNamer(folder: folder, log: args.indexFolder.appendingPathComponent("namer.log"))
            defer { namer.close() }
            emit(["event": "stage", "stage": "naming"])
            for (done, index) in unnamed.enumerated() {
                let pictures = (result[index]["namerSamples"] as? [String]) ?? []
                var name = "Видео"
                if !pictures.isEmpty, let answer = try? namer.answer(pictures: pictures, question: question) {
                    name = cleaned(answer)
                }
                result[index]["name"] = name
                emit(["event": "named", "group": index, "name": name, "done": done + 1, "total": unnamed.count])
                if (done + 1) % 5 == 0 { try write(result, members: members, folders: folders, to: out) }
            }
        }
        try write(result, members: members, folders: folders, to: out)
        return result.count
    }

    // MARK: Reading

    /// The pictures and videos under `folders` (all of them when empty) that have vectors, one vector each.
    static func readMembers(_ store: IndexStore, folders: [String]) throws -> [Member] {
        var byFile: [Int64: Member] = [:]
        try store.db.query("""
            SELECT id, path, kind, size, mtime, info FROM files
            WHERE state IN ('done', 'partial') AND kind IN ('image', 'screenshot', 'video')
            """) { row in
            let path = row.text(1) ?? ""
            guard folders.isEmpty || folders.contains(where: { under(normalized(path), $0) }) else { return }
            byFile[row.int(0)] = Member(path: path, kind: row.text(2) ?? "image", size: row.int(3),
                                        year: year(info: row.text(5), mtime: row.double(4)),
                                        vector: [Float](repeating: 0, count: 768))
        }
        var counts: [Int64: Int] = [:]
        try store.db.query("SELECT file, vec FROM segments WHERE vec IS NOT NULL AND kind IN ('image', 'frame')") { row in
            let file = row.int(0)
            guard var member = byFile[file], let blob = row.blob(1), blob.count == 768 * 2 else { return }
            byFile[file] = nil   // the vector is changed in place, not copied
            blob.withUnsafeBytes { raw in
                let halves = raw.bindMemory(to: Float16.self)
                for i in 0..<768 { member.vector[i] += Float(halves[i]) }
            }
            byFile[file] = member
            counts[file, default: 0] += 1
        }
        return byFile.compactMap { id, member in
            guard counts[id] != nil else { return nil }
            var member = member
            normalize(&member.vector)
            return member
        }.sorted { $0.path < $1.path }
    }

    /// The year it was taken: the camera's date ("2023:07:14 18:02:11"), else when the file was last changed.
    static func year(info: String?, mtime: Double) -> Int? {
        if let info, let data = info.data(using: .utf8),
           let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let taken = fields["taken"] as? String, let year = Int(taken.prefix(4)), year > 1900 {
            return year
        }
        guard mtime > 0 else { return nil }
        return Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: mtime))
    }

    static func normalized(_ path: String) -> String {
        #if os(Windows)
        return path.replacingOccurrences(of: "\\", with: "/").lowercased()
        #else
        return path
        #endif
    }

    static func under(_ path: String, _ folder: String) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix)
    }

    // MARK: Grouping

    /// Spherical k-means (k-means++ start, fixed seed, so the same files give the same groups): about √n × 0.8 groups,
    /// 2 to 60. Groups of fewer than 3 files end up together, last, as one "Разное".
    static func cluster(_ members: inout [Member]) -> (groups: [[Int]], misc: Bool) {
        let n = members.count
        guard n > 0 else { return ([], false) }
        let k = min(n, max(2, min(60, Int((Double(n).squareRoot() * 0.8).rounded()))))
        guard n >= 6 else { return ([Array(0..<n)], false) }
        var random = SeededRandom(seed: 42)
        var centers: [[Float]] = [members[Int(random.next() % UInt64(n))].vector]
        var nearest = members.map { 1 - dot($0.vector, centers[0]) }
        while centers.count < k {
            let total = nearest.reduce(0) { $0 + Double(max($1, 0)) }
            var pick = Double(random.next() % 1_000_000) / 1_000_000 * total
            var chosen = n - 1
            for i in 0..<n {
                pick -= Double(max(nearest[i], 0))
                if pick <= 0 { chosen = i; break }
            }
            centers.append(members[chosen].vector)
            for i in 0..<n { nearest[i] = min(nearest[i], 1 - dot(members[i].vector, centers.last!)) }
        }
        var assignment = [Int](repeating: 0, count: n)
        for _ in 0..<25 {
            var changed = false
            for i in 0..<n {
                var best = 0, bestScore = -Float.infinity
                for c in 0..<centers.count {
                    let score = dot(members[i].vector, centers[c])
                    if score > bestScore { (best, bestScore) = (c, score) }
                }
                if assignment[i] != best { assignment[i] = best; changed = true }
            }
            var sums = [[Float]](repeating: [Float](repeating: 0, count: 768), count: centers.count)
            for i in 0..<n {
                for d in 0..<768 { sums[assignment[i]][d] += members[i].vector[d] }
            }
            for c in centers.indices where sums[c].contains(where: { $0 != 0 }) {
                normalize(&sums[c])
                centers[c] = sums[c]
            }
            if !changed { break }
        }
        var groups = [[Int]](repeating: [], count: centers.count)
        for i in 0..<n { groups[assignment[i]].append(i) }
        // Closest to the center first: the samples, and the order the window shows.
        for c in groups.indices {
            groups[c].sort { dot(members[$0].vector, centers[c]) > dot(members[$1].vector, centers[c]) }
        }
        let small = groups.filter { !$0.isEmpty && $0.count < 3 }.flatMap { $0 }
        var kept = groups.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
        if !small.isEmpty { kept.append(small) }
        return (kept, !small.isEmpty)
    }

    static func describe(_ group: [Int], members: [Member], id: Int) -> [String: Any] {
        var kinds: [String: Int] = [:], years: [String: Int] = [:], bytes: Int64 = 0
        for i in group {
            kinds[members[i].kind, default: 0] += 1
            if let year = members[i].year { years[String(year), default: 0] += 1 }
            bytes += members[i].size
        }
        let pictures = group.filter { members[$0].kind != "video" }
        var fields: [String: Any] = [
            "id": id, "count": group.count, "bytes": bytes, "kinds": kinds, "years": years,
            "samples": group.prefix(9).map { members[$0].path },
            "namerSamples": pictures.prefix(4).map { members[$0].path },
            "members": group.map { members[$0].path },
        ]
        return fields
    }

    // MARK: Names

    static func loadPrevious(_ file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return saved["groups"] as? [[String: Any]] ?? []
    }

    static func overlap(_ group: [String: Any], _ samples: Set<String>) -> Int {
        Set(group["samples"] as? [String] ?? []).intersection(samples).count
    }

    /// The model's answer as a name: one line, no quotes or final period, at most 60 characters.
    static func cleaned(_ answer: String) -> String {
        var name = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? answer
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " \t«»\"'“”„*.:"))
        if name.lowercased().hasPrefix("название") {
            name = String(name.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty { return "Без названия" }
        return String(name.prefix(60))
    }

    static func download(into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var done = NamerFiles.totalBytes - NamerFiles.missing(in: folder).reduce(0) { $0 + $1.bytes }
        for file in NamerFiles.missing(in: folder) {
            var failures = 0
            while true {
                let outcome = fetch(file, into: folder, before: done)
                if case .downloaded(let partial) = outcome {
                    guard try ModelFiles.sha256(of: partial) == file.sha256 else {
                        try? FileManager.default.removeItem(at: partial)
                        failures += 1
                        guard failures < 3 else { throw CLIError("\(file.name) arrived damaged, three times") }
                        continue
                    }
                    try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent(file.name))
                    done += file.bytes
                    break
                }
                if case .failed(let message, let retry) = outcome {
                    failures += 1
                    guard retry, failures <= 20 else { throw CLIError(message) }
                    Thread.sleep(forTimeInterval: Double(min(60, 1 << min(failures, 6))))
                }
            }
        }
    }

    private static func fetch(_ file: ModelFiles.File, into folder: URL, before done: Int64) -> FileFetcher.Outcome {
        let finished = DispatchSemaphore(value: 0)
        let box = Box()
        let fetcher = FileFetcher(file: file, folder: folder, progress: { written in
            emit(["event": "progress", "name": file.name, "bytes": written, "total": file.bytes,
                  "all_bytes": done + written, "all_total": NamerFiles.totalBytes])
        }, waiting: {
            emit(["event": "waiting"])
        }, done: { outcome in
            box.outcome = outcome
            finished.signal()
        })
        fetcher.start()
        finished.wait()
        return box.outcome ?? .failed("the download stopped", retry: true)
    }

    private final class Box: @unchecked Sendable { var outcome: FileFetcher.Outcome? }

    // MARK: Output

    static func write(_ groups: [[String: Any]], members: [Member], folders: [String], to file: URL) throws {
        var kinds: [String: Int] = [:], years: [String: Int] = [:], bytes: Int64 = 0
        for member in members {
            kinds[member.kind, default: 0] += 1
            if let year = member.year { years[String(year), default: 0] += 1 }
            bytes += member.size
        }
        let sizes = Dictionary(members.map { ($0.path, $0.size) }, uniquingKeysWith: { first, _ in first })
        let kindOf = Dictionary(members.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let saved: [String: Any] = [
            "version": 1,
            "created": ISO8601DateFormatter().string(from: Date()),
            "folders": folders,
            "files": members.count, "bytes": bytes, "kinds": kinds, "years": years,
            "groups": groups.map { group -> [String: Any] in
                var group = group
                group["members"] = (group["members"] as? [String] ?? []).map { path -> [String: Any] in
                    ["path": path, "size": sizes[path] ?? 0, "kind": kindOf[path] ?? "image"]
                }
                return group
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = file.appendingPathExtension("partial")
        try data.write(to: partial)
        _ = try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: partial, to: file)
    }

    // MARK: Math

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                var sum: Float = 0
                for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
                return sum
            }
        }
    }

    static func normalize(_ vector: inout [Float]) {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return }
        for i in vector.indices { vector[i] /= length }
    }
}

/// A small fixed-seed generator (SplitMix64): the same files group the same way every run.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
