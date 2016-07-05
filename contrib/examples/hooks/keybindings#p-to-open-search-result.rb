# p: inbox mode: open some saved search quickly

class ::Redwood::InboxMode
  def open_saved_search
    saved_search_name = $config[:saved_search_name]
    SearchResultsMode.spawn_from_query SearchManager.search_string_for(saved_search_name)
  end

  if $config[:saved_search_name]
    keymap.add :open_saved_search, "Open saved search: #{$config[:saved_search_name]}", $config[:saved_search_key] || 'p'
  end
end
