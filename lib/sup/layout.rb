require 'ncursesw'
require 'sup/util'
require 'sup/buffer'

module ::Redwood

class SplitPolicy
  def initialize(id)
    raise "illegal id #{id}" unless [0, 1].include? id
    @id = id
  end

  def call
    # return [top, left, height, width]
    screen_height = Ncurses.rows - LayoutManager.minibuf_height
    screen_width = Ncurses.cols

    case $config[:split_view]
    when :vertical
      split = [screen_width * 2 / 3, screen_width / 5 - 80].max
      [0, split * @id, screen_height, split + (screen_width - 2 * split) * @id]
    else # :horizontal
      split = [[screen_height / 3, 10].max, screen_height * 2 / 3].min
      [split * @id, 0, split + (screen_height - 2 * split) * @id, screen_width]
    end
  end
end

class LayoutManager
  include Redwood::Singleton

  attr_accessor :minibuf_height

  def initialize
    @minibuf_height = 1
    @windows = {}
    @size_policies = {
      'full' => lambda { [ 0, 0, Ncurses.rows - LayoutManager.minibuf_height, Ncurses.cols] },
      'split1' => SplitPolicy.new(0),
      'split2' => SplitPolicy.new(1),
      # special window
      'minibuf' => lambda { [ Ncurses.rows - LayoutManager.minibuf_height, 0, LayoutManager.minibuf_height, Ncurses.cols] },
    }
  end

  def [] name
    # shortcut to find_or_create_window_by_name, return [win, top, left, height, width]
    find_or_create_window_by_name name
  end

  def find_window_by_mode mode
    name = if !should_split?
             'full'
           elsif mode.class.ancestors.any? {|x| x.name.include?('Index')}
             'split1'
           else
             'split2'
           end
    find_or_create_window_by_name name
  end

  def should_split?
    return false if !has_opened_message?
    case $config[:split_view]
    when nil, false
      false
    when :vertical
      Ncurses.cols >= ($config[:split_threshold] || 160)
    else # :horizontal
      Ncurses.rows >= ($config[:split_threshold] || 42)
    end
  end

  def has_opened_message?
    # has a buffer of edit-message-mode or thread-view-mode
    BufferManager.buffers.any? { |name, buf| buf.mode.class.ancestors.any? {|x| x.name[/(?:EditMessage|ThreadView)/]} }
  end

protected

  def find_or_create_window_by_name(name)
    top, left, height, width = @size_policies[name].call
    w = (@windows[name] ||= Ncurses::WINDOW.new(height, width, top, left)).tap do |w|
      # move and resize
      y = []; x = []; w.getbegyx(y, x)
      # the move may fail if resized
      need_move = top != y[0] || left != x[0]
      w.mvwin(top, left) if need_move
      y = []; x = []; w.getmaxyx(y, x)
      w.resize(height, width) if height + top != y[0] || width + left != x[0]
      # try a second move
      if need_move
        w.mvwin(top, left)
        # verify again
        y = []; x = []; w.getbegyx(y, x)
        raise 'cannot move window' if top != y[0] || left != x[0]
      end
    end
    [w, top, left, height, width]
  end

end

end
