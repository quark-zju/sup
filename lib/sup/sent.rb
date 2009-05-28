module Redwood

class SentManager
  include Singleton

  attr_reader :source, :source_uri

  def initialize source_uri
    @source = nil
    @source_uri = source_uri
    self.class.i_am_the_instance self
    Redwood::log "SentManager intialized with source uri: #@source_uri"
  end

  def source_id; @source.id; end

  def source= s
    raise FatalSourceError.new("Configured sent_source [#{s.uri}] can't store mail.  Correct your configuration.") unless s.respond_to? :store_message
    @souce_uri = s.uri
    @source = s
  end

  def default_source
    @source = Recoverable.new SentLoader.new
    Redwood::log "SentManager initializing default source: #@source."
    @source_uri = @source.uri
    @source
  end

  def write_sent_message date, from_email, &block
    @source.store_message date, from_email, &block

    PollManager.add_messages_from(@source) do |m, o, e|
      m.remove_label :unread
      m
    end
  end
end

class SentLoader < MBox::Loader
  yaml_properties :cur_offset

  def initialize cur_offset=0
    @filename = Redwood::SENT_FN
    File.open(@filename, "w") { } unless File.exists? @filename
    super "mbox://" + @filename, cur_offset, true, true
  end

  def file_path; @filename end

  def to_s; 'sup://sent'; end
  def uri; 'sup://sent' end

  def id; 9998; end
  def labels; [:inbox]; end
end

end
