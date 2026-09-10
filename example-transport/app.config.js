const containerId = process.env.CLOUDKIT_CONTAINER_ID;
const bundleIdentifier = process.env.CLOUDKIT_BUNDLE_ID;
const environment = process.env.CLOUDKIT_ENVIRONMENT || 'Development';
if (!containerId?.startsWith('iCloud.') || !bundleIdentifier) {
  throw new Error('Set CLOUDKIT_CONTAINER_ID and CLOUDKIT_BUNDLE_ID to your provisioned disposable verification app before running Expo.');
}
if (!['Development', 'Production'].includes(environment)) {
  throw new Error('CLOUDKIT_ENVIRONMENT must be Development or Production.');
}
module.exports = {
  expo: {
    name: 'CloudKit Transport Verification',
    slug: 'cloudkit-transport-verification',
    version: '1.0.0',
    orientation: 'portrait',
    platforms: ['ios'],
    ios: { bundleIdentifier, supportsTablet: true },
    plugins: [
      ['expo-cloudkit', {
        containerIds: [containerId],
        iCloudContainerEnvironment: environment,
        enableRemoteNotifications: false,
      }],
      ['expo-file-system', { enableFileSharing: true, supportsOpeningDocumentsInPlace: true }],
    ],
    extra: { cloudKitContainerId: containerId, cloudKitEnvironment: environment },
  },
};
