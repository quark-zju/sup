require 'cgi'

new_lines = case type
when :sig
  # Remove signature lines
  []
else
  lines.map do |l|
    # Remove hgdev list signature
    next if l.include?('ercurial-devel') || l.include?('_________________')
    # Restore urldefense URLs
    l.gsub %r[https://urldefense\.proofpoint\.com/v2/url\?(\S+)] do
      CGI::unescape(CGI::parse($1)['u'].join.gsub('-', '%').gsub('_', '/'))
    end
  end.compact
end

{lines: new_lines, expand: (lines.size <= 10 ? true : nil)}
