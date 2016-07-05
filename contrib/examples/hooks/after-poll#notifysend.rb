summary = from_and_subj.map { |from, subj| "#{from.split[0]}: #{subj}" }
if not summary.empty?
  system 'notify-send', '-i', 'mail-unread', "#{summary.size} new email#{ summary.size > 1 ? 's' : ''}", summary.join('\n')
end
