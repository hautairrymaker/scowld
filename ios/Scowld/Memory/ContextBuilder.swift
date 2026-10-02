import Foundation

// MARK: - Context Builder

/// Builds the system prompt by injecting the active chat's saved transcript.
struct ContextBuilder {
    let memoryStore: MemoryStore

    /// Build the complete system prompt with recent messages from the active chat.
    func buildSystemPrompt(visionDescription: String? = nil) -> String {
        let characterName = CharacterPack.resolveCharacterName()
        let pastConversation = memoryStore.buildContextFromActiveSlot()
        // The long-term memory log used to be saved and editable but never
        // reached the model, so the companion could not remember anything across
        // separate chats. It is injected here.
        let memoryLog = memoryStore.getActiveMemoryLog()

        return SystemPromptTemplate.build(
            userName: nil,
            conversationContext: pastConversation,
            visionDescription: visionDescription,
            characterName: characterName,
            memoryLog: memoryLog
        )
    }
}
