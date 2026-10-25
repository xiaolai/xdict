// **The AI providers are sayso's** (github.com/xiaolai/sayso, v0.5.0, ISC): one OpenAI-compatible client with provider
// profiles and a model catalogue, the reader's Claude and Codex CLIs, and Apple's on-device model. Re-exported so the
// rest of XDict keeps importing `XDictAI` alone and the types are one package's, never a copy's. What stays here is
// XDict's own contract: the marking rule, the composer, the validator, the answer schema, and the adapter that binds
// Apple's provider to `AppleAnswer`.
@_exported import SaySoAI
@_exported import SaySoAICLI
@_exported import SaySoAIApple
