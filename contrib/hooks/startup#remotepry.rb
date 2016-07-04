# put "pry-remote" to ".localgems" first

require 'pry-remote'
require 'thread'

module ::Redwood
  def self.get_binding
    binding
  end

  def self.start_remote_pry
    get_binding.remote_pry
  end
end

::Thread.new { ::Redwood::start_remote_pry rescue nil }
