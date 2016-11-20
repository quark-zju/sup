require 'fileutils'
require 'stringio'

module Redwood

class DraftManager
  include Redwood::Singleton

  def write_draft message_id # caller makes sure content has message_id
    if message_id.start_with?('<')
      message_id = message_id[1...-1] # remove '<', '>'
    end
    sio = StringIO.open('', 'w+:UTF-8')
    yield sio
    sio.rewind
    content = sio.read
    raise "message id is required" if message_id.empty?
    raise "message id #{message_id} not in content" if !content.include?(message_id)
    # delete the file with a same message_id
    delete_message_files message_id

    Notmuch.insert(content)
    m = Message.new id: message_id # will load thread_it etc. via notmuch
    m.add_label :draft
    m.sync_back_labels
    UpdateManager.relay self, :updated, m
  end

  def discard m
    raise ArgumentError, "not a draft: source id #{m.source.id.inspect}, should be #{DraftManager.source_id.inspect} for #{m.id.inspect}" unless m.is_draft?
    tid = m.thread_id
    delete_message_files m.id
    UpdateManager.relay self, :single_message_deleted, m
    UpdateManager.relay self, :thread_ids_updated, [tid]
  end

  protected

  def delete_message_files mid, sync: true
    filenames = Notmuch.filenames_from_message_id(mid)
    if not filenames.empty?
      debug "Deleting #{filenames}"
      FileUtils.rm_f filenames
      Notmuch.poll if sync
    end
  end
end

end
