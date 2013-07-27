#####
# Swiftcore Swiftiply
#   http://swiftiply.swiftcore.org
#   Copyright 2007,2008 Kirk Haines
#   wyhaines@gmail.com
#   Copyright 2013 Polar Humenn
#
#   Licensed under the Ruby License.  See the README for details.
#
#####

spec = Gem::Specification.new do |s|
  s.name              = 'swiftiply'
  s.author            = %q(Kirk Haines, Dr. Polar Humenn)
  s.email             = %q(wyhaines@gmail.com, polar@syr.edu)
  s.version           = '0.7.0.pre'
  s.summary           = %q(A fast clustering proxy for web applications.)
  s.platform          = Gem::Platform::RUBY

  s.has_rdoc          = true
  s.rdoc_options      = %w(--title Swiftcore::Swiftiply --main README --line-numbers)
  s.extra_rdoc_files  = %w(README)
  s.extensions        << 'ext/fastfilereader/extconf.rb'
	s.extensions        << 'ext/deque/extconf.rb'
	s.extensions        << 'ext/splaytree/extconf.rb'
  s.files             = Dir['**/*']
	s.executables = %w(swiftiply swiftiplied_mongrel_rails evented_mongrel_rails swiftiply_mongrel_rails)
	s.require_paths = %w(src)

	s.requirements      << "Eventmachine 0.8.1 or higher."
	s.add_dependency('eventmachine','>= 0.8.1')
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
  s.description = description.join(" ")
end
