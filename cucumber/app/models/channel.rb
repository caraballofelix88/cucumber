class Channel < ActiveRecord::Base
  has_many :slices, dependent: :destroy
  
end
