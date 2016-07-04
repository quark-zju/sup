# J: thread view mode, jump to next chunk
# K: thread view mode, jump to next chunk
class ::Redwood::ThreadViewMode
  keymap.add! :jump_to_next, "Jump to the next message", 'J'
  keymap.add! :jump_to_prev, "Jump to the previous message", 'K'
end
