import React, { useEffect, useRef, useState } from 'react';
import { Button, ScrollView, StyleSheet, Switch, Text, TextInput, View } from 'react-native';
import Constants from 'expo-constants';
import { Directory, File, Paths } from 'expo-file-system';
import { requireNativeModule } from 'expo-modules-core';
import {
  createTransportSession, getTransportAccount, TRANSPORT_DEFAULT_OWNER,
  type CloudKitTransportSession, type TransportAccount, type TransportFetchChangesResult,
  type TransportOperation, type TransportRecord, type TransportWrite,
} from 'expo-cloudkit/transport';

const containerId = String(Constants.expoConfig?.extra?.cloudKitContainerId ?? '');
const unique = () => `${Date.now()}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
const freshZone = () => `TransportVerification-${unique()}`;
const notebookDirectory = new Directory(Paths.document, 'transport-verification');
const metadataKeys = ['title', 'revision', 'assetLabel'];
let lastSnapshotTime = Date.now();

type Notebook = {
  containerId: string;
  zoneName: string;
  accountIdentity?: string;
  record?: TransportRecord;
  draft?: TransportWrite;
  clientA?: TransportWrite;
  clientB?: TransportWrite;
  token?: string;
  committedPage?: TransportFetchChangesResult;
  downloads?: { uri: string; byteCount: number; owner: TransportRecord }[];
  uploadUri?: string;
};

function restore(): Notebook {
  notebookDirectory.create({ intermediates: true, idempotent: true });
  const snapshots = notebookDirectory.list().filter((file): file is File => file instanceof File && file.name.endsWith('.json'));
  snapshots.sort((a, b) => b.name.localeCompare(a.name));
  for (const file of snapshots) {
    try {
      const snapshot: Notebook = JSON.parse(file.textSync());
      if (snapshot.containerId === containerId && snapshot.zoneName.startsWith('TransportVerification-')) return snapshot;
    } catch { /* An incomplete snapshot is not a committed notebook. */ }
  }
  return { containerId, zoneName: freshZone() };
}

function NativeLoadingSmoke() {
  const [status, setStatus] = useState('loading');
  useEffect(() => {
    let mounted = true;
    let transport: CloudKitTransportSession | undefined;
    void (async () => {
      try {
        requireNativeModule('ExpoCloudKitTransport');
        transport = createTransportSession({
          containerId, database: 'private', expectedAccountIdentity: 'ci-no-cloud-operations', generation: 'ci-smoke',
        });
        const result = await transport.fetchRecords({ records: [], desiredKeys: [] }).result;
        transport.dispose();
        transport.dispose();
        if (result.status !== 'failed' || result.error.code !== 'invalidArguments' || result.generation !== 'ci-smoke') {
          throw new Error(`Unexpected native validation receipt: ${JSON.stringify(result)}`);
        }
        if (mounted) setStatus('transport-native-loaded');
      } catch (error) {
        if (mounted) setStatus(`transport-native-failed: ${String(error)}`);
      }
    })();
    return () => { mounted = false; transport?.dispose(); };
  }, []);
  return <View style={{ padding: 60 }}><Text accessibilityLabel={status} testID={status}>{status}</Text></View>;
}

// Each explicit commit publishes a whole page+checkpoint as a new local file.
// This is a verification notebook, not an application sync engine or database.
function persist(snapshot: Notebook) {
  lastSnapshotTime = Math.max(Date.now(), lastSnapshotTime + 1);
  const name = String(lastSnapshotTime);
  const partial = new File(notebookDirectory, `${name}.partial`);
  partial.create();
  try {
    partial.write(JSON.stringify(snapshot));
    partial.move(new File(notebookDirectory, `${name}.json`));
  } catch (error) {
    if (partial.exists) partial.delete();
    throw error;
  }
}

export default function App() {
  return process.env.EXPO_PUBLIC_CI_SMOKE === '1' ? <NativeLoadingSmoke /> : <TransportLab />;
}

function TransportLab() {
  const [notebook, setNotebook] = useState<Notebook>(restore);
  const book = useRef(notebook);
  const session = useRef<CloudKitTransportSession | null>(null);
  const subscription = useRef<{ remove(): void } | null>(null);
  const currentGeneration = useRef('');
  const active = useRef(new Map<string, { cancel(): void }>());
  const held = useRef<(() => void)[]>([]);
  const holdAcknowledgements = useRef(false);
  const [holding, setHolding] = useState(false);
  const [account, setAccount] = useState<TransportAccount>();
  const [zoneInput, setZoneInput] = useState(notebook.zoneName);
  const [title, setTitle] = useState('Manual metadata edit');
  const [cancelDelay, setCancelDelay] = useState('25');
  const [pageLimit, setPageLimit] = useState('1');
  const [assetMiB, setAssetMiB] = useState('1');
  const [page, setPage] = useState<TransportFetchChangesResult>();
  const [log, setLog] = useState<string[]>([]);

  const report = (label: string, value?: unknown) => {
    const message = `${new Date().toISOString()} ${label}${value === undefined ? '' : `\n${JSON.stringify(value, null, 2)}`}`;
    console.log(message);
    setLog((previous) => [message, ...previous].slice(0, 40));
  };
  const update = (patch: Partial<Notebook>, commit = false) => {
    const next = { ...book.current, ...patch };
    if (commit) persist(next);
    book.current = next;
    setNotebook(next);
  };
  const close = () => {
    currentGeneration.current = '';
    subscription.current?.remove();
    subscription.current = null;
    session.current?.dispose();
    session.current?.dispose();
    session.current = null;
    report('Session disposed twice; late receipts remain visible but cannot update notebook.');
  };
  useEffect(() => () => {
    subscription.current?.remove();
    session.current?.dispose();
  }, []);

  const requireSession = () => {
    if (!session.current) throw new Error('Probe account, then open a session first.');
    return session.current;
  };
  const zone = () => ({ zoneName: book.current.zoneName, ownerName: TRANSPORT_DEFAULT_OWNER });
  const recordID = () => ({ ...zone(), recordName: 'verification-record' });
  const button = (label: string, action: () => unknown | Promise<unknown>) => (
    <View style={styles.button} key={label}><Button title={label} onPress={() => {
      Promise.resolve().then(action).catch((error: unknown) => report(label, String(error)));
    }} /></View>
  );
  async function run<T>(label: string, operation: TransportOperation<T>, receive?: (value: T) => void) {
    active.current.set(operation.id, operation);
    report(`${label} started`, { operationId: operation.id });
    try {
      const result = await operation.result;
      report(`${label} native receipt`, result);
      const acknowledge = () => {
        if (result.generation !== currentGeneration.current) {
          report(`${label} stale receipt rejected by example generation fence`);
        } else if (result.status === 'success') {
          receive?.(result.value);
        }
      };
      if (holdAcknowledgements.current) {
        held.current.push(acknowledge);
        report('Application acknowledgement held. Cancel or dispose, then release to inspect fencing.');
      } else acknowledge();
    } finally {
      active.current.delete(operation.id);
    }
  }
  const save = (label: string, records: TransportWrite[]) => run(label, requireSession().saveRecords({ records }), (value) => {
    const saved = value.outcomes.find((outcome) => outcome.status === 'saved' && outcome.id.recordName === 'verification-record');
    if (saved?.status === 'saved') update({ record: saved.record });
  });
  const draft = (set: TransportWrite['set'], clear: string[] = []): TransportWrite => {
    if (!book.current.record) throw new Error('Fetch the existing metadata version before preparing an update.');
    return { ...recordID(), recordType: 'TransportProbe', systemFields: book.current.record.systemFields,
      set, clear, correlationId: unique() };
  };
  const asset = () => {
    const size = Number(assetMiB);
    if (!Number.isInteger(size) || size < 1 || size > 32) throw new Error('Asset size must be 1–32 MiB.');
    const file = new File(notebookDirectory, `upload-${unique()}.txt`);
    file.create();
    file.write(`Transport asset ${unique()}\n${'x'.repeat(size * 1024 * 1024)}`);
    update({ uploadUri: file.uri }, true);
    return file.uri;
  };
  const fetchMetadata = () => run('Targeted metadata + missing lookup', requireSession().fetchRecords({
    records: [recordID(), { ...zone(), recordName: `missing-${unique()}` }], desiredKeys: metadataKeys,
  }), (value) => {
    const found = value.outcomes.find((outcome) => outcome.status === 'found');
    if (found?.status === 'found') update({ record: found.record });
  });
  const fetchPage = (initial = false) => {
    const resultsLimit = Number(pageLimit);
    if (!Number.isInteger(resultsLimit) || resultsLimit < 1 || resultsLimit > 200) throw new Error('Page limit must be 1–200.');
    return run('Fetch page (checkpoint unchanged)', requireSession().fetchChanges({
      zone: zone(), previousToken: initial ? undefined : book.current.token, desiredKeys: metadataKeys, resultsLimit,
    }), setPage);
  };
  const download = (cancel = false) => {
    const operation = requireSession().downloadAssets({ record: recordID(), assetFields: ['attachment'], desiredKeys: metadataKeys });
    if (cancel) setTimeout(() => operation.cancel(), Number(cancelDelay));
    return run('Download durable asset', operation, (value) => update({
      downloads: [...(book.current.downloads ?? []), ...value.assets.map((item) => ({
        uri: item.uri, byteCount: item.byteCount, owner: value.record,
      }))],
    }, true));
  };

  return <ScrollView contentContainerStyle={styles.container}>
    <Text style={styles.heading}>CloudKit transport device lab</Text>
    <Text selectable>Container: {containerId}\nEnvironment: {String(Constants.expoConfig?.extra?.cloudKitEnvironment)}\nZone: {notebook.zoneName}\nExpected account: {notebook.accountIdentity ?? '(not bound)'}\nGeneration: {currentGeneration.current || '(closed)'}</Text>
    <Text>Only disposable TransportVerification-* zones are accepted. Creation is explicit. No polling, subscriptions to CloudKit pushes, queues, retries, SQLite, or cloud deletion.</Text>
    {button('1. Probe current account', async () => {
      const result = await getTransportAccount(containerId, `probe-${unique()}`);
      report('Account', result);
      if (result.status === 'success') setAccount(result.value);
    })}
    {button('2. Open session / retain persisted account binding', () => {
      if (account?.availability !== 'available' || !account.identity) throw new Error('Probe an available signed-in account first.');
      close();
      const identity = book.current.accountIdentity ?? account.identity;
      update({ accountIdentity: identity }, true);
      const generation = unique();
      currentGeneration.current = generation;
      session.current = createTransportSession({ containerId, database: 'private', expectedAccountIdentity: identity, generation });
      subscription.current = session.current.addAccountChangeListener((event) => {
        if (event.generation === currentGeneration.current) currentGeneration.current = '';
        report('Account invalidation (open a fresh session only after explicit account decision)', event);
      });
      report('Opened', { generation, expectedAccountIdentity: identity });
    })}
    {button('Dispose twice', close)}
    <TextInput style={styles.input} value={zoneInput} onChangeText={setZoneInput} autoCapitalize="none" accessibilityLabel="Disposable zone name" />
    {button('Use shared disposable zone (reset only local notebook)', () => {
      if (!/^TransportVerification-[A-Za-z0-9-]{8,150}$/.test(zoneInput)) throw new Error('Use a TransportVerification- zone from this lab only.');
      close();
      const next = { containerId, zoneName: zoneInput };
      persist(next); book.current = next; setNotebook(next); setPage(undefined);
      report('Selected zone; no CloudKit create/delete was performed.');
    })}
    {button('Generate a new disposable zone name', () => setZoneInput(freshZone()))}
    {button('Check zone (must not create)', () => run('Fetch zone', requireSession().fetchZone(zone())))}
    {button('Explicitly create this disposable zone', () => run('Create zone', requireSession().createZone(zone())))}
    <Text style={styles.heading}>Records and conditional masks</Text>
    <TextInput style={styles.input} value={title} onChangeText={setTitle} accessibilityLabel="Metadata title" />
    <TextInput style={styles.input} value={assetMiB} onChangeText={setAssetMiB} keyboardType="number-pad" accessibilityLabel="Upload size MiB" />
    {button('Create stable record + local upload (repeat must conflict)', () => save('Create with asset', [{
      ...recordID(), recordType: 'TransportProbe', correlationId: unique(), clear: [],
      set: { title: { type: 'string', value: title }, revision: { type: 'number', value: 1 },
        assetLabel: { type: 'string', value: unique() }, attachment: { type: 'asset', value: asset() } },
    }]))}
    {button('Fetch metadata only + missing record', fetchMetadata)}
    {button('Prepare metadata-only draft and persist mask + system fields', () => {
      update({ draft: draft({ title: { type: 'string', value: title } }) }, true);
      report('Draft saved. Force-quit/reopen, probe/open, then submit without fetching or downloading the asset.');
    })}
    {button('Submit persisted draft unchanged', () => {
      if (!book.current.draft) throw new Error('Prepare a draft first.');
      return save('Persisted draft', [book.current.draft]);
    })}
    {button('Capture two clients at current observed version', () => {
      update({ clientA: draft({ title: { type: 'string', value: `A ${title}` } }),
        clientB: draft({ title: { type: 'string', value: `B ${title}` } }) }, true);
      report('Both masks and identical system fields persisted; save A then B.');
    })}
    {button('Save client A', () => {
      if (!book.current.clientA) throw new Error('Capture clients first.');
      return save('Client A', [book.current.clientA]);
    })}
    {button('Save client B (expect conflict, no merge)', () => {
      if (!book.current.clientB) throw new Error('Capture clients first.');
      return save('Client B', [book.current.clientB]);
    })}
    {button('Mixed batch: new success + stale client B', () => {
      if (!book.current.clientB) throw new Error('Capture clients and save A first.');
      return save('Mixed batch', [{ ...recordID(), recordName: `mixed-${unique()}`, recordType: 'TransportProbe',
        set: { title: { type: 'string', value: title } }, clear: [], correlationId: unique() }, book.current.clientB]);
    })}
    {button('Replace asset + metadata together', () => save('Replace asset', [draft({
      attachment: { type: 'asset', value: asset() }, assetLabel: { type: 'string', value: unique() },
    })]))}
    {button('Explicitly clear asset', () => save('Clear asset', [draft({}, ['attachment'])]))}
    {button('Persist current observed record system fields', () => { persist(book.current); report('Notebook persisted.'); })}
    <Text style={styles.heading}>Changes and caller checkpoint</Text>
    <TextInput style={styles.input} value={pageLimit} onChangeText={setPageLimit} keyboardType="number-pad" accessibilityLabel="Page limit" />
    <Text selectable>Checkpoint: {notebook.token ?? '(initial scan)'}\nLast page: {page ? `${page.records.length} changed, ${page.deletions.length} deleted; more=${page.moreComing}; usable=${page.checkpointUsable}` : '(none)'}</Text>
    {button('Fetch / replay from persisted checkpoint', () => fetchPage())}
    {button('Initial scan without changing checkpoint', () => fetchPage(true))}
    {button('Commit displayed page + next token together to local file', () => {
      if (!page?.checkpointUsable || !page.nextToken) throw new Error('No usable checkpoint; replay instead of advancing.');
      update({ committedPage: page, token: page.nextToken }, true);
      report('Page and checkpoint committed in one notebook snapshot.');
    })}
    <Text style={styles.heading}>Durable files and cancellation</Text>
    <TextInput style={styles.input} value={cancelDelay} onChangeText={setCancelDelay} keyboardType="number-pad" accessibilityLabel="Cancellation delay milliseconds" />
    {button('Download asset and persist owner/version + URI', () => download())}
    {button('Download with delayed cancellation', () => download(true))}
    {button('Verify persisted downloads and upload still readable', async () => {
      for (const item of book.current.downloads ?? []) {
        const file = new File(item.uri);
        const bytes = await file.bytes();
        report('Durable asset read', { uri: item.uri, expectedBytes: item.byteCount, actualBytes: bytes.length,
          matches: bytes.length === item.byteCount, owner: item.owner });
      }
      if (book.current.uploadUri) {
        const file = new File(book.current.uploadUri);
        report('Caller upload source', { uri: file.uri, exists: file.exists, bytes: file.size });
      }
    })}
    {button('Cancel before native submission', () => {
      const operation = requireSession().fetchZone(zone());
      operation.cancel();
      return run('Immediate cancellation', operation);
    })}
    {button('Save draft with delayed cancellation (reconcile stable ID)', () => {
      if (!book.current.draft) throw new Error('Prepare a draft first.');
      const operation = requireSession().saveRecords({ records: [book.current.draft] });
      setTimeout(() => operation.cancel(), Number(cancelDelay));
      return run('Possibly committed save', operation);
    })}
    {button('Cancel all currently pending operations', () => {
      active.current.forEach((operation) => operation.cancel()); report('Cancellation requested; inspect commitState and reconcile by fetch.');
    })}
    <View style={styles.row}><Switch value={holding} onValueChange={(value) => {
      holdAcknowledgements.current = value; setHolding(value);
    }} /><Text>Hold application acknowledgements</Text></View>
    {button('Release held acknowledgements', () => {
      const callbacks = held.current; held.current = []; callbacks.forEach((acknowledge) => acknowledge());
    })}
    <Text>After a native receipt, disposal cannot undo CloudKit. Holding above delays only the example's application acknowledgement, not the native bridge. For native-copy cancellation, use a larger asset and vary delay; inspect logs and staging files on device.</Text>
    <Text style={styles.heading}>Receipts (also in Metro logs)</Text>
    {button('Clear visible log', () => setLog([]))}
    {log.map((entry, index) => <Text selectable style={styles.log} key={index}>{entry}</Text>)}
  </ScrollView>;
}

const styles = StyleSheet.create({
  container: { padding: 20, paddingTop: 64, paddingBottom: 60, gap: 12 },
  heading: { fontSize: 21, fontWeight: '600' },
  button: { borderWidth: 1, borderColor: '#999', borderRadius: 6, padding: 4 },
  input: { borderWidth: 1, borderColor: '#777', padding: 10, borderRadius: 6 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  log: { fontFamily: 'Menlo', fontSize: 11, paddingVertical: 8, borderBottomWidth: 1, borderColor: '#aaa' },
});
