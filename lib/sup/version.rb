module Redwood
  def self.get_version
    git_dir = File.expand_path(File.join(File.dirname(__FILE__), '../../.git'))
    if Dir.exist?(git_dir)
      p = IO::popen(['git', '--git-dir', git_dir, 'rev-parse', 'HEAD'])
      gitver = p.read[0, 7]
      p.close
      "g#{gitver}"
    else
      'unknown'
    end rescue 'unknown'
  end

  VERSION = get_version
end
