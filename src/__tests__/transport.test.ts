import type * as TransportSDK from '../transport';
import type {
  TransportAccountChangeEvent,
  TransportError,
  TransportRecord,
  TransportResult,
  TransportSaveRecordsResult,
  TransportSessionOptions,
  TransportWrite,
} from '../transport.types';

jest.mock('react-native', () => ({ Platform: { OS: 'ios' } }));
jest.mock('expo-modules-core', () => ({
  requireNativeModule: () => {
    if (mockNativeUnavailable) throw new Error('Native module not installed');
    return mockNative;
  },
  EventEmitter: class {
    addListener(_event: string, listener: (event: TransportAccountChangeEvent) => void) {
      mockListeners.add(listener);
      return { remove: () => mockListeners.delete(listener) };
    }
  },
}));

const zone = { zoneName: 'DisposableTransportTests', ownerName: '__defaultOwner__' };
const identity = { ...zone, recordName: 'note-1' };
const record: TransportRecord = { ...identity, recordType: 'Note', systemFields: 'version-2', changeTag: 'v2', fields: {} };
const write: TransportWrite = { ...identity, recordType: 'Note', set: {}, clear: [], correlationId: 'outbox-1' };
const cancelled: TransportError = {
  code: 'cancelled', message: 'Cancelled', nativeDomain: 'CKErrorDomain', nativeCode: 20, commitState: 'unknown',
};

type Reservation = {
  cancelled: boolean;
  resolve?: (receipt: TransportResult<unknown>) => void;
  reject?: (error: Error) => void;
};

/** Models reservation/submission/acknowledgement races, not CloudKit semantics. */
class NativeHarness {
  sessions = new Map<string, TransportSessionOptions>();
  reservations = new Map<string, Reservation>();
  reservationLimit = 200;

  transportCreateSession(options: TransportSessionOptions): string {
    const id = `session-${this.sessions.size + 1}`;
    this.sessions.set(id, { ...options });
    return id;
  }

  transportReserveOperation(sessionId: string, operationId: string): void {
    if (this.reservations.size >= this.reservationLimit) {
      throw Object.assign(new Error('Too many concurrent operations'), { code: 'batchLimitExceeded' });
    }
    this.reservations.set(`${sessionId}/${operationId}`, { cancelled: false });
  }

  transportExecute(sessionId: string, operationId: string): Promise<TransportResult<unknown>> {
    const key = `${sessionId}/${operationId}`;
    const reservation = this.reservations.get(key);
    if (!reservation) throw new Error('Operation was not reserved');
    if (reservation.cancelled) {
      this.reservations.delete(key);
      return Promise.resolve({
        status: 'failed', generation: this.sessions.get(sessionId)!.generation, operationId,
        error: { ...cancelled, commitState: 'notCommitted' },
      });
    }
    return new Promise((resolve, reject) => {
      reservation.resolve = resolve;
      reservation.reject = reject;
    });
  }

  transportCancelOperation(sessionId: string, operationId: string): void {
    const reservation = this.reservations.get(`${sessionId}/${operationId}`);
    if (reservation) reservation.cancelled = true;
  }

  transportDisposeSession(sessionId: string): void {
    for (const [key, reservation] of this.reservations) {
      if (key.startsWith(`${sessionId}/`)) reservation.cancelled = true;
    }
  }

  complete<T>(sessionId: string, operationId: string, value: T): void {
    const key = `${sessionId}/${operationId}`;
    const reservation = this.reservations.get(key);
    if (!reservation?.resolve) throw new Error('Operation has not been submitted');
    this.reservations.delete(key);
    reservation.resolve({ status: 'success', generation: this.sessions.get(sessionId)!.generation, operationId, value });
  }

  disconnect(sessionId: string, operationId: string): void {
    const key = `${sessionId}/${operationId}`;
    const reservation = this.reservations.get(key);
    if (!reservation?.reject) throw new Error('Operation has not been submitted');
    this.reservations.delete(key);
    reservation.reject(new Error('Bridge disconnected after submission'));
  }
}

let mockNative: NativeHarness;
let mockNativeUnavailable = false;
let sdk: typeof TransportSDK;
const mockListeners = new Set<(event: TransportAccountChangeEvent) => void>();
let options: TransportSessionOptions;

beforeEach(() => {
  mockNative = new NativeHarness();
  mockNativeUnavailable = false;
  const reactNative = jest.requireMock<{ Platform: { OS: string } }>('react-native');
  reactNative.Platform.OS = 'ios';
  mockListeners.clear();
  options = { containerId: 'iCloud.example.transport', database: 'private', expectedAccountIdentity: 'account-A', generation: 'generation-1' };
  jest.isolateModules(() => { sdk = jest.requireActual<typeof sdk>('../transport'); });
});

describe('caller-owned transport lifecycle', () => {
  it('cancels before submission without cancelling a sibling operation', async () => {
    const session = sdk.createTransportSession(options);
    const first = session.saveRecords({ records: [write] });
    const sibling = session.fetchZone(zone);
    first.cancel();
    first.cancel();
    await Promise.resolve();
    mockNative.complete('session-1', sibling.id, { status: 'found', zone });

    expect(await first.result).toMatchObject({
      status: 'failed', generation: 'generation-1', error: { code: 'cancelled', commitState: 'notCommitted' },
    });
    expect(await sibling.result).toMatchObject({ status: 'success', value: { status: 'found', zone } });
    session.dispose();
  });

  it('preserves a committed receipt when cancel wins the race to JavaScript acknowledgement', async () => {
    const session = sdk.createTransportSession(options);
    const operation = session.saveRecords({ records: [write] });
    await Promise.resolve();
    mockNative.complete<TransportSaveRecordsResult>('session-1', operation.id, {
      outcomes: [{ status: 'saved', id: identity, correlationId: 'outbox-1', record }],
    });
    operation.cancel();

    const result = await operation.result;
    expect(result).toMatchObject({
      status: 'success', generation: 'generation-1',
      value: { outcomes: [{ status: 'saved', correlationId: 'outbox-1', record: { systemFields: 'version-2' } }] },
    });
    session.dispose();
  });

  it('retains partial acknowledgements and uncertainty across repeated teardown', async () => {
    const session = sdk.createTransportSession(options);
    options.generation = 'generation-2';
    const secondWrite = { ...write, recordName: 'note-2', correlationId: 'outbox-2' };
    const operation = session.saveRecords({ records: [write, secondWrite] });
    await Promise.resolve();
    session.dispose();
    session.dispose();
    mockNative.complete<TransportSaveRecordsResult>('session-1', operation.id, {
      outcomes: [
        { status: 'saved', id: identity, correlationId: 'outbox-1', record },
        { status: 'failed', id: { ...identity, recordName: 'note-2' }, correlationId: 'outbox-2', error: cancelled },
      ],
      operationError: cancelled,
    });

    const result = await operation.result;
    expect(result).toMatchObject({ status: 'success', generation: 'generation-1' });
    if (result.status !== 'success') throw new Error('Lost the native write receipt');
    expect(result.value.outcomes).toMatchObject([
      { status: 'saved', correlationId: 'outbox-1', record: { changeTag: 'v2' } },
      { status: 'failed', correlationId: 'outbox-2', error: { commitState: 'unknown' } },
    ]);
    expect(result.value.operationError?.commitState).toBe('unknown');
    expect(await session.fetchZone(zone).result).toMatchObject({
      status: 'failed', generation: 'generation-1', error: { code: 'sessionDisposed', commitState: 'notCommitted' },
    });
  });

  it('settles a reservation disposed before its execute microtask', async () => {
    const session = sdk.createTransportSession(options);
    const operation = session.saveRecords({ records: [write] });
    session.dispose();
    expect(await operation.result).toMatchObject({
      status: 'failed', generation: 'generation-1', error: { code: 'cancelled', commitState: 'notCommitted' },
    });
  });

  it('returns typed noncommitted reservation failures without poisoning later operations', async () => {
    mockNative.reservationLimit = 1;
    const session = sdk.createTransportSession(options);
    const pending = session.saveRecords({ records: [write] });
    const overflow = session.saveRecords({ records: [write] });
    expect(await overflow.result).toMatchObject({
      status: 'failed', generation: 'generation-1',
      error: { code: 'batchLimitExceeded', nativeDomain: 'ExpoCloudKitTransport', commitState: 'notCommitted' },
    });
    session.dispose();
    mockNative.complete('session-1', pending.id, { outcomes: [], operationError: cancelled });
    await pending.result;

    const nextSession = sdk.createTransportSession(options);
    const next = nextSession.fetchZone(zone);
    await Promise.resolve();
    mockNative.complete('session-2', next.id, { status: 'found', zone });
    expect(await next.result).toMatchObject({ status: 'success', value: { status: 'found', zone } });
    nextSession.dispose();
  });

  it('does not claim an unacknowledged submitted write was rejected', async () => {
    const session = sdk.createTransportSession(options);
    const operation = session.saveRecords({ records: [write] });
    await Promise.resolve();
    mockNative.disconnect('session-1', operation.id);
    expect(await operation.result).toMatchObject({
      status: 'failed', generation: 'generation-1', error: { code: 'unknown', commitState: 'unknown' },
    });
    session.dispose();
  });

  it('filters account events by session and generation and fences queued callbacks after removal', () => {
    const session = sdk.createTransportSession(options);
    const events: TransportAccountChangeEvent[] = [];
    const subscription = session.addAccountChangeListener((event) => events.push(event));
    const queued = [...mockListeners];
    const event: TransportAccountChangeEvent = { sessionId: 'session-1', generation: 'generation-1', reason: 'accountChanged' };
    for (const listener of queued) {
      listener({ ...event, sessionId: 'session-2' });
      listener({ ...event, generation: 'generation-old' });
      listener(event);
    }
    subscription.remove();
    subscription.remove();
    for (const listener of queued) listener(event);
    expect(events).toEqual([event]);
    expect(mockListeners.size).toBe(0);

    session.addAccountChangeListener((next) => events.push(next));
    const queuedAtDisposal = [...mockListeners];
    session.dispose();
    session.addAccountChangeListener((next) => events.push(next));
    for (const listener of queuedAtDisposal) listener(event);
    expect(events).toEqual([event]);
    expect(mockListeners.size).toBe(0);
  });

  it.each(['web', 'android'])('returns explicit unsupported results on %s without a native module', async (platform) => {
    const reactNative = jest.requireMock<{ Platform: { OS: string } }>('react-native');
    reactNative.Platform.OS = platform;
    mockNativeUnavailable = true;
    const session = sdk.createTransportSession(options);
    expect(await sdk.getTransportAccount(options.containerId, options.generation)).toMatchObject({
      status: 'failed', operationId: '', error: { code: 'unsupportedPlatform', commitState: 'notCommitted' },
    });
    expect(await session.fetchZone(zone).result).toMatchObject({ status: 'failed', error: { code: 'unsupportedPlatform' } });
    session.dispose();
    expect(await session.fetchZone(zone).result).toMatchObject({ status: 'failed', error: { code: 'sessionDisposed' } });
  });

  it('keeps module acquisition lazy and reports a missing iOS native module explicitly', async () => {
    // An unavailable module must not prevent importing the standalone entry.
    mockNativeUnavailable = true;
    jest.isolateModules(() => { sdk = jest.requireActual<typeof sdk>('../transport'); });
    expect(await sdk.getTransportAccount(options.containerId, options.generation)).toMatchObject({
      status: 'failed', error: { code: 'nativeModuleUnavailable', commitState: 'notCommitted' },
    });
    mockNativeUnavailable = false;
    const session = sdk.createTransportSession(options);
    const operation = session.fetchZone(zone);
    await Promise.resolve();
    mockNative.complete('session-1', operation.id, { status: 'found', zone });
    expect(await operation.result).toMatchObject({ status: 'success', value: { status: 'found', zone } });
    session.dispose();
  });
});
