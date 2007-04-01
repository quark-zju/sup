require 'rmail'
require 'uri'

module Redwood

## Maildir doesn't provide an ordered unique id, which is what Sup
## requires to be really useful. So we must maintain, in memory, a
## mapping between Sup "ids" (timestamps, essentially) and the
## pathnames on disk.

class Maildir < Source
  SCAN_INTERVAL = 30 # seconds

  def initialize uri, last_date=nil, usual=true, archived=false, id=nil
    super

    @dir = URI(uri).path
    @ids = []
    @ids_to_fns = {}
    @last_scan = nil
    @mutex = Mutex.new
  end

  def load_header id
    scan_mailbox
    with_file_for(id) { |f| MBox::read_header f }
  end

  def load_message id
    scan_mailbox
    with_file_for(id) { |f| RMail::Parser.read f }
  end

  def raw_header id
    scan_mailbox
    ret = ""
    with_file_for(id) do |f|
      until f.eof? || (l = f.gets) =~ /^$/
        ret += l
      end
    end
    ret
  end

  def raw_full_message id
    scan_mailbox
    with_file_for(id) { |f| f.readlines.join }
  end

  def scan_mailbox
    return if @last_scan && (Time.now - @last_scan) < SCAN_INTERVAL

    cdir = File.join(@dir, 'cur')
    ndir = File.join(@dir, 'new')

    begin
      @ids, @ids_to_fns = @mutex.synchronize do
        ids, ids_to_fns = [], {}
        (Dir[File.join(cdir, "*")] + Dir[File.join(ndir, "*")]).map do |fn|
          id = make_id fn
          ids << id
          ids_to_fns[id] = fn
        end
        [ids.sort, ids_to_fns]
      end
    rescue SystemCallError => e
      die "Problem scanning Maildir directories: #{e.message}."
    end
    
    @last_scan = Time.now
  end

  def each
    scan_mailbox
    start = @ids.index(cur_offset || start_offset) or die "Unknown message id #{cur_offset || start_offset}.", :suggest_rebuild => true # couldn't find the most recent email

    start.upto(@ids.length - 1) do |i|         
      id = @ids[i]
      self.cur_offset = id
      yield id, (@ids_to_fns[id] =~ /,.*R.*$/ ? [] : [:unread])
    end
  end

  def start_offset
    scan_mailbox
    @ids.first
  end

  def end_offset
    scan_mailbox
    @ids.last
  end

  def pct_done; 100.0 * (@ids.index(cur_offset) || 0).to_f / (@ids.length - 1).to_f; end

private

  def die message, opts={}
    message += " It is likely that messages have been deleted from this Maildir mailbox. Please run sup-sync --changed #{to_s} to correct this problem." if opts[:suggest_rebuild]
    self.broken_msg = message
    Redwood::log message
    BufferManager.flash "Error communicating with Maildir. See log for details." if BufferManager.instantiated?
    raise SourceError, message
  end
  
  def make_id fn
    # use 7 digits for the size. why 7? seems nice.
    sprintf("%d%07d", File.mtime(fn), File.size(fn)).to_i
  end

  def with_file_for id
    fn = @ids_to_fns[id] or die "No such id: #{id.inspect}.", :suggest_rebuild => true
    begin
      File.open(fn) { |f| yield f }
    rescue SystemCallError => e
      die "Problem reading file for id #{id.inspect}: #{fn.inspect}: #{e.message}."
    end
  end
end

Redwood::register_yaml(Maildir, %w(uri cur_offset usual archived id))

end
