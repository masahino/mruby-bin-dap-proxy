class DapProxy
  def send_message(io, message)
    json_message = message.to_json
    envelope = "Content-Length: #{json_message.bytesize}\r\n\r\n#{json_message}"
    begin
      io.write envelope
      true
    rescue Errno::ESPIPE
      false
    end
  end

  def recv_message(io)
    headers = {}
    while (line = io.gets)
      break if line == "\r\n"

      k, v = line.chomp.split(':')
      headers[k] = v.to_i if k == 'Content-Length'
    end
    message = ''
    message = JSON.parse(io.read(headers['Content-Length'])) unless headers['Content-Length'].nil?

    [headers, message]
  end
end
