#if canImport(ExpoModulesCore)
import ExpoModulesCore
import Foundation

/// Independent of ExpoCloudKit.configure and every high-level manager. Importing
/// the transport neither starts sync engines nor creates queues/subscriptions.
public final class ExpoCloudKitTransportModule: Module {
  private let transport = CloudKitTransport()

  public func definition() -> ModuleDefinition {
    Name("ExpoCloudKitTransport")
    Events("onTransportAccountChanged")

    Function("transportCreateSession") { (options: [String: Any]) throws -> String in
      do {
        return try self.transport.createSession(options) { [weak self] event in
          self?.sendEvent("onTransportAccountChanged", event)
        }
      } catch {
        throw CloudKitTransportBridgeException(error)
      }
    }

    Function("transportReserveOperation") { (sessionId: String, operationId: String) throws in
      do {
        try self.transport.reserve(sessionId: sessionId, operationId: operationId)
      } catch {
        throw CloudKitTransportBridgeException(error)
      }
    }

    AsyncFunction("transportExecute") { (sessionId: String, operationId: String, kind: String, payload: [String: Any], promise: Promise) in
      self.transport.execute(sessionId: sessionId, operationId: operationId, kind: kind, payload: payload) { result in
        promise.resolve(result)
      }
    }

    Function("transportCancelOperation") { (sessionId: String, operationId: String) in
      self.transport.cancel(sessionId: sessionId, operationId: operationId)
    }

    Function("transportDisposeSession") { (sessionId: String) in
      self.transport.dispose(sessionId: sessionId)
    }

    AsyncFunction("transportAccount") { (containerId: String, generation: String, promise: Promise) in
      self.transport.account(containerId: containerId, generation: generation) { result in
        promise.resolve(result)
      }
    }

    OnDestroy {
      self.transport.disposeAll()
    }
  }
}

/// Only synchronous local misuse throws through Expo. CloudKit outcomes resolve
/// typed envelopes so JS never loses successful receipts in a batch rejection.
private final class CloudKitTransportBridgeException: Exception {
  private let detail: String
  private let transportCode: String
  init(_ error: Error) {
    let details = CloudKitTransportCodec.error(error)
    detail = details["message"] as? String ?? "Invalid transport invocation."
    transportCode = details["code"] as? String ?? "unknown"
    super.init()
  }
  override var reason: String { detail }
  override var code: String { transportCode }
}
#endif
