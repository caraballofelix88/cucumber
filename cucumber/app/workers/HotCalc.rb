require 'cinch'
require 'redis'
require 'json'
require 'curb'
require 'yaml'
require 'time'
require 'resque'

#TODO: complete slice generation procedure
class HotCalc
  
  def initialize
    @redis = Redis.new
    @hot_limit = 150 #is this high enough?
  end 


  def run()
    puts "HOT calcultion starting..."
    loop do
      #poll time should be made variable
      sleep(5)

      #checks redis for list of currently online channels, can be done more efficiently
      channel_list = @redis.smembers("channel_list")
      filtered_list = channel_list.select{ |ch| @redis.get("#{ch}:online") == "true"}

      filtered_list.each do |ch|
        print ch
        calculate_hot(ch)
        calculate_meter(ch)
      end 
    end 
  end 


  #calculates and stores HOT index, index avg
  def calculate_hot(ch)
    #redis schema names could use some switching around, maybe
    index = "#{ch}:hot_index"
    prev_index = "#{ch}:prev_hot_index"
    avg_index = "#{ch}:avg_hot"
    hot_poll_count = "#{ch}:hot_poll_count"

    if @redis.get(index).nil?
      @redis.set(index, 0)
    end 
    if @redis.get(prev_index).nil?
      @redis.set(prev_index, 0)
    end 
    if @redis.get(avg_index).nil?
      @redis.set(avg_index, 0)
    end 
    if @redis.get(hot_poll_count).nil?
      @redis.set(hot_poll_count, 0)
    end 

    curr_viewers = @redis.get("#{ch}:viewers_latest").to_f
    avg_viewers = @redis.get("#{ch}:avg_viewers").to_f
    msgs_per_second = @redis.get("#{ch}:mpp").to_f

    #hot formula (subject to change!)
    #plus ones avoid math trouble
    new_hot = 1.0 + ((curr_viewers/avg_viewers) || 1) * Math.log(1 + msgs_per_second * 2) # dunno if this conditional works the way i want
    @redis.set(prev_index, @redis.get(index))
    @redis.set(index, new_hot)

    #avg index
    avg_hot = @redis.get(avg_index).to_f
    poll_count = @redis.get(hot_poll_count).to_f
    new_avg = avg_hot + (new_hot - avg_hot)/(poll_count+1)
    @redis.set(avg_index, new_avg)
    @redis.incr(hot_poll_count)
  end 


  def calculate_meter(ch)

    if @redis.get("#{ch}:hot").nil?
      @redis.set("#{ch}:hot", false)
    end 
    if @redis.get("#{ch}:hot_meter").nil?
      @redis.set("#{ch}:hot_meter", 0)
    end 
    if @redis.get("#{ch}:peak_index").nil?
      @redis.set("#{ch}:peak_index", 0)
    end 

    is_hot = @redis.get("#{ch}:hot")
    meter = @redis.get("#{ch}:hot_meter").to_f
    avg_hot = @redis.get("#{ch}:avg_hot").to_f
    index = @redis.get("#{ch}:hot_index").to_f
    prev_index = @redis.get("#{ch}:prev_hot_index").to_f



    index_increase = (index - prev_index)
    if index_increase < 0
      index_increase = 0
    end 
    new_meter = meter + (index * (index_increase + 1))

    #might have to have 2 different decay rates, one stable, one for post HOT
    #peak_index and starttime only exist if channel is HOT
    if is_hot == "true"
      puts " -- HOT!"
      peak_index = @redis.get("#{ch}:peak_index").to_f
      if index > peak_index
        @redis.set("#{ch}:peak_index", index)
      end 
      start_time = Time.new(@redis.get("#{ch}:hot_starttime"))

      decay = 1 + (peak_index/index) * Math.log((Time.now - start_time) + 1)
    else 
      puts ""
      decay = avg_hot
    end 

    new_meter = new_meter - decay

    if new_meter < 0
      new_meter = 0

      if(is_hot == "true")
        @redis.set("#{ch}:hot", false)
        @redis.set("#{ch}:peak_index", 0)
        puts "#{ch} moment complete."
        #stop time and delegate slice generation here
        #TODO: make a new job class to compile slice chat statistics, and find out how to best wait for video upload, use broadcast_id
        new_sl = Slice.new do |sl|
          sl.channel_id = Channel.find_by_title(ch).id
          sl.broadcast_id = @redis.get("#{ch}:id")
          sl.start_time = @redis.get("#{ch}:hot_starttime")
          sl.end_time = Time.now
        end 
        new_sl.save
      end 
    end 

    if new_meter > @hot_limit && is_hot == "false"
      @redis.set("#{ch}:hot", true)
      @redis.set("#{ch}:hot_starttime", Time.now)
    end

    #assign new val
    @redis.set("#{ch}:hot_meter",new_meter)
  end 
end 

class HotCalcJob
  @queue = :calc_queue
  
  def self.perform()
    h = HotCalc.new
    h.run
  end 
end 



