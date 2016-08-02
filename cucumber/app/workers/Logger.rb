require 'cinch'
require 'redis'
require 'json'
require 'curb'
require 'yaml'
require 'time'
require 'resque'

class Logger
  attr_accessor :logged_channels
  attr_accessor :thread_list
  attr_accessor :channel_list
  attr_accessor :current_list
  attr_reader :nickname
  attr_reader :password
  attr_reader :api_key

  def initialize(thread_num = 25)
    @channel_list = Array.new    #list of channels requested from Twitch API
    @current_list = Array.new    #list of channels currently being monitored
    @thread_list = Array.new     #list of threads running
    @logged_channels = Set.new   #set of previously logged channels
    @thread_num = thread_num      #limit on thread_list size, ie. concurrent channels monitored

    #deets stuff
    deets = YAML.load(File.open("#{Rails.root.to_s}/config/deets.yml"))
    @nickname = deets["nickname"]
    @password = deets["password"]
    @api_key = deets["api_key"]

  end

  def populate_list
    @channel_list.clear
    response = Curl.get("https://api.twitch.tv/kraken/streams")

    #if response has a body, response format is invalid
    if response.body_str.include?("body")
      return
    end

    response_data = JSON.parse(response.body)
    response_data['streams'].each_index do |x|
      entry = response_data['streams'][x]['channel']['name']
      if !(@channel_list.include?(entry) || @current_list.include?(entry))
        @channel_list << entry
        
        if !(@logged_channels.include?(entry))
          @logged_channels << entry

          if Channel.find_by_title(entry).nil?
            new_ch = Channel.new do |nch|
              nch.title = entry
              nch.embed_url = "#{response_data['streams'][x]['channel']['url']}/embed"
            end 
            new_ch.save
          end 
        end 
      end 

      #dont go over thread limit
      if @channel_list.length >= @thread_num - @thread_list.length
        break
      end

    end
  end

  def spool_up
    populate_list()
    while @thread_list.length < @thread_num
      ch = @channel_list.shift
      @current_list << ch
      thread_init(ch)
    end
  end

  def thread_init(ch,poll_frequency = 3, nickname = @nickname, password = @password)
    t = Thread.new(ch) {|channel|
     #dunno what to do with these
      id = nil
      time_created = nil
      current_viewers = 0

      redis = Redis.new

      redis.sadd('channel_list', channel)
      if redis.get('msgcount').nil?
        redis.set('msgcount', 1)
      end 
      if redis.get("#{channel}:poll_count").nil?
        redis.set("#{channel}:poll_count", 1)
      end 
      if redis.get("#{channel}:avg_viewers").nil?
        redis.set("#{channel}:avg_viewers", 1)
      end 
      
      if redis.get("#{channel}:mppc").nil?
        redis.set("#{channel}:mppc", 0)
      end 
      if redis.get("#{channel}:mpp").nil?
        redis.set("#{channel}:mpp", 0)
      end 



      #cinch bot
      bot = Cinch::Bot.new do
        configure do |c|
          c.server = 'irc.twitch.tv'
          c.port = 6667
          c.nick = nickname
          c.password = password
          c.channels = ["##{channel}"]
        end 

        #hook triggered by message
        on :message do |m|

          #Some notes about posting to redis:
          #-Not sure how is best to format time, for now posix style
          #-Used to be a time based set, don't remember why -_-
          #-Stream-based entries might not be necessary, a
          #continuous sorted set per channel may be fine
          #-TODO: Establish expiration dates on messages and streams
          stream_id = "#{channel}:#{time_created.to_i}"
          message_time = m.time.to_i
          msgcount = redis.get('msgcount')
          msgquery = "msg:#{msgcount}"

          redis.multi do
            redis.incr("#{channel}:mppc")
            redis.zadd(stream_id, msgcount, message_time)
            redis.set(msgquery, {'time'=>m.time, 'user'=>m.user, 'message'=>m.message})
            redis.incr('msgcount')
          end 
        end 

        on :connect do |m| 
        end 
      end 


      bot_thread = Thread.new{}
      loop do
        #TODO find a neater way to handle curl requests
        response = Curl.get("https://api.twitch.tv/kraken/streams/#{channel}")
        
        if response.body_str.include?("body")
          puts "body body body"
          puts response.body
          next
        end

        response_data = JSON.parse(response.body)
        #If stream is still running
        if !(response_data['stream'].nil?)
          puts "#{channel} streaming..."

          if id.nil? 
            id = response_data['stream']['_id']
            redis.set("#{channel}:id", id)
          end 

          time_created ||= Time.iso8601(response_data['stream']['created_at'])
          current_viewers = response_data['stream']['viewers'].to_i

          #record current viewership, calculate average
          latest_key ||= "#{channel}:viewers_latest"
          avg_key ||= "#{channel}:avg_viewers"
          polls_key ||= "#{channel}:poll_count"

#          redis.multi do
          mpp = redis.get("#{channel}:mppc")
          puts "#{channel} number #{mpp}"
          redis.set("#{channel}:mppc", 0)
          redis.set("#{channel}:mpp", mpp)
 #         end 

          current_avg = redis.get(avg_key).to_f
          current_polls = redis.get(polls_key).to_f

          redis.set("#{channel}:online", true)

          redis.set(latest_key, current_viewers)
          new_avg = current_avg + (current_viewers - current_avg) / (current_polls + 1)
          redis.set(avg_key, new_avg)
          redis.incr(polls_key)

          #if the stream is running, but theres no thread
          if !(bot_thread.alive?)
            bot_thread = Thread.new { bot.start }
              puts "starting new bot thread"
          end 

        #in the event of response issues, try to end thread gracefully
        elsif response_data.nil?
          redis.set("#{channel}:online", false)
          @current_list.delete(channel)
          puts "response_data error"
          redis.quit
          bot_thread.kill
          self.kill
  
        
        #normal offline behavior
        else
          redis.set("#{channel}:online", false)
  
          if bot_thread.alive?
            @current_list.delete(channel)
            #redis.quit               will this connection close automatically?
            bot_thread.kill
            self.kill
          end 
        end 

        Channel.find_by_title(channel) do |c|
          c.online = redis.get("#{channel}:online");
          c.save
        end 
        sleep(poll_frequency)
      end 
    }
    @thread_list << t
  end 
end 

class LoggerJob
  @queue = :logger_queue
  def self.perform()
    log = Logger.new
    puts "Logger starting..."
    loop do
      log.thread_list.each.map { |t|
      if !(t.alive?)
        log.thread_list.delete(t)
      end 
      }
      log.spool_up

      sleep(5)
    end 
  end 
end




