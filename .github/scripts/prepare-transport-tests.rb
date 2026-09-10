require 'xcodeproj'

# Inject tests into a freshly prebuilt verification app, never a user project.
root = File.expand_path('../..', __dir__)
ios = File.join(root, 'example-transport/ios')
project_path = Dir.glob(File.join(ios, '*.xcodeproj')).first or abort 'Expo prebuild did not produce an Xcode project'
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.product_type == 'com.apple.product-type.application' } or abort 'Missing app target'

def add_test_target(project, app, name, type, files)
  target = project.new_target(type, name, :ios, '16.4')
  target.add_dependency(app)
  target.build_configurations.each do |config|
    config.build_settings['SWIFT_VERSION'] = '5.9'
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "com.example.cloudkittransport.#{name}"
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
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

files = Dir.glob(File.join(root, 'ios/Tests/*.swift'))
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

# A nested target inherits the app's autolinked pod dependency. Do not redeclare
# ExpoCloudKit with a second source; that would hide packed-package resolution.
podfile = File.join(ios, 'Podfile')
content = File.read(podfile)
abort 'Expected Expo autolinking declaration missing' unless content.include?('use_expo_modules!')
content.sub!('use_expo_modules!', "use_expo_modules!\n  target 'TransportNativeTests' do\n    inherit! :complete\n  end")
File.write(podfile, content)
File.write(File.join(ios, 'transport-scheme.txt'), app.name)
puts "Prepared #{app.name}: #{files.length} native test files and actual module-loading UI test"
