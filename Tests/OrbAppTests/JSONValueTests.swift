import Foundation
import Testing
@testable import Orb

struct JSONValueTests {
    @Test func parsesAndReencodes() throws {
        let value = try #require(JSONValue.parse(#"{"path":"~/a.txt","limit":3,"deep":true,"tags":["x"]}"#))
        #expect(value["path"]?.string == "~/a.txt")
        #expect(value["limit"]?.int == 3)
        #expect(value["deep"]?.bool == true)
        #expect(value["tags"]?.array == [.string("x")])
        #expect(JSONValue.parse(value.jsonString) == value)
    }

    @Test func emptyArgumentsAreAnEmptyObject() {
        #expect(JSONValue.parse("  ") == .object([:]))
        #expect(JSONValue.parse("{oops") == nil)
    }
}
