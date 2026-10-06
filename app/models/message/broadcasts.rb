module Message::Broadcasts
  def broadcast_create(html: nil, member_ids: nil)
    if html
      broadcast_append_to room, :messages, target: [ room, :messages ], html: html
    else
      broadcast_append_to room, :messages, target: [ room, :messages ]
    end
    broadcast_unread_room(member_ids)
  end

  def broadcast_remove
    broadcast_remove_to room, :messages
  end

  private
    # Fanned out to the room's members rather than published on one global stream, so
    # that the timing of activity in a room only reaches people who are in it.
    def broadcast_unread_room(member_ids = nil)
      payload = ActiveSupport::JSON.encode(roomId: room.id)

      (member_ids || room.memberships.pluck(:user_id)).each do |user_id|
        ActionCable.server.broadcast UnreadRoomsChannel.stream_name_for(user_id), payload, coder: nil
      end
    end
end
