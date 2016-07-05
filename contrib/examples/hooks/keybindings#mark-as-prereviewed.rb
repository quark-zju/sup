# +: thread view mode, mark as pre-reviewed, with prompt
class ::Redwood::ThreadViewMode
  def mark_as_prereviewed
    current_message.try(:patch).try do |patch|
      return if !BufferManager.ask_yes_or_no("Mark ##{patch.id} as Pre-Reviewed?")
      BufferManager.flash "Marking ##{patch.id} #{patch.name} as Pre-Reviewed"
      patch.change_state! 'Pre-Reviewed'
      BufferManager.flash "Marked ##{patch.id} #{patch.name} as Pre-Reviewed"
      # expire caches
      PatchworkDatabase::updated_at = Time.now.to_i
      # redraw
      BufferManager.draw_screen dirty: true
    end
  end

  keymap.add! :mark_as_prereviewed, "Mark patch as pre-reviewed with prompt", '+'
end
