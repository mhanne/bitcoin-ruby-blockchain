# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require 'bitcoin'
require 'bitcoin/blockchain/version'

Gem::Specification.new do |s|
  s.name        = "bitcoin-ruby-blockchain"
  s.version     = Bitcoin::Blockchain::VERSION
  s.authors     = ["Marius Hanne"]
  s.email       = ["marius.hanne@sourceagency.org"]
  s.summary     = %q{bitcoin blockchain storage based on bitcoin-ruby}
  s.description = %q{bitcoin blockchain storage based on bitcoin-ruby with support for several different backends and database adapters.}
  s.homepage    = "https://github.com/mhanne/bitcoin-ruby-blockchain"
  s.license     = "MIT"

  # s.rubyforge_project = "bitcoin-ruby-blockchain"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  s.required_rubygems_version = ">= 1.3.6"
  # s.add_dependency "bitcoin-ruby"
end
