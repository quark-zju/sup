module Redwood

class DraftManager
  include Redwood::Singleton

  def initialize dir
    @dir = dir
    @source = nil
  end

  def self.source_name; "sup://drafts"; end
  def self.source_id; 9999; end

  def write_draft
    # offset = @source.gen_offset
    # fn = @source.fn_for_offset offset
    # File.open(fn, "w:UTF-8") { |f| yield f }
    # TODO notmuch
    # PollManager.poll_from @source
  end

  def discard m
    raise ArgumentError, "not a draft: source id #{m.source.id.inspect}, should be #{DraftManager.source_id.inspect} for #{m.id.inspect}" unless m.source.id.to_i == DraftManager.source_id
    # TODO notmuch
    # Index.delete m.id
    File.delete @source.fn_for_offset(m.source_info) rescue Errono::ENOENT
    UpdateManager.relay self, :single_message_deleted, m
  end
end

end
