require 'thread'

module Redwood

class PollManager
  include Redwood::Singleton

  def initialize
    @delay = $config[:poll_interval] || 300
    @mutex = Mutex.new
    @thread = nil
    @last_poll = nil
    @notmuch_lastmod = Notmuch.lastmod
    @polling = Mutex.new
    @poll_sources = nil
    @mode = nil
    UpdateManager.register self
  end

  def poll
    if @polling.try_lock
      n = poll_notmuch
      poll_patchwork if n > 0 && $config[:patchwork]
      @last_poll = Time.now
      @polling.unlock
      n
    else
      debug "poll already in progress."
      return
    end
  end

  def poll_patchwork
    # ignore possible network errors
    PatchworkDatabase::Patch.sync! rescue nil
    PatchworkDatabase::updated_at = Time.now.to_i
    # update buffers
    BufferManager.buffers.each do |name, buf|
      buf.mode.update rescue nil
    end
  end

  def poll_notmuch
    nowmod = Notmuch.lastmod
    return 0 if nowmod == @notmuch_lastmod
    thread_ids = Notmuch.search("lastmod:#{@notmuch_lastmod}..#{nowmod}", limit: 9999)
    UpdateManager.relay self, :thread_ids_updated, thread_ids
    thread_ids.size.tap {|n| BufferManager.flash "#{n.pluralize 'thread'} updated"}
  end

  def start
    @thread = Redwood::reporting_thread("periodic poll") do
      while true
        sleep @delay / 2
        poll if @last_poll.nil? || (Time.now - @last_poll) >= @delay
      end
    end
  end

  def stop
    @thread.kill if @thread
    @thread = nil
  end

end

end
