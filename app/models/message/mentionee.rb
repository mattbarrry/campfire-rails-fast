module Message::Mentionee
  extend ActiveSupport::Concern

  def mentionees
    room.users.where(id: mentioned_users.map(&:id))
  end

  private
    def mentioned_users
      if body.body
        body.body.attachables.grep(User).uniq
      else
        []
      end
    end
end
