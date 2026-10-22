import CLlama
import DigUpKit
import Foundation

/// Gemma 3 4B on llama.cpp, looking at a few pictures and answering about them (своя версия: the names of the
/// analysis's groups). The pictures go in through mtmd, the answer comes out greedily, a few words long.
///
/// One question at a time; `close()` frees the model (about 3.5 GB).
public final class LlamaNamer {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private let vocab: OpaquePointer?
    private static let batchTokens: Int32 = 1024   // an image is 256 tokens and must fit one micro-batch

    /// `folder`: where `NamerFiles` are. `log`: where llama.cpp's warnings and errors go (stderr when nil).
    public init(folder: URL, log: URL? = nil) throws {
        LlamaLog.shared.send(to: log)
        _ = LlamaEmbedder.backend
        let textFile = folder.appendingPathComponent(NamerFiles.text.name)
        let mediaFile = folder.appendingPathComponent(NamerFiles.media.name)
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = LlamaEmbedder.cpuOnly ? 0 : 999
        guard let model = llama_model_load_from_file(textFile.path, modelParams) else {
            throw WorkerError.failed("can't load \(textFile.path)")
        }
        var params = llama_context_default_params()
        params.n_ctx = 4096
        params.n_batch = UInt32(Self.batchTokens)
        params.n_ubatch = UInt32(Self.batchTokens)
        #if !os(macOS)
        params.n_threads = LlamaEmbedder.threads
        params.n_threads_batch = LlamaEmbedder.threads
        #endif
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw WorkerError.failed("can't create a llama.cpp context")
        }
        var mediaParams = mtmd_context_params_default()
        mediaParams.use_gpu = !LlamaEmbedder.cpuOnly
        mediaParams.print_timings = false
        #if !os(macOS)
        mediaParams.n_threads = LlamaEmbedder.threads
        #endif
        guard let media = mtmd_init_from_file(mediaFile.path, model, mediaParams) else {
            llama_free(context)
            llama_model_free(model)
            throw WorkerError.failed("can't load \(mediaFile.path)")
        }
        self.model = model
        self.context = context
        self.media = media
        vocab = llama_model_get_vocab(model)
    }

    deinit { close() }

    public func close() {
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (media, context, model) = (nil, nil, nil)
    }

    /// Shows the model `pictures` (those that can't be read are left out) and asks `question`; its answer's first
    /// line, at most `maxTokens` long.
    public func answer(pictures: [String], question: String, maxTokens: Int = 48) throws -> String {
        guard let context, let media else { throw WorkerError.failed("the namer is closed") }
        var bitmaps: [OpaquePointer?] = []
        defer { for bitmap in bitmaps { if let bitmap { mtmd_bitmap_free(bitmap) } } }
        for path in pictures {
            if let bitmap = load(path) { bitmaps.append(bitmap) }
        }
        guard !bitmaps.isEmpty else { throw LlamaError("none of the pictures could be read") }
        let marker = String(cString: mtmd_default_marker())
        let prompt = "<start_of_turn>user\n" + String(repeating: marker, count: bitmaps.count) + "\n" + question
            + "<end_of_turn>\n<start_of_turn>model\n"
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        let count = bitmaps.count
        let status = prompt.withCString { text in
            var input = mtmd_input_text(text: text, text_len: strlen(text), add_special: true, parse_special: true)
            return mtmd_tokenize(media, chunks, &input, &bitmaps, count)
        }
        guard status == 0 else { throw LlamaError("can't tokenize the question (\(status))") }
        llama_memory_clear(llama_get_memory(context), true)
        var past: llama_pos = 0
        guard mtmd_helper_eval_chunks(media, context, chunks, 0, 0, Self.batchTokens, true, &past) == 0 else {
            throw LlamaError("the model failed on the pictures")
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        var bytes: [UInt8] = []
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(token)
            if let newline = bytes.firstIndex(of: 10), bytes[..<newline].contains(where: { $0 > 32 }) {
                bytes.removeSubrange(newline...)
                break
            }
            let decoded = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            guard decoded == 0 else { throw LlamaError("llama_decode failed (\(decoded))") }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }
    }

    /// A picture as mtmd reads it (stb_image); mtmd resizes it for the model. Nil when it can't be read.
    private func load(_ path: String) -> OpaquePointer? {
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let wrapper = bytes.withUnsafeBytes { buffer in
            mtmd_helper_bitmap_init_from_buf(media, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, false,
                                             mtmd_helper_init_opt_default())
        }
        if let video = wrapper.video_ctx {
            if let bitmap = wrapper.bitmap { mtmd_bitmap_free(bitmap) }
            mtmd_helper_video_free(video)
            return nil
        }
        guard let bitmap = wrapper.bitmap else { return nil }
        guard !mtmd_bitmap_is_audio(bitmap) else {
            mtmd_bitmap_free(bitmap)
            return nil
        }
        return bitmap
    }
}
