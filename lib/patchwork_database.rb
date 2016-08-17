# patchwork database

require 'active_record'
require 'fileutils'
require 'pathname'
require 'sqlite3'
require 'xmlrpc/client'

SCRIPT_DIR = File.expand_path(File.dirname(File.dirname(__FILE__)))
BASE_DIR = Pathname.new(ENV["SUP_BASE"] || '~/.sup').expand_path.join('patchwork')
BASE_DIR.mkpath

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: BASE_DIR.join('pwdb.sqlite3').to_s)
ActiveRecord::Migrator.migrate(File.join(SCRIPT_DIR, 'db/migrate'))
ActiveRecord::Base.logger = Logger.new(STDERR)
ActiveRecord::Base.logger.level = (ENV['LOGLEVEL'] || Logger::WARN).to_i

module ::PatchworkDatabase

module PatchResource
  def self.included(resource)
    resource.has_many :patches
    def resource.from_patchrpcobj(rpcobj)
      @resource_name ||= self.name.split('::').last.downcase
      id = rpcobj["#{@resource_name}_id"]
      raise "#{@resource_name}_id is nil in #{rpcobj}" if id.nil?
      @cache ||= {}
      @cache[id] ||= \
        begin
          name = rpcobj[@resource_name]
          raise "#{@resource_name} is nil in #{rpcobj}" if name.nil?
          where(id: id).first_or_create!(name: name)
        end
    end
  end
end

class Delegate < ActiveRecord::Base;  include PatchResource; end
class Project < ActiveRecord::Base;   include PatchResource; end
class State < ActiveRecord::Base
  include PatchResource

  after_save :expire_cache!

  def simplified_sym
    # only 4 states: queuing, accepted, rejected, unrelated
    case name
    when 'New', 'Under Review', 'Pre-Reviewed', /Review Requested/
      :queuing
    when 'Accepted'
      :accepted
    when 'Rejected', 'Changes Requested', 'Deferred', 'Superseded'
      :rejected
    else
      :unrelated
    end
  end

  def self.ids_by_sym sym
    @@ids_by_sym ||=
      begin
        Hash[all.group_by(&:simplified_sym)].tap do |h|
          # convert values to id
          h.each { |k, v| h[k] = v.map(&:id) }
          # built-in hard-coded ids useful when the database is incomplete
          { queuing: [1, 2], accepted: [3], rejected: [4] }.each { |k, v| h[k] ||= v }
        end
      end
    @@ids_by_sym[sym] || []
  end

  def expire_cache!
    @@ids_by_sym = nil
  end
end

class Submitter < ActiveRecord::Base; include PatchResource; end

class Patch < ActiveRecord::Base
  belongs_to :delegate
  belongs_to :project
  belongs_to :state
  belongs_to :submitter

  [:queuing, :accepted, :rejected, :unrelated].each do |sym|
    scope sym, -> { where(state_id: State.ids_by_sym(sym)) }
  end

  def delegated?
    delegate_id.to_i > 0
  end

  def state_desc(show_id: false)
    # describe the state in text
    text = []
    text << id if show_id
    text << state.name
    text << ['by', delegate.name] if delegated?
    text.join(' ')
  end

  def content
    download.read
  end

  def download overwrite: false
    # return path
    full_path.tap do |path|
      next if path.exist? && !overwrite
      path.dirname.mkpath
      content = Patch.rpc.call(:patch_get_mbox, id)
      path.write content
    end
  end

  def download!
    download overwrite: true
  end

  def change_state! new_state_text, old_state_text: 'New', submitter_name: nil
    # push new state to patchwork server
    # get a fresh new patchrpcobj object from the server and check its state first
    if old_state_text
      patchrpcobj = Patch.rpc.call :patch_get, id
      old_state = State.find_by!(name: old_state_text)
      raise "State '#{patchrpcobj['state']}' is not the expected '#{old_state_text}'" if patchrpcobj['state'] != old_state_text
    end

    if submitter_name
      raise "Submitter name #{submitter.name} does not match" if submitter.name =~ submitter_name
    end

    # prepare payload to update
    new_state = State.find_by!(name: new_state_text)
    Patch.rpc.call :patch_set, id, state: new_state.id
    self.state = new_state
    save!
  end

  def full_path
    Patch.patch_dir.join([id, submitter && submitter.name.split.first.downcase, filename].compact.join('-'))
  end

  def fill_with_patchrpcobj(rpcobj)
    self.delegate  = Delegate.from_patchrpcobj(rpcobj)
    self.project   = Project.from_patchrpcobj(rpcobj)
    self.state     = State.from_patchrpcobj(rpcobj)
    self.submitter = Submitter.from_patchrpcobj(rpcobj)
    self.update_attributes rpcobj.select {|k| %w[id commit_ref date filename msgid name].include?(k)}
  end

  def self.fetch(start_id = 0, count = 500, **filter)
    self.transaction do
      rpc.call(:patch_list, max_count: count, id__gte: start_id, **filter).each do |data|
        where(id: data["id"]).first_or_initialize.tap do |patch|
          patch.fill_with_patchrpcobj(data)
          patch.save!
        end
      end
    end
  end

  def self.patch_dir
    @patch_dir ||= BASE_DIR.join('patches')
  end

  def self.fetch_all(start_id = nil)
    max_id = start_id || Patch.last.try(:id) || 0
    loop do
      logger.info "Fetching patches from ##{max_id + 1}"
      fetch max_id + 1
      new_max_id = Patch.last.try(:id) || 0
      break if new_max_id == max_id
      max_id = new_max_id
    end
  end

  def self.sync!
    # update not reviewed states
    logger.info "Updating queuing patches"
    Patch.fetch(id__in: queuing.pluck(:id))
    # fetch new entries
    logger.info "Fetching new patches"
    self.fetch_all
  end

  def self.rpc
    # see https://github.com/getpatchwork/patchwork/blob/master/patchwork/views/xmlrpc.py for the API
    @rpc ||= \
      begin
        config = Hash[File.read(File.expand_path('~/.pwclientrc')).lines.map{|l|l.chomp.split(/[:=]\s*/,2)}.select{|l|l.size==2}]
        uri = URI(config['url'])
        uri.user ||= config['username']
        uri.password ||= config['password']
        XMLRPC::Client.new2(uri).tap do |server|
          # hack: patchwork returns text/html while it should return text/xml
          # ruby stdlib has check on it and will raise errors. wrap it to silent the error
          def server.parse_content_type(str); ['text/xml']; end
        end
      end
  end
end

end # module ::PatchworkDatabase
