import Foundation
import AVFoundation

/// 自动阅读（朗读）：把章节文字交给系统语音合成，读完整章后由调用方切到下一章。
///
/// 说明：
/// - 使用 AVSpeechSynthesizer，离线可用、无需额外权限。
/// - 长文本会按段落切成若干片段依次朗读，便于暂停 / 跳过与进度统计。
/// - 回调可能发生在非主线程，调用方需自行切回主线程更新界面。
final class AutoReader: NSObject {

    /// 全部片段朗读完毕
    var onFinish: (() -> Void)?
    /// 朗读进度（0...1）与已读字数
    var onProgress: ((Double, Int) -> Void)?
    /// 失败（通常是没有可用语音）
    var onError: ((String) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var totalCharacters = 0
    private var spokenCharacters = 0
    private var pendingFinish = false

    /// 语音语言，跟随系统中文语音
    var language = "zh-CN"

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// 是否处于暂停（可继续）
    var isPaused: Bool { synthesizer.isPaused }

    /// 设备是否有可用语音
    static var isAvailable: Bool { !AVSpeechSynthesisVoice.speechVoices().isEmpty }

    /// 开始朗读。wordsPerMinute 为期望语速（字 / 分钟），内部换算成系统速率。
    func speak(_ text: String, wordsPerMinute: Double) {
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard AutoReader.isAvailable else {
            onError?("当前设备没有可用的语音，请在系统设置中下载中文语音。")
            return
        }

        configureAudioSession()

        let chunks = AutoReader.split(trimmed)
        guard !chunks.isEmpty else { return }

        totalCharacters = trimmed.count
        spokenCharacters = 0
        pendingFinish = true

        let rate = AutoReader.systemRate(for: wordsPerMinute)
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = AVSpeechSynthesisVoice(language: language)
            utterance.rate = rate
            utterance.pitchMultiplier = 1.0
            utterance.postUtteranceDelay = 0.08
            synthesizer.speak(utterance)
        }
    }

    /// 停止朗读
    func stop() {
        pendingFinish = false
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// 暂停 / 继续
    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
    }

    // MARK: 工具

    /// 让朗读在静音模式下也有声音，并允许后台继续
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    /// 系统速率区间是 0.0...1.0（默认 0.5 接近正常语速）。
    /// 这里把“字 / 分钟”换算过去，以 600 字 / 分钟对应 1.0。
    static func systemRate(for wordsPerMinute: Double) -> Float {
        let clamped = max(120, min(wordsPerMinute, 900))
        let rate = clamped / 600
        return Float(max(0.1, min(rate, 1.0)))
    }

    /// 按段落切分：短段落合并成一片（片内用换行分隔，朗读时自然停顿），
    /// 单段过长时再按标点切开，保证每片不超过 320 字。
    static func split(_ text: String) -> [String] {
        var result: [String] = []
        var buffer = ""

        func flush() {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            buffer = ""
        }

        for line in text.components(separatedBy: CharacterSet.newlines) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }

            if value.count > 320 {
                flush()
                result.append(contentsOf: splitLongParagraph(value))
                continue
            }

            if buffer.isEmpty {
                buffer = value
            } else if buffer.count + value.count + 1 > 320 {
                flush()
                buffer = value
            } else {
                buffer += "\n" + value
            }
        }
        flush()
        return result
    }

    private static func splitLongParagraph(_ text: String) -> [String] {
        let punctuation = CharacterSet(charactersIn: "。！？；.!?;…")
        var result: [String] = []
        var buffer = ""
        for character in text {
            buffer.append(character)
            if punctuation.contains(character.unicodeScalars.first ?? " ") || buffer.count >= 200 {
                let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result.append(value) }
                buffer = ""
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}

extension AutoReader: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        spokenCharacters += utterance.speechString.count
        let progress = totalCharacters > 0
            ? min(1.0, Double(spokenCharacters) / Double(totalCharacters))
            : 1.0
        onProgress?(progress, spokenCharacters)

        // 所有片段读完后才算本章结束
        guard synthesizer.isSpeaking == false, pendingFinish else { return }
        pendingFinish = false
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        pendingFinish = false
    }
}
