import Foundation
import Testing
@testable import Orb

struct ClaudeCodeNativeRouteTests {
    /// The list does not say a window (it is the plan's, and only an answer states it): none is made up.
    @Test func theFallbackModelsTakePicturesAndStateNoWindow() {
        for model in ClaudeCodeModels.fallback {
            #expect(model.contextLength == nil && model.supportsImages == true, "\(model.id)")
        }
        #expect(ClaudeCodeModels.window(of: "claude-fable-5-1[1m]") == 1_000_000)
        #expect(ClaudeCodeModels.window(of: "claude-fable-5-1") == nil)
    }
}
