import XCTest
@testable import VeneraKit

final class SyncConfigTransferTests: XCTestCase {
    // Fixed AES-GCM/PBKDF2 vector generated with the Flutter-compatible format.
    func testDecodesFlutterPayload() throws {
        let uri = "venera://sync?v=1&d=ABEiM0RVZneImaq7zN3u_wECAwQFBgcICQoLDMjeUTTxDBbs3AMdisLVr81xRsoqvbr6sZ7lrC3BBod_jGLzVEUfnwXWmfny3raBVFofpjJowJIa91DucIAOfKLSOWpbPmjh5ZWWyw2LW_Sr2oUgg4an9lXQYb6IzLaWwX_dvNrhsuksI1oHVgid7cG5gdclMRuM5pFtLsChtb3vuy-looS7ww8ZrAPHmB8I1h3UWX9XEVPRSlk8tkPxjAInyYQSK-IdPz4xaHEUHRPLhMAORQ"
        let payload = try SyncConfigTransfer.decode(uri: uri, pin: "482917")
        XCTAssertEqual(payload.url, "https://dav.example.com/venera/")
        XCTAssertEqual(payload.user, "alice@example.com")
        XCTAssertEqual(payload.pass, "p@$$w0rd with spaces & 符号")
        XCTAssertTrue(payload.autoSync)
        XCTAssertEqual(payload.disableSyncFields, "history,read_later")
    }

    func testRecognizesOnlySyncPayloads() {
        XCTAssertTrue(SyncConfigTransfer.isSyncConfigURI("venera://sync?v=1&d=abc"))
        XCTAssertFalse(SyncConfigTransfer.isSyncConfigURI("venera://comic?id=1"))
        XCTAssertFalse(SyncConfigTransfer.isSyncConfigURI("https://example.com"))
    }

    func testRejectsMalformedAndWrongPin() {
        XCTAssertThrowsError(try SyncConfigTransfer.decode(uri: "venera://sync?v=1&d=bad", pin: "123456")) { error in
            XCTAssertEqual(error as? SyncConfigTransferError, .malformed)
        }
        let uri = "venera://sync?v=1&d=ABEiM0RVZneImaq7zN3u_wECAwQFBgcICQoLDMjeUTTxDBbs3AMdisLVr81xRsoqvbr6sZ7lrC3BBod_jGLzVEUfnwXWmfny3raBVFofpjJowJIa91DucIAOfKLSOWpbPmjh5ZWWyw2LW_Sr2oUgg4an9lXQYb6IzLaWwX_dvNrhsuksI1oHVgid7cG5gdclMRuM5pFtLsChtb3vuy-looS7ww8ZrAPHmB8I1h3UWX9XEVPRSlk8tkPxjAInyYQSK-IdPz4xaHEUHRPLhMAORQ"
        XCTAssertThrowsError(try SyncConfigTransfer.decode(uri: uri, pin: "000000")) { error in
            XCTAssertEqual(error as? SyncConfigTransferError, .wrongPinOrTampered)
        }
    }
}
