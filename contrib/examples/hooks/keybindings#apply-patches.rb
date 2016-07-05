# !: thread view mode, apply patches
class ::Redwood::ThreadViewMode

  def download_and_apply_patches
    patches = @thread.patches
    BufferManager.flash 'No patches in the thread' if patches.empty?

    BufferManager.flash 'Downloading patches'
    filenames = patches.map(&:download)

    apply_command = $config[:apply_patch_command] || "hg import --cwd ~/#{patches.first.project.name}"
    log_file = $config[:apply_patch_log] || '/dev/null'

    BufferManager.flash 'Applying patches'
    require 'shellwords'
    okay = system *Shellwords.split(apply_command), *filenames.map(&:to_s), 1 => log_file, 2 => log_file
    BufferManager.flash(
      okay ? "Successfully applied #{filenames.size} patches"
           : 'Failed to apply patches')
  end

  keymap.add! :download_and_apply_patches, 'Download and apply patches', '!'
end
