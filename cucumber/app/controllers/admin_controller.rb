require "Logger"
require "HotCalc"
require "BroadcastMatchWorker"

class AdminController < ApplicationController
  def start
    Resque.enqueue(LoggerJob)
    Resque.enqueue(HotCalcJob)
    Resque.enqueue(BroadcastMatchJob)
    Channel.all.each do |ch| 
      ch.online = false
      ch.save
    end 
    redirect_to root_path
  end
end

