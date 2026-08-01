import XCTest
@testable import PortlyCompanion

final class PortlyServiceClientTests: XCTestCase {
    func testDecodesServiceStatus() throws {
        let payload = ##"{"ok":true,"data":{"projects":[{"id":"prj_1","name":"Portly","color":"#338CFF","servers":[{"id":"srv_1","name":"website","port":3000,"state":"running","healthy":true,"pid":42}]}]}}"##
        let envelope = try JSONDecoder().decode(PortlyStatusEnvelope.self, from: Data(payload.utf8))

        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.data.projects.first?.name, "Portly")
        XCTAssertEqual(envelope.data.projects.first?.servers.first?.port, 3000)
        XCTAssertTrue(envelope.data.projects.first?.servers.first?.isRunning == true)
    }
}
