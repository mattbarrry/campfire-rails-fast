class UnreadRoomsChannel < ApplicationCable::Channel
  # Scoped per user, like ReadRoomsChannel. A single global stream would tell every
  # authenticated connection when any room on the account is active, including closed
  # rooms and direct conversations they're not part of.
  def self.stream_name_for(user_id)
    "user_#{user_id}_unreads"
  end

  def subscribed
    stream_from self.class.stream_name_for(current_user.id)
  end
end
