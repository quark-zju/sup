require 'sup/constants'
require 'yaml'

module ::Redwood
  ## set up default configuration file
  def load_config filename
    default_config = {
      :editor => ENV["EDITOR"] || "/usr/bin/vim -f -c 'setlocal spell spelllang=en_us' -c 'set ft=mail tw=76' '+$LINE'",
      :thread_by_subject => false,
      :edit_signature => false,
      :ask_for_from => false,
      :ask_for_to => true,
      :ask_for_cc => false,
      :ask_for_bcc => false,
      :ask_for_subject => true,
      :account_selector => true,
      :confirm_no_attachments => true,
      :confirm_top_posting => true,
      :jump_to_open_message => false,
      :discard_snippets_from_encrypted_messages => false,
      :load_more_threads_when_scrolling => true,
      :default_attachment_save_dir => "",
      :sent_source => "sup://sent",
      :archive_sent => false,
      :poll_interval => 300,
      :wrap_width => 0,
      :slip_rows => 10,
      :indent_spaces => 2,
      :col_jump => 2,
      :stem_language => "english",
      :sync_back_to_maildir => true,
      :continuous_scroll => false,
      :always_edit_async => false,
      :patchwork => true,
      :crypto => false,
      :hidden_labels => [],
      :show_startup_progress => true,
      :split_view => false, # :vertical or :horizontal
      :mouse => true,
    }
    if File.exist? filename
      config = Redwood::load_yaml_obj filename
      abort "#{filename} is not a valid configuration file (it's a #{config.class}, not a hash)" unless config.is_a?(Hash)
      default_config.merge config
    else
      require 'etc'
      require 'socket'
      name = Etc.getpwnam(ENV["USER"]).gecos.split(/,/).first.force_encoding($encoding).fix_encoding! rescue nil
      name ||= ENV["USER"]
      email = ENV["USER"] + "@" +
        begin
          Socket.gethostbyname(Socket.gethostname).first
        rescue SocketError
          Socket.gethostname
        end

      config = {
        :accounts => {
          :default => {
            :name => name.dup.fix_encoding!,
            :email => email.dup.fix_encoding!,
            :alternates => [],
            :sendmail => "/usr/sbin/sendmail -oem -ti",
            :signature => File.join(ENV["HOME"], ".signature"),
            :gpgkey => ""
          }
        },
      }
      config.merge! default_config
      begin
        Redwood::save_yaml_obj config, filename, false, true
      rescue StandardError => e
        $stderr.puts "warning: #{e.message}"
      end
      config
    end
  end

## one-stop shop for yamliciousness
  def save_yaml_obj o, fn, safe=false, backup=false
    o = if o.is_a?(Array)
      o.map { |x| (x.respond_to?(:before_marshal) && x.before_marshal) || x }
    elsif o.respond_to? :before_marshal
      o.before_marshal
    else
      o
    end

    mode = if File.exist? fn
      File.stat(fn).mode
    else
      0600
    end

    if backup
      backup_fn = fn + '.bak'
      if File.exist?(fn) && File.size(fn) > 0
        File.open(backup_fn, "w", mode) do |f|
          File.open(fn, "r") { |old_f| FileUtils.copy_stream old_f, f }
          f.fsync
        end
      end
      File.open(fn, "w") do |f|
        f.puts o.to_yaml
        f.fsync
      end
    elsif safe
      safe_fn = "#{File.dirname fn}/safe_#{File.basename fn}"
      File.open(safe_fn, "w", mode) do |f|
        f.puts o.to_yaml
        f.fsync
      end
      FileUtils.mv safe_fn, fn
    else
      File.open(fn, "w", mode) do |f|
        f.puts o.to_yaml
        f.fsync
      end
    end
  end

  def load_yaml_obj fn, compress=false
    o = if File.exist? fn
      if compress
        Zlib::GzipReader.open(fn) { |f| YAML::load f }
      else
        YAML::load_file fn
      end
    end
    if o.is_a?(Array)
      o.each { |x| x.after_unmarshal! if x.respond_to?(:after_unmarshal!) }
    else
      o.after_unmarshal! if o.respond_to?(:after_unmarshal!)
    end
    o
  end

  module_function :load_config, :load_yaml_obj, :save_yaml_obj
end
