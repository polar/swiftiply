begin
	load_attempted ||= false
	require 'swiftcore/swiftiplied_evented_mongrel'
rescue LoadError => e
	unless load_attempted
		load_attempted = true
		require 'rubygems'
		retry
	end
	raise e
end

class SimpleHandler < Mongrel::HttpHandler
	def process(request, response)
		response.start(200) do |head,out|
			head["Content-Type"] = "text/plain"
			out.write("hello!\n")
		end
	end
end

class ChunkedHandler < Mongrel::HttpHandler
  def process(request, response)
    response.status = 200
    response.header['Content-Type'] = "text/plain"
    response.send_status(nil)
    response.send_header
    response.write("0" * 1000)
    response.write("1" * 1000)
    response.write("2" * 1000)
    response.done=true
    response.finished
  end
end


httpserver = Mongrel::HttpServer.new("127.0.0.1", 29999)
httpserver.register("/hello", SimpleHandler.new)
httpserver.register("/chunked", ChunkedHandler.new)
httpserver.register("/dir", Mongrel::DirHandler.new("."))
httpserver.run.join
