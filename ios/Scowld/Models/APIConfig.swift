import Foundation

// MARK: - AI Provider Configuration

enum AIProvider: String, CaseIterable, Codable, Sendable {
    case gemini
    case openai
    case claude
    case ollama
    case groq
    case openRouter
    case xai
    case togetherAI
    case huggingFace
    case veniceAI
    case moonshot
    case deepseek
    case glm

    var displayName: String {
        switch self {
        case .gemini: "Google Gemini"
        case .openai: "OpenAI"
        case .claude: "Anthropic Claude"
        case .ollama: "Ollama (Local)"
        case .groq: "Groq"
        case .openRouter: "OpenRouter"
        case .xai: "xAI (Grok)"
        case .togetherAI: "Together AI"
        case .huggingFace: "Hugging Face"
        case .veniceAI: "Venice AI"
        case .moonshot: "Moonshot AI"
        case .deepseek: "DeepSeek"
        case .glm: "Zhipu GLM"
        }
    }

    var availableModels: [String] {
        switch self {
        case .gemini:
            HostedServiceConfig.geminiFallbackModels
        case .openai:
            [
                "gpt-5.5",
                "gpt-5.4",
                "gpt-5.4-mini",
                "gpt-5.4-nano",
                "gpt-4.1",
                "gpt-4.1-mini",
                "gpt-4.1-nano",
                "gpt-4o",
                "gpt-4o-mini",
            ]
        case .claude:
            [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-opus-4-1-20250805",
                "claude-sonnet-4-20250514",
            ]
        case .ollama:
            ["llama3.3", "llama3.2", "qwen3", "gemma3", "phi4", "mistral", "deepseek-r1"]
        case .groq:
            [
                "llama-3.1-8b-instant",
                "llama-3.3-70b-versatile",
                "openai/gpt-oss-20b",
                "openai/gpt-oss-120b",
                "meta-llama/llama-4-scout-17b-16e-instruct",
                "meta-llama/llama-4-maverick-17b-128e-instruct",
                "qwen/qwen3-32b",
                "moonshotai/kimi-k2-instruct-0905",
                "groq/compound-mini",
                "groq/compound",
            ]
        case .openRouter:
            [
                "openrouter/auto",
                "google/gemini-3.1-pro-preview",
                "google/gemini-3.1-flash-lite",
                "openai/gpt-5.5",
                "openai/gpt-5.4-mini",
                "anthropic/claude-sonnet-4.6",
                "x-ai/grok-4.3",
                "deepseek/deepseek-v4-flash",
                "qwen/qwen3.6-flash",
                "moonshotai/kimi-k2.6",
            ]
        case .xai:
            [
                "grok-4.3",
                "grok-4.20",
                "grok-4.20-multi-agent",
                "grok-4-1-fast-reasoning",
                "grok-4-1-fast-non-reasoning",
            ]
        case .togetherAI:
            [
                "meta-llama/Llama-3.3-70B-Instruct-Turbo",
                "Qwen/Qwen3.6-Plus",
                "moonshotai/Kimi-K2.6",
                "moonshotai/Kimi-K2.5",
                "openai/gpt-oss-120b",
                "openai/gpt-oss-20b",
                "deepseek-ai/DeepSeek-V4-Pro",
                "zai-org/GLM-5.1",
            ]
        case .huggingFace:
            [
                "openai/gpt-oss-20b:fireworks-ai",
                "openai/gpt-oss-120b:fireworks-ai",
                "Qwen/Qwen3-Coder-30B-A3B-Instruct:novita",
                "deepseek-ai/DeepSeek-R1:novita",
                "meta-llama/Llama-3.3-70B-Instruct:novita",
            ]
        case .veniceAI:
            [
                "qwen-3-6-plus",
                "venice-uncensored-1-2",
                "gemini-3-1-pro-preview",
                "grok-4-3",
                "claude-sonnet-4-6",
                "openai-gpt-55",
                "openai-gpt-54-mini",
                "kimi-k2-6",
                "deepseek-v4-flash",
                "llama-3.3-70b",
            ]
        case .moonshot:
            [
                "kimi-k2.6",
                "kimi-k2.5",
                "kimi-k2-thinking",
                "kimi-k2-thinking-turbo",
                "kimi-k2-turbo-preview",
                "kimi-k2-0905-preview",
                "moonshot-v1-8k",
                "moonshot-v1-32k",
                "moonshot-v1-128k",
            ]
        case .deepseek:
            [
                "deepseek-chat",
                "deepseek-reasoner",
            ]
        case .glm:
            [
                "glm-4-plus",
                "glm-4-air",
                "glm-4-airx",
                "glm-4-flash",
                "glm-4-long",
            ]
        }
    }

    var defaultModel: String {
        switch self {
        case .gemini: HostedServiceConfig.defaultGeminiModel
        case .openai: "gpt-5.4-mini"
        case .claude: "claude-sonnet-4-6"
        case .ollama: "llama3.2"
        case .groq: "llama-3.1-8b-instant"
        case .openRouter: "openrouter/auto"
        case .xai: "grok-4.3"
        case .togetherAI: "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        case .huggingFace: "openai/gpt-oss-20b:fireworks-ai"
        case .veniceAI: "qwen-3-6-plus"
        case .moonshot: "kimi-k2.6"
        case .deepseek: "deepseek-chat"
        case .glm: "glm-4-flash"
        }
    }

    var requiresAPIKey: Bool {
        self != .ollama
    }

    /// Keychain key for storing this provider's API key
    var keychainKey: String {
        "com.scowld.apikey.\(rawValue)"
    }

    var modelDefaultsKey: String {
        "com.scowld.ai.model.\(rawValue)"
    }

    /// Whether this provider supports vision (image input)
    var supportsVision: Bool {
        switch self {
        case .gemini, .openai, .claude, .openRouter, .xai, .togetherAI, .moonshot: true
        case .huggingFace: true // some models
        case .ollama, .groq, .veniceAI, .deepseek, .glm: false
        }
    }

    /// Base URL for OpenAI-compatible providers
    var baseURL: String? {
        switch self {
        case .groq: "https://api.groq.com/openai/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .xai: "https://api.x.ai/v1"
        case .togetherAI: "https://api.together.xyz/v1"
        case .huggingFace: "https://router.huggingface.co/v1"
        case .veniceAI: "https://api.venice.ai/api/v1"
        case .moonshot: "https://api.moonshot.ai/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        default: nil
        }
    }

    /// Some providers reject custom sampling values for their newest models.
    var includesSamplingTemperature: Bool {
        switch self {
        case .moonshot: false
        default: true
        }
    }

    /// Whether this provider uses the OpenAI-compatible API format
    var isOpenAICompatible: Bool {
        baseURL != nil
    }
}

// MARK: - Ollama Configuration

enum OllamaConfig {
    static let defaultURL = "http://localhost:11434"
    static let keychainURLKey = "com.scowld.ollama.url"
}

// MARK: - Text-to-Speech Configuration

enum TTSBackend: String, CaseIterable, Codable, Sendable {
    case elevenLabs = "elevenlabs"
    case openAI = "openai_tts"
    case doubao = "doubao_tts"
    case minimax = "minimax_tts"
    case fishAudio = "fish_audio_tts"

    var displayName: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .openAI: "OpenAI"
        case .doubao: "Doubao Voice"
        case .minimax: "MiniMax"
        case .fishAudio: "Fish Audio"
        }
    }

    var keychainKey: String {
        switch self {
        case .elevenLabs, .doubao, .minimax, .fishAudio: "com.scowld.tts.\(rawValue)"
        // OpenAI TTS reuses the OpenAI chat provider key (one key for chat + speech).
        case .openAI: AIProvider.openai.keychainKey
        }
    }

    var modelDefaultsKey: String {
        "com.scowld.tts.model.\(rawValue)"
    }

    /// Per-backend voice / speaker identifier.
    var voiceDefaultsKey: String {
        "com.scowld.tts.voice.\(rawValue)"
    }

    /// Per-backend API endpoint override.
    var endpointDefaultsKey: String {
        "com.scowld.tts.endpoint.\(rawValue)"
    }

    var availableModels: [String] {
        switch self {
        case .elevenLabs:
            [
                "eleven_flash_v2_5",
                "eleven_multilingual_v2",
                "eleven_turbo_v2_5",
                "eleven_flash_v2",
            ]
        case .openAI:
            [
                "gpt-4o-mini-tts",
                "tts-1",
                "tts-1-hd",
            ]
        case .doubao:
            // Volcano Engine "business cluster" values.
            ["volcano_tts", "volcano_tts_concurr"]
        case .minimax:
            [
                "speech-02-hd",
                "speech-02-turbo",
                "speech-01-hd",
                "speech-01-turbo",
            ]
        case .fishAudio:
            ["s1"]
        }
    }

    var defaultModel: String {
        switch self {
        case .elevenLabs: HostedServiceConfig.defaultElevenLabsModel
        case .openAI: "gpt-4o-mini-tts"
        case .doubao: "volcano_tts"
        case .minimax: "speech-02-hd"
        case .fishAudio: "s1"
        }
    }

    var defaultVoice: String {
        switch self {
        case .elevenLabs: ""
        case .openAI: HostedServiceConfig.defaultOpenAITTSVoice
        case .doubao: "zh_female_qingxin"
        case .minimax: "female-shaonv"
        case .fishAudio: ""
        }
    }

    /// Default upstream endpoint. Doubao / MiniMax / Fish Audio are reached only
    /// through the native proxy, never straight from the page.
    var defaultEndpoint: String {
        switch self {
        case .elevenLabs: ""
        case .openAI: ""
        case .doubao: "https://openspeech.bytedance.com/api/v1/tts"
        case .minimax: "https://api.minimaxi.com/v1/t2a_v2"
        case .fishAudio: "https://api.fish.audio/v1/tts"
        }
    }

    /// Whether the backend needs a free-form voice identifier typed in by hand.
    var usesCustomVoiceField: Bool {
        switch self {
        case .elevenLabs, .openAI: false
        case .doubao, .minimax, .fishAudio: true
        }
    }

    /// Whether the endpoint is user-editable (region / self-hosted deployments).
    var usesEndpointField: Bool {
        switch self {
        case .elevenLabs, .openAI: false
        case .doubao, .minimax, .fishAudio: true
        }
    }

    /// The key the bundled web app understands. Everything that is not ElevenLabs
    /// is routed through its generic OpenAI-compatible TTS slot, whose URL we point
    /// at our own native proxy.
    var webBackendKey: String {
        switch self {
        case .elevenLabs: "elevenlabs"
        default: "openai_tts"
        }
    }

    /// Path of the native proxy that speaks this provider's real protocol.
    var proxyPath: String {
        switch self {
        case .openAI: "/api/openai-tts"
        case .doubao: "/api/doubao-tts"
        case .minimax: "/api/minimax-tts"
        case .fishAudio: "/api/fish-tts"
        case .elevenLabs: "/api/openai-tts"
        }
    }

    /// Short explanation shown under the picker for the proxy-routed providers.
    var providerHint: String {
        switch self {
        case .elevenLabs:
            "Speaks through the app's local proxy, which keeps your key in the Keychain."
        case .openAI:
            "Speaks through the app's local proxy using your OpenAI key."
        case .doubao:
            "Routed by the app to Volcano Engine. Audio is synthesised on their servers."
        case .minimax:
            "Routed by the app to MiniMax. Audio is synthesised on their servers."
        case .fishAudio:
            "Routed by the app to Fish Audio. Audio is synthesised on their servers."
        }
    }

    /// Fixed built-in voices exposed by the provider (OpenAI). ElevenLabs uses the
    /// named/custom voice library instead, so it returns an empty list here.
    var voiceOptions: [String] {
        switch self {
        case .elevenLabs: []
        case .openAI:
            ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer", "verse"]
        case .doubao, .minimax, .fishAudio: []
        }
    }

    static func selectedModel(for backend: TTSBackend) -> String {
        let saved = UserDefaults.standard.string(forKey: backend.modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty {
            return saved
        }
        return backend.defaultModel
    }

    static func selectedVoice(for backend: TTSBackend) -> String {
        // OpenAI keeps its voice in the pre-existing key so current installs keep
        // whatever the user already picked.
        if backend == .openAI {
            return HostedServiceConfig.selectedOpenAITTSVoice()
        }
        let saved = UserDefaults.standard.string(forKey: backend.voiceDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? backend.defaultVoice : saved
    }

    static func selectedEndpoint(for backend: TTSBackend) -> String {
        let saved = UserDefaults.standard.string(forKey: backend.endpointDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? backend.defaultEndpoint : saved
    }

    /// The token handed to the web page. The real secret never leaves the Keychain —
    /// the native proxy reads it directly — so the page only needs a non-empty value.
    static let keychainSentinel = "stored_in_ios_keychain"
}
