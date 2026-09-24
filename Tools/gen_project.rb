#!/usr/bin/env ruby
# Generates CookConsole.xcodeproj for the Cook Console iOS app.
# Run from any checkout location: ruby Tools/gen_project.rb
require 'xcodeproj'
require 'fileutils'
require 'json'

repo_root = File.expand_path('..', __dir__)
Dir.chdir(repo_root)

proj_path = 'CookConsole.xcodeproj'
FileUtils.rm_rf(proj_path)

project = Xcodeproj::Project.new(proj_path)

# --- App target ------------------------------------------------------------
app = project.new_target(:application, 'CookConsole', :ios, '26.0')
app.add_file_references(
  Dir['Sources/CookConsole/**/*.swift'].sort.map { |f| project.main_group.new_file(f) }
)

app.resources_build_phase.add_file_reference(project.main_group.new_file('Resources/Assets.xcassets'))

# --- Unit test target ------------------------------------------------------
tests = project.new_target(:unit_test_bundle, 'CookConsoleTests', :ios, '26.0')
tests.add_file_references(
  Dir['Tests/CookConsoleTests/**/*.swift'].sort.map { |f| project.main_group.new_file(f) }
)
tests.add_dependency(app)

# --- UI test target --------------------------------------------------------
ui_tests = project.new_target(:ui_test_bundle, 'CookConsoleUITests', :ios, '26.0')
ui_tests.add_file_references(
  Dir['Tests/CookConsoleUITests/**/*.swift'].sort.map { |f| project.main_group.new_file(f) }
)
ui_tests.add_dependency(app)

# --- Swift package dependencies --------------------------------------------
# Pin Xcode's separate package graph to the immutable revision locked by
# SwiftPM at the repository root.
resolved = JSON.parse(File.read('Package.resolved'))
grdb_pin = resolved.fetch('pins').find { |pin| pin.fetch('identity') == 'grdb.swift' }
raise 'GRDB.swift is missing from Package.resolved' unless grdb_pin
grdb_revision = grdb_pin.fetch('state').fetch('revision')

# Release version seed (docs/release.md).
marketing_version = File.read('VERSION').strip
raise 'VERSION file is empty' if marketing_version.empty?

grdb_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
grdb_package.repositoryURL = 'https://github.com/groue/GRDB.swift.git'
grdb_package.requirement = {
  'kind' => 'revision',
  'revision' => grdb_revision,
}
project.root_object.package_references << grdb_package

[app, tests].each do |target|
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = grdb_package
  product.product_name = 'GRDB'
  target.package_product_dependencies << product

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = product
  target.frameworks_build_phase.files << build_file
end

# --- Build settings --------------------------------------------------------
common = {
  'IPHONEOS_DEPLOYMENT_TARGET' => '26.0',
  'SWIFT_VERSION' => '6.0',
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
  c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  c.build_settings['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  # Release versioning (docs/release.md): MARKETING_VERSION is seeded from
  # the repo-root VERSION file; the release workflow overrides
  # CURRENT_PROJECT_VERSION with the Actions run number for monotonic
  # TestFlight build numbers.
  c.build_settings['MARKETING_VERSION'] = marketing_version
  c.build_settings['CURRENT_PROJECT_VERSION'] = '1'
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

ui_tests.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.infinityball.cookconsole.uitests'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  c.build_settings['TEST_TARGET_NAME'] = 'CookConsole'
end

project.save

# --- Shared scheme ----------------------------------------------------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.add_test_target(ui_tests)
scheme.set_launch_target(app)
scheme.save_as(proj_path, 'CookConsole', true)

puts 'OK: generated ' + proj_path
