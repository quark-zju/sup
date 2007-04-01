require 'uri'
require 'net/imap'
require 'stringio'
require 'time'
require 'rmail'

## fucking imap fucking sucks. what the FUCK kind of committee of
## dunces designed this shit.

## imap talks about 'unique ids' for messages, to be used for
## cross-session identification. great---just what sup needs! except
## it turns out the uids can be invalidated every time the
## 'uidvalidity' value changes on the server, and 'uidvalidity' can
## change without restriction. it can change any time you log in. it
## can change EVERY time you log in. of course the imap spec "strongly
## recommends" that it never change, but there's nothing to stop
## people from just setting it to the current timestamp, and in fact
## that's exactly what the one imap server i have at my disposal
## does. thus the so-called uids are absolutely useless and imap
## provides no cross-session way of uniquely identifying a
## message. but thanks for the "strong recommendation", guys!

## so right now i'm using the 'internal date' and the size of each
## message to uniquely identify it, and i scan over the entire mailbox
## each time i open it to map those things to message ids. that can be
## slow for large mailboxes, and we'll just have to hope that there
## are no collisions. ho ho! a perfectly reasonable solution!

## fuck you, imap committee. you managed to design something nearly as
## shitty as mbox but goddamn THIRTY YEARS LATER.
module Redwood

class IMAP < Source
  SCAN_INTERVAL = 60 # seconds

  ## upon these errors we'll try to rereconnect a few times
  RECOVERABLE_ERRORS = [ Errno::EPIPE, Errno::ETIMEDOUT ]

  attr_accessor :username, :password

  def initialize uri, username, password, last_idate=nil, usual=true, archived=false, id=nil
    raise ArgumentError, "username and password must be specified" unless username && password
    raise ArgumentError, "not an imap uri" unless uri =~ %r!imaps?://!

    super uri, last_idate, usual, archived, id

    @parsed_uri = URI(uri)
    @username = username
    @password = password
    @imap = nil
    @imap_ids = {}
    @ids = []
    @last_scan = nil
    @labels = [:unread]
    @labels << mailbox.intern unless mailbox =~ /inbox/i
    @mutex = Mutex.new
  end

  def host; @parsed_uri.host; end
  def port; @parsed_uri.port || (ssl? ? 993 : 143); end
  def mailbox
    x = @parsed_uri.path[1..-1]
    x.nil? || x.empty? ? 'INBOX' : x
  end
  def ssl?; @parsed_uri.scheme == 'imaps' end

  ## is this necessary? TODO: remove maybe
  def == o; o.is_a?(IMAP) && o.uri == self.uri && o.username == self.username; end

  def load_header id
    MBox::read_header StringIO.new(raw_header(id))
  end

  def load_message id
    RMail::Parser.read raw_full_message(id)
  end

  def raw_header id
    unsynchronized_scan_mailbox
    header, flags = get_imap_fields id, 'RFC822.HEADER', 'FLAGS'
    header = header + "Status: RO\n" if flags.include? :Seen # fake an mbox-style read header # TODO: improve source-marked-as-read reporting system
    header.gsub(/\r\n/, "\n")
  end
  synchronized :raw_header

  def raw_full_message id
    unsynchronized_scan_mailbox
    get_imap_fields(id, 'RFC822').first.gsub(/\r\n/, "\n")
  end
  synchronized :raw_full_message

  def connect
    return if broken? || @imap
    safely { } # do nothing!
  end
  synchronized :connect

  def scan_mailbox
    return if @last_scan && (Time.now - @last_scan) < SCAN_INTERVAL
    last_id = safely do
      @imap.examine mailbox
      @imap.responses["EXISTS"].last
    end
    @last_scan = Time.now

    return if last_id == @ids.length

    Redwood::log "fetching IMAP headers #{(@ids.length + 1) .. last_id}"
    values = safely { @imap.fetch((@ids.length + 1) .. last_id, ['RFC822.SIZE', 'INTERNALDATE']) }
    values.each do |v|
      id = make_id v
      @ids << id
      @imap_ids[id] = v.seqno
    end
  end
  synchronized :scan_mailbox

  def each
    ids = 
      @mutex.synchronize do
        unsynchronized_scan_mailbox
        @ids
      end

    start = ids.index(cur_offset || start_offset) or die_from "Unknown message id #{cur_offset || start_offset}.", :suggest_rebuild => true # couldn't find the most recent email

    start.upto(ids.length - 1) do |i|         
      id = ids[i]
      self.cur_offset = id
      yield id, @labels.clone
    end
  end

  def start_offset
    unsynchronized_scan_mailbox
    @ids.first
  end
  synchronized :start_offset

  def end_offset
    unsynchronized_scan_mailbox
    @ids.last
  end
  synchronized :end_offset

  def pct_done; 100.0 * (@ids.index(cur_offset) || 0).to_f / (@ids.length - 1).to_f; end

private

  def unsafe_connect
    say "Connecting to IMAP server #{host}:#{port}..."

    ## apparently imap.rb does a lot of threaded stuff internally and
    ## if an exception occurs, it will catch it and re-raise it on the
    ## calling thread. but i can't seem to catch that exception, so
    ## i've resorted to initializing it in its own thread. surely
    ## there's a better way.
    exception = nil
    ::Thread.new do
      begin
        #raise Net::IMAP::ByeResponseError, "simulated imap failure"
        @imap = Net::IMAP.new host, port, ssl?
        say "Logging in..."

        ## although RFC1730 claims that "If an AUTHENTICATE command
        ## fails with a NO response, the client may try another", in
        ## practice it seems like they can also send a BAD response.
        begin
          @imap.authenticate 'CRAM-MD5', @username, @password
        rescue Net::IMAP::BadResponseError, Net::IMAP::NoResponseError => e
          Redwood::log "CRAM-MD5 authentication failed: #{e.class}. Trying LOGIN auth..."
          begin
            @imap.authenticate 'LOGIN', @username, @password
          rescue Net::IMAP::BadResponseError, Net::IMAP::NoResponseError => e
            Redwood::log "LOGIN authentication failed: #{e.class}. Trying plain-text LOGIN..."
            @imap.login @username, @password
          end
        end
        say "Successfully connected to #{@parsed_uri}."
      rescue Exception => e
        exception = e
      ensure
        shutup
      end
    end.join

    raise exception if exception
  end

  def say s
    @say_id = BufferManager.say s, @say_id if BufferManager.instantiated?
    Redwood::log s
  end

  def shutup
    BufferManager.clear @say_id if BufferManager.instantiated?
    @say_id = nil
  end

  def die_from e, opts={}
    @imap = nil

    message =
      case e
      when Exception
        "Error while #{opts[:while]}: #{e.message.chomp} (#{e.class.name})."
      when String
        e
      end

    message += " It is likely that messages have been deleted from this IMAP mailbox. Please run sup-sync --changed #{to_s} to correct this problem." if opts[:suggest_rebuild]

    self.broken_msg = message
    Redwood::log message
    BufferManager.flash "Error communicating with IMAP server. See log for details." if BufferManager.instantiated?
    raise SourceError, message
  end
  
  ## build a fake unique id
  def make_id imap_stuff
    # use 7 digits for the size. why 7? seems nice.
    msize, mdate = imap_stuff.attr['RFC822.SIZE'] % 10000000, Time.parse(imap_stuff.attr["INTERNALDATE"])
    sprintf("%d%07d", mdate.to_i, msize).to_i
  end

  def get_imap_fields id, *fields
    raise SourceError, broken_msg if broken?
    imap_id = @imap_ids[id] or die_from "Unknown message id #{id}.", :suggest_rebuild => true

    retried = false
    results = safely { @imap.fetch imap_id, (fields + ['RFC822.SIZE', 'INTERNALDATE']).uniq }.first
    got_id = make_id results
    die_from "IMAP message mismatch: requested #{id}, got #{got_id}.", :suggest_rebuild => true unless got_id == id

    fields.map { |f| results.attr[f] }
  end

  ## execute a block, connected if unconnected, re-connected up to 3
  ## times if a recoverable error occurs, and properly dying if an
  ## unrecoverable error occurs.
  def safely
    retries = 0
    begin
      begin
        unsafe_connect unless @imap
        yield
      rescue *RECOVERABLE_ERRORS
        if (retries += 1) <= 3
          @imap = nil
          retry
        end
        raise
      end
    rescue Net, SocketError, Net::IMAP::Error, SystemCallError => e
      die_from e, :while => "communicating with IMAP server"
    end
  end

end

Redwood::register_yaml(IMAP, %w(uri username password cur_offset usual archived id))

end
