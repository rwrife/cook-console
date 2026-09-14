#!/usr/bin/env ruby
# Generates CookConsole.xcodeproj for the Cook Console iOS app.
# Run inside: docker run --rm -v "$PWD:/work" ruby:3.3-slim bash -lc "gem install xcodeproj --no-document && ruby /work/Tools/gen_project.rb"
require 'xcodeproj'

Dir.chdir('/work')

proj_path = 'CookConsole.xcodeproj'
require 'fileutils'
FileUtils.rm_rf(proj_path)

project = Xcodeproj::Project.new(proj_path)

# --- App target ------------------------------------------------------------
app = project.new_target(:application, 'CookConsole', :ios, '26.0')
app.add_file_references(
  Dir['Sources/CookConsole/**/*.swift'].sort.map { |f| project.main_group.new_file(f) }
)

# --- Unit test target ------------------------------------------------------
tests = project.new_target(:unit_test_bundle, 'CookConsoleTests', :ios, '26.0')
tests.add_file_references(
  Dir['Tests/CookConsoleTests/**/*.swift'].sort.map { |f| project.main_group.new_file(f) }
)
tests.add_dependency(app)

# --- Build settings --------------------------------------------------------
common = {
  'IPHONEOS_DEPLOYMENT_TARGET' => '26.0',
  'SWIFT_VERSION' => '5.0',
  'SWIFT_STRICT_CONCURRENCY' => 'complete',
  'CODE_SIGN_STYLE' => 'Automatic',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'YES',
}
project.build_configurations.each do |c|
  common.each { |k, v| c.build_settings[k] = v }
end

app.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.infinityball.cookconsole'
  c.build_settings['PRODUCT_NAME'] = 'CookConsole'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  c.build_settings['INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone'] = 'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
  c.build_settings['ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_EXTENSIONS'] = 'YES'
  c.build_settings['ENABLE_PREVIEWS'] = 'YES'
end

tests.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.infinityball.cookconsole.tests'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/CookConsole.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CookConsole'
  c.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

project.save

# --- Shared scheme ----------------------------------------------------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(proj_path, 'CookConsole', true)

puts 'OK: generated ' + proj_path
