module RawRequestBody
  extend ActiveSupport::Concern

  private

  def raw_request_body
    request.body.rewind
    request.body.read.force_encoding("UTF-8")
  ensure
    request.body.rewind
  end
end
