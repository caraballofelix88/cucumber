class MainController < ApplicationController
  def index
    @channels = Channel.all.select{|ch| ch.online}
    @slices = Slice.all
  end
end
