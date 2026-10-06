# Fast path for posting a plain-text message: POST /rooms/:room_id/messages(.turbo_stream).
#
# Runs at the front of the middleware stack and does what MessagesController#create does for the
# common case, with as little Ruby as possible per post:
#
#   * the same gates: allowed browser, banned IP, session cookie, membership and Rails' own CSRF
#     check (fed the session's token directly, so the session middleware isn't needed); decoding a
#     given Cookie header always gives the same answer, so it's done once per header
#   * one lookup query (session, user, room, membership, ban) and one write transaction (message,
#     rich text, search index, room touch, unread markers, members), on cached prepared statements
#   * the same HTML, stamped from a template rendered from the real messages/_message partial (see
#     MessageStamp), and the same turbo stream, which is also exactly what the room broadcast sends
#   * the same side effects (room broadcast, unread fan-out, push job when Web Push is configured),
#     after the response has been written when the server supports it (Puma's rack.after_reply)
#
# Anything else -- attachments, bodies with markup/links/mentions, direct rooms (bot webhooks),
# bot keys, other formats, a session due for its activity refresh, a room the user can't reach --
# falls through to the regular stack untouched.
class FastPost
  PATH = %r{\A/rooms/(\d+)/messages(\.turbo_stream)?\z}
  PLAIN_BODY = /\A(?=.*\p{Alpha})[\p{Alnum} ]{1,1000}\z/
  TURBO_STREAM = "text/vnd.turbo-stream.html"

  def initialize(app)
    @app = app
    @credentials = Credentials.new
  end

  def call(env)
    if env["REQUEST_METHOD"] == "POST" && (match = PATH.match(env["PATH_INFO"]))
      post(env, match[1].to_i, match[2]) || @app.call(env)
    else
      @app.call(env)
    end
  end

  private
    def post(env, room_id, turbo_stream_extension)
      return unless turbo_stream_extension || env["HTTP_ACCEPT"].to_s.include?(TURBO_STREAM)

      request = ActionDispatch::Request.new(env)
      params = request.request_parameters["message"]
      return unless params.is_a?(Hash) && params.keys.all? { |key| key == "body" || key == "client_message_id" }
      return if request.params.key?("bot_key")
      body = params["body"].to_s.strip
      return unless body.match?(PLAIN_BODY)
      client_message_id = params["client_message_id"].presence || Random.uuid
      return unless client_message_id.match?(MessageStamp::SAFE_ID)

      return if browser_blocked?(request)
      session_token, csrf_token = @credentials.fetch(request)
      return unless session_token

      context = ActiveRecord::Base.with_connection { Context.lookup(it, session_token, room_id, request.remote_ip) }
      return unless context&.postable?
      return unless forgery_verified?(request, csrf_token)

      post =
        if GroupCommit.enabled?
          GroupCommit.instance.write(context, body, client_message_id)
        else
          ActiveRecord::Base.with_connection { Writer.new(context).write(it, body, client_message_id) }
        end
      html = MessageStamp.render(post, context, request)
      stream = %(<turbo-stream action="append" target="#{context.messages_target}"><template>#{html}</template></turbo-stream>)

      after_reply(env) { SideEffects.new(context, post, stream).run }
      [ 200, Response.headers, [ stream ] ]
    end

    def browser_blocked?(request)
      ActionController::AllowBrowser::BrowserBlocker.new(request, versions: AllowBrowser::VERSIONS).blocked?
    end

    # Rails' own checks (origin, then the masked token against the session's), via a controller
    # instance. Rails reads the session's token from the request env before going to the session
    # store, so it's put there. verified_request? itself can't be used: ahead of the session
    # middleware it sees no enabled session and treats protection as off.
    def forgery_verified?(request, csrf_token)
      return true unless ActionController::Base.allow_forgery_protection
      return false unless csrf_token

      request.set_header(ActionController::RequestForgeryProtection::CSRF_TOKEN, csrf_token)
      controller = MessagesController.new
      controller.set_request!(request)
      controller.send(:valid_request_origin?) && controller.send(:any_authenticity_token_valid?)
    end

    def after_reply(env, &block)
      if (after_reply = env["rack.after_reply"])
        after_reply << block
      else
        block.call
      end
    end

    module Response
      def self.headers
        @headers ||= {
          "content-type" => "#{TURBO_STREAM}; charset=utf-8",
          "x-version" => Rails.application.config.app_version.to_s,
          "x-rev" => Rails.application.config.git_revision.to_s,
          "cache-control" => "no-store"
        }.freeze
        @headers.dup
      end
    end

    # The session token (signed session_token cookie) and the CSRF token (in the encrypted Rails
    # session cookie) for a Cookie header, decoded once per distinct header.
    class Credentials
      MAX = 50_000

      def initialize
        @cache = {}
        @lock = Mutex.new
      end

      def fetch(request)
        cookie = request.get_header("HTTP_COOKIE") or return
        @lock.synchronize { @cache[cookie] } || decode(request, cookie)
      end

      private
        def decode(request, cookie)
          jar = request.cookie_jar
          session_token = jar.signed[:session_token] or return
          session = jar.signed_or_encrypted[Rails.application.config.session_options[:key]]
          credentials = [ session_token, (session["_csrf_token"] if session.is_a?(Hash)) ].freeze

          @lock.synchronize do
            @cache.clear if @cache.size >= MAX
            @cache[cookie] = credentials
          end
        end
    end

    # Prepared statements, kept per SQLite connection.
    module Statements
      def self.run(db, sql, *binds)
        statements = db.instance_variable_get(:@fast_post_statements) || db.instance_variable_set(:@fast_post_statements, {})
        (statements[sql] ||= db.prepare(sql)).execute(*binds).to_a
      end

      def self.value(row, key)
        row.is_a?(Hash) ? row.fetch(key) : row.first
      end
    end

    # Everything the request needs to know about the poster, the room and the client, in one query.
    class Context
      SQL = <<~SQL.squish
        SELECT sessions.last_active_at AS last_active_at, users.id AS user_id, users.name AS user_name,
               users.updated_at AS user_updated_at, rooms.id AS room_id, rooms.name AS room_name,
               rooms.type AS room_type, rooms.created_at AS room_created_at, rooms.updated_at AS room_updated_at,
               rooms.creator_id AS room_creator_id,
               (SELECT blob_id FROM active_storage_attachments
                 WHERE record_type = 'User' AND record_id = users.id AND name = 'avatar' LIMIT 1) AS avatar_blob_id,
               EXISTS (SELECT 1 FROM bans WHERE bans.ip_address = ?) AS banned
        FROM sessions
        JOIN users ON users.id = sessions.user_id
        JOIN memberships ON memberships.user_id = users.id AND memberships.room_id = ?
        JOIN rooms ON rooms.id = memberships.room_id
        WHERE sessions.token = ?
        LIMIT 1
      SQL

      ROOMS = Concurrent::Map.new # room id => [ messages target, broadcast stream name, unread payload ]

      attr_reader :user_id, :user_name, :user_updated_at, :room_id, :room_name, :room_type, :avatar_blob_id

      def self.lookup(connection, token, room_id, ip)
        row = Statements.run(connection.raw_connection, SQL, ip, room_id, token).first
        new(row.to_h) if row
      end

      def initialize(row)
        @row = row
        @user_id, @user_name, @user_updated_at = row.values_at("user_id", "user_name", "user_updated_at")
        @room_id, @room_name, @room_type = row.values_at("room_id", "room_name", "room_type")
        @avatar_blob_id = row["avatar_blob_id"]
      end

      # Not banned, not a direct room (those deliver bot webhooks), and a session that doesn't need
      # its hourly activity refresh (the regular stack does that).
      def postable?
        @row["banned"].to_i.zero? && room_type != "Rooms::Direct" &&
          Time.parse("#{@row["last_active_at"]} UTC") > Session::ACTIVITY_REFRESH_RATE.ago
      end

      def messages_target = room_strings[0]
      def messages_stream = room_strings[1]
      def unread_payload = room_strings[2]

      def user
        @user ||= User.find(user_id)
      end

      def room
        @room ||= Room.instantiate("id" => room_id, "name" => room_name, "type" => room_type,
          "created_at" => @row["room_created_at"], "updated_at" => @row["room_updated_at"], "creator_id" => @row["room_creator_id"])
      end

      private
        def room_strings
          ROOMS.compute_if_absent(room_id) do
            [ ActionView::RecordIdentifier.dom_id(room, :messages),
              Turbo::StreamsChannel.send(:stream_name_from, [ room, :messages ]),
              ActiveSupport::JSON.encode(roomId: room_id) ].map(&:freeze).freeze
          end
        end
    end

    # The new message's values, without an Active Record object (MessageStamp only needs these).
    Post = Struct.new(:id, :client_message_id, :created_at, :body, :member_ids)

    class Writer
      INSERT_MESSAGE = "INSERT INTO messages (client_message_id, created_at, creator_id, room_id, updated_at) VALUES (?, ?, ?, ?, ?) RETURNING id"
      INSERT_BODY = "INSERT INTO action_text_rich_texts (body, created_at, name, record_id, record_type, updated_at) VALUES (?, ?, 'body', ?, 'Message', ?)"
      TOUCH_ROOM = "UPDATE rooms SET updated_at = ? WHERE id = ?"
      INDEX = "INSERT INTO message_search_index(rowid, body) VALUES (?, ?)"
      # Room#unread_memberships: memberships.visible.disconnected.where.not(user: creator)
      UNREAD = <<~SQL.squish
        UPDATE memberships SET unread_at = ?, updated_at = ?
        WHERE room_id = ? AND involvement != 'invisible'
          AND (connected_at IS NULL OR connected_at < ?) AND user_id != ?
      SQL
      MEMBERS = "SELECT user_id FROM memberships WHERE room_id = ?"
      TIMESTAMP = "%Y-%m-%d %H:%M:%S.%6N"

      def initialize(context)
        @context = context
      end

      # Message#create plus Room#receive's unread markers, in one transaction (one write lock per
      # post, as the Rust port does), and the members the unread fan-out goes to.
      def write(connection, body, client_message_id)
        post = nil
        connection.transaction do
          connection.materialize_transactions
          post = write_rows(connection.raw_connection, body, client_message_id)
        end
        # Raw SQL bypasses Active Record's query cache invalidation.
        connection.clear_query_cache
        post
      end

      # The rows for one post, inside the caller's transaction.
      def write_rows(db, body, client_message_id)
        now = Time.now.utc.floor(6)
        stamp = now.strftime(TIMESTAMP)
        room_id, user_id = @context.room_id, @context.user_id

        id = Statements.value(Statements.run(db, INSERT_MESSAGE, client_message_id, stamp, user_id, room_id, stamp).first, "id")
        Statements.run(db, INSERT_BODY, body, stamp, id, stamp)
        Statements.run(db, TOUCH_ROOM, stamp, room_id)
        Statements.run(db, INDEX, id, body)
        Statements.run(db, UNREAD, stamp, stamp, room_id, (now - Membership::CONNECTION_TTL).strftime(TIMESTAMP), user_id)
        member_ids = Statements.run(db, MEMBERS, room_id).map { Statements.value(it, "user_id") }

        Post.new(id, client_message_id, now.in_time_zone, body, member_ids)
      end
    end

    # Group commit: one writer thread per process takes posts off a queue and writes whatever has
    # queued up in a single transaction, so concurrent posts share one write lock and one commit
    # instead of taking turns. Request threads wait on their own result (GVL released). A failed
    # batch is retried post by post, so one bad post can't fail the others.
    class GroupCommit
      MAX_BATCH = 64
      Job = Struct.new(:context, :body, :client_message_id, :result)

      def self.enabled? = @enabled ||= Rails.env.production? && ENV["FAST_POST_GROUP_COMMIT"] != "0"
      def self.instance = (@instances ||= {})[Process.pid] ||= new

      def initialize
        @queue = Thread::Queue.new
        @thread = Thread.new { run }
      end

      def write(context, body, client_message_id)
        job = Job.new(context, body, client_message_id, Thread::Queue.new)
        @queue << job
        result = job.result.pop
        result.is_a?(Exception) ? raise(result) : result
      end

      private
        def run
          loop do
            jobs = [ @queue.pop ]
            while jobs.size < MAX_BATCH && (job = @queue.pop(timeout: 0))
              jobs << job
            end
            commit(jobs)
          end
        end

        def commit(jobs)
          ActiveRecord::Base.with_connection do |connection|
            posts = nil
            connection.transaction do
              connection.materialize_transactions
              db = connection.raw_connection
              posts = jobs.map { Writer.new(it.context).write_rows(db, it.body, it.client_message_id) }
            end
            connection.clear_query_cache
            jobs.zip(posts) { |job, post| job.result << post }
          end
        rescue Exception => error
          if jobs.one?
            jobs.first.result << error
          else
            jobs.each { commit([ it ]) }
          end
        end
    end

    # What Message's after_create_commit (Room#receive) and MessagesController#create do after the
    # insert, in the same order: Message#broadcast_create (the room append, which is exactly the
    # response's turbo stream, then the unread fan-out) and the push job.
    class SideEffects
      def initialize(context, post, stream)
        @context, @post, @stream = context, post, stream
      end

      def run
        server = ActionCable.server
        BatchedCable.batch do
          server.broadcast @context.messages_stream, @stream
          @post.member_ids.each do |user_id|
            server.broadcast UnreadRoomsChannel.stream_name_for(user_id), @context.unread_payload, coder: nil
          end
        end

        if Rails.configuration.x.vapid.private_key.present?
          Rails.application.executor.wrap do
            message = Message.find(@post.id)
            message.room.send(:push_later, message)
          end
        end
      end
    end
end

# Renders a new plain-text message's HTML by filling in a template instead of running the
# messages/_message partial (about 1ms of ERB, helpers and sanitizing per message).
#
# The template comes from the partial itself: once per poster/room/host, a prototype message with
# sentinel id, client id, timestamp and body is rendered through the real partial, and the sentinels
# are cut out. The first real message stamped from each template is also rendered through the
# partial and compared byte for byte; a template that doesn't reproduce it is never used again. So
# the partial stays the only definition of the markup.
class MessageStamp
  SAFE_ID = /\A[\w-]{1,100}\z/
  PROTOTYPE_TIME = Time.utc(2001, 2, 3, 4, 5, 6, 789_000)

  Template = Struct.new(:parts, :state) # state: :unverified, :verified, :broken

  @templates = {}
  @lock = Mutex.new
  @sequence = 0

  class << self
    # post: id, client_message_id, created_at and a plain-text body (FastPost::PLAIN_BODY, so it
    # is its own HTML).
    def render(post, context, request)
      key = [ context.user_id, context.user_name, context.user_updated_at, context.avatar_blob_id,
              context.room_id, context.room_name, context.room_type, request.host_with_port, request.ssl? ]
      template = @lock.synchronize { @templates[key] }

      if template&.state == :verified
        stamp(template, post)
      else
        # First post for this template, or a template that can't be used: the Rails way, inside
        # the executor (connections, Current) since this runs ahead of the middleware stack.
        Rails.application.executor.wrap do
          template ||= build(key, context, request)
          template&.state == :unverified ? verify(template, post, request) : full_render(post, request)
        end
      end
    end

    def reset!
      @lock.synchronize { @templates.clear }
    end

    private
      def stamp(template, post)
        created_at = post.created_at
        values = {
          id: post.id.to_s,
          client_id: post.client_message_id,
          epoch: created_at.to_fs(:epoch).to_s,
          iso: created_at.iso8601,
          body: post.body
        }
        html = +""
        template.parts.each { |part| html << (part.is_a?(Symbol) ? values.fetch(part) : part) }
        html
      end

      def verify(template, post, request)
        expected = full_render(post, request).to_str
        template.state = stamp(template, post) == expected ? :verified : :broken
        Rails.logger.warn "MessageStamp: template doesn't reproduce messages/_message; using the partial" if template.state == :broken
        expected
      end

      def full_render(post, request)
        fresh = Message.with_presentation.find(post.id)
        Current.set(user: fresh.creator) { renderer(request).render(partial: "messages/message", locals: { message: fresh }) }
      end

      def build(key, context, request)
        n = @lock.synchronize { @sequence += 1 }
        id = 9_100_000_000_000 + n
        client_id = "fastpoststamp#{n}client"
        body = "zqxjfastpoststamp#{n}bodyzqxj"

        prototype = Message.instantiate("id" => id, "client_message_id" => client_id, "creator_id" => context.user_id,
          "room_id" => context.room_id, "created_at" => PROTOTYPE_TIME, "updated_at" => PROTOTYPE_TIME)
        prototype.association(:room).target = context.room
        prototype.association(:creator).target = context.user
        prototype.association(:rich_text_body).target =
          ActionText::RichText.instantiate("id" => nil, "name" => "body", "body" => body, "record_type" => "Message", "record_id" => id)

        html = Current.set(user: context.user) { renderer(request).render(partial: "messages/message", locals: { message: prototype }) }.to_str
        time = prototype.created_at
        parts = cut(html, { id.to_s => :id, client_id => :client_id, time.to_fs(:epoch).to_s => :epoch, time.iso8601 => :iso, body => :body })

        template = Template.new(parts, parts ? :unverified : :broken)
        @lock.synchronize { @templates[key] = template }
      rescue => error
        Rails.logger.warn "MessageStamp: couldn't build a template (#{error.class}: #{error.message})"
        nil
      end

      # Splits html on each sentinel; nil unless every sentinel occurs.
      def cut(html, sentinels)
        return unless sentinels.keys.all? { |sentinel| html.include?(sentinel) }

        pattern = Regexp.union(sentinels.keys.sort_by { -it.length })
        html.split(/(#{pattern})/).reject(&:empty?).map { |part| sentinels.fetch(part, part) }
      end

      def renderer(request)
        ApplicationController.renderer.new(http_host: request.host_with_port, https: request.ssl?, script_name: request.script_name)
      end
  end
end
