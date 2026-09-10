/** Caller-owned CloudKit transport. All tokens and system fields are opaque strings. */
export type TransportErrorCode =
  | 'networkUnavailable'
  | 'serviceUnavailable'
  | 'notAuthenticated'
  | 'accountTemporarilyUnavailable'
  | 'accountMismatch'
  | 'permissionFailure'
  | 'quotaExceeded'
  | 'rateLimited'
  | 'zoneBusy'
  | 'zoneNotFound'
  | 'zoneDeleted'
  | 'recordNotFound'
  | 'tokenExpired'
  | 'conflict'
  | 'invalidArguments'
  | 'invalidRecord'
  | 'assetFileNotFound'
  | 'assetTooLarge'
  | 'batchLimitExceeded'
  | 'cancelled'
  | 'sessionDisposed'
  | 'invalidToken'
  | 'invalidSystemFields'
  | 'fileIO'
  | 'diskFull'
  | 'unsupportedPlatform'
  | 'nativeModuleUnavailable'
  | 'unknown';

export interface TransportError {
  code: TransportErrorCode;
  message: string;
  nativeDomain: string;
  nativeCode: number;
  retryAfterSeconds?: number;
  /** unknown requires reconciliation: cancellation cannot undo an accepted write. */
  commitState: 'notCommitted' | 'unknown';
}

/** A successful envelope may still contain partial per-record failures. */
export type TransportResult<T> =
  | { status: 'success'; generation: string; operationId: string; value: T }
  | { status: 'failed'; generation: string; operationId: string; error: TransportError };

export interface TransportAccount {
  availability: 'available' | 'noAccount' | 'restricted' | 'couldNotDetermine' | 'temporarilyUnavailable';
  /** Opaque, container-scoped account binding; never a credential. */
  identity?: string;
}

export interface TransportSessionOptions {
  containerId: string;
  database: 'private';
  expectedAccountIdentity: string;
  generation: string;
}

export interface TransportZoneID {
  zoneName: string;
  ownerName: string;
}

export interface TransportRecordID extends TransportZoneID {
  recordName: string;
}

export interface TransportReference extends TransportRecordID {
  action: 'none' | 'deleteSelf';
}

export interface TransportLocation {
  latitude: number;
  longitude: number;
}

export type TransportValueField =
  | { type: 'string'; value: string }
  | { type: 'number'; value: number }
  | { type: 'date'; value: string }
  | { type: 'data'; value: string }
  | { type: 'location'; value: TransportLocation }
  | { type: 'reference'; value: TransportReference }
  | { type: 'stringList'; value: string[] }
  | { type: 'numberList'; value: number[] }
  | { type: 'dateList'; value: string[] }
  | { type: 'dataList'; value: string[] }
  | { type: 'locationList'; value: TransportLocation[] }
  | { type: 'referenceList'; value: TransportReference[] };

/** Dates use ISO 8601; data uses base64; upload assets use stable local file URIs. */
export type TransportFieldInput = TransportValueField | { type: 'asset'; value: string };

/** Read assets expose metadata only, never CloudKit temporary file locations. */
export type TransportField =
  | TransportValueField
  | { type: 'asset'; value: { available: true } }
  | { type: 'assetList'; value: { count: number } };

export interface TransportRecord extends TransportRecordID {
  recordType: string;
  systemFields: string;
  changeTag?: string;
  fields: Record<string, TransportField>;
  creationDate?: number;
  modificationDate?: number;
}

export interface TransportWrite extends TransportRecordID {
  recordType: string;
  /** Required when updating a previously observed record. Omit only for creation. */
  systemFields?: string;
  /** Omitted fields, including assets, are preserved. */
  set: Record<string, TransportFieldInput>;
  /** Explicit removals. A field cannot appear in both set and clear. */
  clear: string[];
  correlationId: string;
}

export interface TransportZoneResult {
  status: 'found' | 'created';
  zone: TransportZoneID;
}

export interface TransportFetchChangesOptions {
  zone: TransportZoneID;
  previousToken?: string;
  /** Required; [] requests metadata only. */
  desiredKeys: string[];
  /** 1...200, if supplied. */
  resultsLimit?: number;
}

export interface TransportDeletion extends TransportRecordID {
  recordType: string;
}

export interface TransportRecordFailure {
  id: TransportRecordID;
  error: TransportError;
}

export interface TransportFetchChangesResult {
  records: TransportRecord[];
  deletions: TransportDeletion[];
  /** Absent on any failure. Persist only together with the applied page. */
  nextToken?: string;
  moreComing: boolean;
  failures: TransportRecordFailure[];
  checkpointUsable: boolean;
  operationError?: TransportError;
}

export interface TransportFetchRecordsOptions {
  /** At most 200 unique identities; no automatic chunking. */
  records: TransportRecordID[];
  desiredKeys: string[];
}

export type TransportFetchRecordOutcome =
  | { status: 'found'; id: TransportRecordID; record: TransportRecord }
  | { status: 'notFound'; id: TransportRecordID }
  | { status: 'failed'; id: TransportRecordID; error: TransportError };

export interface TransportFetchRecordsResult {
  outcomes: TransportFetchRecordOutcome[];
  operationError?: TransportError;
}

export interface TransportSaveRecordsOptions {
  /** At most 200; conditional, non-atomic writes with no merge or retry. */
  records: TransportWrite[];
}

export type TransportSaveRecordOutcome =
  | { status: 'saved'; id: TransportRecordID; correlationId: string; record: TransportRecord }
  | {
    status: 'conflict';
    id: TransportRecordID;
    correlationId: string;
    /** If absent, the caller can perform a targeted fetch for conflict recovery. */
    serverRecord?: TransportRecord;
    /** Serialization failure for the server record, separate from the conflict. */
    serverRecordError?: TransportError;
    error: TransportError;
  }
  | { status: 'failed' | 'unattempted'; id: TransportRecordID; correlationId: string; error: TransportError };

export interface TransportSaveRecordsResult {
  outcomes: TransportSaveRecordOutcome[];
  operationError?: TransportError;
}

export interface TransportDownloadAssetsOptions {
  record: TransportRecordID;
  assetFields: string[];
  /** Other owner/version metadata to fetch alongside the assets. */
  desiredKeys: string[];
}

export interface TransportStagedAsset {
  field: string;
  /** Durable app-sandbox file. After delivery, the caller owns adoption/deletion. */
  uri: string;
  byteCount: number;
}

export interface TransportDownloadAssetsResult {
  /** Asset owner and version from the same fetched record. */
  record: TransportRecord;
  assets: TransportStagedAsset[];
}

export interface TransportAccountChangeEvent {
  sessionId: string;
  generation: string;
  reason: 'accountChanged' | 'accountMismatch';
  account?: TransportAccount;
}

export interface TransportSubscription {
  remove(): void;
}

export interface TransportOperation<T> {
  id: string;
  result: Promise<TransportResult<T>>;
  /** Best effort; the eventual result retains any known write receipts. */
  cancel(): void;
}

export interface CloudKitTransportSession {
  fetchZone(zone: TransportZoneID): TransportOperation<TransportZoneResult>;
  createZone(zone: TransportZoneID): TransportOperation<TransportZoneResult>;
  fetchChanges(options: TransportFetchChangesOptions): TransportOperation<TransportFetchChangesResult>;
  fetchRecords(options: TransportFetchRecordsOptions): TransportOperation<TransportFetchRecordsResult>;
  saveRecords(options: TransportSaveRecordsOptions): TransportOperation<TransportSaveRecordsResult>;
  downloadAssets(options: TransportDownloadAssetsOptions): TransportOperation<TransportDownloadAssetsResult>;
  addAccountChangeListener(listener: (event: TransportAccountChangeEvent) => void): TransportSubscription;
  /** Idempotent. Cancels native operations and removes subscriptions, without discarding receipts. */
  dispose(): void;
}
