source "https://rubygems.org"

# Fastlane >2.211 requires Ruby < 3.0 (version 2.x)
ruby ">= 2.6.0", "< 3.0"

gem "fastlane"
gem "ostruct"
gem "abbrev"

plugins_path = File.join(File.dirname(__FILE__), 'fastlane', 'Pluginfile')
eval_gemfile(plugins_path) if File.exist?(plugins_path)
