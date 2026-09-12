require 'xcodeproj'

# Inject tests into a freshly prebuilt verification app, never a user project.
root = File.expand_path('../..', __dir__)
consumer = File.expand_path(ENV.fetch('CLOUDKIT_CONSUMER_DIR', File.join(root, 'example-transport')))
ios = File.join(consumer, 'ios')
project_path = Dir.glob(File.join(ios, '*.xcodeproj')).first or abort 'Expo prebuild did not produce an Xcode project'
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.product_type == 'com.apple.product-type.application' } or abort 'Missing app target'

if ARGV.include?('--after-pods')
  unit = project.targets.find { |target| target.name == 'TransportNativeTests' } or abort 'Missing hosted test target'
  # Expo generates a provider for inherited targets too. The test host already owns it.
  unit.source_build_phase.files.select { |file| file.file_ref&.display_name == 'ExpoModulesProvider.swift' }
      .each(&:remove_from_project)
  unit.shell_script_build_phases.select { |phase| phase.name == '[Expo] Configure project' }
      .each(&:remove_from_project)
  project.save
  exit
end

def add_test_target(project, app, name, type, files)
  target = project.new_target(type, name, :ios, '16.4')
  target.product_name = name
  target.product_reference.path = "#{name}.xctest"
  target.add_dependency(app)
  target.build_configurations.each do |config|
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['PRODUCT_NAME'] = name
    config.build_settings['PRODUCT_MODULE_NAME'] = name
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "com.example.cloudkittransport.#{name}"
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'YES'
    config.build_settings['CODE_SIGN_IDENTITY'] = '-'
    if type == :unit_test_bundle
      config.build_settings['TEST_HOST'] = "$(BUILT_PRODUCTS_DIR)/#{app.name}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/#{app.name}"
      config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
    else
      config.build_settings['TEST_TARGET_NAME'] = app.name
    end
  end
  group = project.main_group.new_group(name)
  files.each { |file| target.source_build_phase.add_file_reference(group.new_file(file)) }
  target
end

# Packed verification must compile the tests shipped in the installed package,
# never reach back into the checkout for the native regression suite.
package = root
if ENV.key?('CLOUDKIT_CONSUMER_DIR')
  consumer_real = File.realpath(consumer)
  root_real = File.realpath(root)
  abort 'Packed consumer must be outside the checkout' if consumer_real == root_real || consumer_real.start_with?("#{root_real}/")
  package = File.join(consumer_real, 'node_modules/expo-cloudkit')
  abort 'Packed package must not resolve through a source link' unless File.realpath(package) == package
end
files = Dir.glob(File.join(package, 'ios/Tests/*.swift'))
abort 'Native regression tests missing' if files.empty?
unit = add_test_target(project, app, 'TransportNativeTests', :unit_test_bundle, files)
ui = add_test_target(project, app, 'TransportModuleUITests', :ui_test_bundle,
                     [File.join(__dir__, 'TransportModuleUITests.swift')])
scheme_path = File.join(Xcodeproj::XCScheme.shared_data_dir(project_path), "#{app.name}.xcscheme")
abort "Missing shared scheme #{scheme_path}" unless File.exist?(scheme_path)
scheme = Xcodeproj::XCScheme.new(scheme_path)
scheme.add_test_target(unit)
scheme.add_test_target(ui)
scheme.save!
project.save

# Hosted tests inherit search paths; the application supplies linked pods and its provider.
# Do not redeclare ExpoCloudKit with a second source and hide packed-package resolution.
podfile = File.join(ios, 'Podfile')
content = File.read(podfile)
abort 'Expected Expo autolinking declaration missing' unless content.include?('use_expo_modules!')
content.sub!('use_expo_modules!', "use_expo_modules!\n  target 'TransportNativeTests' do\n    inherit! :search_paths\n  end")
File.write(podfile, content)
File.write(File.join(ios, 'transport-scheme.txt'), app.name)
puts "Prepared #{app.name}: #{files.length} native test files and actual module-loading UI test"
