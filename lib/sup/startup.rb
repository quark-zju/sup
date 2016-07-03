# show a progress telling user what's going on

require 'thread'
require 'sup/logger'

module ::Redwood

class StartupManager

  def self.say new_msg
    return if disabled?
    if is_debug?
      if !new_msg.to_s.empty?
        if Logger.instance
          Logger.instance.debug new_msg
        else
          puts new_msg
        end
      end
      return
    end
    start
    # update what startup step current is
    # the thread will print it with spinner prefix thus do not print it here
    @message = new_msg
    print_message @message if @thread.nil?
  end

  def self.done
    @thread.kill if @thread
    message = ''
  end

  def self.start
    return if @started
    @started = true
    # do not start a thread if we are in debug mode or threads are disabled
    return if is_debug? || disabled? || !$opts || $opts[:no_threads]
    @thread = ::Thread.new do
      spin = '-\|/'
      count = 0
      loop do
        count += 1
        print_message "[#{spin[count % spin.size]}] #{@message}" if @message
        sleep 0.16
      end
    end
  end

  def self.stop
    # startup completes
    if @thread
      @thread.kill
      @thread.join
      @thread = nil
    end
    print_message ''
    @started = false
  end

  def self.disabled?
    !$config || !$config[:show_startup_progress]
  end

protected

  def self.is_debug?
    ENV['SUP_LOG_LEVEL'] == 'debug'
  end

  def self.print_message new_msg
    # print the message in the same line
    padding = ' ' * [@old_msg.to_s.size - new_msg.size, 0].max
    print "\r#{new_msg}#{padding}\r"
    @old_msg = new_msg
  end

end

end
