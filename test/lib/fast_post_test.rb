require "test_helper"

class FastPostTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    sign_in :david
    @room = rooms(:watercooler)
    MessageStamp.reset!
  end

  test "plain text posts skip the controller" do
    controllers = []
    ActiveSupport::Notifications.subscribe("process_action.action_controller") { |event| controllers << event.payload[:controller] }

    assert_difference -> { Message.count }, +1 do
      post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "Fast one", client_message_id: "fast-1" } }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    message = Message.last
    assert_equal "Fast one", message.plain_text_body
    assert_equal users(:david), message.creator
    assert_equal "fast-1", message.client_message_id
    assert_includes Message.search("Fast").to_a, message
    assert_not_includes controllers, "MessagesController"
  end

  test "stamped html is byte for byte what the partial renders" do
    post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "First one", client_message_id: "fast-a" } }
    post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "Second one", client_message_id: "fast-b" } }

    templates = MessageStamp.instance_variable_get(:@templates).values
    assert_equal [ :verified ], templates.map(&:state)

    message = Message.with_presentation.find_by!(client_message_id: "fast-b")
    expected = Current.set(user: message.creator) do
      ApplicationController.renderer.new(http_host: "once.campfire.test", https: false).render(partial: "messages/message", locals: { message: message })
    end
    assert_includes response.body, expected
  end

  test "marks the room unread for other disconnected members" do
    membership = @room.memberships.visible.where.not(user: users(:david)).first
    membership.update_columns(unread_at: nil, connected_at: nil)

    post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "Unread now", client_message_id: "fast-u" } }

    assert_not_nil membership.reload.unread_at
  end

  test "posts the fast path can't do fall through to the controller" do
    assert_handled_by_controller do
      post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "<b>bold</b> https://example.com", client_message_id: "slow-1" } }
    end
    assert_response :success
  end

  test "direct rooms (bot webhooks) fall through to the controller" do
    room = users(:david).rooms.directs.first

    assert_handled_by_controller do
      post room_messages_url(room, format: :turbo_stream), params: { message: { body: "Hello", client_message_id: "slow-2" } }
    end
    assert_response :success
  end

  test "the room broadcast is exactly what Turbo's broadcast_append_to sends" do
    post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "Broadcast me", client_message_id: "fast-bc" } }

    message = Message.find_by!(client_message_id: "fast-bc")
    html = Current.set(user: message.creator) do
      ApplicationController.renderer.new(http_host: "once.campfire.test", https: false).render(partial: "messages/message", locals: { message: Message.with_presentation.find(message.id) })
    end
    expected = Turbo::StreamsChannel.turbo_stream_action_tag(:append, target: ActionView::RecordIdentifier.dom_id(@room, :messages), template: html)

    stream = Turbo::StreamsChannel.send(:stream_name_from, [ @room, :messages ])
    assert_includes broadcasts(stream).map { ActiveSupport::JSON.decode(it) }, expected.to_str
    assert_equal expected.to_str, response.body
  end

  test "with forgery protection on, a valid token posts and a bad one is rejected" do
    with_forgery_protection do
      get room_url(@room)
      token = css_select("meta[name=csrf-token]").first["content"]

      assert_difference -> { Message.count }, +1 do
        post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "With token", client_message_id: "csrf-ok" } },
          headers: { "X-CSRF-Token" => token }
      end
      assert_response :success

      assert_no_difference -> { Message.count } do
        assert_raises ActionController::InvalidAuthenticityToken do
          post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "Bad token", client_message_id: "csrf-bad" } },
            headers: { "X-CSRF-Token" => "not-the-token" }
        end
      end
    end
  end

  test "banned IPs fall through to the controller, which refuses them" do
    ban = Ban.new(user: users(:jason), ip_address: "203.0.113.9")
    ban.save!

    assert_no_difference -> { Message.count } do
      post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "Banned", client_message_id: "ban-1" } },
        env: { "REMOTE_ADDR" => "203.0.113.9" }
    end
    assert_response :too_many_requests
  end

  private
    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    def assert_handled_by_controller(&block)
      controllers = []
      callback = ->(event) { controllers << event.payload[:controller] }
      ActiveSupport::Notifications.subscribed(callback, "process_action.action_controller", &block)
      assert_includes controllers, "MessagesController"
    end
end
