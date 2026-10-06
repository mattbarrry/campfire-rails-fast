class WelcomeController < ApplicationController
  def show
    if Current.user.rooms.any?
      redirect_to room_url(last_room_visited)
    else
      render
    end
  end
end
