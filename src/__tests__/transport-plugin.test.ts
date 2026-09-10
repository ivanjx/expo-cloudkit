/** @jest-environment node */
import { compileModsAsync, type ConfigPlugin } from '@expo/config-plugins';
import { withCloudKit, type WithCloudKitOptions } from '../../plugin/withCloudKit';

async function generate(options: Partial<WithCloudKitOptions> = {}, ios: Parameters<ConfigPlugin>[0]['ios'] = {}) {
  const config = withCloudKit({ name: 'Transport Verification', slug: 'transport-verification', ios }, {
    containerIds: ['iCloud.test.transport'],
    ...options,
  });
  return (await compileModsAsync(config, {
    projectRoot: process.cwd(), platforms: ['ios'], introspect: true, ignoreExistingNativeFiles: true,
  })).ios!;
}

describe('manual transport config plugin', () => {
  it('does not request unused background modes and merges entitlements without losing app capabilities', async () => {
    const ios = await generate({ enableRemoteNotifications: false, iCloudContainerEnvironment: 'Development' }, {
      entitlements: {
        'com.apple.developer.icloud-container-identifiers': ['iCloud.test.existing', 'iCloud.test.transport'],
        'com.apple.developer.icloud-services': ['CloudDocuments'],
        'com.apple.security.application-groups': ['group.test.existing'],
        'com.apple.developer.associated-domains': ['applinks:example.com'],
      },
    });
    expect(ios.infoPlist?.UIBackgroundModes).toBeUndefined();
    expect(ios.entitlements).toMatchObject({
      'com.apple.developer.icloud-container-identifiers': ['iCloud.test.existing', 'iCloud.test.transport'],
      'com.apple.developer.icloud-services': ['CloudDocuments', 'CloudKit'],
      'com.apple.developer.icloud-container-environment': 'Development',
      'com.apple.security.application-groups': ['group.test.existing'],
      'com.apple.developer.associated-domains': ['applinks:example.com'],
    });
  });

  it('preserves explicitly requested background work when remote notifications are disabled', async () => {
    const ios = await generate({ enableRemoteNotifications: false, backgroundSyncTaskIdentifier: 'test.sync' }, {
      infoPlist: { UIBackgroundModes: ['audio', 'remote-notification'], BGTaskSchedulerPermittedIdentifiers: ['test.existing'] },
    });
    expect(ios.infoPlist?.UIBackgroundModes).toEqual(['audio', 'remote-notification', 'fetch', 'processing']);
    expect(ios.infoPlist?.BGTaskSchedulerPermittedIdentifiers).toEqual(['test.existing', 'test.sync']);
  });

  it('retains push-driven sync for existing callers and Production configuration', async () => {
    const ios = await generate({}, { infoPlist: { UIBackgroundModes: ['audio'] } });
    expect(ios.infoPlist?.UIBackgroundModes).toEqual(['audio', 'remote-notification']);
    expect(ios.entitlements?.['com.apple.developer.icloud-container-environment']).toBe('Production');
  });
});
