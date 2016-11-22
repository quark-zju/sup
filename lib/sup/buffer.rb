# encoding: utf-8

require 'etc'
require 'thread'
require 'ncursesw'

require 'sup/util/ncurses'
require 'sup/layout'

module Redwood

class InputSequenceAborted < StandardError; end

class Buffer
  attr_reader :mode, :x, :y, :width, :height, :title, :atime
  bool_reader :dirty, :system
  bool_accessor :force_to_top, :hidden

  def initialize mode, opts={}
    @mode = mode
    @dirty = true
    @focus = false
    @title = opts[:title] || ""
    @force_to_top = opts[:force_to_top] || false
    @hidden = opts[:hidden] || false
    update_window!
    raise 'something is wrong' unless @x && @y && @width && @height && @w && @mode
    @atime = Time.at 0
    @system = opts[:system] || false
  end

  def content_height; @height - 1; end
  def content_width; @width; end

  def update_window!
    # let LayoutManager give us a window and its sizes
    w, y, x, height, width = *LayoutManager.find_window_by_mode(@mode)
    if [w, y, x, height, width] != [@w, @y, @x, @height, @width]
      # probably resized
      mark_dirty
      @w, @y, @x, @height, @width = w, y, x, height, width
      # tell mode
      mode.buffer ||= self
      mode.resize @height, @width
      mode.respond_to?(:update) && mode.update
    end
  end

  def redraw
    if @dirty
      draw
    else
      draw_status
    end

    commit
  end

  def mark_dirty; @dirty = true; end

  def commit
    @dirty = false
    @w.refresh
  end

  def draw
    @mode.draw
    draw_status
    commit
    @atime = Time.now
  end

  ## s nil means a blank line!
  def write y, x, s, opts={}
    return if x >= @width || y >= @height

    @w.attrset Colormap.color_for(opts[:color] || :none, opts[:highlight], !@focus)
    s ||= ""
    maxl = @width - x # maximum display width width

    # fill up the line with blanks to overwrite old screen contents
    @w.mvaddstr y, x, " " * maxl unless opts[:no_fill]
    @w.mvaddstr y, x, s.slice_by_display_length(maxl)
  end

  def clear
    @w.clear
  end

  def draw_status inactive=nil
    inactive = (BufferManager.focus_buf != self) if inactive.nil?
    color = inactive ? :status_inactive_color : :status_color
    write @height - 1, 0, status_text, :color => color
  end

  def focus
    @focus = true
    @dirty = true
    @mode.focus
    draw_status true
  end

  def blur
    @focus = false
    @dirty = true
    @mode.blur
    draw_status false
  end

  def overlap_with? buf
    return true if @w == buf.instance_variable_get(:@w)
    rx, ry, rw, rh = [:@x, :@y, :@width, :@height].map {|x| buf.instance_variable_get x}
    @x < rx + rw && @x + @width > rx && @y < ry + rh && @y + @height > ry
  end

  def status_text
    # unlike status, status_text considers hooks
    HookManager.run("status-bar-text") { hook_opts } || default_status_bar
  end

  def title_text
    # unlike title, title_text considers hooks
    HookManager.run("terminal-title-text") { hook_opts } || default_terminal_title
  end

protected

  def default_status_bar
    " [#{self.mode.name}] #{self.title}   #{self.mode.status}"
  end

  def default_terminal_title
    "Sup #{Redwood::VERSION} :: #{self.title}"
  end

  def hook_opts
    {
      :num_inbox => lambda { Index.num_results_for :label => :inbox },
      :num_inbox_unread => lambda { Index.num_results_for :labels => [:inbox, :unread] },
      :num_total => lambda { Index.size },
      :num_spam => lambda { Index.num_results_for :label => :spam },
      :title => self.title,
      :mode => self.mode.name,
      :status => self.mode.status
    }
  end
end

class BufferManager
  include Redwood::Singleton

  attr_reader :focus_buf

  ## we have to define the key used to continue in-buffer search here, because
  ## it has special semantics that BufferManager deals with---current searches
  ## are canceled by any keypress except this one.
  CONTINUE_IN_BUFFER_SEARCH_KEY = "n"

  HookManager.register "status-bar-text", <<EOS
Sets the status bar. The default status bar contains the mode name, the buffer
title, and the mode status. Note that this will be called at least once per
keystroke, so excessive computation is discouraged.

Variables:
         num_inbox: number of messages in inbox
  num_inbox_unread: total number of messages marked as unread
         num_total: total number of messages in the index
          num_spam: total number of messages marked as spam
             title: title of the current buffer
              mode: current mode name (string)
            status: current mode status (string)
Return value: a string to be used as the status bar.
EOS

  HookManager.register "terminal-title-text", <<EOS
Sets the title of the current terminal, if applicable. Note that this will be
called at least once per keystroke, so excessive computation is discouraged.

Variables: the same as status-bar-text hook.
Return value: a string to be used as the terminal title.
EOS

  HookManager.register "extra-contact-addresses", <<EOS
A list of extra addresses to propose for tab completion, etc. when the
user is entering an email address. Can be plain email addresses or can
be full "User Name <email@domain.tld>" entries.

Variables: none
Return value: an array of email address strings.
EOS

  def initialize
    @name_map = {}  # {title: Buffer}
    @buffers = []
    @focus_buf = nil
    @dirty = true
    @minibuf_stack = []
    @minibuf_mutex = Mutex.new
    @textfields = {}
    @flash = nil
    @shelled = @asking = false
    @in_x = ENV["TERM"] =~ /(xterm|rxvt|screen)/
    @sigwinch_happened = false
    @sigwinch_mutex = Mutex.new
  end

  def send_key! ch
    Ncurses.ungetch ch.ord
    # see Ncurses::CharCode::nonblocking_getwch
    $sigpipe[1].write(' ') if $sigpipe
  end

  def sigwinch_happened!
    @sigwinch_mutex.synchronize do
      return if @sigwinch_happened
      @sigwinch_happened = true
      # indirectly calls completely_redraw_screen
      send_key! ?\C-l
    end
  end

  def sigwinch_happened?; @sigwinch_mutex.synchronize { @sigwinch_happened } end

  def buffers; @name_map.to_a; end
  def shelled?; @shelled; end

  def front_buffers
    # return an array of visible buffers in the current split view
    # group buffers by pos (y, x)
    grouped = @name_map.values.group_by { |buf| [buf.y, buf.x] }
    # sort by pos, for each group, only return the most recent (visible) buffer
    grouped.sort_by(&:first). map { |pos, bufs| bufs.max_by(&:atime) }
  end

  def next_front_buffer
    bufs = front_buffers
    index = bufs.index(@focus_buf)
    if index
      bufs[(index + 1) % bufs.size]
    else
      bufs[0]
    end
  end

  def focus_on buf
    return unless @buffers.member? buf
    return if buf == @focus_buf
    @focus_buf.blur if @focus_buf
    @focus_buf = buf
    @focus_buf.focus
  end

  def raise_to_front buf
    @buffers.delete(buf) or return
    if @buffers.length > 0 && @buffers.last.force_to_top?
      @buffers.insert(-2, buf)
    else
      @buffers.push buf
    end
    focus_on @buffers.last
    @dirty = true
  end

  ## we reset force_to_top when rolling buffers. this is so that the
  ## human can actually still move buffers around, while still
  ## programmatically being able to pop stuff up in the middle of
  ## drawing a window without worrying about covering it up.
  ##
  ## if we ever start calling roll_buffers programmatically, we will
  ## have to change this. but it's not clear that we will ever actually
  ## do that.
  def roll_buffers
    bufs = rollable_buffers
    bufs.last.force_to_top = false
    raise_to_front bufs.first
  end

  def roll_buffers_backwards
    bufs = rollable_buffers
    return unless bufs.length > 1
    bufs.last.force_to_top = false
    raise_to_front bufs[bufs.length - 2]
  end

  def rollable_buffers
    @buffers.select { |b| !(b.system? || b.hidden?) || @buffers.last == b }
  end

  def handle_input c # called by bin/sup
    mev = c.mouseevent
    if mev
      buf = front_buffers.find { |b| (b.y <= mev.y && b.y + b.height > mev.y && b.x <= mev.x && b.x + b.width > mev.x) }
      if buf
        focus_on buf if @focus_buf != buf
        mev.y -= buf.y
        mev.x -= buf.x
        buf.mode.handle_mouse_event mev
      end
      true # bin/sup does not need to try anything else
    else
      if @focus_buf
        if @focus_buf.mode.in_search? && c != CONTINUE_IN_BUFFER_SEARCH_KEY
          @focus_buf.mode.cancel_search!
          @focus_buf.mark_dirty
        end
        @focus_buf.mode.handle_input c
      end
    end
  end

  def exists? n; @name_map.member? n; end
  def [] n; @name_map[n]; end
  def []= n, b
    raise ArgumentError, "duplicate buffer name" if b && @name_map.member?(n)
    raise ArgumentError, "title must be a string" unless n.is_a? String
    @name_map[n] = b
  end

  def completely_redraw_screen
    return if @shelled

    ## this magic makes Ncurses get the new size of the screen
    Ncurses.endwin
    Ncurses.stdscr.keypad 1
    Ncurses.curs_set 0
    Ncurses.refresh
    @sigwinch_mutex.synchronize { @sigwinch_happened = false }
    debug "new screen size is #{Ncurses.rows} x #{Ncurses.cols}"

    draw_screen :clear => true, :refresh => true, :dirty => true, :sync => true

    # don't know why but a second non-clear draw will resolve some blank screens
    draw_screen :clear => false, :refresh => true, :dirty => true, :sync => true
  end

  def draw_title
    return if @focus_buf.nil?
    @focus_buf.title_text.tap do |title|
      # http://rtfm.etla.org/xterm/ctlseq.html (see Operating System Controls)
      print "\033]0;#{title}\07" if title && @in_x && title != @last_title
      @last_title = title
    end
  end

  def draw_screen opts={}
    return if @shelled

    draw_title

    # resize minibuf
    LayoutManager.minibuf_height = minibuf_lines

    Ncurses.mutex.lock unless opts[:sync] == false

    Ncurses.clear if opts[:clear]

    ## disabling this for the time being, to help with debugging
    ## (currently we only have one buffer visible at a time).
    ## TODO: reenable this if we allow multiple buffers

    drawn_buffers = []

    ([@focus_buf].compact + @buffers.reverse).each do |buf|
      buf.update_window!
      next if drawn_buffers.any? {|rhs| buf.overlap_with? rhs}
      buf.mark_dirty if @dirty || opts[:dirty]
      buf.draw
      drawn_buffers << buf
    end

    draw_minibuf sync: false, refresh: true unless opts[:skip_minibuf]

    @dirty = false
    Ncurses.doupdate
    Ncurses.refresh if opts[:refresh]
    Ncurses.mutex.unlock unless opts[:sync] == false
  end

  ## if the named buffer already exists, pops it to the front without
  ## calling the block. otherwise, gets the mode from the block and
  ## creates a new buffer. returns two things: the buffer, and a boolean
  ## indicating whether it's a new buffer or not.
  def spawn_unless_exists title, opts={}
    new =
      if @name_map.member? title
        raise_to_front @name_map[title] unless opts[:hidden]
        false
      else
        mode = yield
        spawn title, mode, opts
        true
      end
    [@name_map[title], new]
  end

  def spawn title, mode, opts={}
    raise ArgumentError, "title must be a string" unless title.is_a? String
    realtitle = title
    num = 2
    while @name_map.member? realtitle
      realtitle = "#{title} <#{num}>"
      num += 1
    end

    # Buffer's window object is obtained from LayoutManager
    b = Buffer.new mode, :title => realtitle, :force_to_top => opts[:force_to_top], :system => opts[:system]
    mode.buffer = b
    @name_map[realtitle] = b

    @buffers.unshift b
    if opts[:hidden]
      focus_on b unless @focus_buf
    else
      raise_to_front b
    end
    b
  end

  ## requires the mode to have #done? and #value methods
  def spawn_modal title, mode, opts={}
    b = spawn title, mode, opts
    draw_screen

    until mode.done?
      c = Ncurses::CharCode.get
      next unless c.present? # getch timeout
      break if c.is_keycode? Ncurses::KEY_CANCEL
      begin
        mode.handle_input c
      rescue InputSequenceAborted # do nothing
      end
      draw_screen
      erase_flash
    end

    kill_buffer b
    mode.value
  end

  def kill_all_buffers_safely
    until @buffers.empty?
      ## inbox mode always claims it's unkillable. we'll ignore it.
      return false unless @buffers.last.mode.is_a?(InboxMode) || @buffers.last.mode.killable?
      kill_buffer @buffers.last
    end
    true
  end

  def kill_buffer_safely buf
    return false unless buf.mode.killable?
    kill_buffer buf
    true
  end

  def kill_all_buffers
    kill_buffer @buffers.first until @buffers.empty?
  end

  def kill_buffer buf
    raise ArgumentError, "buffer not on stack: #{buf}: #{buf.title.inspect}" unless @buffers.member? buf

    buf.mode.cleanup
    @buffers.delete buf
    @name_map.delete buf.title
    @focus_buf = nil if @focus_buf == buf
    if @buffers.empty?
      ## TODO: something intelligent here
      ## for now I will simply prohibit killing the inbox buffer.
    else
      raise_to_front @buffers.last
    end
  end

  ## ask* functions. these functions display a one-line text field with
  ## a prompt at the bottom of the screen. answers typed or choosen by
  ## tab-completion
  ##
  ## common arguments are:
  ##
  ## domain:      token used as key for @textfields, which seems to be a
  ##              dictionary of input field objects
  ## question:    string used as prompt
  ## completions: array of possible answers, that can be completed by using
  ##              the tab key
  ## default:     default value to return
  def ask_with_completions domain, question, completions, default=nil
    ask domain, question, default do |s|
      s.fix_encoding!
      completions.select { |x| x =~ /^#{Regexp::escape s}/iu }.map { |x| [x, x] }
    end
  end

  def ask_many_with_completions domain, question, completions, default=nil
    ask domain, question, default do |partial|
      prefix, target =
        case partial
        when /^\s*$/
          ["", ""]
        when /^(.*\s+)?(.*?)$/
          [$1 || "", $2]
        else
          raise "william screwed up completion: #{partial.inspect}"
        end

      prefix.fix_encoding!
      target.fix_encoding!
      completions.select { |x| x =~ /^#{Regexp::escape target}/iu }.map { |x| [prefix + x, x] }
    end
  end

  def ask_many_emails_with_completions domain, question, completions, default=nil
    ask domain, question, default do |partial|
      prefix, target = partial.split_on_commas_with_remainder
      target ||= prefix.pop || ""
      target.fix_encoding!

      prefix = prefix.join(", ") + (prefix.empty? ? "" : ", ")
      prefix.fix_encoding!

      completions.select { |x| x =~ /^#{Regexp::escape target}/iu }.sort_by { |c| [ContactManager.contact_for(c) ? 0 : 1, c] }.map { |x| [prefix + x, x] }
    end
  end

  def ask_for_filename domain, question, default=nil, allow_directory=false
    answer = ask domain, question, default do |s|
      if s =~ /(~([^\s\/]*))/ # twiddle directory expansion
        full = $1
        name = $2.empty? ? Etc.getlogin : $2
        dir = Etc.getpwnam(name).dir rescue nil
        if dir
          [[s.sub(full, dir), "~#{name}"]]
        else
          users.select { |u| u =~ /^#{Regexp::escape name}/u }.map do |u|
            [s.sub("~#{name}", "~#{u}"), "~#{u}"]
          end
        end
      else # regular filename completion
        Dir["#{s}*"].sort.map do |fn|
          suffix = File.directory?(fn) ? "/" : ""
          [fn + suffix, File.basename(fn) + suffix]
        end
      end
    end

    if answer
      answer =
        if answer.empty?
          spawn_modal "file browser", FileBrowserMode.new
        elsif File.directory?(answer) && !allow_directory
          spawn_modal "file browser", FileBrowserMode.new(answer)
        else
          File.expand_path answer
        end
    end

    answer
  end

  ## returns an array of labels
  def ask_for_labels domain, question, default_labels, forbidden_labels=[]
    default_labels = default_labels - forbidden_labels - LabelManager::RESERVED_LABELS
    default = default_labels.to_a.join(" ")
    default += " " unless default.empty?

    # here I would prefer to give more control and allow all_labels instead of
    # user_defined_labels only
    applyable_labels = (LabelManager.user_defined_labels - forbidden_labels).map { |l| LabelManager.string_for l }.sort_by { |s| s.downcase }

    answer = ask_many_with_completions domain, question, applyable_labels, default

    return unless answer

    user_labels = answer.to_set_of_symbols
    user_labels.each do |l|
      if forbidden_labels.include?(l) || LabelManager::RESERVED_LABELS.include?(l)
        BufferManager.flash "'#{l}' is a reserved label!"
        return
      end
    end
    user_labels
  end

  def ask_for_contacts domain, question, default_contacts=[]
    default = default_contacts.is_a?(String) ? default_contacts : default_contacts.map { |s| s.to_s }.join(", ")
    default += " " unless default.empty?

    recent = Index.load_contacts(AccountManager.user_emails, :num => 10).map { |c| [c.full_address, c.email] }
    contacts = ContactManager.contacts.map { |c| [ContactManager.alias_for(c), c.full_address, c.email] }

    completions = (recent + contacts).flatten.uniq
    completions += HookManager.run("extra-contact-addresses") || []

    answer = BufferManager.ask_many_emails_with_completions domain, question, completions, default

    if answer
      answer.split_on_commas.map { |x| ContactManager.contact_for(x) || Person.from_address(x) }
    end
  end

  def ask_for_account domain, question
    completions = AccountManager.user_emails
    answer = BufferManager.ask_many_emails_with_completions domain, question, completions, ""
    answer = AccountManager.default_account.email if answer == ""
    AccountManager.account_for Person.from_address(answer).email if answer
  end

  ## for simplicitly, we always place the question at the very bottom of the
  ## screen
  def ask domain, question, default=nil, &block
    raise "impossible!" if @asking
    raise "Question too long" if Ncurses.cols <= question.length
    @asking = true
    @question = question

    @textfields[domain] ||= TextField.new
    tf = @textfields[domain]
    completion_buf = nil

    w, top, left, height, width = LayoutManager['minibuf']
    Ncurses.sync do
      # draw_screen will update minibuf height
      @dirty = true # for some reason that blanks the whole fucking screen
      draw_screen :sync => false
      tf.activate w, top, left, height, width, question, default, &block
    end

    w.keypad 1
    while true
      c = Ncurses::CharCode.get(win: w)
      next unless c.present? # getch timeout
      break unless tf.handle_input c # process keystroke

      if tf.new_completions?
        kill_buffer completion_buf if completion_buf

        shorts = tf.completions.map { |full, short| short }
        prefix_len = shorts.shared_prefix(caseless=true).length

        mode = CompletionMode.new shorts, :header => "Possible completions for \"#{tf.value}\": ", :prefix_len => prefix_len
        completion_buf = spawn "<completions>", mode, :height => 10

        draw_screen :skip_minibuf => true
        tf.position_cursor
      elsif tf.roll_completions?
        completion_buf.mode.roll
        draw_screen :skip_minibuf => true
        tf.position_cursor
      end

      Ncurses.sync { w.refresh }
    end

    kill_buffer completion_buf if completion_buf

    @dirty = true
    @asking = false
    Ncurses.sync do
      tf.deactivate
      draw_screen :sync => false
    end
    tf.value.tap { |x| x }
  end

  def ask_getch question, accept=nil
    raise "impossible!" if @asking

    accept = accept.split(//).map { |x| x.ord } if accept

    @asking = true
    w, top, left, height, width = *LayoutManager['minibuf']
    Ncurses.sync do
      draw_screen :sync => false
      w.attrset Colormap.color_for(:text_color)
      w.mvaddstr 0, 0, question + ' ' * [(width - question.length), 0].max
      w.move 0, question.length + 1
      Ncurses.curs_set 1
      w.refresh
    end

    ret = nil
    done = false
    until done
      w.move 0, question.length + 1
      key = Ncurses::CharCode.get(win: w)
      next if key.empty?
      if key.is_keycode? Ncurses::KEY_CANCEL
        done = true
      elsif accept.nil? || accept.empty? || accept.member?(key.code)
        ret = key
        done = true
      end
    end

    @asking = false
    Ncurses.sync do
      Ncurses.curs_set 0
      draw_screen :sync => false
    end

    ret
  end

  ## returns true (y), false (n), or nil (ctrl-g / cancel)
  def ask_yes_or_no question
    case(r = ask_getch question, "ynYN")
    when ?y, ?Y
      true
    when nil
      nil
    else
      false
    end
  end

  ## turns an input keystroke into an action symbol. returns the action
  ## if found, nil if not found, and throws InputSequenceAborted if
  ## the user aborted a multi-key sequence. (Because each of those cases
  ## should be handled differently.)
  ##
  ## this is in BufferManager because multi-key sequences require prompting.
  def resolve_input_with_keymap c, keymap
    action, text = keymap.action_for c
    while action.is_a? Keymap # multi-key commands, prompt
      key = BufferManager.ask_getch text
      unless key # user canceled, abort
        erase_flash
        raise InputSequenceAborted
      end
      action, text = action.action_for(key) if action.has_key?(key)
    end
    action
  end

  def minibuf_lines
    @minibuf_mutex.synchronize do
      [(@flash ? 1 : 0) +
       @minibuf_stack.compact.size, 1].max
    end
  end

  def draw_minibuf opts={}
    lines = [*@flash]
    @minibuf_mutex.synchronize do
      lines += @minibuf_stack.compact.reverse
    end
    lines << '' if lines.empty?  # to clear it

    Ncurses.mutex.lock unless opts[:sync] == false

    w, top, left, height, width = *LayoutManager['minibuf']
    w.attrset Colormap.color_for(:text_color)
    lines.each.with_index do |s, i|
      next if i == 0 && @asking
      w.mvaddstr i, 0, s + (' ' * [width - s.length, 0].max)
    end
    w.refresh if opts[:refresh]

    Ncurses.mutex.unlock unless opts[:sync] == false
  end

  def say s, id=nil
    new_id = nil

    @minibuf_mutex.synchronize do
      new_id = id.nil?
      id ||= @minibuf_stack.length
      @minibuf_stack[id] = s
    end

    if new_id
      draw_screen :refresh => true
    else
      draw_minibuf :refresh => true
    end

    if block_given?
      begin
        yield id
      ensure
        clear id
      end
    end
    id
  end

  def erase_flash; @flash = nil; end

  def flash s
    @flash = s
    # there can be races that something needed to draw is gone, ie. @focus_buf becomes nil during kill_buffer
    draw_screen :refresh => true rescue nil
  end

  ## a little tricky because we can't just delete_at id because ids
  ## are relative (they're positions into the array).
  def clear id
    @minibuf_mutex.synchronize do
      @minibuf_stack[id] = nil
      if id == @minibuf_stack.length - 1
        id.downto(0) do |i|
          break if @minibuf_stack[i]
          @minibuf_stack.delete_at i
        end
      end
    end

    draw_screen :refresh => true
  end

  def shell_out command, is_gui=false
    debug "shell out #{command}"
    success = false
    if is_gui
      # no need to save and restore ncurses state
      success = system command
    else
      @shelled = true
      Ncurses.sync do
        Ncurses.endwin
        success = system command
        Ncurses.stdscr.keypad 1
        Ncurses.refresh
        Ncurses.curs_set 0
      end
      @shelled = false
    end
    success
  end

private

  def default_status_bar buf
    " [#{buf.mode.name}] #{buf.title}   #{buf.mode.status}"
  end

  def default_terminal_title buf
    "Sup #{Redwood::VERSION} :: #{buf.title}"
  end

  def users
    unless @users
      @users = []
      while(u = Etc.getpwent)
        @users << u.name
      end
    end
    @users
  end
end
end
