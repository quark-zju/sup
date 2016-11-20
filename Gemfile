source 'https://rubygems.org/'

nosup = File.exists?(File.expand_path("../.nosup", __FILE__))

if nosup
  # only use patchwork, no sup deps
  gem 'activerecord', '~> 5.0'
  gem 'sqlite3', '~> 1.3.0'
  gem 'activesupport', '~> 5.0'
  gem 'json'
  gem 'pry', '~> 0.10.0'
  gem 'table_print', '~> 1.5.6'
else
  # normal sup deps
  gemspec
end

# other gems (like pry-remote) for local debugging
(File.read(File.join(File.dirname(__FILE__), '.localgems')).each_line rescue []).each do |line|
  gemname, version = line.split
  gem gemname, version
end
