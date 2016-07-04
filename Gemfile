source 'https://rubygems.org/'

if !RbConfig::CONFIG['arch'].include?('openbsd')
  # update version in ext/mkrf_conf_xapian.rb as well.
  gem 'xapian-ruby', '~> 1.2'
end

gemspec

# other gems (like pry-remote) for local debugging
(File.read(File.join(File.dirname(__FILE__), '.localgems')).each_line rescue []).each do |line|
  gemname, version = line.split
  gem gemname, version
end
