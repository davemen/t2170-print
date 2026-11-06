import Foundation
import Testing
@testable import T2170Print

struct PrintSettingsTests {
    @Test func roundTripsThroughJSON() throws {
        let original = PrintSettings()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PrintSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func mediaTypeListMatchesMacDriver() {
        #expect(MediaType.allCases.count == 25)
    }
}
