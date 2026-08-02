import Foundation
@testable import PortlyCore
import XCTest

final class UXContractTests: XCTestCase {
    func testFreePortJSONIncludesExplicitNullOccupant() throws {
        let response = PortlyAPI.PortQueryResponse(port: 5173, occupant: nil)
        let data = try PortlyAPI.encoder().encode(response)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["port"] as? Int, 5173)
        XCTAssertTrue(json["occupant"] is NSNull)
    }

    func testPortResponseStillDecodesLegacyPayloadWithoutOccupant() throws {
        let data = Data(#"{"port":5173}"#.utf8)
        let response = try PortlyAPI.decoder().decode(PortlyAPI.PortQueryResponse.self, from: data)

        XCTAssertEqual(response.port, 5173)
        XCTAssertNil(response.occupant)
    }
}
