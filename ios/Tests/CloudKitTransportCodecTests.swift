import CloudKit
import Foundation
import XCTest
@testable import ExpoCloudKit

final class CloudKitTransportCodecTests: XCTestCase {
  private let scope = TransportScope(containerId: "iCloud.test.transport", database: "private", accountIdentity: "account-A")
  private let zone = CKRecordZone.ID(zoneName: "DisposableCodecTests", ownerName: CKCurrentUserDefaultName)

  private func write(_ record: CKRecord, set: [String: [String: Any]], clear: [String]) throws -> [String: Any] {
    let encoded = try CloudKitTransportCodec.encodeRecord(record, scope: scope)
    var result = CloudKitTransportCodec.identity(record.recordID)
    result["recordType"] = record.recordType
    result["systemFields"] = encoded["systemFields"]
    result["set"] = set
    result["clear"] = clear
    result["correlationId"] = "durable-outbox-row"
    return result
  }

  func testSerializedSystemFieldsReapplyOnlyExplicitDirtyMask() throws {
    let record = CKRecord(recordType: "TransportProbe", recordID: CKRecord.ID(recordName: "stable", zoneID: zone))
    record["omitted"] = "not archived"
    let input = try write(record, set: ["title": ["type": "string", "value": "updated"]], clear: ["photo"])
    let serialized = try JSONSerialization.data(withJSONObject: input)
    let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: serialized) as? [String: Any])
    let rebuilt = try CloudKitTransportCodec.decodeWrite(restored, scope: scope)
    XCTAssertEqual(rebuilt.recordID, record.recordID)
    XCTAssertEqual(rebuilt["title"] as? String, "updated")
    XCTAssertNil(rebuilt["omitted"])
    XCTAssertNil(rebuilt["photo"])
    XCTAssertEqual(Set(rebuilt.changedKeys()), Set(["title", "photo"]))
    // This proves local dirty intent, NOT CloudKit server partial-save semantics.
  }

  func testSystemFieldsCannotBeReusedForAnotherIdentityAccountOrZone() throws {
    let record = CKRecord(recordType: "TransportProbe", recordID: CKRecord.ID(recordName: "stable", zoneID: zone))
    let input = try write(record, set: [:], clear: [])
    var otherID = input
    otherID["recordName"] = "another"
    XCTAssertThrowsError(try CloudKitTransportCodec.decodeWrite(otherID, scope: scope))
    let otherAccount = TransportScope(containerId: scope.containerId, database: "private", accountIdentity: "account-B")
    XCTAssertThrowsError(try CloudKitTransportCodec.decodeWrite(input, scope: otherAccount))
    var otherZone = input
    otherZone["zoneName"] = "another-zone"
    XCTAssertThrowsError(try CloudKitTransportCodec.decodeWrite(otherZone, scope: scope))
  }

  func testAmbiguousMaskAndMalformedArchivesAreRejectedBeforeSubmission() throws {
    let record = CKRecord(recordType: "TransportProbe", recordID: CKRecord.ID(recordName: "stable", zoneID: zone))
    let overlapping = try write(record, set: ["title": ["type": "string", "value": "new"]], clear: ["title"])
    XCTAssertThrowsError(try CloudKitTransportCodec.decodeWrite(overlapping, scope: scope)) { error in
      XCTAssertEqual((error as? TransportFailure)?.code, "invalidArguments")
    }
    var malformed = try write(record, set: [:], clear: [])
    malformed["systemFields"] = "not-base64"
    XCTAssertThrowsError(try CloudKitTransportCodec.decodeWrite(malformed, scope: scope)) { error in
      XCTAssertEqual((error as? TransportFailure)?.code, "invalidSystemFields")
    }
    XCTAssertThrowsError(try CloudKitTransportCodec.decodeToken("not-base64", scope: scope, zone: zone)) { error in
      XCTAssertEqual((error as? TransportFailure)?.code, "invalidToken")
    }
  }

  func testInvalidFieldNamesAreRejectedBeforeCloudKitSetters() throws {
    let record = CKRecord(recordType: "TransportProbe", recordID: CKRecord.ID(recordName: "stable", zoneID: zone))
    let input = try write(record, set: ["bad.key": ["type": "string", "value": "value"]], clear: [])
    XCTAssertThrowsError(try CloudKitTransportCodec.decodeWrite(input, scope: scope)) { error in
      XCTAssertEqual((error as? TransportFailure)?.code, "invalidArguments")
    }
    let clear = try write(record, set: [:], clear: ["_reserved"])
    XCTAssertThrowsError(try CloudKitTransportCodec.decodeWrite(clear, scope: scope)) { error in
      XCTAssertEqual((error as? TransportFailure)?.code, "invalidArguments")
    }
  }

  func testReferencesRetainFullIdentityAndDatesRetainMilliseconds() throws {
    let record = CKRecord(recordType: "TransportProbe", recordID: CKRecord.ID(recordName: "stable", zoneID: zone))
    let ref = CKRecord.ID(recordName: "dependency", zoneID: CKRecordZone.ID(zoneName: "ForeignZone", ownerName: "owner"))
    record["ref"] = CKRecord.Reference(recordID: ref, action: .none)
    record["date"] = Date(timeIntervalSince1970: 1_700_000_000.123)
    let encoded = try CloudKitTransportCodec.encodeRecord(record, scope: scope)
    let fields = try XCTUnwrap(encoded["fields"] as? [String: [String: Any]])
    let rebuilt = try CloudKitTransportCodec.decodeWrite(write(record, set: fields, clear: []), scope: scope)
    XCTAssertEqual((rebuilt["ref"] as? CKRecord.Reference)?.recordID, ref)
    XCTAssertEqual(try XCTUnwrap(rebuilt["date"] as? Date).timeIntervalSince1970, 1_700_000_000.123, accuracy: 0.0001)
  }

  func testDownloadedAssetSurvivesTemporarySourceRemoval() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("caller-source")
    let bytes = Data("durable photo bytes".utf8)
    try bytes.write(to: source)
    let record = CKRecord(recordType: "TransportProbe", recordID: CKRecord.ID(recordName: "photo", zoneID: zone))
    record["photo"] = CKAsset(fileURL: source)
    let metadata = try CloudKitTransportCodec.encodeRecord(record, scope: scope)
    let json = try JSONSerialization.data(withJSONObject: metadata)
    XCTAssertFalse(String(decoding: json, as: UTF8.self).contains(source.absoluteString))
    let assets = try CloudKitTransportCodec.stageAssets(record, fields: ["photo"], cancelled: { false })
    defer { CloudKitTransportCodec.removeStagedAssets(assets) }
    let durable = try XCTUnwrap(URL(string: try XCTUnwrap(assets.first?["uri"] as? String)))
    XCTAssertEqual(assets.first?["byteCount"] as? Int, bytes.count)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Staging must not move/delete the source")
    try FileManager.default.removeItem(at: source)
    XCTAssertEqual(try Data(contentsOf: durable), bytes)
  }

  func testCancellationDuringAssetCopyDoesNotDeleteUploadSource() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: source) }
    try Data(repeating: 42, count: 600_000).write(to: source)
    let record = CKRecord(recordType: "TransportProbe", recordID: CKRecord.ID(recordName: "photo", zoneID: zone))
    record["photo"] = CKAsset(fileURL: source)
    var checks = 0
    XCTAssertThrowsError(try CloudKitTransportCodec.stageAssets(record, fields: ["photo"], cancelled: {
      checks += 1
      return checks >= 4 // First chunk copied; next chunk observes cancellation.
    })) { error in
      XCTAssertEqual((error as? TransportFailure)?.code, "cancelled")
    }
    XCTAssertEqual(try Data(contentsOf: source).count, 600_000)
  }

  func testSubmittedCancellationIsUncertainButConflictIsDefinitive() {
    let cancelled = CloudKitTransportCodec.error(CKError(.operationCancelled), submitted: true)
    XCTAssertEqual(cancelled["commitState"] as? String, "unknown")
    let conflict = CloudKitTransportCodec.error(CKError(.serverRecordChanged), submitted: true)
    XCTAssertEqual(conflict["code"] as? String, "conflict")
    XCTAssertEqual(conflict["commitState"] as? String, "notCommitted")
    let rate = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 3.5])
    XCTAssertEqual(CloudKitTransportCodec.error(rate)["retryAfterSeconds"] as? Double, 3.5)
  }
}
