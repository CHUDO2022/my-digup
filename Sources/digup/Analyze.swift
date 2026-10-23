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
        let mtime: Double
        let duration: Double?
        var vector: [Float]
    }

    static let kinds = ["image", "screenshot", "video"]
    static let question = """
        Это фотографии и кадры из видео одной группы в личном архиве. Придумай короткое название для этой группы на русском \
        языке: 2–5 слов о том, что у них общего (например: «Скриншоты переписок», «Дети на площадке», «Фото \
        документов», «Закаты на море»). Ответь только названием, без кавычек и пояснений.
        """

    static func sectionQuestion(_ names: [String]) -> String {
        "Это примеры из нескольких похожих групп личного фотоархива: " + names.prefix(8).joined(separator: "; ")
            + ". Придумай общее короткое название для раздела, который их объединяет, на русском языке: 1–3 слова "
            + "(например: «Дети», «Путешествия», «Документы и чеки»). Ответь только названием, без кавычек."
    }

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
        var extras: [String: Any] = [:]
        try write(result, members: members, folders: folders, extras: extras, to: out)
        extras["junk"] = Junk.find(members, groups: groups, cache: args.indexFolder.appendingPathComponent("quality.json"))
        // Groups that look alike, merged step by step: the window cuts this anywhere (bigger or finer groups), and
        // the cut into a handful of sections gets names too.
        let merges = Sections.merges(groups, members: members, misc: misc)
        extras["merges"] = merges.map { merge -> [String: Any] in
            ["a": merge.a, "b": merge.b, "into": merge.into, "similarity": Double(merge.similarity)]
        }
        let sections = Sections.cut(merges, groups: groups.count - (misc ? 1 : 0))
        var sectionNames: [Int: String] = [:]
        try write(result, members: members, folders: folders, extras: extras, to: out)
        let unnamed = result.indices.filter { result[$0]["name"] == nil }
        let unnamedSections = sections.indices.filter { sections[$0].count > 1 }
        if !args.flags.contains("--no-names") && (!unnamed.isEmpty || !unnamedSections.isEmpty) {
            let folder = NamerFiles.folder
            if !NamerFiles.missing(in: folder).isEmpty {
                emit(["event": "stage", "stage": "downloading"])
                try download(into: folder)
            }
            emit(["event": "stage", "stage": "loading"])
            let namer = try LlamaNamer(folder: folder, log: args.indexFolder.appendingPathComponent("namer.log"))
            defer { namer.close() }
            let frames = args.indexFolder.appendingPathComponent("namer-pictures")
            try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: frames) }
            let byPath = Dictionary(members.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            // What the model looks at: a JPEG of each picture (HEIC too), a frame from the middle of each video.
            func pictures(_ paths: [String]) -> [String] {
                paths.compactMap { path in
                    guard let member = byPath[path] else { return nil }
                    if member.kind == "video" {
                        return try? PreviewImages.make(.video, of: path, at: max(0.5, (member.duration ?? 2) / 2),
                                                       pixels: 768, in: frames)
                    }
                    return try? PreviewImages.make(.image, of: path, at: nil, pixels: 768, in: frames)
                }
            }
            emit(["event": "stage", "stage": "naming"])
            let total = unnamed.count + unnamedSections.count
            for (done, index) in unnamed.enumerated() {
                let shown = pictures((result[index]["namerSamples"] as? [String]) ?? [])
                var name = "Без названия"
                if !shown.isEmpty, let answer = try? namer.answer(pictures: shown, question: question) {
                    name = cleaned(answer)
                }
                result[index]["name"] = name
                emit(["event": "named", "group": index, "name": name, "done": done + 1, "total": total])
                if (done + 1) % 5 == 0 { try write(result, members: members, folders: folders, extras: extras, to: out) }
            }
            for (done, index) in unnamedSections.enumerated() {
                // The biggest groups of the section: one picture and the name of each.
                let parts = sections[index].sorted { (result[$0]["count"] as? Int ?? 0) > (result[$1]["count"] as? Int ?? 0) }
                let names = parts.compactMap { result[$0]["name"] as? String }
                let shown = pictures(parts.prefix(4).compactMap { ((result[$0]["namerSamples"] as? [String]) ?? []).first })
                let ask = Self.sectionQuestion(names)
                var name = names.first ?? "Раздел"
                if !shown.isEmpty, let answer = try? namer.answer(pictures: shown, question: ask) { name = cleaned(answer) }
                sectionNames[index] = name
                emit(["event": "named", "section": index, "name": name, "done": unnamed.count + done + 1, "total": total])
            }
        }
        extras["sections"] = sections.indices.map { index -> [String: Any] in
            let fallback = result[sections[index][0]]["name"] as? String ?? "Раздел"
            return ["groups": sections[index].sorted(), "name": sectionNames[index] ?? fallback]
        }
        try write(result, members: members, folders: folders, extras: extras, to: out)
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
                                        year: year(info: row.text(5), mtime: row.double(4)), mtime: row.double(4),
                                        duration: duration(info: row.text(5)),
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

    static func duration(info: String?) -> Double? {
        guard let info, let data = info.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (fields["duration"] as? String).flatMap(Double.init) ?? (fields["duration"] as? NSNumber)?.doubleValue
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
            "namerSamples": (pictures.count >= 3 ? pictures : group).prefix(4).map { members[$0].path },
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

    static func write(_ groups: [[String: Any]], members: [Member], folders: [String], extras: [String: Any],
                      to file: URL) throws {
        var kinds: [String: Int] = [:], years: [String: Int] = [:], bytes: Int64 = 0
        for member in members {
            kinds[member.kind, default: 0] += 1
            if let year = member.year { years[String(year), default: 0] += 1 }
            bytes += member.size
        }
        let sizes = Dictionary(members.map { ($0.path, $0.size) }, uniquingKeysWith: { first, _ in first })
        let kindOf = Dictionary(members.map { ($0.path, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var saved: [String: Any] = [
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
        for (key, value) in extras { saved[key] = value }
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

// MARK: Junk

extension Analysis {
    /// What may be worth removing (своя версия, "Мусор"): exact copies, series of nearly the same shot, blurry, dark or
    /// washed-out pictures, short accidental videos, screenshots and the heaviest videos. Nothing is removed here: the
    /// window shows the lists and the person decides. Each list of extras names the copy worth keeping.
    enum Junk {
        static let blurryBelow = 40.0          // Laplacian variance on the ~320-pixel grid
        static let darkMean = 28.0
        static let washedOut = 0.85       // share of nearly white pixels
        static let shortVideo = 3.0       // seconds
        static let seriesCosine: Float = 0.96

        static func find(_ members: [Member], groups: [[Int]], cache: URL) -> [String: Any] {
            emit(["event": "stage", "stage": "duplicates"])
            let duplicates = exactCopies(members)
            let copies = Set(duplicates.flatMap { $0["extra"] as? [String] ?? [] })
            emit(["event": "stage", "stage": "quality"])
            let quality = measure(members, cache: cache)
            let series = nearCopies(members, groups: groups, quality: quality, leaving: copies)
            var blurry: [String] = [], dark: [String] = [], washed: [String] = []
            for member in members where member.kind == "image" {
                guard let q = quality[member.path] else { continue }
                if q.brightness < darkMean || q.dark > 0.9 { dark.append(member.path) }
                else if q.bright > washedOut { washed.append(member.path) }
                else if q.sharpness < blurryBelow { blurry.append(member.path) }
            }
            let shortVideos = members.filter { $0.kind == "video" && ($0.duration ?? 99) < shortVideo }.map(\.path)
            let screenshots = members.filter { $0.kind == "screenshot" }.sorted { $0.mtime < $1.mtime }.map(\.path)
            let heavy = members.filter { $0.kind == "video" && $0.size >= 100 << 20 }.sorted { $0.size > $1.size }
                .prefix(100).map(\.path)
            return ["duplicates": duplicates, "series": series, "blurry": blurry, "dark": dark, "washed": washed,
                    "shortVideos": shortVideos, "screenshots": screenshots, "heavy": heavy,
                    "measured": quality.count]
        }

        /// Files with the same bytes: same size first, then the same SHA-256. The oldest copy is the one to keep.
        static func exactCopies(_ members: [Member]) -> [[String: Any]] {
            var bySize: [Int64: [Member]] = [:]
            for member in members where member.size > 0 { bySize[member.size, default: []].append(member) }
            var found: [[String: Any]] = []
            for (_, same) in bySize where same.count > 1 {
                var byHash: [String: [Member]] = [:]
                for member in same {
                    guard let hash = try? ModelFiles.sha256(of: URL(fileURLWithPath: member.path)) else { continue }
                    byHash[hash, default: []].append(member)
                }
                for (_, copies) in byHash where copies.count > 1 {
                    let sorted = copies.sorted { ($0.mtime, $0.path.count) < ($1.mtime, $1.path.count) }
                    found.append(["keep": sorted[0].path, "extra": sorted.dropFirst().map(\.path)])
                }
            }
            return found.sorted { ($0["keep"] as? String ?? "") < ($1["keep"] as? String ?? "") }
        }

        /// Pictures of one group whose vectors nearly match (series of the same shot), joined into sets. The sharpest
        /// (else the largest) is the one to keep.
        static func nearCopies(_ members: [Member], groups: [[Int]], quality: [String: PictureInfo],
                               leaving copies: Set<String>) -> [[String: Any]] {
            var parent = Array(0..<members.count)
            func root(_ i: Int) -> Int {
                var i = i
                while parent[i] != i {
                    parent[i] = parent[parent[i]]
                    i = parent[i]
                }
                return i
            }
            for group in groups {
                let pictures = group.filter { members[$0].kind != "video" && !copies.contains(members[$0].path) }
                for (a, i) in pictures.enumerated() {
                    for j in pictures[(a + 1)...] where Analysis.dot(members[i].vector, members[j].vector) >= seriesCosine {
                        let (ri, rj) = (root(i), root(j))
                        if ri != rj { parent[ri] = rj }
                    }
                }
            }
            var sets: [Int: [Int]] = [:]
            for i in members.indices { sets[root(i), default: []].append(i) }
            var found: [[String: Any]] = []
            for (_, set) in sets where set.count > 1 {
                var best = set[0]
                for candidate in set.dropFirst() {
                    let qa = quality[members[best].path], qb = quality[members[candidate].path]
                    let better: Bool
                    if let qa, let qb, abs(qa.sharpness - qb.sharpness) > 5 {
                        better = qb.sharpness > qa.sharpness
                    } else {
                        better = members[candidate].size > members[best].size
                    }
                    if better { best = candidate }
                }
                found.append(["keep": members[best].path,
                              "extra": set.filter { $0 != best }.map { members[$0].path }.sorted()])
            }
            return found.sorted { ($0["keep"] as? String ?? "") < ($1["keep"] as? String ?? "") }
        }

        struct PictureInfo: Codable {
            let size: Int64
            let mtime: Double
            let sharpness: Double
            let brightness: Double
            let dark: Double
            let bright: Double
        }

        /// Sharpness and brightness of every photo (not screenshots, not videos), kept in `cache` by path, size and
        /// time, so a later run reads only new pictures. Several at once: decoding is most of the time.
        static func measure(_ members: [Member], cache: URL) -> [String: PictureInfo] {
            var known = (try? JSONDecoder().decode([String: PictureInfo].self, from: Data(contentsOf: cache))) ?? [:]
            let photos = members.filter { $0.kind == "image" }
            let missing = photos.filter { member in
                guard let entry = known[member.path] else { return true }
                return entry.size != member.size || entry.mtime != member.mtime
            }
            #if !canImport(ImageIO)
            let results = Results()
            let workers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                var index = worker
                while index < missing.count {
                    let member = missing[index]
                    let measured = PictureQuality.measure(member.path).map {
                        PictureInfo(size: member.size, mtime: member.mtime, sharpness: $0.sharpness,
                                    brightness: $0.brightness, dark: $0.dark, bright: $0.bright)
                    }
                    results.add(member.path, measured, of: missing.count)
                    index += workers
                }
            }
            for (path, info) in results.measured { known[path] = info }
            #endif
            let present = Set(photos.map(\.path))
            known = known.filter { present.contains($0.key) }
            if !missing.isEmpty, let data = try? JSONEncoder().encode(known) { try? data.write(to: cache) }
            return known
        }

        /// What the workers measured, under a lock.
        final class Results: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var measured: [String: PictureInfo] = [:]
            private var done = 0

            func add(_ path: String, _ info: PictureInfo?, of total: Int) {
                lock.withLock {
                    if let info { measured[path] = info }
                    done += 1
                    if done % 50 == 0 || done == total { emit(["event": "measured", "done": done, "total": total]) }
                }
            }
        }
    }
}

// MARK: Sections

extension Analysis {
    /// Bigger groups out of the small ones (своя версия): the groups whose files look most alike merge first, then
    /// the next pair, until one is left. The merges are kept in order, so the window can stop anywhere: more steps
    /// make bigger groups, fewer keep them fine. "Разное" stays out.
    enum Sections {
        struct Merge {
            let a: Int
            let b: Int
            let into: Int
            let similarity: Float
        }

        static func merges(_ groups: [[Int]], members: [Member], misc: Bool) -> [Merge] {
            let count = groups.count - (misc ? 1 : 0)
            guard count > 1 else { return [] }
            var sums: [Int: [Float]] = [:]
            for index in 0..<count {
                var sum = [Float](repeating: 0, count: 768)
                for member in groups[index] {
                    for d in 0..<768 { sum[d] += members[member].vector[d] }
                }
                sums[index] = sum
            }
            var merges: [Merge] = []
            var next = count
            while sums.count > 1 {
                let ids = sums.keys.sorted()
                var best: (Int, Int, Float) = (ids[0], ids[1], -2)
                for (position, a) in ids.enumerated() {
                    for b in ids[(position + 1)...] {
                        let similarity = cosine(sums[a]!, sums[b]!)
                        if similarity > best.2 { best = (a, b, similarity) }
                    }
                }
                var merged = sums[best.0]!
                let other = sums[best.1]!
                for d in 0..<768 { merged[d] += other[d] }
                sums[best.0] = nil
                sums[best.1] = nil
                sums[next] = merged
                merges.append(Merge(a: best.0, b: best.1, into: next, similarity: best.2))
                next += 1
            }
            return merges
        }

        /// The groups (by index) of each section: a handful, about a quarter as many as the groups, 2 to 12.
        static func cut(_ merges: [Merge], groups count: Int) -> [[Int]] {
            guard count > 4 else { return (0..<count).map { [$0] } }
            let target = max(2, min(12, Int((Double(count) / 4).rounded())))
            var parts: [Int: [Int]] = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, [$0]) })
            for merge in merges.prefix(count - target) {
                parts[merge.into] = (parts[merge.a] ?? []) + (parts[merge.b] ?? [])
                parts[merge.a] = nil
                parts[merge.b] = nil
            }
            return parts.values.sorted { $0.count > $1.count }
        }

        static func cosine(_ a: [Float], _ b: [Float]) -> Float {
            let ab = Analysis.dot(a, b), aa = Analysis.dot(a, a), bb = Analysis.dot(b, b)
            guard aa > 0, bb > 0 else { return 0 }
            return ab / (aa.squareRoot() * bb.squareRoot())
        }
    }
}
