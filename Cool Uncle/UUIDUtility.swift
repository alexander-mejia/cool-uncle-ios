import Foundation

/// Shared utility class for UUID operations across the application
class UUIDUtility {
    
    /// Replace UUID placeholders (like {{UUID}}, {UUID}, UUID_PLACEHOLDER) with actual UUIDs
    /// Only replaces obvious placeholders, not real UUIDs
    static func replaceUUIDPlaceholders(in text: String) -> String {
        var processedText = text
        var replacementsMade = false
        
        // Pattern 1: {{UUID}} or {UUID}
        let pattern1 = #"\{\{?UUID\}?\}"#
        let regex1 = try! NSRegularExpression(pattern: pattern1, options: [.caseInsensitive])
        let range1 = NSRange(processedText.startIndex..<processedText.endIndex, in: processedText)
        
        if regex1.firstMatch(in: processedText, options: [], range: range1) != nil {
            let newUUID = UUID().uuidString.lowercased()
            processedText = regex1.stringByReplacingMatches(
                in: processedText,
                options: [],
                range: range1,
                withTemplate: newUUID
            )
            replacementsMade = true
        }
        
        // Pattern 2: "id": "UUID_PLACEHOLDER" or similar obvious placeholders
        let pattern2 = #""id"\s*:\s*"(UUID_PLACEHOLDER|uuid|UUID|placeholder|PLACEHOLDER)""#
        let regex2 = try! NSRegularExpression(pattern: pattern2, options: [])
        let range2 = NSRange(processedText.startIndex..<processedText.endIndex, in: processedText)
        
        if regex2.firstMatch(in: processedText, options: [], range: range2) != nil {
            let newUUID = UUID().uuidString.lowercased()
            processedText = regex2.stringByReplacingMatches(
                in: processedText,
                options: [],
                range: range2,
                withTemplate: "\"id\": \"\(newUUID)\""
            )
            replacementsMade = true
        }
        
        // Only log if we actually made replacements
        if replacementsMade {
            AppLogger.emit(type: .debug, content: "UUIDUtility: Replaced placeholder - Original: \(text)")
            AppLogger.emit(type: .debug, content: "UUIDUtility: Replaced placeholder - Result: \(processedText)")
        }
        
        return processedText
    }
    
    /// Generate a new UUID string in lowercase format (matching Zaparoo API expectations)
    static func generateUUID() -> String {
        return UUID().uuidString.lowercased()
    }
    
    /// Check if a string contains UUID placeholders that need replacement
    static func containsUUIDPlaceholders(in text: String) -> Bool {
        // Check for {{UUID}}, {UUID}
        let pattern1 = #"\{\{?UUID\}?\}"#
        let regex1 = try! NSRegularExpression(pattern: pattern1, options: [.caseInsensitive])
        let range1 = NSRange(text.startIndex..<text.endIndex, in: text)
        
        if regex1.firstMatch(in: text, options: [], range: range1) != nil {
            return true
        }
        
        // Check for "id": "UUID_PLACEHOLDER" etc
        let pattern2 = #""id"\s*:\s*"(UUID_PLACEHOLDER|uuid|UUID|placeholder|PLACEHOLDER)""#
        let regex2 = try! NSRegularExpression(pattern: pattern2, options: [])
        let range2 = NSRange(text.startIndex..<text.endIndex, in: text)
        
        return regex2.firstMatch(in: text, options: [], range: range2) != nil
    }
    
    // MARK: - Future Utility Methods
    // Add other shared utility methods here as needed:
    // - JSON validation
    // - Command formatting
    // - Error message standardization
    // - Logging helpers
    // etc.
}