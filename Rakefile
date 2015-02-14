require 'bundler'
Bundler.setup
require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new do |t|
  t.rspec_opts = ["-f documentation", "--color"]
  t.pattern = "spec/blockchain/*_spec.rb"
end

task :default => [:spec]

desc 'Generate documentation'
task :doc do
  `rm -rf doc`
  system("yard")
end
