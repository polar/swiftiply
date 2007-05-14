#####
# Swiftcore Analogger
#   http://analogger.swiftcore.org
#   Copyright 2007 Kirk Haines
#
#   Licensed under the Ruby License.  See the README for details.
#
#####

spec = Gem::Specification.new do |s|
  s.name              = 'swiftiply'
  s.author            = %q(Kirk Haines)
  s.email             = %q(wyhaines@gmail.com)
  s.version           = '0.5.0'
  s.summary           = %q(A fast clustering proxy for web applications.)
  s.platform          = Gem::Platform::RUBY

  s.has_rdoc          = true
  s.rdoc_options      = %w(--title Swiftcore::Swiftiply --main README --line-numbers)
  s.extra_rdoc_files  = %w(README)

  s.files = Dir['**/*']
	s.executables = %w(swiftiply mongrel_rails swiftiply_mongrel_rails)
	s.require_paths = %w(src)

	s.requirements      << "Eventmachine 0.7.0 or higher."
	s.add_dependency('eventmachine')
  s.test_files = []

  s.rubyforge_project = %q(swiftiply)
  s.homepage          = %q(http://swiftiply.swiftcore.org/)
  description         = []
  File.open("README") do |file|
    file.each do |line|
      line.chomp!
      break if line.empty?
      description << "#{line.gsub(/\[\d\]/, '')}"
    end
  end
  s.description = description[1..-1].join(" ")
end