import CloudKit
import CryptoKit
import CoreFoundation
import Foundation

/// A manual, caller-owned transport. All mutable state and promise settlement are
/// confined to `queue`; CloudKit callbacks never mutate session state directly.
final class CloudKitTransport {
  typealias Dictionary = [String: Any]
  typealias Completion = (Dictionary) -> Void

  private final class Session {
    let id = UUID().uuidString
    let scope: TransportScope
    let generation: String
    let container: CKContainer
    var observer: NSObjectProtocol?
    var invalidation: Dictionary?
    var disposed = false
    var operations: [String: Work] = [:]
    let event: Completion?

    init(scope: TransportScope, generation: String, event: Completion?) {
      self.scope = scope
      self.generation = generation
      container = CKContainer(identifier: scope.containerId)
      self.event = event
    }
  }

  private final class Work {
    let id: String
    var completion: Completion?
    var result: Dictionary?
    var started = false
    var submitted = false
    var writes = false
    var native: CKOperation?
    var cancellationValue: ((Dictionary) -> Dictionary)?
    var cancellationCleanup: (() -> Void)?

    init(_ id: String) { self.id = id }
  }

  private let queue = DispatchQueue(label: "expo.cloudkit.transport.state")
  private var sessions: [String: Session] = [:]

  func createSession(_ options: Dictionary, event: @escaping Completion) throws -> String {
    guard let container = options["containerId"] as? String,
          container.hasPrefix("iCloud."), container.utf8.count <= 255,
          options["database"] as? String == "private",
          let identity = options["expectedAccountIdentity"] as? String,
          !identity.isEmpty, identity.utf8.count <= 1024,
          let generation = options["generation"] as? String,
          !generation.isEmpty, generation.utf8.count <= 1024 else {
      throw TransportFailure("invalidArguments", "A container, private database, expected identity and generation are required.")
    }
    return queue.sync {
      let session = Session(scope: TransportScope(containerId: container, database: "private", accountIdentity: identity), generation: generation, event: event)
      register(session)
      return session.id
    }
  }

  private func register(_ session: Session) {
    sessions[session.id] = session
    session.observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self, weak session] _ in
      guard let self = self, let session = session else { return }
      self.queue.async {
        guard !session.disposed, session.invalidation == nil else { return }
        self.invalidate(session, reason: "accountChanged", error: CloudKitTransportCodec.failure("accountMismatch", "The iCloud account changed; create a new bound session."))
      }
    }
  }

  func reserve(sessionId: String, operationId: String) throws {
    try queue.sync {
      guard let session = sessions[sessionId], !session.disposed else {
        throw TransportFailure("sessionDisposed", "The transport session has been disposed.")
      }
      guard !operationId.isEmpty, operationId.utf8.count <= 128,
            session.operations[operationId] == nil else {
        throw TransportFailure("invalidArguments", "Operation IDs must be unique, nonempty and at most 128 bytes.")
      }
      guard session.operations.count < 200 else {
        throw TransportFailure("batchLimitExceeded", "At most 200 operations may be outstanding per session.")
      }
      session.operations[operationId] = Work(operationId)
    }
  }

  func execute(sessionId: String, operationId: String, kind: String, payload: Dictionary, completion: @escaping Completion) {
    queue.async {
      guard let session = self.sessions[sessionId] else {
        completion(Self.envelope(generation: "", operationId: operationId, error: CloudKitTransportCodec.failure("sessionDisposed", "The transport session has been disposed.")))
        return
      }
      guard let work = session.operations[operationId], !work.started else {
        completion(Self.envelope(generation: session.generation, operationId: operationId, error: CloudKitTransportCodec.failure("invalidArguments", "Reserve a unique operation before executing it.")))
        return
      }
      work.started = true
      work.completion = completion
      if let result = work.result {
        self.deliver(session, work, result)
        return
      }
      if let error = session.invalidation {
        self.finish(session, work, error: error)
        return
      }
      do {
        let operation = try self.prepare(session, work, kind: kind, payload: payload)
        guard let operation = operation else { return }
        self.verifyAccount(session, work) { account in
          guard account["identity"] as? String == session.scope.accountIdentity else {
            self.invalidate(session, reason: "accountMismatch", error: CloudKitTransportCodec.failure("accountMismatch", "The active iCloud account does not match the expected binding."), account: account)
            return
          }
          self.submit(session, work, operation)
        }
      } catch {
        self.finish(session, work, error: CloudKitTransportCodec.error(error))
      }
    }
  }

  func cancel(sessionId: String, operationId: String) {
    queue.sync {
      guard let session = sessions[sessionId], let work = session.operations[operationId], work.result == nil else { return }
      cancel(session, work, error: CloudKitTransportCodec.failure("cancelled", "Operation cancelled.", submitted: work.writes && work.submitted))
    }
  }

  func dispose(sessionId: String) {
    queue.sync {
      guard let session = sessions[sessionId] else { return }
      dispose(session)
    }
  }

  func disposeAll() {
    queue.sync {
      for session in Array(sessions.values) { dispose(session) }
      // The module is gone: there can be no future execute call to attach to a
      // reservation. Individual dispose retains only those awaiting delivery.
      sessions.removeAll()
    }
  }

  private func dispose(_ session: Session) {
    guard !session.disposed else { return }
    session.disposed = true
    removeObserver(session)
    for work in Array(session.operations.values) where work.result == nil {
      cancel(session, work, error: CloudKitTransportCodec.failure("sessionDisposed", "The transport session has been disposed.", submitted: work.writes && work.submitted))
    }
    releaseDisposed(session)
  }

  private func removeObserver(_ session: Session) {
    if let observer = session.observer { NotificationCenter.default.removeObserver(observer) }
    session.observer = nil
  }

  private func releaseDisposed(_ session: Session) {
    if session.disposed && session.operations.isEmpty { sessions.removeValue(forKey: session.id) }
  }

  private func invalidate(_ session: Session, reason: String, error: Dictionary, account: Dictionary? = nil) {
    guard session.invalidation == nil, !session.disposed else { return }
    session.invalidation = error
    removeObserver(session)
    for work in Array(session.operations.values) where work.result == nil {
      var failure = error
      if work.writes && work.submitted { failure["commitState"] = "unknown" }
      cancel(session, work, error: failure)
    }
    var event: Dictionary = ["sessionId": session.id, "generation": session.generation, "reason": reason]
    if let account = account { event["account"] = account }
    session.event?(event)
  }

  private func cancel(_ session: Session, _ work: Work, error: Dictionary) {
    work.native?.cancel()
    work.cancellationCleanup?()
    if let value = work.cancellationValue?(error) {
      finish(session, work, value: value)
    } else {
      finish(session, work, error: error)
    }
  }

  private static func envelope(generation: String, operationId: String, value: Dictionary? = nil, error: Dictionary? = nil) -> Dictionary {
    if let error = error {
      return ["status": "failed", "generation": generation, "operationId": operationId, "error": error]
    }
    return ["status": "success", "generation": generation, "operationId": operationId, "value": value ?? [:]]
  }

  private func finish(_ session: Session, _ work: Work, value: Dictionary? = nil, error: Dictionary? = nil) {
    guard work.result == nil else { return }
    let result = Self.envelope(generation: session.generation, operationId: work.id, value: value, error: error)
    work.result = result
    work.native = nil
    work.cancellationValue = nil
    work.cancellationCleanup = nil
    if work.completion != nil { deliver(session, work, result) }
  }

  private func deliver(_ session: Session, _ work: Work, _ result: Dictionary) {
    let completion = work.completion
    work.completion = nil
    session.operations.removeValue(forKey: work.id)
    releaseDisposed(session)
    completion?(result)
  }

  private func active(_ session: Session, _ work: Work) -> Bool {
    !session.disposed && session.invalidation == nil && work.result == nil
  }

  /// Preserve callback ordering on the state queue, including per-item receipts
  /// arriving before the operation's terminal callback.
  private func receive(_ session: Session, _ work: Work, _ body: @escaping () -> Void) {
    queue.async {
      guard self.active(session, work) else { return }
      body()
    }
  }

  private func submit(_ session: Session, _ work: Work, _ operation: CKDatabaseOperation) {
    guard active(session, work) else { operation.cancel(); return }
    work.native = operation
    work.submitted = true
    operation.qualityOfService = .userInitiated
    session.container.privateCloudDatabase.add(operation)
  }

  // MARK: Account probes and per-operation account binding

  func account(containerId: String, generation: String, completion: @escaping Completion) {
    guard containerId.hasPrefix("iCloud."), containerId.utf8.count <= 255,
          !generation.isEmpty, generation.utf8.count <= 1024 else {
      completion(Self.envelope(generation: generation, operationId: "", error: CloudKitTransportCodec.failure("invalidArguments", "A valid container and generation are required.")))
      return
    }
    queue.async {
      let session = Session(scope: TransportScope(containerId: containerId, database: "private", accountIdentity: ""), generation: generation, event: nil)
      self.register(session)
      let work = Work("")
      work.started = true
      work.completion = { result in
        completion(result)
        self.dispose(session)
      }
      session.operations[work.id] = work
      self.verifyAccount(session, work, probe: true) { account in
        self.finish(session, work, value: account)
      }
    }
  }

  private func verifyAccount(_ session: Session, _ work: Work, probe: Bool = false, completion: @escaping Completion) {
    // accountStatus has no cancellable CKOperation counterpart. Its late callback
    // is fenced; fetching the actual user identity uses a cancellable operation.
    session.container.accountStatus { status, error in
      self.receive(session, work) {
        if let error = error {
          self.finishOperationFailure(session, work, error: CloudKitTransportCodec.error(error))
          return
        }
        let availability: String
        switch status {
        case .available: availability = "available"
        case .noAccount: availability = "noAccount"
        case .restricted: availability = "restricted"
        case .couldNotDetermine: availability = "couldNotDetermine"
        case .temporarilyUnavailable: availability = "temporarilyUnavailable"
        @unknown default: availability = "couldNotDetermine"
        }
        guard status == .available else {
          if probe { completion(["availability": availability]); return }
          let code: String
          switch status {
          case .noAccount: code = "notAuthenticated"
          case .restricted: code = "permissionFailure"
          case .temporarilyUnavailable: code = "accountTemporarilyUnavailable"
          default: code = "serviceUnavailable"
          }
          self.finishOperationFailure(session, work, error: CloudKitTransportCodec.failure(code, "The iCloud account is not available (\(availability))."))
          return
        }
        let operation = CKFetchRecordsOperation.fetchCurrentUserRecordOperation()
        operation.desiredKeys = []
        var identity: String?
        var identityError: Error?
        operation.perRecordResultBlock = { _, result in
          self.receive(session, work) {
            switch result {
            case .success(let record):
              // Length-prefixing avoids delimiter ambiguity; identifiers never
              // leave native code, only this container-scoped opaque digest.
              let container = session.scope.containerId
              let name = record.recordID.recordName
              let source = "\(container.utf8.count):\(container)\(name.utf8.count):\(name)"
              identity = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
            case .failure(let error): identityError = error
            }
          }
        }
        operation.fetchRecordsResultBlock = { result in
          self.receive(session, work) {
            work.native = nil
            if case .failure(let error) = result { identityError = identityError ?? error }
            if let error = identityError {
              self.finishOperationFailure(session, work, error: CloudKitTransportCodec.error(error))
            } else if let identity = identity {
              completion(["availability": "available", "identity": identity])
            } else {
              self.finishOperationFailure(session, work, error: CloudKitTransportCodec.failure("unknown", "CloudKit returned no current user identity."))
            }
          }
        }
        work.native = operation
        operation.qualityOfService = .userInitiated
        session.container.publicCloudDatabase.add(operation)
      }
    }
  }

  private func finishOperationFailure(_ session: Session, _ work: Work, error: Dictionary) {
    if let value = work.cancellationValue?(error) { finish(session, work, value: value) }
    else { finish(session, work, error: error) }
  }

  // MARK: Input bounds

  private func keys(_ payload: Dictionary, _ name: String, nonempty: Bool = false) throws -> [String] {
    guard let values = payload[name] as? [String], values.count <= 200,
          !nonempty || !values.isEmpty,
          values.allSatisfy(CloudKitTransportCodec.isValidFieldName),
          Set(values).count == values.count else {
      throw TransportFailure("invalidArguments", "\(name) must contain at most 200 unique, nonempty field names.")
    }
    return values
  }

  private func batch(_ payload: Dictionary) throws -> [Dictionary] {
    guard let values = payload["records"] as? [Dictionary], !values.isEmpty else {
      throw TransportFailure("invalidArguments", "records must be a nonempty array.")
    }
    guard values.count <= 200 else { throw TransportFailure("batchLimitExceeded", "At most 200 records may be submitted per operation.") }
    return values
  }

  private func prepare(_ session: Session, _ work: Work, kind: String, payload: Dictionary) throws -> CKDatabaseOperation? {
    switch kind {
    case "fetchZone", "createZone":
      return try zoneOperation(session, work, payload: payload, create: kind == "createZone")
    case "fetchChanges": return try changesOperation(session, work, payload: payload)
    case "fetchRecords": return try fetchOperation(session, work, payload: payload)
    case "saveRecords": return try saveOperation(session, work, payload: payload)
    case "downloadAssets": return try assetOperation(session, work, payload: payload)
    default: throw TransportFailure("invalidArguments", "Unknown transport operation.")
    }
  }

  // MARK: Explicit zones (never auto-created by a read)

  private func zoneOperation(_ session: Session, _ work: Work, payload: Dictionary, create: Bool) throws -> CKDatabaseOperation {
    let id = try CloudKitTransportCodec.zoneID(payload)
    if create {
      work.writes = true
      let operation = CKModifyRecordZonesOperation(recordZonesToSave: [CKRecordZone(zoneID: id)], recordZoneIDsToDelete: nil)
      operation.modifyRecordZonesCompletionBlock = { saved, _, error in
        self.receive(session, work) {
          if let zone = saved?.first(where: { $0.zoneID == id }) {
            self.finish(session, work, value: ["status": "created", "zone": CloudKitTransportCodec.zoneIdentity(zone.zoneID)])
          } else if let error = error {
            self.finish(session, work, error: self.itemError(error, id: id, submitted: true))
          } else {
            self.finish(session, work, error: CloudKitTransportCodec.failure("unknown", "CloudKit returned no zone creation receipt.", submitted: true))
          }
        }
      }
      return operation
    }
    let operation = CKFetchRecordZonesOperation(recordZoneIDs: [id])
    var receipt: Result<CKRecordZone, Error>?
    operation.perRecordZoneResultBlock = { _, result in
      self.receive(session, work) { receipt = result }
    }
    operation.fetchRecordZonesResultBlock = { result in
      self.receive(session, work) {
        if let receipt = receipt {
          switch receipt {
          case .success(let zone): self.finish(session, work, value: ["status": "found", "zone": CloudKitTransportCodec.zoneIdentity(zone.zoneID)])
          case .failure(let error): self.finish(session, work, error: CloudKitTransportCodec.error(error))
          }
        } else if case .failure(let error) = result {
          self.finish(session, work, error: self.itemError(error, id: id))
        } else {
          self.finish(session, work, error: CloudKitTransportCodec.failure("unknown", "CloudKit returned no zone lookup receipt."))
        }
      }
    }
    return operation
  }

  private func itemError(_ error: Error, id: AnyHashable, submitted: Bool = false) -> Dictionary {
    let partial = (error as NSError).userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error]
    return CloudKitTransportCodec.error(partial?[id] ?? error, submitted: submitted)
  }

  // MARK: Caller-owned pages

  private func changesOperation(_ session: Session, _ work: Work, payload: Dictionary) throws -> CKDatabaseOperation {
    guard let zone = payload["zone"] as? Dictionary else { throw TransportFailure("invalidArguments", "A custom zone is required.") }
    let id = try CloudKitTransportCodec.zoneID(zone)
    let desiredKeys = try keys(payload, "desiredKeys")
    let limit: Int
    if let raw = payload["resultsLimit"] {
      guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
            number.doubleValue >= 1, number.doubleValue <= 200 else {
        throw TransportFailure("invalidArguments", "resultsLimit must be an integer between 1 and 200.")
      }
      limit = number.intValue
    } else { limit = 200 }
    let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
    configuration.desiredKeys = desiredKeys
    configuration.resultsLimit = limit
    if let raw = payload["previousToken"] {
      guard let token = raw as? String else { throw TransportFailure("invalidToken", "The previous token must be a string.") }
      configuration.previousServerChangeToken = try CloudKitTransportCodec.decodeToken(token, scope: session.scope, zone: id)
    }
    let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [id], configurationsByRecordZoneID: [id: configuration])
    operation.fetchAllChanges = false
    var records: [Dictionary] = []
    var deletions: [Dictionary] = []
    var failures: [Dictionary] = []
    var nextToken: String?
    var moreComing = true
    var zoneFinished = false
    var operationError: Dictionary?
    let value: (Dictionary?) -> Dictionary = { error in
      let failure = error ?? operationError
      let usable = failure == nil && failures.isEmpty && zoneFinished && nextToken != nil
      var result: Dictionary = ["records": records, "deletions": deletions, "failures": failures, "checkpointUsable": usable, "moreComing": usable ? moreComing : true]
      if usable, let nextToken = nextToken { result["nextToken"] = nextToken }
      if let failure = failure { result["operationError"] = failure }
      return result
    }
    work.cancellationValue = { value($0) }
    operation.recordWasChangedBlock = { recordID, result in
      self.receive(session, work) {
        do {
          let record = try result.get()
          records.append(try CloudKitTransportCodec.encodeRecord(record, scope: session.scope))
        } catch {
          failures.append(["id": CloudKitTransportCodec.identity(recordID), "error": CloudKitTransportCodec.error(error)])
        }
      }
    }
    operation.recordWithIDWasDeletedBlock = { recordID, recordType in
      self.receive(session, work) {
        var deletion = CloudKitTransportCodec.identity(recordID)
        deletion["recordType"] = recordType
        deletions.append(deletion)
      }
    }
    operation.recordZoneFetchResultBlock = { _, result in
      self.receive(session, work) {
        do {
          let page = try result.get()
          nextToken = try CloudKitTransportCodec.encodeToken(page.serverChangeToken, scope: session.scope, zone: id)
          moreComing = page.moreComing
          zoneFinished = true
        } catch { operationError = CloudKitTransportCodec.error(error) }
      }
    }
    operation.fetchRecordZoneChangesResultBlock = { result in
      self.receive(session, work) {
        if case .failure(let error) = result { operationError = operationError ?? self.itemError(error, id: id) }
        if !zoneFinished && operationError == nil { operationError = CloudKitTransportCodec.failure("unknown", "CloudKit returned no completed zone checkpoint.") }
        self.finish(session, work, value: value(nil))
      }
    }
    return operation
  }

  // MARK: Bounded targeted reads

  private func fetchOperation(_ session: Session, _ work: Work, payload: Dictionary) throws -> CKDatabaseOperation {
    let ids = try batch(payload).map { try CloudKitTransportCodec.recordID($0) }
    guard Set(ids).count == ids.count else { throw TransportFailure("invalidArguments", "Targeted fetch record IDs must be unique.") }
    let operation = CKFetchRecordsOperation(recordIDs: ids)
    operation.desiredKeys = try keys(payload, "desiredKeys")
    var receipts: [CKRecord.ID: Dictionary] = [:]
    let value: (Dictionary?) -> Dictionary = { error in
      let fallback = error ?? CloudKitTransportCodec.failure("unknown", "CloudKit returned no record lookup receipt.")
      var result: Dictionary = ["outcomes": ids.map { id in
        receipts[id] ?? ["status": "failed", "id": CloudKitTransportCodec.identity(id), "error": fallback]
      }]
      if let error = error { result["operationError"] = error }
      return result
    }
    work.cancellationValue = { value($0) }
    operation.perRecordResultBlock = { id, result in
      self.receive(session, work) {
        let identity = CloudKitTransportCodec.identity(id)
        do {
          receipts[id] = ["status": "found", "id": identity, "record": try CloudKitTransportCodec.encodeRecord(result.get(), scope: session.scope)]
        } catch {
          if let cloudError = error as? CKError, cloudError.code == .unknownItem {
            receipts[id] = ["status": "notFound", "id": identity]
          } else {
            receipts[id] = ["status": "failed", "id": identity, "error": CloudKitTransportCodec.error(error)]
          }
        }
      }
    }
    operation.fetchRecordsResultBlock = { result in
      self.receive(session, work) {
        var error: Dictionary?
        if case .failure(let failure) = result {
          error = CloudKitTransportCodec.error(failure)
          for id in ids where receipts[id] == nil {
            let mapped = self.itemError(failure, id: id)
            receipts[id] = mapped["nativeCode"] as? Int == CKError.unknownItem.rawValue && mapped["nativeDomain"] as? String == CKErrorDomain
              ? ["status": "notFound", "id": CloudKitTransportCodec.identity(id)]
              : ["status": "failed", "id": CloudKitTransportCodec.identity(id), "error": mapped]
          }
        }
        self.finish(session, work, value: value(error))
      }
    }
    return operation
  }

  // MARK: Conditional writes and receipts

  private func saveOperation(_ session: Session, _ work: Work, payload: Dictionary) throws -> CKDatabaseOperation? {
    let writes = try batch(payload)
    work.writes = true
    var ids: [CKRecord.ID?] = writes.map { try? CloudKitTransportCodec.recordID($0) }
    var counts: [CKRecord.ID: Int] = [:]
    for id in ids.compactMap({ $0 }) { counts[id, default: 0] += 1 }
    var receipts: [Int: Dictionary] = [:]
    var indices: [CKRecord.ID: Int] = [:]
    var records: [CKRecord] = []
    let identity: (Int) -> Dictionary = { index in
      if let id = ids[index] { return CloudKitTransportCodec.identity(id) }
      // Invalid input still receives its original caller identity, never a
      // fabricated CloudKit ID; valid sibling writes remain eligible.
      return ["recordName": writes[index]["recordName"] as? String ?? "", "zoneName": writes[index]["zoneName"] as? String ?? "", "ownerName": writes[index]["ownerName"] as? String ?? ""]
    }
    let correlation: (Int) -> String = { writes[$0]["correlationId"] as? String ?? "" }
    for (index, write) in writes.enumerated() {
      do {
        let id = try CloudKitTransportCodec.recordID(write)
        guard counts[id] == 1 else { throw TransportFailure("invalidArguments", "Duplicate record IDs in a save batch are ambiguous.") }
        guard let correlationId = write["correlationId"] as? String, !correlationId.isEmpty, correlationId.utf8.count <= 1024 else {
          throw TransportFailure("invalidArguments", "Every write requires a nonempty correlationId of at most 1024 bytes.")
        }
        let record = try CloudKitTransportCodec.decodeWrite(write, scope: session.scope)
        ids[index] = record.recordID
        indices[record.recordID] = index
        records.append(record)
      } catch {
        receipts[index] = ["status": "unattempted", "id": identity(index), "correlationId": correlation(index), "error": CloudKitTransportCodec.error(error)]
      }
    }
    let value: (Dictionary?) -> Dictionary = { error in
      let fallback = error ?? CloudKitTransportCodec.failure("unknown", "CloudKit returned no save receipt.", submitted: work.submitted)
      var result: Dictionary = ["outcomes": writes.indices.map { index in
        receipts[index] ?? ["status": work.submitted ? "failed" : "unattempted", "id": identity(index), "correlationId": correlation(index), "error": fallback]
      }]
      if let error = error { result["operationError"] = error }
      return result
    }
    work.cancellationValue = { value($0) }
    guard !records.isEmpty else { finish(session, work, value: value(nil)); return nil }
    let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
    operation.savePolicy = .ifServerRecordUnchanged
    operation.isAtomic = false
    let recordFailure: (Int, Error) -> Dictionary = { index, error in
      let mapped = CloudKitTransportCodec.error(error, submitted: true)
      var receipt: Dictionary = ["status": "failed", "id": identity(index), "correlationId": correlation(index), "error": mapped]
      if let cloudError = error as? CKError, cloudError.code == .serverRecordChanged {
        receipt["status"] = "conflict"
        if let server = cloudError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
          do { receipt["serverRecord"] = try CloudKitTransportCodec.encodeRecord(server, scope: session.scope) }
          catch { receipt["serverRecordError"] = CloudKitTransportCodec.error(error) }
        }
      }
      return receipt
    }
    operation.perRecordSaveBlock = { id, result in
      self.receive(session, work) {
        guard let index = indices[id] else { return }
        switch result {
        case .success(let record):
          do {
            receipts[index] = ["status": "saved", "id": identity(index), "correlationId": correlation(index), "record": try CloudKitTransportCodec.encodeRecord(record, scope: session.scope)]
          } catch {
            // The write committed, but its receipt cannot be serialized. Do not
            // claim a definitive rejection or retry it on the caller's behalf.
            var failure = CloudKitTransportCodec.error(error, submitted: true)
            failure["commitState"] = "unknown"
            receipts[index] = ["status": "failed", "id": identity(index), "correlationId": correlation(index), "error": failure]
          }
        case .failure(let error): receipts[index] = recordFailure(index, error)
        }
      }
    }
    operation.modifyRecordsResultBlock = { result in
      self.receive(session, work) {
        var error: Dictionary?
        if case .failure(let failure) = result {
          error = CloudKitTransportCodec.error(failure, submitted: true)
          let partial = (failure as NSError).userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error]
          for (id, index) in indices where receipts[index] == nil {
            if let item = partial?[id] { receipts[index] = recordFailure(index, item) }
          }
        }
        self.finish(session, work, value: value(error))
      }
    }
    return operation
  }

  // MARK: Durable asset delivery

  private func assetOperation(_ session: Session, _ work: Work, payload: Dictionary) throws -> CKDatabaseOperation {
    guard let raw = payload["record"] as? Dictionary else { throw TransportFailure("invalidArguments", "An asset owner record is required.") }
    let id = try CloudKitTransportCodec.recordID(raw)
    let fields = try keys(payload, "assetFields", nonempty: true)
    let desiredKeys = try keys(payload, "desiredKeys")
    let operation = CKFetchRecordsOperation(recordIDs: [id])
    operation.desiredKeys = Array(Set(desiredKeys + fields)).sorted()
    var receipt: Dictionary?
    var receiptError: Dictionary?
    var staged: [Dictionary] = []
    work.cancellationCleanup = {
      CloudKitTransportCodec.removeStagedAssets(staged)
      staged = []
    }
    operation.perRecordResultBlock = { _, result in
      var assets: [Dictionary] = []
      do {
        let record = try result.get()
        let encoded = try CloudKitTransportCodec.encodeRecord(record, scope: session.scope)
        assets = try CloudKitTransportCodec.stageAssets(record, fields: fields) {
          self.queue.sync { !self.active(session, work) }
        }
        let copied = assets
        self.queue.sync {
          guard self.active(session, work) else {
            CloudKitTransportCodec.removeStagedAssets(copied)
            return
          }
          staged = copied
          receipt = ["record": encoded, "assets": copied]
        }
      } catch {
        CloudKitTransportCodec.removeStagedAssets(assets)
        self.receive(session, work) { receiptError = CloudKitTransportCodec.error(error) }
      }
    }
    operation.fetchRecordsResultBlock = { result in
      self.queue.async {
        guard self.active(session, work) else {
          CloudKitTransportCodec.removeStagedAssets(staged)
          staged = []
          return
        }
        if case .failure(let error) = result { receiptError = receiptError ?? self.itemError(error, id: id) }
        if let error = receiptError {
          CloudKitTransportCodec.removeStagedAssets(staged)
          staged = []
          self.finish(session, work, error: error)
        } else if let receipt = receipt {
          // Settlement transfers ownership. A subsequent cancellation cannot
          // revoke a delivered file or delete a caller-adopted asset.
          staged = []
          self.finish(session, work, value: receipt)
        } else {
          self.finish(session, work, error: CloudKitTransportCodec.failure("unknown", "CloudKit returned no asset owner record."))
        }
      }
    }
    return operation
  }
}
