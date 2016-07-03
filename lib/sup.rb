# encoding: utf-8
require 'zlib'
require 'thread'
require 'fileutils'
require 'locale'
require 'ncursesw'
require 'rmail'
require 'uri'
begin
  require 'fastthread'
rescue LoadError
end

# make hooks easier
require 'active_support/core_ext/object/try'

class Object
  ## this is for debugging purposes because i keep calling #id on the
  ## wrong object and i want it to throw an exception
  def id
    raise "wrong id called on #{self.inspect}"
  end
end

class Module
  def yaml_properties *props
    props = props.map { |p| p.to_s }

    path = name.gsub(/::/, "/")
    yaml_tag "!#{Redwood::YAML_DOMAIN},#{Redwood::YAML_DATE}/#{path}"

    define_method :init_with do |coder|
      initialize(*coder.map.values_at(*props))
    end

    define_method :encode_with do |coder|
      coder.map = props.inject({}) do |hash, key|
        hash[key] = instance_variable_get("@#{key}")
        hash
      end
    end

    # Legacy
    Psych.load_tags["!#{Redwood::LEGACY_YAML_DOMAIN},#{Redwood::YAML_DATE}/#{path}"] = self
  end
end

module Redwood
  ## record exceptions thrown in threads nicely
  @exceptions = []
  @exception_mutex = Mutex.new

  attr_reader :exceptions
  def record_exception e, name
    @exception_mutex.synchronize do
      @exceptions ||= []
      @exceptions << [e, name]
    end
  end

  def reporting_thread name
    if $opts[:no_threads]
      yield
    else
      ::Thread.new do
        begin
          yield
        rescue Exception => e
          record_exception e, name
        end
      end
    end
  end

  module_function :reporting_thread, :record_exception, :exceptions

  def managers
    %w(HookManager SentManager ContactManager LabelManager AccountManager
    DraftManager UpdateManager PollManager CryptoManager UndoManager
    SourceManager SearchManager IdleManager LayoutManager).map { |x| Redwood.const_get x.to_sym }
  end

  def start bypass_sync_check = false
    StartupManager.say 'initializing components'

    managers.each { |x| fail "#{x} already instantiated" if x.instantiated? }

    FileUtils.mkdir_p Redwood::BASE_DIR
    $config = load_config Redwood::CONFIG_FN unless $config
    @log_io = File.open(Redwood::LOG_FN, 'a')
    Redwood::Logger.add_sink @log_io
    Redwood::HookManager.init Redwood::HOOK_DIR
    Redwood::SentManager.init $config[:sent_source] || 'sup://sent'
    Redwood::ContactManager.init Redwood::CONTACT_FN
    Redwood::LabelManager.init Redwood::LABEL_FN
    Redwood::AccountManager.init $config[:accounts]
    Redwood::DraftManager.init Redwood::DRAFT_DIR
    Redwood::SearchManager.init Redwood::SEARCH_FN

    managers.each { |x| x.init unless x.instantiated? }

    if $config[:patchwork]
      StartupManager.say 'connecting to patchwork database'
      require_relative './patchwork_database'
      ::PatchworkDatabase.class_eval do
        class << self; attr_accessor :updated_at; end
      end
    end

    StartupManager.stop

    return if bypass_sync_check

    if $config[:sync_back_to_maildir]
      if not File.exist? Redwood::SYNC_OK_FN
        Redwood.warn_syncback <<EOS
It appears that the "sync_back_to_maildir" option has been changed
from false to true since the last execution of sup.
EOS
        $stderr.puts <<EOS

Should I complain about this again? (Y/n)
EOS
        File.open(Redwood::SYNC_OK_FN, 'w') {|f| f.write(Redwood::MAILDIR_SYNC_CHECK_SKIPPED) } if STDIN.gets.chomp.downcase == 'n'
      end
    elsif not $config[:sync_back_to_maildir] and File.exist? Redwood::SYNC_OK_FN
      File.delete(Redwood::SYNC_OK_FN)
    end
  end

  def check_syncback_settings
    # don't check if syncback was never performed
    return unless File.exist? Redwood::SYNC_OK_FN
    active_sync_sources = File.readlines(Redwood::SYNC_OK_FN).collect { |e| e.strip }.find_all { |e| not e.empty? }
    return if active_sync_sources.length == 1 and active_sync_sources[0] == Redwood::MAILDIR_SYNC_CHECK_SKIPPED
    sources = SourceManager.sources
    newly_synced = sources.select { |s| s.is_a? Maildir and s.sync_back_enabled? and not active_sync_sources.include? s.uri }
    unless newly_synced.empty?

      details =<<EOS
It appears that the option "sync_back" of the following source(s)
has been changed from false to true since the last execution of
sup:

EOS
      newly_synced.each do |s|
        details += "#{s} (usual: #{s.usual})\n"
      end

      Redwood.warn_syncback details
    end
  end

  def self.warn_syncback details
    $stderr.puts <<EOS
WARNING
-------

#{details}

It is *strongly* recommended that you run "sup-sync-back-maildir"
before continuing, otherwise you might lose changes you have made in sup
to your Xapian index.

This script should be run each time you change the
"sync_back_to_maildir" flag in config.yaml from false to true or
the "sync_back" flag is changed to true for a source in sources.yaml.

Please run "sup-sync-back-maildir -h" for more information and why this
is needed.

Note that if you have any sources that are not marked as 'ususal' in
sources.yaml you need to manually specify them when running  the
sup-sync-back-maildir script.

Are you really sure you want to continue? (y/N)
EOS
    abort "Aborted" unless STDIN.gets.chomp.downcase == 'y'
  end

  def finish
    Redwood::LabelManager.save if Redwood::LabelManager.instantiated?
    Redwood::ContactManager.save if Redwood::ContactManager.instantiated?
    Redwood::SearchManager.save if Redwood::SearchManager.instantiated?
    Redwood::Logger.remove_sink @log_io

    managers.each { |x| x.deinstantiate! if x.instantiated? }

    @log_io.close if @log_io
    @log_io = nil
    $config = nil
  end

  ## not really a good place for this, so I'll just dump it here.
  ##
  ## a source error is either a FatalSourceError or an OutOfSyncSourceError.
  ## the superclass SourceError is just a generic.
  def report_broken_sources opts={}
    return unless BufferManager.instantiated?

    broken_sources = SourceManager.sources.select { |s| s.error.is_a? FatalSourceError }
    unless broken_sources.empty?
      BufferManager.spawn_unless_exists("Broken source notification for #{broken_sources.join(',')}", opts) do
        TextMode.new(<<EOM)
Source error notification
-------------------------

Hi there. It looks like one or more message sources is reporting
errors. Until this is corrected, messages from these sources cannot
be viewed, and new messages will not be detected.

#{broken_sources.map { |s| "Source: " + s.to_s + "\n Error: " + s.error.message.wrap(70).join("\n        ")}.join("\n\n")}
EOM
#' stupid ruby-mode
      end
    end

    desynced_sources = SourceManager.sources.select { |s| s.error.is_a? OutOfSyncSourceError }
    unless desynced_sources.empty?
      BufferManager.spawn_unless_exists("Out-of-sync source notification for #{broken_sources.join(',')}", opts) do
        TextMode.new(<<EOM)
Out-of-sync source notification
-------------------------------

Hi there. It looks like one or more sources has fallen out of sync
with my index. This can happen when you modify these sources with
other email clients. (Sorry, I don't play well with others.)

Until this is corrected, messages from these sources cannot be viewed,
and new messages will not be detected. Luckily, this is easy to correct!

#{desynced_sources.map do |s|
  "Source: " + s.to_s +
   "\n Error: " + s.error.message.wrap(70).join("\n        ") +
   "\n   Fix: sup-sync --changed #{s.to_s}"
  end}
EOM
#' stupid ruby-mode
      end
    end
  end

  module_function :start, :finish, :report_broken_sources, :managers,
                  :check_syncback_settings
end

require 'sup/config'
require 'sup/version'
require "sup/util"
require "sup/hook"
require 'sup/startup'
require "sup/time"

## everything we need to get logging working
require "sup/logger/singleton"

## determine encoding and character set
$encoding = Locale.current.charset
$encoding = "UTF-8" if $encoding == "utf8"
$encoding = "UTF-8" if $encoding == "UTF8"
if $encoding
  debug "using character set encoding #{$encoding.inspect}"
else
  warn "can't find character set by using locale, defaulting to utf-8"
  $encoding = "UTF-8"
end

# test encoding
teststr = "test"
teststr.encode('UTF-8')
begin
  teststr.encode($encoding)
rescue Encoding::ConverterNotFoundError
  warn "locale encoding is invalid, defaulting to utf-8"
  $encoding = "UTF-8"
end

require "sup/buffer"
require "sup/keymap"
require "sup/mode"
require "sup/modes/scroll_mode"
require "sup/modes/text_mode"
require "sup/modes/log_mode"
require "sup/update"
require "sup/message_chunks"
require "sup/message"
require "sup/source"
require "sup/mbox"
require "sup/maildir"
require "sup/person"
require "sup/account"
require "sup/thread"
require "sup/interactive_lock"
require "sup/index"
require "sup/textfield"
require "sup/colormap"
require "sup/label"
require "sup/contact"
require "sup/tagger"
require "sup/draft"
require "sup/poll"
require "sup/crypto"
require "sup/undo"
require "sup/horizontal_selector"
require "sup/modes/line_cursor_mode"
require "sup/modes/help_mode"
require "sup/modes/edit_message_mode"
require "sup/modes/edit_message_async_mode"
require "sup/modes/compose_mode"
require "sup/modes/resume_mode"
require "sup/modes/forward_mode"
require "sup/modes/reply_mode"
require "sup/modes/label_list_mode"
require "sup/modes/contact_list_mode"
require "sup/modes/thread_view_mode"
require "sup/modes/thread_index_mode"
require "sup/modes/label_search_results_mode"
require "sup/modes/search_results_mode"
require "sup/modes/person_search_results_mode"
require "sup/modes/inbox_mode"
require "sup/modes/buffer_list_mode"
require "sup/modes/poll_mode"
require "sup/modes/file_browser_mode"
require "sup/modes/completion_mode"
require "sup/modes/console_mode"
require "sup/sent"
require "sup/search"
require "sup/modes/search_list_mode"
require "sup/idle"

$:.each do |base|
  d = File.join base, "sup/share/modes/"
  Redwood::Mode.load_all_modes d if File.directory? d
end
