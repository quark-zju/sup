# Note: Bundler/setup is slow on cygwin

$:.unshift File.dirname(__FILE__)

base_dir = File.join(File.dirname(__FILE__), '..')

if File.readable?(File.join(base_dir, 'Gemfile.lock')) && !File.exists?(File.join(base_dir, '.nobundle'))
  require 'bundler/setup' rescue nil
end
