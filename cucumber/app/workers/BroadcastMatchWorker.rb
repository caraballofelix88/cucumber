require 'resque'
require 'json'
require 'curb'
require 'time'


#goes through all channels with "orphan" video slices, and checks channel videos for matching broadcast_ids
class BroadcastMatchJob
  @queue = :match_queue
  def self.perform
    while true do
      Channel.all.each do |ch|
        slice_list = ch.slices.select {|sl| sl.video_url.nil?}
        if !slice_list.nil?

          response = Curl.get("https://api.twitch.tv/kraken/channels/#{ch.title}/videos?broadcasts=true")

          response_data = JSON.parse(response.body)
          video_list = response_data['videos']

          video_list.each do |vid|
            slice_list.each do |sl|
              puts "#{vid['broadcast_id']}, #{sl.broadcast_id}"
              if vid['broadcast_id'] == sl.broadcast_id
                #determine time offset for link
                puts "Matched video: #{vid['title']}"
                time = DateTime.parse(sl.start_time) - DateTime.parse(vid['recorded_at'])

                sl.video_url = "#{vid['url']}?t=#{time.hours}h#{time.minutes}m#{time.seconds}s"
                sl.save
              end 
            end 
          end 
        end 
      end 

      puts "working..."
      sleep(300)
    end 
  end 
end 
