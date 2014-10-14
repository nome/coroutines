require 'rubygems'
require 'rdoc'

readme_header = open("README.rdoc").drop(1).take_while{|l| not l.strip.empty? }

SPEC = Gem::Specification.new do |s|
	s.name     = "coroutines"
	s.version  = %x(git describe --tags --dirty 2>/dev/null)[1..-1]
	if $? != 0
		s.version = File.read("VERSION")
	end
	s.licenses = ["Ruby", "BSD-2-Clause"]
	s.summary  = "Library for producer/transformer/consumer coroutines"
	s.description = readme_header.join
	s.homepage = "http://nome.github.io/coroutines"
	s.metadata = {
		"issue_tracker" => "https://github.com/nome/coroutines/issues",
		"source_code" => "https://github.com/nome/coroutines"
	}
	s.authors  = ["Knut Franke"]
	s.email    = "knut.franke@gmx.de"
	s.platform = Gem::Platform::RUBY
	s.files    = [
		"lib/coroutines.rb",
		"lib/coroutines/sink.rb",
		"lib/coroutines/base.rb",
		"lib/coroutines/operators.rb",
	]
	s.require_path = "lib"
	s.test_file = "tests/suite.rb"
	s.has_rdoc = true
	s.extra_rdoc_files = ["README.rdoc"]
	s.add_runtime_dependency "lazy_enumerator"
	s.add_development_dependcy "test-unit", "~> 3.0"
end
