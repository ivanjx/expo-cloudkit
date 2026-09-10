import CloudKit
import CoreLocation
import Foundation

struct TransportScope: Equatable {
  let containerId: String
  let database: String
  let accountIdentity: String
}

struct TransportFailure: Error, LocalizedError {
  let code: String
  let message: String
  init(_ code: String, _ message: String) {
    self.code = code
    self.message = message
  }
  var errorDescription: String? { message }
}

/// Wire formats for the caller-owned transport. No token store or legacy converter:
/// legacy conversion loses reference zone identity and exposes temporary asset URLs.
enum CloudKitTransportCodec {
  static func failure(_ code: String, _ message: String, submitted: Bool = false) -> [String: Any] {
    ["code": code, "message": message, "nativeDomain": "ExpoCloudKitTransport",
     "nativeCode": 0, "commitState": submitted ? "unknown" : "notCommitted"]
  }

  static func error(_ error: Error, submitted: Bool = false) -> [String: Any] {
    if let local = error as? TransportFailure {
      return failure(local.code, local.message, submitted: submitted)
    }
    let ns = error as NSError
    var code = "unknown"
    var uncertain = submitted
    if let ck = error as? CKError {
      switch ck.code {
      case .networkUnavailable, .networkFailure: code = "networkUnavailable"
      case .serviceUnavailable, .serverResponseLost: code = "serviceUnavailable"
      case .notAuthenticated: code = "notAuthenticated"
      case .accountTemporarilyUnavailable: code = "accountTemporarilyUnavailable"
      case .permissionFailure: code = "permissionFailure"
      case .quotaExceeded: code = "quotaExceeded"
      case .requestRateLimited: code = "rateLimited"
      case .zoneBusy: code = "zoneBusy"
      case .zoneNotFound: code = "zoneNotFound"
      case .userDeletedZone: code = "zoneDeleted"
      case .changeTokenExpired: code = "tokenExpired"
      case .serverRecordChanged: code = "conflict"
      case .unknownItem: code = "recordNotFound"
      case .invalidArguments: code = "invalidArguments"
      case .constraintViolation, .referenceViolation, .serverRejectedRequest: code = "invalidRecord"
      case .assetFileNotFound: code = "assetFileNotFound"
      case .assetFileModified: code = "invalidRecord"
      case .limitExceeded: code = "batchLimitExceeded"
      case .operationCancelled: code = "cancelled"
      default: break
      }
      // Only an explicit per-item rejection proves that that item did not commit.
      // Aggregate partial failures and transport failures remain ambiguous.
      switch ck.code {
      case .serverRecordChanged, .invalidArguments, .constraintViolation, .referenceViolation,
           .permissionFailure, .quotaExceeded, .zoneNotFound, .userDeletedZone, .unknownItem,
           .assetFileNotFound, .assetFileModified, .limitExceeded, .notAuthenticated,
           .accountTemporarilyUnavailable, .changeTokenExpired:
        uncertain = false
      default: break
      }
    } else if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
      code = "diskFull"
    } else if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain {
      code = "fileIO"
    }
    var result: [String: Any] = [
      "code": code, "message": ns.localizedDescription, "nativeDomain": ns.domain,
      "nativeCode": ns.code, "commitState": uncertain ? "unknown" : "notCommitted"
    ]
    if let retry = (error as? CKError)?.retryAfterSeconds { result["retryAfterSeconds"] = retry }
    return result
  }

  static func zoneID(_ dict: [String: Any]) throws -> CKRecordZone.ID {
    guard let name = dict["zoneName"] as? String, !name.isEmpty,
          name != CKRecordZone.ID.default.zoneName,
          let owner = dict["ownerName"] as? String, owner == CKCurrentUserDefaultName else {
      throw TransportFailure("invalidArguments", "A private custom zone and default owner are required.")
    }
    return CKRecordZone.ID(zoneName: name, ownerName: owner)
  }

  static func recordID(_ dict: [String: Any]) throws -> CKRecord.ID {
    guard let name = dict["recordName"] as? String, !name.isEmpty else {
      throw TransportFailure("invalidArguments", "A stable nonempty recordName is required.")
    }
    return CKRecord.ID(recordName: name, zoneID: try zoneID(dict))
  }

  static func zoneIdentity(_ id: CKRecordZone.ID) -> [String: Any] {
    ["zoneName": id.zoneName, "ownerName": id.ownerName]
  }

  static func identity(_ id: CKRecord.ID) -> [String: Any] {
    ["recordName": id.recordName, "zoneName": id.zoneID.zoneName, "ownerName": id.zoneID.ownerName]
  }

  // Secure archives are wrapped with durable scope, not the ephemeral generation:
  // a new process/session for the SAME binding must be able to resume a checkpoint.
  private static func wrap(_ data: Data, kind: String, scope: TransportScope,
                           zone: CKRecordZone.ID) throws -> String {
    let envelope: [String: Any] = [
      "version": 1, "kind": kind, "container": scope.containerId, "database": scope.database,
      "account": scope.accountIdentity, "zone": zoneIdentity(zone), "archive": data.base64EncodedString()
    ]
    return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).base64EncodedString()
  }

  private static func unwrap(_ value: String, kind: String, scope: TransportScope,
                             zone: CKRecordZone.ID) throws -> Data {
    let code = kind == "token" ? "invalidToken" : "invalidSystemFields"
    guard value.utf8.count <= 4 * 1024 * 1024,
          let data = Data(base64Encoded: value), data.base64EncodedString() == value,
          let json = try? JSONSerialization.jsonObject(with: data), let dict = json as? [String: Any],
          dict["version"] as? Int == 1, dict["kind"] as? String == kind,
          dict["container"] as? String == scope.containerId, dict["database"] as? String == scope.database,
          dict["account"] as? String == scope.accountIdentity,
          let savedZone = dict["zone"] as? [String: Any],
          savedZone["zoneName"] as? String == zone.zoneName,
          savedZone["ownerName"] as? String == zone.ownerName,
          let archive = dict["archive"] as? String, let bytes = Data(base64Encoded: archive),
          !bytes.isEmpty, bytes.base64EncodedString() == archive else {
      throw TransportFailure(code, "Malformed or differently scoped \(kind) envelope.")
    }
    return bytes
  }

  static func encodeToken(_ token: CKServerChangeToken, scope: TransportScope,
                          zone: CKRecordZone.ID) throws -> String {
    try wrap(NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true),
             kind: "token", scope: scope, zone: zone)
  }

  static func decodeToken(_ value: String, scope: TransportScope,
                          zone: CKRecordZone.ID) throws -> CKServerChangeToken {
    do {
      let data = try unwrap(value, kind: "token", scope: scope, zone: zone)
      guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) else {
        throw TransportFailure("invalidToken", "The archive contains no CloudKit change token.")
      }
      return token
    } catch {
      throw TransportFailure("invalidToken", "Invalid or differently scoped CloudKit change token.")
    }
  }

  static func encodeRecord(_ record: CKRecord, scope: TransportScope) throws -> [String: Any] {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: coder)
    coder.finishEncoding()
    if let error = coder.error { throw error }
    var result = identity(record.recordID)
    result["recordType"] = record.recordType
    result["systemFields"] = try wrap(coder.encodedData, kind: "record", scope: scope, zone: record.recordID.zoneID)
    if let tag = record.recordChangeTag { result["changeTag"] = tag }
    if let date = record.creationDate { result["creationDate"] = date.timeIntervalSince1970 * 1000 }
    if let date = record.modificationDate { result["modificationDate"] = date.timeIntervalSince1970 * 1000 }
    var fields: [String: Any] = [:]
    for key in record.allKeys() {
      if let value = record[key] { fields[key] = try encodeField(value) }
    }
    result["fields"] = fields
    return result
  }

  /// CloudKit field keys are ASCII schema identifiers. Validate before calling
  /// Objective-C setters, whose invalid-argument exceptions Swift cannot catch.
  static func isValidFieldName(_ name: String) -> Bool {
    let bytes = name.utf8
    let letter: (UInt8) -> Bool = { (65...90).contains($0) || (97...122).contains($0) }
    guard bytes.count <= 255, let first = bytes.first, letter(first) else { return false }
    return bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) || $0 == 95 }
  }

  static func decodeWrite(_ dict: [String: Any], scope: TransportScope) throws -> CKRecord {
    let id = try recordID(dict)
    guard let type = dict["recordType"] as? String, !type.isEmpty,
          let set = dict["set"] as? [String: [String: Any]], let clear = dict["clear"] as? [String],
          let correlation = dict["correlationId"] as? String, !correlation.isEmpty,
          Set(clear).count == clear.count,
          set.keys.allSatisfy(isValidFieldName), clear.allSatisfy(isValidFieldName),
          Set(set.keys).isDisjoint(with: clear) else {
      throw TransportFailure("invalidArguments", "Provide a record type, correlation ID, and disjoint explicit set/clear masks.")
    }
    let record: CKRecord
    if let encoded = dict["systemFields"] {
      guard let encoded = encoded as? String else {
        throw TransportFailure("invalidSystemFields", "systemFields must be an opaque string, or omitted for creation.")
      }
      do {
        let data = try unwrap(encoded, kind: "record", scope: scope, zone: id.zoneID)
        let coder = try NSKeyedUnarchiver(forReadingFrom: data)
        coder.requiresSecureCoding = true
        coder.decodingFailurePolicy = .setErrorAndReturn
        defer { coder.finishDecoding() }
        guard let decoded = CKRecord(coder: coder), coder.error == nil,
              decoded.recordID == id, decoded.recordType == type else {
          throw TransportFailure("invalidSystemFields", "System fields do not match the write's identity and type.")
        }
        record = decoded
      } catch {
        throw TransportFailure("invalidSystemFields", "Invalid, mismatched, or differently scoped record system fields.")
      }
    } else {
      record = CKRecord(recordType: type, recordID: id)
    }
    // System-field archives contain neither user fields nor dirty-key intent.
    // Assign nil even when absent locally: CloudKit must receive the explicit clear.
    for (key, value) in set { record[key] = try decodeField(value) }
    for key in clear { record[key] = nil }
    return record
  }

  private static func dateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func parseDate(_ value: Any?) throws -> Date {
    guard let string = value as? String else { throw TransportFailure("invalidRecord", "Expected an ISO8601 date.") }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else { throw TransportFailure("invalidRecord", "Invalid ISO8601 date.") }
    return date
  }

  private static func locationValue(_ location: CLLocation) -> [String: Any] {
    ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude]
  }

  private static func referenceValue(_ reference: CKRecord.Reference) -> [String: Any] {
    var value = identity(reference.recordID)
    value["action"] = reference.action == .deleteSelf ? "deleteSelf" : "none"
    return value
  }

  private static func encodeField(_ value: CKRecordValueProtocol) throws -> [String: Any] {
    switch value {
    case let v as String: return ["type": "string", "value": v]
    case let v as NSNumber: return ["type": "number", "value": v]
    case let v as Date: return ["type": "date", "value": dateString(v)]
    case let v as Data: return ["type": "data", "value": v.base64EncodedString()]
    case let v as CLLocation: return ["type": "location", "value": locationValue(v)]
    case let v as CKRecord.Reference: return ["type": "reference", "value": referenceValue(v)]
    case is CKAsset: return ["type": "asset", "value": ["available": true]]
    case let v as [String]: return ["type": "stringList", "value": v]
    case let v as [NSNumber]: return ["type": "numberList", "value": v]
    case let v as [Date]: return ["type": "dateList", "value": v.map(dateString)]
    case let v as [Data]: return ["type": "dataList", "value": v.map { $0.base64EncodedString() }]
    case let v as [CLLocation]: return ["type": "locationList", "value": v.map(locationValue)]
    case let v as [CKRecord.Reference]: return ["type": "referenceList", "value": v.map(referenceValue)]
    case let v as [CKAsset]: return ["type": "assetList", "value": ["count": v.count]]
    default: throw TransportFailure("invalidRecord", "Unsupported CloudKit field type; record was not acknowledged.")
    }
  }

  private static func decodeLocation(_ value: Any?) throws -> CLLocation {
    guard let dict = value as? [String: Any], let lat = dict["latitude"] as? Double,
          let lon = dict["longitude"] as? Double, lat.isFinite, lon.isFinite,
          (-90...90).contains(lat), (-180...180).contains(lon) else {
      throw TransportFailure("invalidRecord", "Invalid latitude/longitude.")
    }
    return CLLocation(latitude: lat, longitude: lon)
  }

  private static func decodeReference(_ value: Any?) throws -> CKRecord.Reference {
    guard let dict = value as? [String: Any], let action = dict["action"] as? String,
          action == "none" || action == "deleteSelf",
          let name = dict["recordName"] as? String, !name.isEmpty,
          let zone = dict["zoneName"] as? String, !zone.isEmpty,
          let owner = dict["ownerName"] as? String, !owner.isEmpty else {
      throw TransportFailure("invalidRecord", "References require complete record/zone identity and action.")
    }
    let id = CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: zone, ownerName: owner))
    return CKRecord.Reference(recordID: id, action: action == "deleteSelf" ? .deleteSelf : .none)
  }

  private static func decodeData(_ value: Any?) throws -> Data {
    guard let string = value as? String, let data = Data(base64Encoded: string),
          data.base64EncodedString() == string else { throw TransportFailure("invalidRecord", "Invalid base64 data.") }
    return data
  }

  private static func decodeField(_ dict: [String: Any]) throws -> CKRecordValueProtocol {
    let value = dict["value"]
    switch dict["type"] as? String {
    case "string": if let v = value as? String { return v }
    case "number": if let v = value as? NSNumber, v.doubleValue.isFinite { return v }
    case "date": return try parseDate(value)
    case "data": return try decodeData(value)
    case "location": return try decodeLocation(value)
    case "reference": return try decodeReference(value)
    case "asset":
      guard let string = value as? String, let url = URL(string: string), url.isFileURL,
            url.host == nil || url.host == "" || url.host == "localhost" else {
        throw TransportFailure("invalidRecord", "Uploads require a stable local file URI.")
      }
      guard FileManager.default.isReadableFile(atPath: url.path) else {
        throw TransportFailure("assetFileNotFound", "Upload file is not readable.")
      }
      let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard info.isRegularFile == true else {
        throw TransportFailure("assetFileNotFound", "Upload file is not a readable regular file.")
      }
      // CloudKit documents a 50 MB per-asset limit. Server remains authoritative.
      guard (info.fileSize ?? 0) <= 50 * 1024 * 1024 else {
        throw TransportFailure("assetTooLarge", "Upload exceeds CloudKit's 50 MB per-asset limit.")
      }
      return CKAsset(fileURL: url)
    case "stringList": if let v = value as? [String] { return v }
    case "numberList": if let v = value as? [NSNumber], v.allSatisfy({ $0.doubleValue.isFinite }) { return v }
    case "dateList": if let v = value as? [String] { return try v.map { try parseDate($0) } }
    case "dataList": if let v = value as? [String] { return try v.map { try decodeData($0) } }
    case "locationList": if let v = value as? [[String: Any]] { return try v.map { try decodeLocation($0) } }
    case "referenceList": if let v = value as? [[String: Any]] { return try v.map { try decodeReference($0) } }
    default: break
    }
    throw TransportFailure("invalidRecord", "Unsupported field type or incompatible field value.")
  }

  private static let stagingLock = NSLock()
  private static var initializedStagingRoot: URL?

  /// Only successful initialization is cached. A caller can retry after freeing
  /// disk space; failed setup must not poison every later operation this process.
  /// The lock also keeps first-use abandoned-partial cleanup ahead of all copies.
  private static func stagingRoot() throws -> URL {
    stagingLock.lock()
    defer { stagingLock.unlock() }
    if let root = initializedStagingRoot { return root }
    let fm = FileManager.default
    let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
    var root = support.appendingPathComponent("ExpoCloudKitTransport/Assets", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try root.setResourceValues(values)
    for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      let name = url.lastPathComponent
      if name.hasPrefix(".partial-"), UUID(uuidString: String(name.dropFirst(9))) != nil {
        try fm.removeItem(at: url)
      }
    }
    initializedStagingRoot = root
    return root
  }

  static func stageAssets(_ record: CKRecord, fields: [String], cancelled: () -> Bool) throws -> [[String: Any]] {
    guard !fields.isEmpty, Set(fields).count == fields.count, fields.allSatisfy(isValidFieldName) else {
      throw TransportFailure("invalidArguments", "Specify unique nonempty asset field names.")
    }
    if cancelled() { throw TransportFailure("cancelled", "Asset download cancelled.") }
    let root = try stagingRoot()
    let fm = FileManager.default
    let name = UUID().uuidString
    let partial = root.appendingPathComponent(".partial-" + name, isDirectory: true)
    let destination = root.appendingPathComponent(name, isDirectory: true)
    try fm.createDirectory(at: partial, withIntermediateDirectories: false)
    var retained = false
    defer {
      if !retained {
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: destination)
      }
    }
    var assets: [[String: Any]] = []
    for field in fields {
      if cancelled() { throw TransportFailure("cancelled", "Asset download cancelled.") }
      guard let value = record[field] else { continue } // Explicitly absent on this server version.
      guard let asset = value as? CKAsset, let source = asset.fileURL else {
        throw TransportFailure("invalidRecord", "Requested field is not a downloaded scalar asset.")
      }
      let filename = UUID().uuidString
      let target = partial.appendingPathComponent(filename)
      // Preserve the Foundation/POSIX error (especially disk-full), and never
      // overwrite an existing path even in the private, uniquely named directory.
      try Data().write(to: target, options: .withoutOverwriting)
      let input = try FileHandle(forReadingFrom: source)
      defer { try? input.close() }
      let output = try FileHandle(forWritingTo: target)
      defer { try? output.close() }
      var count = 0
      while true {
        if cancelled() { throw TransportFailure("cancelled", "Asset copying cancelled.") }
        guard let data = try input.read(upToCount: 256 * 1024), !data.isEmpty else { break }
        try output.write(contentsOf: data)
        count += data.count
      }
      try output.synchronize()
      try output.close()
      try input.close()
      assets.append(["field": field, "uri": destination.appendingPathComponent(filename).absoluteString,
                     "byteCount": count])
    }
    if cancelled() { throw TransportFailure("cancelled", "Asset copying cancelled.") }
    if assets.isEmpty { return [] }
    try fm.moveItem(at: partial, to: destination)
    if cancelled() { throw TransportFailure("cancelled", "Asset delivery cancelled.") }
    retained = true
    return assets
  }

  /// Internal failed-delivery cleanup. Successful staging belongs to the caller;
  /// teardown never deletes a successfully handed-off file.
  static func removeStagedAssets(_ assets: [[String: Any]]) {
    guard let root = try? stagingRoot() else { return }
    var directories: Set<URL> = []
    for asset in assets {
      guard let string = asset["uri"] as? String, let url = URL(string: string), url.isFileURL,
            UUID(uuidString: url.lastPathComponent) != nil else { continue }
      let directory = url.deletingLastPathComponent()
      guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
            UUID(uuidString: directory.lastPathComponent) != nil else { continue }
      directories.insert(directory)
    }
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
  }
}
