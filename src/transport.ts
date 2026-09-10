/**
 * Standalone caller-owned transport. This entry does not load the legacy SDK,
 * React hooks, sync engines, queues, or native modules when imported.
 */
import type {
  CloudKitTransportSession,
  TransportAccount,
  TransportAccountChangeEvent,
  TransportError,
  TransportErrorCode,
  TransportOperation,
  TransportResult,
  TransportSessionOptions,
  TransportSubscription,
} from './transport.types';

export type * from './transport.types';

export const TRANSPORT_DEFAULT_OWNER = '__defaultOwner__';

type OperationKind = 'fetchZone' | 'createZone' | 'fetchChanges' | 'fetchRecords' | 'saveRecords' | 'downloadAssets';

interface NativeTransportModule {
  transportCreateSession(options: TransportSessionOptions): string;
  transportReserveOperation(sessionId: string, operationId: string): void;
  transportExecute<T>(sessionId: string, operationId: string, kind: OperationKind, payload: unknown): Promise<TransportResult<T>>;
  transportCancelOperation(sessionId: string, operationId: string): void;
  transportDisposeSession(sessionId: string): void;
  transportAccount(containerId: string, generation: string): Promise<TransportResult<TransportAccount>>;
}

interface AccountEmitter {
  addListener(event: 'onTransportAccountChanged', listener: (event: TransportAccountChangeEvent) => void): TransportSubscription;
}

interface NativeBridge {
  module: NativeTransportModule;
  subscribe(listener: (event: TransportAccountChangeEvent) => void): TransportSubscription;
}

let nativeBridge: NativeBridge | undefined;

function failure(code: TransportErrorCode, message: string): TransportError {
  return { code, message, nativeDomain: 'ExpoCloudKitTransport.JS', nativeCode: 0, commitState: 'notCommitted' };
}

function bridgeError(error: unknown, submittedWrite: boolean): TransportError {
  if (typeof error === 'object' && error !== null) {
    const details = error as Partial<TransportError>;
    if (typeof details.code === 'string' && typeof details.message === 'string'
      && typeof details.nativeDomain === 'string' && typeof details.nativeCode === 'number'
      && (details.commitState === 'notCommitted' || details.commitState === 'unknown')) {
      return details as TransportError;
    }
    // Expo synchronous Exceptions retain code/message, but drop custom fields.
    // These codes are emitted only by local validation before cloud submission.
    if (typeof details.message === 'string' && (details.code === 'invalidArguments'
      || details.code === 'sessionDisposed' || details.code === 'batchLimitExceeded')) {
      return {
        code: details.code,
        message: details.message,
        nativeDomain: 'ExpoCloudKitTransport',
        nativeCode: 0,
        commitState: 'notCommitted',
      };
    }
  }
  return {
    ...failure('unknown', error instanceof Error ? error.message : 'The native transport bridge failed.'),
    commitState: submittedWrite ? 'unknown' : 'notCommitted',
  };
}

function failed<T>(generation: string, operationId: string, error: TransportError): TransportResult<T> {
  return { status: 'failed', generation, operationId, error };
}

function getNativeBridge(): NativeBridge {
  if (nativeBridge) return nativeBridge;

  // Deliberately lazy: merely importing this entry must not acquire native modules.
  // eslint-disable-next-line @typescript-eslint/no-require-imports -- Synchronous lazy acquisition is part of this entry's contract.
  const { Platform } = require('react-native') as { Platform: { OS: string } };
  if (Platform.OS !== 'ios') {
    throw failure('unsupportedPlatform', 'The caller-owned CloudKit transport is supported only on iOS; web and Android are unsupported.');
  }

  let core: {
    requireNativeModule<T>(name: string): T;
    EventEmitter: new (module: NativeTransportModule) => AccountEmitter;
  };
  let module: NativeTransportModule;
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports -- Do not load Expo on import or unsupported platforms.
    core = require('expo-modules-core') as typeof core;
    module = core.requireNativeModule<NativeTransportModule>('ExpoCloudKitTransport');
  } catch {
    throw failure('nativeModuleUnavailable', 'ExpoCloudKitTransport is unavailable. Build an iOS development client containing this native module; Expo Go is unsupported.');
  }

  let emitter: AccountEmitter | undefined;
  nativeBridge = {
    module,
    subscribe(listener) {
      emitter ??= new core.EventEmitter(module);
      return emitter.addListener('onTransportAccountChanged', listener);
    },
  };
  return nativeBridge;
}

/** Probe identity without configuring the high-level SDK or creating a session. */
export async function getTransportAccount(containerId: string, generation: string): Promise<TransportResult<TransportAccount>> {
  try {
    return await getNativeBridge().module.transportAccount(containerId, generation);
  } catch (error) {
    return failed(generation, '', bridgeError(error, false));
  }
}

/**
 * Creates a manual private-database session. No network request is made here.
 * Each operation verifies account identity natively. Session creation errors are
 * retained as structured failures on operations, including unsupported platforms.
 */
export function createTransportSession(options: TransportSessionOptions): CloudKitTransportSession {
  const scope = { ...options };
  let bridge: NativeBridge | undefined;
  let sessionId = '';
  let creationError: TransportError | undefined;
  let disposed = false;
  let sequence = 0;
  const subscriptions = new Set<TransportSubscription>();

  if (scope.database !== 'private' || typeof scope.containerId !== 'string' || !scope.containerId
    || typeof scope.expectedAccountIdentity !== 'string' || !scope.expectedAccountIdentity
    || typeof scope.generation !== 'string' || !scope.generation) {
    creationError = failure('invalidArguments', 'A private database, container ID, expected account identity, and nonempty generation are required.');
  } else {
    try {
      bridge = getNativeBridge();
      sessionId = bridge.module.transportCreateSession(scope);
    } catch (error) {
      creationError = bridgeError(error, false);
    }
  }

  function operation<T>(kind: OperationKind, payload: unknown): TransportOperation<T> {
    const id = String(++sequence);
    const initialError = disposed ? failure('sessionDisposed', 'This transport session has been disposed.') : creationError;
    if (initialError || !bridge) {
      return {
        id,
        result: Promise.resolve(failed(scope.generation, id, initialError ?? failure('nativeModuleUnavailable', 'The native transport is unavailable.'))),
        cancel() {},
      };
    }

    const module = bridge.module;
    try {
      // Reserve before returning the handle: cancellation can win even before execute.
      module.transportReserveOperation(sessionId, id);
    } catch (error) {
      return { id, result: Promise.resolve(failed(scope.generation, id, bridgeError(error, false))), cancel() {} };
    }

    let settled = false;
    let cancelled = false;
    const result = Promise.resolve()
      .then(() => module.transportExecute<T>(sessionId, id, kind, payload))
      .catch((error: unknown) => failed<T>(scope.generation, id, bridgeError(error, kind === 'saveRecords' || kind === 'createZone')))
      .then((receipt) => {
        settled = true;
        // Never replace a native receipt after cancel/dispose or retag its generation.
        return receipt;
      });

    return {
      id,
      result,
      cancel() {
        if (settled || cancelled || disposed) return;
        cancelled = true;
        try {
          module.transportCancelOperation(sessionId, id);
        } catch {
          // A bridge cancellation failure cannot establish whether a write committed.
          // The original operation remains the sole authority for its receipt.
        }
      },
    };
  }

  return {
    fetchZone: (zone) => operation('fetchZone', zone),
    createZone: (zone) => operation('createZone', zone),
    fetchChanges: (request) => operation('fetchChanges', request),
    fetchRecords: (request) => operation('fetchRecords', request),
    saveRecords: (request) => operation('saveRecords', request),
    downloadAssets: (request) => operation('downloadAssets', request),
    addAccountChangeListener(listener) {
      if (disposed || creationError || !bridge) return { remove() {} };
      let active = true;
      const nativeSubscription = bridge.subscribe((event) => {
        if (active && !disposed && event.sessionId === sessionId && event.generation === scope.generation) {
          listener(event);
        }
      });
      const subscription: TransportSubscription = {
        remove() {
          if (!active) return;
          active = false;
          subscriptions.delete(subscription);
          try {
            nativeSubscription.remove();
          } catch {
            // Fence any already-queued callback even if native observer removal fails.
          }
        },
      };
      subscriptions.add(subscription);
      return subscription;
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const subscription of subscriptions) subscription.remove();
      if (bridge && !creationError) {
        try {
          bridge.module.transportDisposeSession(sessionId);
        } catch {
          // Do not replace pending native write receipts with a fabricated rejection.
        }
      }
    },
  };
}
