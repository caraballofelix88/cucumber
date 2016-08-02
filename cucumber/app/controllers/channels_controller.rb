class ChannelsController < ApplicationController
  def new
  end

  def show
    @channel = Channel.find_by_title(params[:name]) or not_found
    @slices = @channel.slices
  end

  def index

  end

  def create
  end

  def destroy
  end

  def edit
  end
end
