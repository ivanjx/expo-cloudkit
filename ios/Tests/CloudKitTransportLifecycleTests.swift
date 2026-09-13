import CloudKit
import Foundation
import XCTest
@testable import ExpoCloudKit

/// These exercise native registry/settlement without submitting CloudKit work.
/// They do not establish signed-device account or server cancellation semantics.
final class CloudKitTransportLifecycleTests: XCTestCase {
  private func session(_ transport: CloudKitTransport, event: @escaping ([String: Any]) -> Void = { _ in }) throws -> String {
    try transport.createSession([
      "containerId": "iCloud.test.transport",
      "database": "private",
      "expectedAccountIdentity": "bound-account",
      "generation": "originating-generation"
    ], event: event)
  }

  func testCancellationBetweenReserveAndExecuteNeverSubmitsAndRetainsGeneration() throws {
    let transport = CloudKitTransport()
    defer { transport.disposeAll() }
    let id = try session(transport)
    try transport.reserve(sessionId: id, operationId: "1")
    transport.cancel(sessionId: id, operationId: "1")
    transport.cancel(sessionId: id, operationId: "1")
    let settled = expectation(description: "Cancelled reservation settles once")
    settled.assertForOverFulfill = true
    transport.execute(sessionId: id, operationId: "1", kind: "saveRecords", payload: [:]) { result in
      XCTAssertEqual(result["status"] as? String, "failed")
      XCTAssertEqual(result["generation"] as? String, "originating-generation")
      XCTAssertEqual(result["operationId"] as? String, "1")
      let error = result["error"] as? [String: Any]
      XCTAssertEqual(error?["code"] as? String, "cancelled")
      XCTAssertEqual(error?["commitState"] as? String, "notCommitted")
      settled.fulfill()
    }
    wait(for: [settled], timeout: 2)
  }

  func testRepeatedDisposeSettlesEveryUndeliveredReservation() throws {
    let transport = CloudKitTransport()
    defer { transport.disposeAll() }
    let id = try session(transport)
    try transport.reserve(sessionId: id, operationId: "1")
    try transport.reserve(sessionId: id, operationId: "2")
    transport.dispose(sessionId: id)
    transport.dispose(sessionId: id)
    let settled = expectation(description: "Both reservations settle once")
    settled.expectedFulfillmentCount = 2
    settled.assertForOverFulfill = true
    for operationId in ["1", "2"] {
      transport.execute(sessionId: id, operationId: operationId, kind: "fetchZone", payload: [:]) { result in
        XCTAssertEqual(result["generation"] as? String, "originating-generation")
        XCTAssertEqual(result["operationId"] as? String, operationId)
        let error = result["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "sessionDisposed")
        XCTAssertEqual(error?["commitState"] as? String, "notCommitted")
        settled.fulfill()
      }
    }
    wait(for: [settled], timeout: 2)
    XCTAssertThrowsError(try transport.reserve(sessionId: id, operationId: "3")) { error in
      XCTAssertEqual((error as? TransportFailure)?.code, "sessionDisposed")
    }
  }

  func testAccountNotificationInvalidatesReservedOperationAndNotifiesOnce() throws {
    let transport = CloudKitTransport()
    defer { transport.disposeAll() }
    let changed = expectation(description: "Account change event")
    changed.assertForOverFulfill = true
    let id = try session(transport) { event in
      XCTAssertEqual(event["reason"] as? String, "accountChanged")
      XCTAssertEqual(event["generation"] as? String, "originating-generation")
      changed.fulfill()
    }
    try transport.reserve(sessionId: id, operationId: "1")
    NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
    NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
    let settled = expectation(description: "Invalidated reservation")
    transport.execute(sessionId: id, operationId: "1", kind: "fetchZone", payload: [:]) { result in
      XCTAssertEqual(result["generation"] as? String, "originating-generation")
      XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "accountMismatch")
      settled.fulfill()
    }
    wait(for: [changed, settled], timeout: 2)
  }
}
