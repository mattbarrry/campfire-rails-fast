# index_messages_on_room_id_and_created_at already serves every lookup by room_id; the single-column
# index only costs every message insert.
class RemoveRedundantMessagesRoomIdIndex < ActiveRecord::Migration[8.2]
  def change
    remove_index :messages, :room_id, name: "index_messages_on_room_id"
  end
end
